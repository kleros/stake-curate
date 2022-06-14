/**
 * @authors: [@greenlucid, @chotacabras]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8.14;
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "./Cint32.sol";

/// note: should i prevent challenging an item with the account can withdraw?

/**
 * @title Stake Curate
 * @author Green
 * @notice Curate with indefinitely held, capital-efficient stake.
 * @dev The stakes of the items are handled here. Handling arbitrary on-chain data is
 * possible, but many curation needs can be solved by keeping off-chain state availability.
 * This dapp should be reviewed taking the subgraph role into account.
 */
contract StakeCurate is IArbitrable, IEvidence {

  enum Party { Staker, Challenger }
  enum DisputeState { Free, Used }
  /// @dev Item may be free even if "Used"! Use itemIsFree view. (because of removingTimestamp)
  enum ItemSlotState { Free, Used, Disputed }

  uint256 internal constant RULING_OPTIONS = 2;

  /// @dev Some uint256 are lossily compressed into uint32 using Cint32.sol
  struct Account {
    address owner;
    uint32 fullStake;
    uint32 lockedStake;
    uint32 withdrawingTimestamp; // frontrunning protection. overflows in 2106.
    // when this becomes a problem, shift bits around and use days instead of seconds, for example.
  }

  /* note on why ids can be 56 bits
    say gas needed is 32. overflow is not economical
    that's ~10**18 bytes of calldata. to publish on L1
    lets say, 0.00001 cent per id increment. thats 0.7T$, for a grief.
    and during this effort, every user can leave to a new contract.
  */
  struct List {
    uint56 governorId; // governor needs an account
    uint32 requiredStake; 
    uint32 removalPeriod; 
    uint56 arbitrationSettingId;
    uint32 versionTimestamp;
    uint32 upgradePeriod; // extends time to edit the item without getting adopted.
    bool freeAdoptions; // all items are in adoption all the time
    uint8 freespace;
  }

  struct Item {
    uint56 accountId;
    uint56 listId;
    uint32 committedStake; // used for protection against governor changing stake amounts
    uint32 removingTimestamp; // frontrunning protection
    bool removing; // on failed dispute, will automatically reset removingTimestamp
    ItemSlotState slotState;
    uint32 submissionBlock; // only used to make evidenceGroupId.
    uint32 editionTimestamp; // you could hold bounties here?
    bytes harddata;
  }

  struct DisputeSlot {
    uint256 arbitratorDisputeId;
    // ----
    uint56 challengerId;
    uint56 itemSlot;
    uint56 arbitrationSetting;
    DisputeState state;
    uint80 freespace;
    // ----
  }

  struct ArbitrationSetting {
    bytes arbitratorExtraData;
    IArbitrator arbitrator;
  }

  // ----- EVENTS -----

  // Used to initialize counters in the subgraph
  event StakeCurateCreated();
  event ChangedStakeCurateSettings(uint256 _withdrawalPeriod, address _governor);

  event AccountCreated(address _owner, uint32 _fullStake);
  event AccountFunded(uint56 _accountId, uint32 _fullStake);
  event AccountStartWithdraw(uint56 _accountId);
  event AccountWithdrawn(uint56 _accountId, uint32 _fullStake);

  event ArbitrationSettingCreated(address _arbitrator, bytes _arbitratorExtraData);

  event ListCreated(uint56 _governorId, uint32 _requiredStake, uint32 _removalPeriod,
    uint32 _upgradePeriod, bool _freeAdoptions, uint56 _arbitrationSettingId, string _metalist);
  event ListUpdated(uint56 _listId, uint56 _governorId, uint32 _requiredStake,
    uint32 _removalPeriod, uint32 _upgradePeriod, bool _freeAdoptions,
    uint64 _arbitrationSettingId, string _metalist);

  event ItemAdded(uint56 _itemSlot, uint56 _listId, uint56 _accountId, string _ipfsUri,
    bytes _harddata
  );
  event ItemEdited(uint56 _itemSlot, string _ipfsUri, bytes _harddata);
  event ItemStartRemoval(uint56 _itemSlot);
  event ItemStopRemoval(uint56 _itemSlot);
  // there's no need for "ItemRemoved", since it will automatically be considered removed after the period.
  event ItemRecommitted(uint56 _itemSlot);
  event ItemAdopted(uint56 _itemSlot, uint56 _adopterId);

  event ItemChallenged(uint56 _itemSlot, uint56 _disputeSlot);

  // ----- CONTRACT STORAGE -----

  // governor of stake curate, only used to update metaEvidence
  address public governor;
  uint256 public withdrawalPeriod;
  uint256 public currentMetaEvidenceId;

  uint56 public listCount;
  uint56 public accountCount;
  uint56 public arbitrationSettingCount;

  mapping(uint56 => Account) public accounts;
  mapping(uint56 => List) public lists;
  mapping(uint56 => Item) public items;
  mapping(uint56 => DisputeSlot) public disputes;
  mapping(address => mapping(uint256 => uint56)) public arbitratorAndDisputeIdToDisputeSlot;
  mapping(uint56 => ArbitrationSetting) public arbitrationSettings;

  /** 
   * @dev Constructs the StakeCurate contract.
   * @param _withdrawalPeriod Waiting period to execute a withdrawal
   * @param _governor Address able to update withdrawalPeriod, metaEvidence, and change govenor
   * @param _metaEvidence IPFS uri of the initial MetaEvidence
   */
  constructor(uint256 _withdrawalPeriod, address _governor, string memory _metaEvidence) {
    withdrawalPeriod = _withdrawalPeriod;
    governor = _governor;
    emit StakeCurateCreated();
    emit ChangedStakeCurateSettings(_withdrawalPeriod, governor);
    emit MetaEvidence(0, _metaEvidence);
  }

  // ----- PUBLIC FUNCTIONS -----

  /**
   * @dev Governor changes the general settings of Stake Curate
   * @param _withdrawalPeriod Waiting period to execute a withdrawal
   * @param _governor The new address able to change these settings
   * @param _metaEvidence IPFS uri to the new MetaEvidence
   */
  function changeStakeCurateSettings(
    uint256 _withdrawalPeriod, address _governor,
    string calldata _metaEvidence
  ) external {
    require(msg.sender == governor, "Only governor can change these settings");
    withdrawalPeriod = _withdrawalPeriod;
    governor = _governor;
    emit ChangedStakeCurateSettings(_withdrawalPeriod, _governor);
    currentMetaEvidenceId++;
    emit MetaEvidence(currentMetaEvidenceId, _metaEvidence);
  }

  /// @dev Creates an account and starts it with funds dependent on value
  function createAccount() external payable {
    Account storage account = accounts[accountCount];
    unchecked {accountCount++;}
    account.owner = msg.sender;
    uint32 fullStake = Cint32.compress(msg.value);
    account.fullStake = fullStake;
    emit AccountCreated(msg.sender, fullStake);
  }

  /**
   * @dev Creates an account for a given address and starts it with funds dependent on value.
   * @param _owner The address of the account you will create.
   */
  function createAccountForAddress(address _owner) external payable {
    Account storage account = accounts[accountCount];
    unchecked {accountCount++;}
    account.owner = _owner;
    uint32 fullStake = Cint32.compress(msg.value);
    account.fullStake = fullStake;
    emit AccountCreated(_owner, fullStake);
  }

  /**
   * @dev Funds an existing account.
   * @param _accountId The id of the account to fund. Doesn't have to belong to sender.
   */
  function fundAccount(uint56 _accountId) external payable {
    unchecked {
      Account storage account = accounts[_accountId];
      uint256 fullStake = Cint32.decompress(account.fullStake) + msg.value;
      uint32 compressedFullStake = Cint32.compress(fullStake);
      account.fullStake = compressedFullStake;
      emit AccountFunded(_accountId, compressedFullStake);
    }
  }

  /**
   * @dev Starts a withdrawal process on an account you own.
   * Withdrawals are not instant to prevent frontrunning.
   * @param _accountId The id of the account. Must belong to sender.
   */
  function startWithdrawAccount(uint56 _accountId) external {
    Account storage account = accounts[_accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    account.withdrawingTimestamp = uint32(block.timestamp);
    emit AccountStartWithdraw(_accountId);
  }

  /**
   * @dev Withdraws any amount on an account that finished the withdrawing process.
   * @param _accountId The id of the account. Must belong to sender.
   * @param _amount The amount to be withdrawn.
   */
  function withdrawAccount(uint56 _accountId, uint256 _amount) external {
    unchecked {
      Account storage account = accounts[_accountId];
      require(account.owner == msg.sender, "Only account owner can invoke account");
      uint32 timestamp = account.withdrawingTimestamp;
      require(timestamp != 0, "Withdrawal didn't start");
      require(timestamp + withdrawalPeriod <= block.timestamp, "Withdraw period didn't pass");
      uint256 fullStake = Cint32.decompress(account.fullStake);
      uint256 lockedStake = Cint32.decompress(account.lockedStake);
      uint256 freeStake = fullStake - lockedStake; // we needed to decompress fullstake anyway
      require(freeStake >= _amount, "You can't afford to withdraw that much");
      // Initiate withdrawal
      uint32 newStake = Cint32.compress(fullStake - _amount);
      account.fullStake = newStake;
      account.withdrawingTimestamp = 0;
      payable(account.owner).send(_amount);
      emit AccountWithdrawn(_accountId, newStake);
    }
  }

  /**
   * @dev Create arbitrator setting. Will be immutable, and assigned to an id.
   * @param _arbitrator The address of the IArbitrator
   * @param _arbitratorExtraData The extra data
   */
  function createArbitrationSetting(address _arbitrator, bytes calldata _arbitratorExtraData) external {
    arbitrationSettings[arbitrationSettingCount++] = ArbitrationSetting({
      arbitrator: IArbitrator(_arbitrator),
      arbitratorExtraData: _arbitratorExtraData
    });
    emit ArbitrationSettingCreated(_arbitrator, _arbitratorExtraData);
  }

  /**
   * @dev Creates a list. They store all settings related to the dispute, stake, etc.
   * @param _governorId The id of the governor.
   * @param _requiredStake The Cint32 version of the required stake per item.
   * @param _removalPeriod The amount of seconds an item needs to go through removal period to be removed.
   * @param _upgradePeriod Seconds from last edition the item has to be upgraded before adoptable.
   * @param _freeAdoptions Whether if the items in this list are in adoption all the time.
   * @param _arbitrationSettingId Id of the internally stored arbitrator setting
   * @param _metalist IPFS uri of metaEvidence
   */
  function createList(
    uint56 _governorId,
    uint32 _requiredStake,
    uint32 _removalPeriod,
    uint32 _upgradePeriod,
    bool _freeAdoptions,
    uint56 _arbitrationSettingId,
    string calldata _metalist
  ) external {
    require(_governorId < accountCount, "Account must exist");
    require(_arbitrationSettingId < arbitrationSettingCount, "ArbitrationSetting must exist");
    uint56 listId = listCount;
    unchecked {listCount++;}
    List storage list = lists[listId];
    list.governorId = _governorId;
    list.requiredStake = _requiredStake;
    list.removalPeriod = _removalPeriod;
    list.upgradePeriod = _upgradePeriod;
    list.freeAdoptions = _freeAdoptions;
    list.arbitrationSettingId = _arbitrationSettingId;
    list.versionTimestamp = uint32(block.timestamp);
    emit ListCreated(
      _governorId, _requiredStake, _removalPeriod,
      _upgradePeriod, _freeAdoptions, _arbitrationSettingId, _metalist
    );
  }

  /**
   * @dev Updates an existing list. Can only be called by its governor.
   * @param _listId Id of the list to be updated.
   * @param _governorId Id of the new governor.
   * @param _requiredStake Cint32 version of the new required stake per item.
   * @param _removalPeriod Seconds until item is considered removed after starting removal.
   * @param _upgradePeriod Seconds from last edition the item has to be upgraded before adoptable.
   * @param _freeAdoptions Whether if the items in this list are in adoption all the time.
   * @param _arbitrationSettingId Id of the new arbitrator extra data.
   * @param _metalist IPFS uri of the metadata of this list.
   */
  function updateList(
    uint56 _listId,
    uint56 _governorId,
    uint32 _requiredStake,
    uint32 _removalPeriod,
    uint32 _upgradePeriod,
    bool _freeAdoptions,
    uint56 _arbitrationSettingId,
    string calldata _metalist
  ) external {
    require(_governorId < accountCount, "Account must exist");
    require(_arbitrationSettingId < arbitrationSettingCount, "ArbitrationSetting must exist");
    List storage list = lists[_listId];
    require(accounts[list.governorId].owner == msg.sender, "Only governor can update list");
    list.governorId = _governorId;
    list.requiredStake = _requiredStake;
    list.removalPeriod = _removalPeriod;
    list.upgradePeriod = _upgradePeriod;
    list.freeAdoptions = _freeAdoptions;
    list.arbitrationSettingId = _arbitrationSettingId;
    list.versionTimestamp = uint32(block.timestamp);
    emit ListUpdated(
      _listId, _governorId, _requiredStake,
      _removalPeriod, _upgradePeriod, _freeAdoptions, _arbitrationSettingId, _metalist
    );
  }

  /**
   * @notice Adds an item in a slot.
   * @param _fromItemSlot Slot to look for a free itemSlot from.
   * @param _listId Id of the list the item will be included in
   * @param _accountId Id of the account owning the item.
   * @param _ipfsUri IPFS uri that links to the content of the item
   * @param _harddata Optional data that is stored on-chain
   */
  function addItem(
    uint56 _fromItemSlot,
    uint56 _listId,
    uint56 _accountId,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external {
    uint56 itemSlot = firstFreeItemSlot(_fromItemSlot);
    Account memory account = accounts[_accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    Item storage item = items[itemSlot];
    List storage list = lists[_listId];
    require(item.submissionBlock != block.number, "Wait until next block");
    uint32 compressedRequiredStake = list.requiredStake;
    uint256 freeStake = getFreeStake(account);
    uint256 requiredStake = Cint32.decompress(compressedRequiredStake);
    require(freeStake >= requiredStake, "Not enough free stake");
    // Item can be submitted
    item.slotState = ItemSlotState.Used;
    item.committedStake = compressedRequiredStake;
    item.accountId = _accountId;
    item.listId = _listId;
    item.removingTimestamp = 0;
    item.removing = false;
    // (not sure) in arbitrum, this is actually the L1 block number
    // which means, collisions in the L2 might be possible, so
    // this doesn't guarantee identity. when moving to arbitrum,
    // remember to change this to get the arb block number instead.
    // https://developer.offchainlabs.com/docs/time_in_arbitrum
    item.submissionBlock = uint32(block.number);
    item.editionTimestamp = uint32(block.timestamp);
    item.harddata = _harddata;

    emit ItemAdded(itemSlot, _listId, _accountId, _ipfsUri, _harddata);
  }

  function editItem(
    uint56 _itemSlot,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    require(!item.removing, "Item is being removed");
    require(item.slotState == ItemSlotState.Used, "ItemSlot must be Used");
    uint256 freeStake = getFreeStake(account);
    List memory list = lists[item.listId];
    require(freeStake >= Cint32.decompress(list.requiredStake), "Cannot afford to edit this item");
    
    item.committedStake = list.requiredStake;
    item.harddata = _harddata;
    item.editionTimestamp = uint32(block.timestamp);

    emit ItemEdited(_itemSlot, _ipfsUri, _harddata);
  }

  /**
   * @dev Starts an item removal process.
   * @param _itemSlot Slot of the item to remove.
   */
  function startRemoveItem(uint56 _itemSlot) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
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
  function cancelRemoveItem(uint56 _itemSlot) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    List memory list = lists[item.listId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
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
  function adoptItem(uint56 _itemSlot, uint56 _adopterId) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    Account memory adopter = accounts[_adopterId];
    List memory list = lists[item.listId];

    require(adopter.owner == msg.sender, "Only adopter owner can adopt");
    require(item.slotState == ItemSlotState.Used, "Item slot must be Used");
    require(itemIsInAdoption(item, list, account), "Item is not in adoption");
    uint256 freeStake = getFreeStake(adopter);
    require(Cint32.decompress(list.requiredStake) <= freeStake, "Cannot afford adopting this item");

    item.accountId = _adopterId;
    item.committedStake = list.requiredStake;
    item.removing = false;
    item.removingTimestamp = 0;
    // item.editionTimestamp is purposedly not set here!
    // if needed, adopter is adviced to batch the edit after adoption

    emit ItemAdopted(_itemSlot, _adopterId);
  }

  /**
   * @dev Update committed amount of an item. Amounts are committed as a form of protection
   * for item submitters, to support updating list required amounts without potentially draining
   * users of their amounts.
   * @param _itemSlot Slot of the item to recommit.
   */
  function recommitItem(uint56 _itemSlot) external {
    Item storage item = items[_itemSlot];
    Account memory account = accounts[item.accountId];
    List memory list = lists[item.listId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    require(!itemIsFree(item, list) && item.slotState == ItemSlotState.Used, "ItemSlot must be Used");
    require(!item.removing, "Item is being removed");
    
    uint256 freeStake = getFreeStake((account));
    require(freeStake >= Cint32.decompress(list.requiredStake), "Not enough to recommit item");

    item.committedStake = list.requiredStake;
    item.editionTimestamp = uint32(block.timestamp);

    emit ItemRecommitted(_itemSlot);
  }

  /**
   * @notice Challenge an item, with the intent of removing it and obtaining a reward.
   * @param _challengerId Id of the account challenger is challenging on behalf
   * @param _itemSlot Slot of the item to challenge.
   * @param _fromDisputeSlot DisputeSlot to start finding a place to store the dispute
   * @param _minAmount Frontrunning protection due to this edge case:
   * Submitter frontruns submitting a wrong item, and challenges himself to lock himself out of
   * funds, so that his free stake is lower than whatever he has committed or is the requirement
   * of the list. This way, challenger can verify that a desirable amount of funds will be obtained
   * by challenging, with his transaction reverting otherwise, protecting from loss. 
   * @param _reason IPFS uri containing the evidence for the challenge.
   */
  function challengeItem(
    uint56 _challengerId,
    uint56 _itemSlot,
    uint56 _fromDisputeSlot,
    uint256 _minAmount,
    string calldata _reason
  ) external payable {
    Item storage item = items[_itemSlot];
    List memory list = lists[item.listId];
    Account storage account = accounts[item.accountId];

    // this validation is not needed for security, since the challenger is only
    // referenced to forward the reward if challenge is won. but, it's nicer.
    require(accounts[_challengerId].owner == msg.sender, "Only account owner can challenge on behalf");
    
    require(itemCanBeChallenged(item, list), "Item cannot be challenged");
    uint256 freeStake = getFreeStake(account);
    require(_minAmount <= freeStake, "Not enough free stake to satisfy minAmount");

    // All requirements met, begin
    uint256 committedAmount = Cint32.decompress(list.requiredStake) <= freeStake
      ? Cint32.decompress(list.requiredStake)
      : freeStake
    ;
    uint56 disputeSlot = firstFreeDisputeSlot(_fromDisputeSlot);

    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    uint256 arbitratorDisputeId =
      arbSetting.arbitrator.createDispute{value: msg.value}(
        RULING_OPTIONS, arbSetting.arbitratorExtraData
      );
    arbitratorAndDisputeIdToDisputeSlot
      [address(arbSetting.arbitrator)][arbitratorDisputeId] = disputeSlot;

    item.slotState = ItemSlotState.Disputed;
    // todo revisit the removing logic. instead of setting the removing timestamp to 0,
    // just reset the timestamp to current block when challenge fails.
    item.removingTimestamp = 0;
    item.committedStake = Cint32.compress(committedAmount);
    unchecked {
      account.lockedStake = Cint32.compress(Cint32.decompress(account.lockedStake) + committedAmount);
    }
    disputes[disputeSlot] = DisputeSlot({
      arbitratorDisputeId: arbitratorDisputeId,
      itemSlot: _itemSlot,
      challengerId: _challengerId,
      arbitrationSetting: list.arbitrationSettingId,
      state: DisputeState.Used,
      freespace: 0
    });

    emit ItemChallenged(_itemSlot, disputeSlot);
    // ERC 1497
    uint256 evidenceGroupId = getEvidenceGroupId(_itemSlot);
    emit Dispute(arbSetting.arbitrator, arbitratorDisputeId, currentMetaEvidenceId, evidenceGroupId);
    emit Evidence(arbSetting.arbitrator, evidenceGroupId, msg.sender, _reason);
  }

  /**
   * @dev Submits evidence to potentially any dispute or item.
   * @param _itemSlot The slot containing the item to submit evidence to.
   * @param _arbitrator The arbitrator to submit evidence to. This is needed because:
   * 1. it's not possible to obtain the dispute from an item
   * 2. the item may be currently ruled by a different arbitrator than the one
   * its list it's pointing to
   * 3. the item may not even be in a dispute (so, just use the arbitrator in the list)
   * ---
   * Anyhow, the subgraph will be ignoring this parameter. It's kept to allow arbitrators
   * to render evidence properly.
   * @param _evidence IPFS uri linking to the evidence.
   */
  function submitEvidence(uint56 _itemSlot, IArbitrator _arbitrator, string calldata _evidence) external {
    uint256 evidenceGroupId = getEvidenceGroupId(_itemSlot);
    emit Evidence(_arbitrator, evidenceGroupId, msg.sender, _evidence);
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
    // 1. get slot from dispute
    uint56 disputeSlot = arbitratorAndDisputeIdToDisputeSlot[msg.sender][_disputeId];
    DisputeSlot storage dispute = disputes[disputeSlot];
    ArbitrationSetting storage arbSetting = arbitrationSettings[dispute.arbitrationSetting];
    require(msg.sender == address(arbSetting.arbitrator), "Only arbitrator can rule");

    Item storage item = items[dispute.itemSlot];
    Account storage account = accounts[item.accountId];
    // 2. make sure that dispute has an ongoing dispute
    require(dispute.state == DisputeState.Used, "Can only be executed if Used");
    // 3. apply ruling. what to do when refuse to arbitrate?
    // just default towards keeping the item.
    // 0 refuse, 1 staker, 2 challenger.
    if (_ruling == 1 || _ruling == 0) {
      // staker won.
      // 4a. return item to used, not disputed.
      if (item.removing) {
        item.removingTimestamp = uint32(block.timestamp);
      }
      item.slotState = ItemSlotState.Used;
      // free the locked stake
      uint256 lockedAmount = Cint32.decompress(account.lockedStake);
      unchecked {
        uint256 updatedLockedAmount = lockedAmount - Cint32.decompress(item.committedStake);
        account.lockedStake = Cint32.compress(updatedLockedAmount);
      }
    } else {
      // challenger won.
      // 4b. slot is now Free
      item.slotState = ItemSlotState.Free;
      // now, award the commited stake to challenger
      uint256 amount = Cint32.decompress(item.committedStake);
      // remove amount from the account
      account.fullStake = Cint32.compress(Cint32.decompress(account.fullStake) - amount);
      account.lockedStake = Cint32.compress(Cint32.decompress(account.lockedStake) - amount);
      // is it dangerous to send before the end of the function? please answer on audit
      payable(accounts[dispute.challengerId].owner).send(amount);
    }
    dispute.state = DisputeState.Free;
    emit Ruling(arbSetting.arbitrator, _disputeId, _ruling);
  }

  // ----- VIEW FUNCTIONS -----
  function firstFreeDisputeSlot(uint56 _fromSlot) internal view returns (uint56) {
    uint56 i = _fromSlot;
    while (disputes[i].state != DisputeState.Free) {
      unchecked {i++;}
    }
    return i;
  }

  function firstFreeItemSlot(uint56 _fromSlot) internal view returns (uint56) {
    uint56 i = _fromSlot;
    Item memory item = items[i];
    List memory list = lists[item.listId];
    while (!itemIsFree(item, list)) {
      unchecked {i++;}
      item = items[i];
      list = lists[item.listId];
    }
    return(i);
  }

  function itemIsFree(Item memory _item, List memory _list) internal view returns (bool) {
    unchecked {
      bool notInUse = _item.slotState == ItemSlotState.Free;
      bool removed = _item.removing && _item.removingTimestamp + _list.removalPeriod <= block.timestamp;
      return (notInUse || removed);
    }
  }

  function itemCanBeChallenged(Item memory _item, List memory _list) internal view returns (bool) {
    bool free = itemIsFree(_item, _list);

    // the item must have same or more committed amount than required for list
    bool enoughCommitted = Cint32.decompress(_item.committedStake) >= Cint32.decompress(_list.requiredStake);
    return (
      !free
      && (_item.editionTimestamp > _list.versionTimestamp)
      && _item.slotState == ItemSlotState.Used
      && enoughCommitted
    );
  }

  function getEvidenceGroupId(uint56 _itemSlot) public view returns (uint256) {
    // evidenceGroupId is obtained from the (itemSlot, submissionBlock) pair
    // I couldn't figure out how to encodePacked on the subgraph, plus this is cheaper.
    return (uint256((_itemSlot << 32) + items[_itemSlot].submissionBlock));
  }

  // ----- PURE FUNCTIONS -----

  function itemIsInAdoption(Item memory _item, List memory _list, Account memory _account) internal view returns (bool) {
    // check if any of the 5 conditions for adoption is met:
    bool beingRemoved = _item.removing;
    bool accountWithdrawing = _account.withdrawingTimestamp != 0;
    bool committedUnderRequired = Cint32.decompress(_item.committedStake) < Cint32.decompress(_list.requiredStake);
    bool noCommitAfterListUpdate = _item.editionTimestamp <= _list.versionTimestamp
      && block.timestamp >= _list.versionTimestamp + _list.upgradePeriod;
    uint256 freeStake = getFreeStake(_account);
    bool notEnoughFreeStake = freeStake < Cint32.decompress(_list.requiredStake);
    return (
      beingRemoved
      || accountWithdrawing
      || committedUnderRequired
      || noCommitAfterListUpdate
      || notEnoughFreeStake
      || _list.freeAdoptions
    );
  }

  function getFreeStake(Account memory _account) internal pure returns (uint256) {
    unchecked {
      return(Cint32.decompress(_account.fullStake) - Cint32.decompress(_account.lockedStake));
    }
  }
}