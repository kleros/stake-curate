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

/**
 * @title Stake Curate
 * @author Green
 * @dev Curate with indefinitely held, capital-efficient stake.
 */
contract StakeCurate is IArbitrable, IEvidence {

  enum Party { Staker, Challenger }
  enum DisputeState { Free, Used, Withdrawing }
  // Item may be free even if "Used"! Use itemIsFree view. (because of removingTimestamp)
  enum ItemSlotState { Free, Used, Disputed }

  // loses up to 4 gwei, used for Contribution amounts
  uint256 internal constant AMOUNT_BITSHIFT = 32;
  uint256 internal constant ACCOUNT_WITHDRAW_PERIOD = 604_800; // 1 week
  uint256 internal constant RULING_OPTIONS = 2;
  
  // In Slot Curate I let people set their custom multipliers,
  // this is, the amount of extra contribution that must be done
  // in order for an appeal to happen. There must be surplus to
  // intentivize contributors to appeal what they think is right.
  // Here I just hardcoded this ratio, but setting it custom is straightforward.
  uint256 internal constant MULTIPLIER = 2;

  // Some uint256 are lossily compressed into uint32 using Cint32.sol
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
    // we can discuss to use uint64 instead, if uint32 was too vulnerable to spam attack
  }

  struct Item {
    uint64 accountId;
    uint64 listId;
    uint32 commitedStake; // used for protection against governor changing stake amounts
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
    uint80 appealCost;
    uint16 filler; // to make sure the storage slot never goes back to zero, set it to 1 on discovery.
  }

  /**
    * Unlike Slot Curate, I'm just going to concern myself with
    * it being easy to develop. No shenanigans like compressing Event params,
    * or validating input in the subgraph. I rather have it "clean".
    * The two slot-related functions that can have their slots frontrun, both have
    * forcibly the frontrun protection on, to keep it DRY.

    * Have events for all possible interactions, and enough info in the events so that
    * subgraph can figure everything out. e.g. think ahead, like for L2s
   */

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

  event ItemChallenged(uint64 _itemSlot, uint64 _disputeSlot);

  event NextRound(uint64 _disputeSlot);

  event DisputeSuccessful(uint64 _disputeSlot);
  event DisputeFailed(uint64 _disputeSlot);

  event FreedDisputeSlot(uint64 _disputeSlot);

  event Contribute(uint64 _disputeSlot, uint8 _round, uint80 _amount, Party _party);
  event WithdrawnContribution(uint64 _disputeSlot, uint64 _contributionSlot);

  // ----- CONTRACT STORAGE -----

  // Note: This contract is vulnerable to deprecated arbitrator. Redeploying contract would mean that
  // everyone would have to manually withdraw their stake and submit all items again in the newer version.
  // only one arbitrator per contract. changing arbitrator requires redeployment
  IArbitrator internal immutable arbitrator;

  uint64 internal listCount;
  uint64 internal accountCount;
  uint32 internal arbitratorExtraDataCount;

  mapping(uint64 => Account) internal accounts;
  mapping(uint64 => List) internal lists;
  mapping(uint64 => Item) internal items;
  mapping(uint64 => DisputeSlot) internal disputes;
  mapping(uint64 => mapping(uint64 => Contribution)) internal contributions; // contributions[disputeSlot][n]
  // roundContributionsMap[disputeSlot][round]
  mapping(uint64 => mapping(uint8 => RoundContributions)) internal roundContributionsMap;
  mapping(uint256 => uint64) internal disputeIdToDisputeSlot; // disputeIdToDisputeSlot[disputeId]
  mapping(uint32 => bytes) internal arbitratorExtraDataMap;

  /** @dev Constructs the StakeCurate contract.
   *  @param _arbitrator The address of the arbitrator.
   */
  constructor(
    address _arbitrator,
    string memory _metaEvidence
  ) {
    arbitrator = IArbitrator(_arbitrator);
    emit MetaEvidence(0, _metaEvidence);
  }

  // ----- PUBLIC FUNCTIONS -----

  function createAccount() external payable {
    Account storage account = accounts[accountCount++];
    uint32 compressedStake = compress(msg.value);
    account.wallet = msg.sender;
    account.fullStake = compressedStake;
    emit AccountCreated();
  }

  function fundAccount(uint64 _accountId) external payable {
    Account storage account = accounts[_accountId];
    uint256 fullStake = decompress(account.fullStake) + msg.value;
    account.fullStake = compress(fullStake);
    emit AccountFunded(_accountId, fullStake);
  }

  function startWithdrawAccount(uint64 _accountId) external {
    Account storage account = accounts[_accountId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    account.withdrawingTimestamp = uint32(block.timestamp);
    emit AccountStartWithdraw(_accountId);
  }

  function withdrawAccount(uint64 _accountId, uint256 _amount) external {
    Account storage account = accounts[_accountId];
    require(account.wallet == msg.sender, "Only account owner can invoke account");
    uint32 timestamp = account.withdrawingTimestamp;
    require(timestamp != 0, "Withdrawal didn't start");
    require(timestamp + ACCOUNT_WITHDRAW_PERIOD <= block.timestamp, "Withdraw period didn't pass");
    uint256 fullStake = decompress(account.fullStake);
    uint256 lockedStake = decompress(account.lockedStake);
    uint256 freeStake = fullStake - lockedStake;
    require(freeStake >= _amount, "You can't afford to withdraw that much");
    // Initiate withdrawal
    uint256 newStake = fullStake - _amount;
    account.fullStake = compress(newStake);
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
  function createArbitratorExtraData(bytes calldata _arbitratorExtraData) external {
    arbitratorExtraDataMap[arbitratorExtraDataCount++] = _arbitratorExtraData;
    emit ArbitratorExtraDataCreated(_arbitratorExtraData);
  }

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
    uint256 freeStake = decompress(account.fullStake) - decompress(account.lockedStake);
    uint256 requiredStake = decompress(compressedRequiredStake);
    require(freeStake >= requiredStake, "Not enough free stake");
    // Item can be submitted
    item.slotState = ItemSlotState.Used;
    item.commitedStake = compressedRequiredStake;
    item.accountId = _accountId;
    item.listId = _listId;
    item.removingTimestamp = 0;
    item.removing = false;
    item.submissionTimestamp = uint32(block.timestamp);

    emit ItemAdded(itemSlot, _listId, _accountId, _ipfsUri);
  }

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

  function challengeItem(
    uint64 _itemSlot,
    uint64 _fromDisputeSlot,
    string calldata _reason
  ) external payable {
    Item storage item = items[_itemSlot];
    List memory list = lists[item.listId];
    require(itemCanBeChallenged(item, list), "Item cannot be challenged");
    uint64 disputeSlot = firstFreeDisputeSlot(_fromDisputeSlot);
    // Begin. Should I require enough for the cost?
    bytes memory arbitratorExtraData = arbitratorExtraDataMap[list.arbitratorExtraDataId];
    uint256 arbitratorDisputeId = arbitrator.createDispute{value: msg.value}(RULING_OPTIONS, arbitratorExtraData);
    disputeIdToDisputeSlot[arbitratorDisputeId] = disputeSlot;

    item.slotState = ItemSlotState.Disputed;
    // should item stop being removed? this opens a (costly?) dispute spam attack that disallows removing item.
    // if you don't stop the removal, the opposite happens. submitter can make dofus disputes until making the removal period
    item.removingTimestamp = 0;
    item.commitedStake = list.requiredStake; // in case requiredStake was lowered. o.w. remains same.

    DisputeSlot storage dispute = disputes[disputeSlot];
    dispute.arbitratorDisputeId = arbitratorDisputeId;
    dispute.itemSlot = _itemSlot;
    dispute.challenger = msg.sender;
    dispute.state = DisputeState.Used;
    dispute.currentRound = 0;

    dispute.nContributions = 0;
    dispute.pendingWithdraws[0] = 0;
    dispute.pendingWithdraws[1] = 0;
    dispute.appealDeadline = 0;
    dispute.arbitratorExtraDataId = list.arbitratorExtraDataId;

    RoundContributions storage roundContributions = roundContributionsMap[disputeSlot][1];
    roundContributions.filler = 1;
    roundContributions.appealCost = 0;
    roundContributions.partyTotal[0] = 0;
    roundContributions.partyTotal[1] = 0;

    emit ItemChallenged(_itemSlot, disputeSlot);
    // ERC 1497
    // evidenceGroupId is obtained from the (itemSlot, submissionTimestamp) pair
    uint256 evidenceGroupId = uint256(keccak256(abi.encodePacked(_itemSlot, item.submissionTimestamp)));
    // metaEvidenceId is just 0 (afaik, it should be enough to have the same metaEvidence for all items?)
    emit Dispute(arbitrator, arbitratorDisputeId, 0, evidenceGroupId);
    emit Evidence(arbitrator, evidenceGroupId, msg.sender, _reason);
  }

  /**
   * Intermission. How to duplicate evidenceGroupId (is this an exploit?)
   * In the same block:
   * 1. make a list with 0 removalPeriod.
   * 2. Submit item (A) to a slot I
   * 3. Set it for removal
   * 4. Submit item (B) to slot I
   * 5. Challenge it. Now both A and B technically had same evidenceGroupId.
   * I don't see how this could be exploited in any way.
   */

  function submitEvidence(uint256 _evidenceGroupId, string calldata _evidence) external {
    // you can just submit evidence directly to any _evidenceGroupId
    // alternatively, could be (itemSlot, submissionTimestamp) pair 
    emit Evidence(arbitrator, _evidenceGroupId, msg.sender, _evidence);
  }

  function contribute(uint64 _disputeSlot, Party _party) public payable {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    require(dispute.state == DisputeState.Used, "DisputeSlot has to be used");
    require(uint256(_party) < 2, "Party doesn't exist");

    _verifyUnderAppealDeadline(dispute);

    dispute.nContributions++;
    dispute.pendingWithdraws[uint256(_party)]++;
    // compress amount, possibly losing up to 4 gwei. they will be burnt.
    uint80 amount = contribCompress(msg.value);
    uint8 nextRound = dispute.currentRound + 1;
    roundContributionsMap[_disputeSlot][nextRound].partyTotal[uint256(_party)] += amount;

    // pendingWithdrawal = true, it's the first bit. party = _party is the second bit.
    uint8 contribdata = 128 + uint8(_party) * 64;
    contributions[_disputeSlot][dispute.nContributions++] =
      Contribution({round: nextRound, contribdata: contribdata, contributor: msg.sender, amount: amount});
    emit Contribute(_disputeSlot, nextRound, amount, _party);
  }

  function startNextRound(uint64 _disputeSlot) external {
    DisputeSlot storage dispute = disputes[_disputeSlot];
    uint8 nextRound = dispute.currentRound + 1;
    Item storage item = items[dispute.itemSlot];
    List memory list = lists[item.listId];
    require(dispute.state == DisputeState.Used, "Dispute must be Used");

    _verifyUnderAppealDeadline(dispute);
    bytes memory arbitratorExtraData = arbitratorExtraDataMap[list.arbitratorExtraDataId];
    uint256 appealCost = arbitrator.appealCost(dispute.arbitratorDisputeId, arbitratorExtraData);
    uint256 totalAmountNeeded = (appealCost * MULTIPLIER);

    uint256 currentAmount = contribDecompress(
      roundContributionsMap[_disputeSlot][nextRound].partyTotal[0]
      + roundContributionsMap[_disputeSlot][nextRound].partyTotal[1]
    );
    require(currentAmount >= totalAmountNeeded, "Not enough to fund round");
    // All clear, let's appeal
    arbitrator.appeal{value: appealCost}(dispute.arbitratorDisputeId, arbitratorExtraData);
    // Record the cost for sharing the spoils later
    roundContributionsMap[_disputeSlot][nextRound].appealCost = contribCompress(appealCost);

    dispute.currentRound++;

    RoundContributions storage roundContributions = roundContributionsMap[_disputeSlot][nextRound + 1];
    roundContributions.appealCost = 0;
    roundContributions.partyTotal[0] = 0;
    roundContributions.partyTotal[1] = 0;
    roundContributions.filler = 1; // to avoid getting whole storage slot to 0.

    emit NextRound(_disputeSlot);
  }

  function rule(uint256 _disputeId, uint256 _ruling) external override {
    // arbitrator is trusted to:
    // a. call this only once, after dispute is final
    // b. not call this with an unknown _disputeId (it would affect the disputeSlot = 0)
    require(msg.sender == address(arbitrator), "Only arbitrator can rule");
    // 1. get slot from dispute
    uint64 disputeSlot = disputeIdToDisputeSlot[_disputeId];
    DisputeSlot storage dispute = disputes[disputeSlot];
    Item storage item = items[dispute.itemSlot];
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
    } else {
      // challenger won. emit disputeslot to update the status to Withdrawing in the subgraph
      emit DisputeSuccessful(disputeSlot);
      dispute.winningParty = Party.Challenger;
      // 4b. slot is now Free
      item.slotState = ItemSlotState.Free;
      // now, award the commited stake to challenger
      uint256 amount = decompress(item.commitedStake);
      // is it dangerous to send before the end of the function? please answer on audit
      payable(dispute.challenger).send(amount);
    }

    if (dispute.nContributions == 0) {
      dispute.state = DisputeState.Free;
    } else {
      dispute.state = DisputeState.Withdrawing;
    }
    emit Ruling(arbitrator, _disputeId, _ruling);
  }

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

    if (roundContributions.appealCost != 0) {
      // then this is a contribution from an appealed round.
      // only winner party can withdraw.
      require(party == winningParty, "That side lost the dispute");
      _withdrawSingleReward(contribution, roundContributions, party);
    } else {
      // this is a contrib from a round that didnt get appealed.
      // just refund the same amount
      uint256 refund = contribDecompress(contribution.amount);
      // is it safe to send here?
      payable(contribution.contributor).send(refund);
    }

    if (dispute.pendingWithdraws[uint256(winningParty)] == 1) {
      // this was last contrib remaining
      // no need to decrement pendingWithdraws if last. saves gas.
      dispute.state = DisputeState.Free;
      emit FreedDisputeSlot(_disputeSlot);
    } else {
      dispute.pendingWithdraws[uint256(winningParty)]--;
      // set contribution as withdrawn. party doesn't matter, so it's chosen as Party.Requester
      // (pendingWithdrawal = false, party = Party.Requester) => paramsToContribution(false, Party.Requester) = 0
      contribution.contribdata = 0;
      emit WithdrawnContribution(_disputeSlot, _contributionSlot);
    }
  }

  function withdrawAllContributions(uint64 _disputeSlot) public {
    // this func is a "public good". it uses less gas overall to withdraw all
    // contribs. because you only need to change 1 single flag to free the dispute slot.

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
      payable(contribution.contributor).transfer(refund);
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
      - _roundContributions.appealCost
    );
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
    while (disputes[i].state == DisputeState.Used) {
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
    bool enoughCommitted = decompress(_item.commitedStake) >= decompress(_list.requiredStake);
    return (!free && _item.slotState == ItemSlotState.Used && enoughCommitted);
  }

  // ----- PURE FUNCTIONS -----
  // Pasted from Cint32.sol
  function compress(uint256 _amount) internal pure returns (uint32) {
    // maybe binary search to find ndigits? there should be a better way
    uint8 digits = 0;
    uint256 clone = _amount;
    while (clone != 0) {
      clone = clone >> 1;
      digits++;
    }
    // if digits < 24, don't shift it!
    uint256 shiftAmount = (digits < 24) ? 0 : (digits - 24);
    uint256 significantPart = _amount >> shiftAmount;
    uint256 shiftedShift = shiftAmount << 24;
    return (uint32(significantPart + shiftedShift));
  }

  function decompress(uint32 _cint32) internal pure returns (uint256) {
    uint256 shift = _cint32 >> 24;
    uint256 significantPart = _cint32 & 16_777_215; // 2^24 - 1
    return(significantPart << shift);
  }

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
}