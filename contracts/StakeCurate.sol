/**
 * @authors: [@greenlucid]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8.11;
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "./Cint32.sol";

/**
 * @title Stake Curate
 * @author Green
 * @notice Curate with indefinitely held, capital-efficient stake.
 * @dev The stakes of the items are handled here, but the items aren't stored here.
 * This dapp should be reviewed taking the subgraph role into account.
 */
contract StakeCurate is IArbitrable, IEvidence {

  enum Party { Staker, Challenger }
  enum DisputeState { Free, Used, Withdrawing }
  /// @dev Item may be free even if "Used"! Use itemIsFree view. (because of removingTimestamp)
  enum ItemSlotState { Free, Used, Disputed }

  /// @dev loses up to 1/128 gwei, used for Contribution amounts
  uint256 internal constant AMOUNT_BITSHIFT = 24;
  uint256 internal constant ACCOUNT_WITHDRAW_PERIOD = 604_800; // 1 week
  uint256 internal constant RULING_OPTIONS = 2;
  
  /**
   * @dev Amount of times the appeal cost must be contributed to advance to next round
   * With it being 4, it means there are economical incentives to contribute to a side
   * if the other side has received >20% of the total in contributions.
   * Stake Curate uses a prediction market to contribute, unlike previous versions of Curate.
   */
  uint256 internal constant SURPLUS_FACTOR = 4;

  /// @dev Some uint256 are lossily compressed into uint32 using Cint32.sol
  struct Account {
    address wallet;
    uint32 fullStake;
    uint32 lockedStake;
    uint32 withdrawingTimestamp; // frontrunning protection. overflows in 2106.
    // when this becomes a problem, shift bits around and use days instead of seconds, for example.
  }

  struct List {
    address governor;
    uint32 requiredStake;
    uint32 removalPeriod;
    uint32 arbitratorExtraDataId; // arbitratorExtraData cant mutate (because of risks during dispute)
    // review we can discuss to use uint64 instead, if uint32 was too vulnerable to spam attack
  }

  struct Item {
    uint64 accountId;
    uint64 listId;
    uint32 committedStake; // used for protection against governor changing stake amounts
    uint32 removingTimestamp; // frontrunning protection
    bool removing; // on failed dispute, will automatically reset removingTimestamp
    ItemSlotState slotState;
    uint32 submissionTimestamp; // only used to make evidenceGroupId
    uint16 freespace; // you could hold bounties here?
  }

  struct DisputeSlot {
    uint256 arbitratorDisputeId;
    // ----
    address challenger;
    uint64 itemSlot;
    DisputeState state;
    uint8 currentRound;
    uint64 nContributions; // ---- first 16 bits are in 2nd slot, last 48 bits in 3rd slot.
    uint64[2] pendingWithdraws; // pendingWithdraws[_party], used to set the disputeSlot free
    uint40 appealDeadline; // cache appealDeadline. saves gas or avoids cross-chain messaging.
    Party winningParty; // for withdrawals, set at rule()
    uint32 arbitratorExtraDataId; // make sure arbitratorExtraData doesn't change
  }

  // Contribution amounts are kept uint80 to have them compatible
  // with the Contribution system in SlotCurate.
  struct Contribution {
    uint8 round; // with exponential cost on appeal, uint8 is enough.
    uint8 contribdata; // first bit is withdrawn, second is party.
    uint80 amount;
    address contributor;
  }

  struct RoundContributions {
    uint80[2] partyTotal; // partyTotal[Party]
    uint32 appealCost; // compressed with cint32 format instead
    // this appealCost is always init to "1" to disallow the storage slot getting to zero
    uint64 contribCount; // used for unappealed rounds withdrawal
  }

  // ----- EVENTS -----

  event AccountCreated();
  event AccountFunded(uint64 _accountId, uint256 _fullStake);
  event AccountStartWithdraw(uint64 _accountId);
  event AccountWithdrawn(uint64 _accountId, uint256 _amount);

  event ArbitratorExtraDataCreated(bytes _arbitratorExtraData);

  event ListCreated(address _governor, uint32 _requiredStake, uint32 _removalPeriod,
    uint32 _arbitratorExtraDataId, string _ipfsUri);
  event ListUpdated(uint64 _listId, address _governor, uint32 _requiredStake,
    uint32 _removalPeriod, uint32 _arbitratorExtraDataId, string _ipfsUri);

  event ItemAdded(uint64 _itemSlot, uint64 _listId, uint64 _accountId, string _ipfsUri);
  event ItemStartRemoval(uint64 _itemSlot);
  event ItemStopRemoval(uint64 _itemSlot);
  // there's no need for "ItemRemoved", since it will automatically be considered removed after the period.
  event ItemRecommitted(uint64 _itemSlot);
  event ItemAdopted(uint64 _itemSlot, uint64 _adopterId);

  event ItemChallenged(uint64 _itemSlot, uint64 _disputeSlot);

  event NextRound(uint64 _disputeSlot);

  event DisputeSuccessful(uint64 _disputeSlot);
  event DisputeFailed(uint64 _disputeSlot);

  // technically this is -only- needed for calling withdrawAllContributions
  // so I may remove calls in other functions (rule and withdrawOneContribution)
  // it's like 750 gas called once per disputeSlot but it makes dev easier
  event FreedDisputeSlot(uint64 _disputeSlot);

  event Contribute(uint64 _disputeSlot, Party _party);
  event WithdrawnContribution(uint64 _disputeSlot, uint64 _contributionSlot);

  // ----- CONTRACT STORAGE -----

  // Note: This contract is vulnerable to deprecated arbitrator. Redeploying contract would mean that
  // everyone would have to manually withdraw their stake and submit all items again in the newer version.
  // only one arbitrator per contract. changing arbitrator requires redeployment
  IArbitrator internal immutable arbitrator;

  uint64 internal listCount;
  uint64 internal accountCount;
  /// @dev Using 32 bits to index arbitratorExtraDatas is susceptible to overflow spam
  /// Either increase bits or limit creating arbitratorExtraDatas to governor
  /// Increasing to 48 bits looks doable without much refactoring and keeping structs fit.
  uint32 internal arbitratorExtraDataCount;

  mapping(uint64 => Account) internal accounts;
  mapping(uint64 => List) internal lists;
  mapping(uint64 => Item) internal items;
  mapping(uint64 => DisputeSlot) internal disputes;
  // contributions[disputeSlot][n]
  mapping(uint64 => mapping(uint64 => Contribution)) internal contributions;
  // roundContributionsMap[disputeSlot][round]
  mapping(uint64 => mapping(uint8 => RoundContributions)) internal roundContributionsMap;
  mapping(uint256 => uint64) internal disputeIdToDisputeSlot;
  mapping(uint32 => bytes) internal arbitratorExtraDataMap;

  /** @dev Constructs the StakeCurate contract.
   *  @param _arbitrator The address of the arbitrator.
   *  @param _metaEvidence The IPFS uri of the metaEvidence to be used for a
   *  Please review this if you think using the same _metaEvidence for all disputes is not feasible.
   */
  constructor(
    address _arbitrator,
    string memory _metaEvidence
  ) {
    arbitrator = IArbitrator(_arbitrator);
    emit MetaEvidence(0, _metaEvidence);
  }

  // ----- PUBLIC FUNCTIONS -----

  /// @dev Creates an account and starts it with funds dependent on value
  function createAccount() external payable {
    Account storage account = accounts[accountCount++];
    account.wallet = msg.sender;
    account.fullStake = Cint32.compress(msg.value);
    emit AccountCreated();
  }

  /**
   * @dev Funds an existing account.
   * @param _accountId The id of the account to fund. Doesn't have to belong to sender.
   */
  function fundAccount(uint64 _accountId) external payable {
    Account storage account = accounts[_accountId];
    uint256 fullStake = Cint32.decompress(account.fullStake) + msg.value;
    account.fullStake = Cint32.compress(fullStake);
    emit AccountFunded(_accountId, fullStake);
  }

  /**
   * @dev Starts a withdrawal process on an account you own.
   * Withdrawals are not instant to prevent frontrunning.
   * @param _accountId The id of the account. Must belong to sender.
   */
  function startWithdrawAccount(uint64 _accountId) external {
    Account storage account = accounts[_accountId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    account.withdrawingTimestamp = uint32(block.timestamp);
    emit AccountStartWithdraw(_accountId);
  }

  /**
   * @dev Withdraws any amount on an account that finished the withdrawing process.
   * @param _accountId The id of the account. Must belong to sender.
   * @param _amount The amount to be withdrawn.
   */
  function withdrawAccount(uint64 _accountId, uint256 _amount) external {
    Account storage account = accounts[_accountId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    uint32 timestamp = account.withdrawingTimestamp;
    require(timestamp != 0, "Withdrawal didn't start");
    require(timestamp + ACCOUNT_WITHDRAW_PERIOD <= block.timestamp, "Withdraw period didn't pass");
    uint256 fullStake = Cint32.decompress(account.fullStake);
    uint256 lockedStake = Cint32.decompress(account.lockedStake);
    uint256 freeStake = fullStake - lockedStake;
    require(freeStake >= _amount, "You can't afford to withdraw that much");
    // Initiate withdrawal
    uint256 newStake = fullStake - _amount;
    account.fullStake = Cint32.compress(newStake);
    account.withdrawingTimestamp = 0;
    payable(account.wallet).send(_amount);
    emit AccountWithdrawn(_accountId, _amount);
  }

  /**
   * overflow estimate for optimistic rollup: 
   * 4294967296 * 3 * 32 * 3 * (100 / 1000000000) = 123.6k ETH
   * id_space * slots * bytes_per_slot * gas_per_calldata_byte * gas_price
   * that's an (estimated) ETH cost to overflow the arbitratorExtraDataId
   * at 100 calls per second, that's 1.38 years
   * for a stake curate deployed in mainnet:
   * 4294967296 * 26000 * (100 / 1000000000) = 11.16M ETH
   * time unknown.
  */

  /**
   * @dev Create arbitrator extra data. Will be assigned to an id.
   * @param _arbitratorExtraData The extra data
   */
  function createArbitratorExtraData(bytes calldata _arbitratorExtraData) external {
    arbitratorExtraDataMap[arbitratorExtraDataCount++] = _arbitratorExtraData;
    emit ArbitratorExtraDataCreated(_arbitratorExtraData);
  }

  /**
   * @dev Creates a list. They store all settings related to the dispute, stake, etc.
   * @param _governor The address of the governor.
   * @param _requiredStake The Cint32 version of the required stake per item.
   * @param _removalPeriod The amount of seconds an item needs to go through removal period to be removed.
   * @param _arbitratorExtraDataId Id of the internally stored arbitrator extra data
   * @param _ipfsUri IPFS uri that links to the policy for this list
   */
  function createList(
    address _governor,
    uint32 _requiredStake,
    uint32 _removalPeriod,
    uint32 _arbitratorExtraDataId,
    string calldata _ipfsUri
  ) external {
    List storage list = lists[listCount++];
    list.governor = _governor;
    list.requiredStake = _requiredStake;
    list.removalPeriod = _removalPeriod;
    list.arbitratorExtraDataId = _arbitratorExtraDataId;
    emit ListCreated(_governor, _requiredStake, _removalPeriod, _arbitratorExtraDataId, _ipfsUri);
  }

  /**
   * @dev Updates an existing list. Can only be called by its governor.
   * @param _listId Id of the list to be updated.
   * @param _governor Address of the new governor.
   * @param _requiredStake Cint32 version of the new required stake per item.
   * @param _removalPeriod Seconds until item is considered removed after starting removal.
   * @param _arbitratorExtraDataId Id of the new arbitrator extra data
   * @param _ipfsUri IPFS uri linking to the new policy.
   */
  function updateList(
    uint64 _listId,
    address _governor,
    uint32 _requiredStake,
    uint32 _removalPeriod,
    uint32 _arbitratorExtraDataId,
    string calldata _ipfsUri
  ) external {
    List storage list = lists[_listId];
    require(list.governor == msg.sender, "Only governor can update list");
    list.governor = _governor;
    list.requiredStake = _requiredStake;
    list.removalPeriod = _removalPeriod;
    list.arbitratorExtraDataId = _arbitratorExtraDataId;
    emit ListUpdated(_listId, _governor, _requiredStake, _removalPeriod, _arbitratorExtraDataId, _ipfsUri);
  }

  /**
   * @notice Adds an item in a slot.
   * @param _fromItemSlot Slot to look for a free itemSlot from.
   * @param _listId Id of the list the item will be included in
   * @param _accountId Id of the account owning the item.
   * @param _ipfsUri IPFS uri that links to the content of the item
   */
  function addItem(
    uint64 _fromItemSlot,
    uint64 _listId,
    uint64 _accountId,
    string calldata _ipfsUri
  ) external {
    uint64 itemSlot = firstFreeItemSlot(_fromItemSlot);
    Account memory account = accounts[_accountId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    Item storage item = items[itemSlot];
    List storage list = lists[_listId];
    uint32 compressedRequiredStake = list.requiredStake;
    uint256 freeStake = Cint32.decompress(account.fullStake) - Cint32.decompress(account.lockedStake);
    uint256 requiredStake = Cint32.decompress(compressedRequiredStake);
    require(freeStake >= requiredStake, "Not enough free stake");
    // Item can be submitted
    item.slotState = ItemSlotState.Used;
    item.committedStake = compressedRequiredStake;
    item.accountId = _accountId;
    item.listId = _listId;
    item.removingTimestamp = 0;
    item.removing = false;
    item.submissionTimestamp = uint32(block.timestamp);

    emit ItemAdded(itemSlot, _listId, _accountId, _ipfsUri);
  }

  /**
   * @dev Starts an item removal process.
   * @param _itemSlot Slot of the item to remove.
   */
  function startRemoveItem(uint64 _itemSlot) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    require(!item.removing, "Item is already being removed");
    require(item.slotState == ItemSlotState.Used, "ItemSlot must be Used");

    item.removingTimestamp = uint32(block.timestamp);
    item.removing = true;
    emit ItemStartRemoval(_itemSlot);
  }

  /**
   * @dev Cancels an ongoing removal process.
   * @param _itemSlot Slot of the item.
   */
  function cancelRemoveItem(uint64 _itemSlot) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    List memory list = lists[item.listId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    require(!itemIsFree(item, list), "ItemSlot must not be free"); // You can cancel removal while Disputed
    require(item.removing, "Item is not being removed");
    item.removingTimestamp = 0;
    item.removing = false;
    emit ItemStopRemoval(_itemSlot);
  }

  /**
   * @dev Adopts an item that's in adoption. This means, the ownership of the item is transferred
   * from previous account to this new account. This serves as protection for certain attacks.
   * @param _itemSlot Slot of the item to adopt.
   * @param _adopterId Id of an account belonging to adopter, that will be new owner.
   */
  function adoptItem(uint64 _itemSlot, uint64 _adopterId) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    Account memory adopter = accounts[_adopterId];
    List memory list = lists[item.listId];

    require(adopter.wallet == msg.sender, "Only adopter owner can adopt");
    require(item.slotState == ItemSlotState.Used, "Item slot must be Used");
    require(itemIsInAdoption(item, list, account), "Item is not in adoption");
    uint256 freeStake = Cint32.decompress(adopter.fullStake) - Cint32.decompress(adopter.lockedStake);
    require(Cint32.decompress(list.requiredStake) <= freeStake, "Cannot afford adopting this item");

    item.accountId = _adopterId;
    item.committedStake = list.requiredStake;
    item.removing = false;
    item.removingTimestamp = 0;

    emit ItemAdopted(_itemSlot, _adopterId);
  }

  /**
   * @dev Update committed amount of an item. Amounts are committed as a form of protection
   * for item submitters, to support updating list required amounts without potentially draining
   * users of their amounts.
   * @param _itemSlot Slot of the item to recommit.
   */
  function recommitItem(uint64 _itemSlot) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    List memory list = lists[item.listId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    require(!itemIsFree(item, list) && item.slotState == ItemSlotState.Used, "ItemSlot must be Used");
    require(!item.removing, "Item is being removed");
    
    uint256 freeStake = Cint32.decompress(account.fullStake) - Cint32.decompress(account.lockedStake);
    require(freeStake >= Cint32.decompress(list.requiredStake), "Not enough to recommit item");

    item.committedStake = list.requiredStake;

    emit ItemRecommitted(_itemSlot);
  }

  /**
   * @notice Challenge an item, with the intent of removing it and obtaining a reward.
   * @param _itemSlot Slot of the item to challenge.
   * @param _fromDisputeSlot DisputeSlot to start finding a place to store the dispute
   * @param _minAmount Frontrunning protection due to this edge case:
   * Submitter frontruns submitting a wrong item, and challenges himself to lock himself out of
   * funds, so that his free stake is lower than whatever he has committed or is the requirement
   * of the list. Possibly unneeded in OR. Also, it doesn't protect fully anyway, since submitter
   * could challenge himself out of 99% of his funds. I'm open to remove it.
   * @param _reason IPFS uri containing the evidence for the challenge.
   */
  function challengeItem(
    uint64 _itemSlot,
    uint64 _fromDisputeSlot,
    uint256 _minAmount,
    string calldata _reason
  ) external payable {
    Item storage item = items[_itemSlot];
    List memory list = lists[item.listId];
    Account storage account = accounts[item.accountId];
    
    require(itemCanBeChallenged(item, list), "Item cannot be challenged");
    uint256 freeStake = Cint32.decompress(account.fullStake) - Cint32.decompress(account.lockedStake);
    require(_minAmount <= freeStake, "Not enough free stake to satisfy minAmount");

    // All requirements met, begin
    uint256 comittedAmount = Cint32.decompress(list.requiredStake) <= freeStake
      ? Cint32.decompress(list.requiredStake)
      : freeStake
    ;
    uint64 disputeSlot = firstFreeDisputeSlot(_fromDisputeSlot);

    bytes memory arbitratorExtraData = arbitratorExtraDataMap[list.arbitratorExtraDataId];
    uint256 arbitratorDisputeId = arbitrator.createDispute{value: msg.value}(RULING_OPTIONS, arbitratorExtraData);
    disputeIdToDisputeSlot[arbitratorDisputeId] = disputeSlot;

    item.slotState = ItemSlotState.Disputed;
    // should item stop being removed? this opens a (costly?) dispute spam attack that disallows removing item.
    // if you don't stop the removal, the opposite happens. submitter can make dofus disputes until making the removal period
    item.removingTimestamp = 0;
    item.committedStake = Cint32.compress(comittedAmount);
    account.lockedStake = Cint32.compress(Cint32.decompress(account.lockedStake) + comittedAmount);

    disputes[disputeSlot] = DisputeSlot({
      arbitratorDisputeId: arbitratorDisputeId,
      itemSlot: _itemSlot,
      challenger: msg.sender,
      state: DisputeState.Used,
      currentRound: 0,

      nContributions: 0,
      pendingWithdraws: [uint64(0), uint64(0)],
      appealDeadline: 0,
      winningParty: Party.Staker, // don't worry it'll be overriden later
      arbitratorExtraDataId: list.arbitratorExtraDataId
    });

    roundContributionsMap[disputeSlot][1] = RoundContributions({
      contribCount: 0,
      appealCost: 1, // never let the slot go to zero
      partyTotal: [uint80(0), uint80(0)]
    });

    emit ItemChallenged(_itemSlot, disputeSlot);
    // ERC 1497
    // evidenceGroupId is obtained from the (itemSlot, submissionTimestamp) pair
    uint256 evidenceGroupId = uint256(keccak256(abi.encodePacked(_itemSlot, item.submissionTimestamp)));
    // metaEvidenceId is just 0 (afaik, it should be enough to have the same metaEvidence for all items?)
    emit Dispute(arbitrator, arbitratorDisputeId, 0, evidenceGroupId);
    emit Evidence(arbitrator, evidenceGroupId, msg.sender, _reason);
  }

  /**
   * @dev Submits evidence to potentially any dispute or item.
   * @param _evidenceGroupId Id to identify the dispute or item to submit evidence for.
   * @param _evidence IPFS uri linking to the evidence.
   */
  function submitEvidence(uint256 _evidenceGroupId, string calldata _evidence) external {
    // you can just submit evidence directly to any _evidenceGroupId
    // alternatively, could be (itemSlot, submissionTimestamp) pair 
    emit Evidence(arbitrator, _evidenceGroupId, msg.sender, _evidence);
  }

  /**
   * @notice Makes a contribution towards the appeal of one of the sides of a dispute.
   * @dev In order to contribute, the appealDeadline must not have passed.
   * @param _disputeSlot DisputeSlot containing the Dispute to contribute in.
   * @param _party Party to support in this appeal. This decides if there's a reward.
   */
  function contribute(uint64 _disputeSlot, Party _party) public payable {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Used, "DisputeSlot has to be used");

    _verifyUnderAppealDeadline(dispute);

    dispute.pendingWithdraws[uint256(_party)]++;
    // compress amount, possibly losing up to 1/128 gwei. they will be burnt.
    uint80 amount = contribCompress(msg.value);
    uint8 nextRound = dispute.currentRound + 1;
    RoundContributions storage roundContributions = roundContributionsMap[_disputeSlot][nextRound];
    roundContributions.partyTotal[uint256(_party)] += amount;
    roundContributions.contribCount++;
    // pendingWithdrawal = true, it's the first bit. party = _party is the second bit.
    uint8 contribdata = 128 + uint8(_party) * 64;
    Contribution storage contribution = contributions[_disputeSlot][dispute.nContributions++];
    contribution.round = nextRound;
    contribution.contribdata = contribdata;
    contribution.contributor = msg.sender;
    contribution.amount = amount;
    
    emit Contribute(_disputeSlot, _party);
  }

  /**
   * @dev Executes an appeal and gets a dispute in appeal phase to the next round.
   * Logic is separate from contribute in order to save gas. If this isn't called before
   * appeal deadline, the Dispute won't be appealed at all, even if it was fully funded.
   * @param _disputeSlot DisputeSlot to get to the next round.
   */
  function startNextRound(uint64 _disputeSlot) external {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    uint8 nextRound = dispute.currentRound + 1;
    Item storage item = items[dispute.itemSlot];
    List memory list = lists[item.listId];
    require(dispute.state == DisputeState.Used, "Dispute must be Used");

    _verifyUnderAppealDeadline(dispute);
    bytes memory arbitratorExtraData = arbitratorExtraDataMap[list.arbitratorExtraDataId];
    uint256 appealCost = arbitrator.appealCost(dispute.arbitratorDisputeId, arbitratorExtraData);
    uint256 totalAmountNeeded = (appealCost * SURPLUS_FACTOR);

    uint256 currentAmount = contribDecompress(
      roundContributionsMap[_disputeSlot][nextRound].partyTotal[0]
      + roundContributionsMap[_disputeSlot][nextRound].partyTotal[1]
    );
    require(currentAmount >= totalAmountNeeded, "Not enough to fund round");
    // All clear, let's appeal
    arbitrator.appeal{value: appealCost}(dispute.arbitratorDisputeId, arbitratorExtraData);
    /** Cint32 compression is lossy, rounded down. This could be a hazard if an exploiter finds a way
     * to slowly drain <1/2**24 portions of the appealCost. It could be possible, since the contributions
     * use a different compression scheme. And appealCost is there to lower the reward to compensate for the cost
     * so having it lower than intended may open up the chance for draining.
     * Possible solutions: use same compression scheme everywhere, or round appealCost up.
     */
    roundContributionsMap[_disputeSlot][nextRound].appealCost = Cint32.compress(appealCost);

    dispute.currentRound++;

    RoundContributions storage roundContributions = roundContributionsMap[_disputeSlot][nextRound + 1];
    roundContributions.appealCost = 1; // never let the slot go to zero
    roundContributions.partyTotal[0] = 0;
    roundContributions.partyTotal[1] = 0;
    roundContributions.contribCount = 0;

    emit NextRound(_disputeSlot);
  }

  /**
   * @dev External function for the arbitrator to decide the result of a dispute. TRUSTED
   * Arbitrator is trusted to:
   * a. call this only once, after dispute is final.
   * b. not call this to an unmapped _disputeId (since it would affect disputeSlot 0)
   * @param _disputeId External id of the dispute
   * @param _ruling Ruling of the dispute. If 0 or 1, submitter wins. Else (2) challenger wins
   */
  function rule(uint256 _disputeId, uint256 _ruling) external override {
    require(msg.sender == address(arbitrator), "Only arbitrator can rule");
    // 1. get slot from dispute
    uint64 disputeSlot = disputeIdToDisputeSlot[_disputeId];
    DisputeSlot storage dispute = disputes[disputeSlot];
    Item storage item = items[dispute.itemSlot];
    Account storage account = accounts[item.accountId];
    // 2. make sure that dispute has an ongoing dispute
    require(dispute.state == DisputeState.Used, "Can only be executed if Used");
    // 3. apply ruling. what to do when refuse to arbitrate?
    // just default towards keeping the item.
    // 0 refuse, 1 staker, 2 challenger.
    if (_ruling == 1 || _ruling == 0) {
      // staker won.
      emit DisputeFailed(disputeSlot);
      dispute.winningParty = Party.Staker;
      // 4a. return item to used, not disputed.
      if (item.removing) {
        item.removingTimestamp = uint32(block.timestamp);
      }
      item.slotState = ItemSlotState.Used;
      // free the locked stake
      uint256 lockedAmount = Cint32.decompress(account.lockedStake);
      uint256 updatedLockedAmount = lockedAmount - Cint32.decompress(item.committedStake);
      account.lockedStake = Cint32.compress(updatedLockedAmount);
    } else {
      // challenger won. emit disputeslot to update the status to Withdrawing in the subgraph
      emit DisputeSuccessful(disputeSlot);
      dispute.winningParty = Party.Challenger;
      // 4b. slot is now Free
      item.slotState = ItemSlotState.Free;
      // now, award the commited stake to challenger
      uint256 amount = Cint32.decompress(item.committedStake);
      // remove amount from the account
      account.fullStake = Cint32.compress(Cint32.decompress(account.fullStake) - amount);
      account.lockedStake = Cint32.compress(Cint32.decompress(account.lockedStake) - amount);
      // is it dangerous to send before the end of the function? please answer on audit
      payable(dispute.challenger).send(amount);
    }

    if (dispute.pendingWithdraws[uint256(dispute.winningParty)] == 0) {
      dispute.state = DisputeState.Free;
      emit FreedDisputeSlot(disputeSlot); // technically, subgraph doesn't need this
      // but it makes for easier testing and subgraph mapping
    } else {
      dispute.state = DisputeState.Withdrawing;
    }
    emit Ruling(arbitrator, _disputeId, _ruling);
  }

  /**
   * @dev Withdraws a contribution either eligible for reward or belonging to an unappealed round
   * @param _disputeSlot Dispute slot containing the contribution
   * @param _contributionSlot Contribution slot to withdraw
   */
  function withdrawOneContribution(uint64 _disputeSlot, uint64 _contributionSlot) public {
    // check if dispute is used.
    DisputeSlot storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Withdrawing, "DisputeSlot must be in withdraw");
    require(dispute.nContributions > _contributionSlot, "DisputeSlot lacks that contrib");

    Contribution storage contribution = contributions[_disputeSlot][_contributionSlot];
    (bool pendingWithdrawal, Party party) = contribdataToParams(contribution.contribdata);

    require(pendingWithdrawal, "Contribution withdrawn already");

    // okay, all checked. let's get the contribution.

    RoundContributions memory roundContributions = roundContributionsMap[_disputeSlot][contribution.round];
    Party winningParty = dispute.winningParty;
    // Contrib "round" starts at 1, while dispute starts at 0.
    if (contribution.round != dispute.currentRound + 1) {      
      // then this is a contribution from an appealed round.
      // only winner party can withdraw.
      require(party == winningParty, "That side lost the dispute");
      dispute.pendingWithdraws[uint256(winningParty)]--;
      // set contribution as withdrawn. party doesn't matter, so it's chosen as Party.Requester
      // (pendingWithdrawal = false, party = Party.Requester) => paramsToContribution(false, Party.Requester) = 0
      contribution.contribdata = 0;
      _withdrawSingleReward(contribution, roundContributions, party);
    } else {
      // this is a contrib from a round that didnt get appealed.
      // just refund the same amount
      uint256 refund = contribDecompress(contribution.amount);
      roundContributionsMap[_disputeSlot][contribution.round].contribCount--;
      if (winningParty == party) dispute.pendingWithdraws[uint256(winningParty)]--;
      contribution.contribdata = 0;
      // is it safe to send here?
      payable(contribution.contributor).send(refund);
    }

    if (dispute.pendingWithdraws[uint256(winningParty)] == 0
        && roundContributionsMap[_disputeSlot][dispute.currentRound + 1].contribCount == 0
    ) {
      /// @dev I'm ignoring a potential gas save because it makes logic simpler
      dispute.state = DisputeState.Free;
      emit WithdrawnContribution(_disputeSlot, _contributionSlot);
      emit FreedDisputeSlot(_disputeSlot);
    } else {
      emit WithdrawnContribution(_disputeSlot, _contributionSlot);
    }
  }

  /**
   * @dev Withdraws all contributions. Cheaper than doing so individually, because you save the
   * 21k gas overhead and you don't need to keep track of withdrawn flags, except freeing the disputeSlot
   * at the end. It's a public good.
   * @param _disputeSlot Dispute to withdraw all contributions from.
   */
  function withdrawAllContributions(uint64 _disputeSlot) public {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Withdrawing, "Dispute must be in withdraw");

    Party winningParty = dispute.winningParty;
    // this is due to how contribdata is encoded. the variable name is self-explanatory.
    uint8 pendingAndWinnerContribdata = 128 + 64 * uint8(winningParty);

    // there are two types of contribs that are handled differently:
    // 1. the contributions of appealed rounds.
    uint64 contribSlot = 0;
    uint8 currentRound = 1;
    RoundContributions memory roundContributions = roundContributionsMap[_disputeSlot][currentRound];
    while (contribSlot < dispute.nContributions) {
      Contribution memory contribution = contributions[_disputeSlot][contribSlot];
      // update the round
      if (contribution.round != currentRound) {
        roundContributions = roundContributionsMap[_disputeSlot][contribution.round];
        currentRound = contribution.round;
      }

      if (currentRound > dispute.currentRound) break; // see next loop.

      if (contribution.contribdata == pendingAndWinnerContribdata) {
        _withdrawSingleReward(contribution, roundContributions, winningParty);
      }
      contribSlot++;
    }

    // 2. the contributions of the last, unappealed round.
    while (contribSlot < dispute.nContributions) {
      // refund every transaction
      Contribution memory contribution = contributions[_disputeSlot][contribSlot];
      uint256 refund = contribDecompress(contribution.amount);
      payable(contribution.contributor).send(refund);
      contribSlot++;
    }
    // afterwards, set the dispute slot Free.
    dispute.state = DisputeState.Free;
    emit FreedDisputeSlot(_disputeSlot);
  }

  // ----- PRIVATE FUNCTIONS -----
  function _verifyUnderAppealDeadline(DisputeSlot storage _dispute) private {
    if (block.timestamp >= _dispute.appealDeadline) {
      // you're over it. get updated appealPeriod
      (, uint256 end) = arbitrator.appealPeriod(_dispute.arbitratorDisputeId);
      require(block.timestamp < end, "Over submision period");
      _dispute.appealDeadline = uint40(end);
    }
  }

  function _withdrawSingleReward(
    Contribution memory _contribution,
    RoundContributions memory _roundContributions,
    Party _winningParty
  ) private {
    uint256 spoils = contribDecompress(
      _roundContributions.partyTotal[0]
      + _roundContributions.partyTotal[1]
    ) - Cint32.decompress(_roundContributions.appealCost);
    uint256 share = (spoils * uint256(_contribution.amount)) / uint256(_roundContributions.partyTotal[uint256(_winningParty)]);
    // should use transfer instead? if transfer fails, then disputeSlot will stay in DisputeState.Withdrawing
    // if a transaction reverts due to not enough gas, does the send() ether remain sent? if that's so,
    // it would break withdrawAllContributions as currently designed,
    // and for single withdraws, then sending the ether will have to be the very last thing that occurs
    // after all the flags have been modified.
    payable(_contribution.contributor).send(share);
  }

  // ----- VIEW FUNCTIONS -----
  function firstFreeDisputeSlot(uint64 _fromSlot) internal view returns (uint64) {
    uint64 i = _fromSlot;
    while (disputes[i].state != DisputeState.Free) {
      i++;
    }
    return i;
  }

  function firstFreeItemSlot(uint64 _fromSlot) internal view returns (uint64) {
    uint64 i = _fromSlot;
    Item memory item = items[i];
    List memory list = lists[item.listId];
    while (!itemIsFree(item, list)) {
      i++;
      item = items[i];
      list = lists[item.listId];
    }
    return(i);
  }

  function itemIsFree(Item memory _item, List memory _list) internal view returns (bool) {
    bool notInUse = _item.slotState == ItemSlotState.Free;
    bool removed = _item.removing && _item.removingTimestamp + _list.removalPeriod <= block.timestamp;
    return (notInUse || removed);
  }

  function itemCanBeChallenged(Item memory _item, List memory _list) internal view returns (bool) {
    bool free = itemIsFree(_item, _list);

    // the item must have same or more committed amount than required for list
    bool enoughCommitted = Cint32.decompress(_item.committedStake) >= Cint32.decompress(_list.requiredStake);
    return (!free && _item.slotState == ItemSlotState.Used && enoughCommitted);
  }

  // ----- PURE FUNCTIONS -----

  function contribCompress(uint256 _amount) internal pure returns (uint80) {
    return (uint80(_amount >> AMOUNT_BITSHIFT));
  }

  function contribDecompress(uint80 _compressedAmount) internal pure returns (uint256) {
    return (uint256(_compressedAmount) << AMOUNT_BITSHIFT);
  }

  function contribdataToParams(uint8 _contribdata) internal pure returns (bool, Party) {
    uint8 pendingWithdrawalAddend = _contribdata & 128;
    bool pendingWithdrawal = pendingWithdrawalAddend != 0;
    uint8 partyAddend = _contribdata & 64;
    Party party = Party(partyAddend >> 6);
    return (pendingWithdrawal, party);
  }

  function itemIsInAdoption(Item memory _item, List memory _list, Account memory _account) internal pure returns (bool) {
    // check if any of the 4 conditions for adoption is met:
    bool beingRemoved = _item.removing;
    bool accountWithdrawing = _account.withdrawingTimestamp != 0;
    bool committedUnderRequired = Cint32.decompress(_item.committedStake) < Cint32.decompress(_list.requiredStake);
    uint256 freeStake = Cint32.decompress(_account.fullStake) - Cint32.decompress(_account.lockedStake);
    bool notEnoughFreeStake = freeStake < Cint32.decompress(_list.requiredStake);
    return (beingRemoved || accountWithdrawing || committedUnderRequired || notEnoughFreeStake);
  }
}