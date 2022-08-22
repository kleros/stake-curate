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

  /**
   * @dev "+" means the state can be stored. Else, is dynamic. Meanings:
   * +Nothing: does not exist yet.
   * Young: item is not considered included, but can be challenged.
   * +Included: the item is considered included, can be challenged.
   * +Disputed: currently under a Dispute.
   * +Removed: a Dispute ruled to remove this item.
   * Uncollateralized: owner doesn't have enough collateral,
   * * also triggers if owner can withdraw.
   * Outdated: item was committed before the last list version.
   * Retracting: owner is currently retracting the item.
   * * can still be challenged.
   * Retracted: owner made it go through the retraction period.
   */
  enum ItemState {
    Nothing,
    Young,
    Included,
    Disputed,
    Removed,
    IllegalList,
    Uncollateralized,
    Outdated,
    Retracting,
    Retracted
  }

  uint256 internal constant RULING_OPTIONS = 2;

  /// @dev Makes SLOADs trigger hot accesses more often.
  struct StakeCurateSettings {
    // can change these settings
    address governor;
    // to be able to withdraw freeStake after init
    uint32 withdrawalPeriod;
    // span of time granted to challenger to reference previous editions
    // check its usage in challengeItem and the general policy to understand its role
    uint32 challengeWindow;
    uint32 currentMetaEvidenceId;
  }

  /// @dev Some uint256 are lossily compressed into uint32 using Cint32.sol
  struct Account {
    address owner;
    uint32 fullStake;
    uint32 lockedStake;
    uint32 withdrawingTimestamp; // frontrunning protection. overflows in 2106.
  }

  struct List {
    uint64 governorId; // governor needs an account
    uint32 requiredStake;
    uint32 retractionPeriod; 
    uint64 arbitrationSettingId;
    uint32 versionTimestamp;
    // vvv reconsider removing this. holding items is a liability.
    // if keep, rename. todo
    uint32 upgradePeriod; // extends time to edit the item without getting adopted. could be uint16 w/ minutes
    // ----
    // todo add erc20 token address
    bool freeAdoptions; // all items are in adoption all the time
    uint32 challengerStake; // how much challenger puts as stake to be awarded on failure to owner
    uint32 ageForInclusion; // how much time from Young to Included, in seconds
  }

  struct Item {
    uint64 accountId;
    uint64 listId;
    uint32 retractionTimestamp;
    ItemState state;
    uint32 commitTimestamp;
    uint56 freeSpace;
    bytes harddata;
  }

  struct DisputeSlot {
    uint256 arbitratorDisputeId;
    // ----
    uint64 challengerId;
    uint64 itemId;
    uint64 arbitrationSetting;
    DisputeState state;
    uint32 itemStake; // unlocks to submitter if Keep, sent to challenger if Remove
    uint24 freespace;
    // ----
    uint32 challengerStake; // put by the challenger, sent to whoever side wins.
  }

  struct ArbitrationSetting {
    bytes arbitratorExtraData;
    IArbitrator arbitrator;
  }

  // ----- EVENTS -----

  // Used to initialize counters in the subgraph
  event StakeCurateCreated();
  event ChangedStakeCurateSettings(uint256 _withdrawalPeriod, uint32 _challengeWindow, address _governor);

  event AccountCreated(address _owner);
  event AccountFunded(uint64 _accountId, uint32 _fullStake);
  event AccountStartWithdraw(uint64 _accountId);
  event AccountWithdrawn(uint64 _accountId, uint32 _fullStake);

  event ArbitrationSettingCreated(address _arbitrator, bytes _arbitratorExtraData);

  event ListCreated(List _list, string _metalist);
  event ListUpdated(uint64 _listId, List _list, string _metalist);

  event ItemAdded(uint64 _listId, string _ipfsUri, bytes _harddata);
  event ItemEdited(uint64 _itemId, string _ipfsUri, bytes _harddata);
  event ItemStartRetraction(uint64 _itemId);
  event ItemStopRetraction(uint64 _itemId);
  // there's no need for "ItemRetracted"
  // since it will automatically be considered retracted after the period.
  event ItemRecommitted(uint64 _itemId);
  // no need for event for adopt. new owner can be read from sender.
  // this is the case for Recommit or Edit.

  event ItemChallenged(uint64 _itemId, uint32 _editionTimestamp, string _reason);

  // ----- CONTRACT STORAGE -----
  
  StakeCurateSettings public stakeCurateSettings;

  // todo get these counts in a single struct?
  uint64 public itemCount;
  uint64 public listCount;
  uint64 public disputeCount;
  uint64 public accountCount;
  uint64 public arbitrationSettingCount;

  mapping(address => uint64) public accountIdOf;
  mapping(uint64 => Account) public accounts;

  mapping(uint64 => List) public lists;
  mapping(uint64 => Item) public items;
  mapping(uint64 => DisputeSlot) public disputes;
  mapping(address => mapping(uint256 => uint64)) public arbitratorAndDisputeIdToLocal;
  mapping(uint64 => ArbitrationSetting) public arbitrationSettings;

  /** 
   * @dev Constructs the StakeCurate contract.
   * @param _withdrawalPeriod Waiting period to execute a withdrawal
   * @param _governor Address able to update withdrawalPeriod, metaEvidence, and change govenor
   * @param _metaEvidence IPFS uri of the initial MetaEvidence
   */
  constructor(uint32 _withdrawalPeriod, uint32 _challengeWindow, address _governor, string memory _metaEvidence) {
    stakeCurateSettings.withdrawalPeriod = _withdrawalPeriod;
    stakeCurateSettings.challengeWindow = _challengeWindow;
    stakeCurateSettings.governor = _governor;
    // starting metaEvidenceId is 0, no need to set it. 

    // purpose: prevent dispute zero from being used.
    // this dispute has the ArbitrationSetting = 0. it will be
    // made impossible to rule with, and kept with arbitrator = address(0) forever,
    // so, it cannot be ruled. thus, requiring the disputeSlot != 0 on rule is not needed.
    arbitrationSettingCount = 1;
    disputes[0].state = DisputeState.Used;
    disputeCount = 1; // since disputes are incremental, prevent local dispute 0
    accountCount = 1; // accounts[0] cannot be used either

    emit StakeCurateCreated();
    emit ChangedStakeCurateSettings(_withdrawalPeriod, _challengeWindow, _governor);
    emit MetaEvidence(0, _metaEvidence);
    emit ArbitrationSettingCreated(address(0), "");
  }

  // ----- PUBLIC FUNCTIONS -----

  /**
   * @dev Governor changes the general settings of Stake Curate
   * @param _withdrawalPeriod Waiting period to execute a withdrawal
   * @param _governor The new address able to change these settings
   * @param _metaEvidence IPFS uri to the new MetaEvidence
   */
  function changeStakeCurateSettings(
    uint32 _withdrawalPeriod, uint32 _challengeWindow, address _governor,
    string calldata _metaEvidence
  ) external {
    require(msg.sender == stakeCurateSettings.governor, "Only governor can change these settings");
    stakeCurateSettings.withdrawalPeriod = _withdrawalPeriod;
    stakeCurateSettings.challengeWindow = _challengeWindow;
    stakeCurateSettings.governor = _governor;
    emit ChangedStakeCurateSettings(_withdrawalPeriod, _challengeWindow, _governor);
    stakeCurateSettings.currentMetaEvidenceId++;
    emit MetaEvidence(stakeCurateSettings.currentMetaEvidenceId, _metaEvidence);
  }

  /**
   * @dev If account already exists, returns its id.
   * If not, it creates an account for a given address and returns the id.
   * @param _owner The address of the account.
   */
  function accountRoutine(address _owner) public returns (uint64 id) {
    if (accountIdOf[_owner] != 0) {
      id = accountIdOf[_owner];
    } else {
      id = accountCount++;
      accountIdOf[_owner] = id;
      accounts[id] = Account({
        owner: _owner,
        fullStake: 0,
        lockedStake: 0,
        withdrawingTimestamp: 0
      });
      emit AccountCreated(_owner);
    }
  }

  /**
   * @dev Funds an existing account.
   * @param _accountId The id of the account to fund. Doesn't have to belong to sender.
   */
  // todo modify for erc20, and pass address instead
  function fundAccount(uint64 _accountId) external payable {
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
  // todo modify for erc20, don't pass id nor address. pass token addr
  function startWithdrawAccount(uint64 _accountId) external {
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
  // todo modify for erc20, don't pass id nor address.
  // pass token and amont
  function withdrawAccount(uint64 _accountId, uint256 _amount) external {
    unchecked {
      Account storage account = accounts[_accountId];
      require(account.owner == msg.sender, "Only account owner can invoke account");
      uint32 timestamp = account.withdrawingTimestamp;
      require(timestamp != 0, "Withdrawal didn't start");
      require(
        timestamp + stakeCurateSettings.withdrawalPeriod <= block.timestamp,
        "Withdraw period didn't pass"
      );
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
  function createArbitrationSetting(address _arbitrator, bytes calldata _arbitratorExtraData)
      external returns (uint64 id) {
    unchecked {id = arbitrationSettingCount++;}
    require(_arbitrator != address(0), "Address 0 can't be arbitrator");
    arbitrationSettings[id] = ArbitrationSetting({
      arbitrator: IArbitrator(_arbitrator),
      arbitratorExtraData: _arbitratorExtraData
    });
    emit ArbitrationSettingCreated(_arbitrator, _arbitratorExtraData);
  }

  /**
   * @dev Creates a list. They store all settings related to the dispute, stake, etc.
   * @param _list The list to create.
   * @param _metalist IPFS uri with additional data pertaining to the list.
   */
  function createList(
      List memory _list,
      string calldata _metalist
  ) external returns (uint64 id) {
    // todo also pass governor as address, and override passed governorId.
    // try to create if it doesn't exist with "accountRoutine"
    require(_list.arbitrationSettingId < arbitrationSettingCount, "ArbitrationSetting must exist");
    unchecked {id = listCount++;}
    lists[id] = _list;
    require(listLegalCheck(id), "Cannot create illegal list");
    emit ListCreated(_list, _metalist);
  }

  /**
   * @dev Updates an existing list. Can only be called by its governor.
   * @param _listId Id of the list to be updated.
   * @param _list New list data to replace current one.
   * @param _metalist IPFS uri with additional data pertaining to the list.
   */
  function updateList(
    uint64 _listId,
    List memory _list,
    string calldata _metalist
  ) external {
    // todo also pass governor as address, and override passed governorId.
    // try to create if it doesn't exist with "accountRoutine"
    require(_list.arbitrationSettingId < arbitrationSettingCount, "ArbitrationSetting must exist");
    require(accounts[lists[_listId].governorId].owner == msg.sender, "Only governor can update list");
    lists[_listId] = _list;
    require(listLegalCheck(_listId), "Cannot make list illegal");
    emit ListUpdated(_listId, _list, _metalist);
  }

  /**
   * @notice Adds an item to a list.
   * @param _listId Id of the list the item will be included in
   * @param _ipfsUri IPFS uri that links to the content of the item
   * @param _harddata Optional data that is stored on-chain
   */
  function addItem(
    uint64 _listId,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external returns (uint64 id) {
    require(listLegalCheck(_listId), "Cannot add item to illegal list");
    uint64 accountId = accountRoutine(msg.sender);
    Account memory account = accounts[accountId];
    unchecked {id = itemCount++;} 
    Item storage item = items[id];
    List storage list = lists[_listId];
    uint256 freeStake = getFreeStake(account);
    require(freeStake >= Cint32.decompress(list.requiredStake), "Not enough free stake");
    // Item can be submitted
    item.state = ItemState.Included;
    item.accountId = accountId;
    item.listId = _listId;
    item.retractionTimestamp = 0;
    item.commitTimestamp = uint32(block.timestamp);
    item.harddata = _harddata;

    emit ItemAdded(_listId, _ipfsUri, _harddata);
  }

  // todo redo this function
  // will be refactored into attempting to adopt / revive if not owned.
  function editItem(
    uint64 _itemId,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external {
    Item storage item = items[_itemId];
    require(listLegalCheck(item.listId), "Cannot edit item in illegal list");
    Account memory account = accounts[item.accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    require(item.retractionTimestamp == 0, "Item is being removed");
    require(item.state == ItemState.Included, "Item must be Included");
    uint256 freeStake = getFreeStake(account);
    List memory list = lists[item.listId];
    require(freeStake >= Cint32.decompress(list.requiredStake), "Cannot afford to edit this item");

    item.harddata = _harddata;
    item.commitTimestamp = uint32(block.timestamp);

    emit ItemEdited(_itemId, _ipfsUri, _harddata);
  }

  /**
   * @dev Starts an item retraction process.
   * @param _itemId Item to retract.
   */
  function startRetractItem(uint64 _itemId) external {
    Item storage item = items[_itemId];
    Account memory account = accounts[item.accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    require(item.retractionTimestamp == 0, "Item is already being retracted");
    require(item.state == ItemState.Included, "Item must be Included");

    item.retractionTimestamp = uint32(block.timestamp);
    emit ItemStartRetraction(_itemId);
  }

  /**
   * @dev Cancels an ongoing retraction process.
   * @param _itemId Item to stop retracting.
   */
  function cancelRetractItem(uint64 _itemId) external {
    Item storage item = items[_itemId];
    Account memory account = accounts[item.accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    // v todo this might be flawed. item may be outdated, uncollateralized...
    // but, solution may be to just stop the retraction on edit / recommit
    require(getItemState(_itemId) == ItemState.Retracting, "Item is not being retracted");
    item.retractionTimestamp = 0;
    emit ItemStopRetraction(_itemId);
  }

  /**
   * @dev Updates commit timestamp of an item. This is used as protection for 
   * item submitters. Items have to opt in to the new list version.
   * @param _itemId Item to recommit.
   */
  // todo redo this function. instead of just updating, it should act as the goto function for:
  // adopting
  // reviving an item (because they can be Removed, Retracted, etc...)
  // the previous "update commit timestamp" usage for list versions.
  // function currently broken.
  function recommitItem(uint64 _itemId) external {
    Item storage item = items[_itemId];
    require(listLegalCheck(item.listId), "Cannot recommit item in illegal list");

    Account memory account = accounts[item.accountId];
    List memory list = lists[item.listId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    require(item.retractionTimestamp == 0, "Item is being retracted");
    
    uint256 freeStake = getFreeStake((account));
    require(freeStake >= Cint32.decompress(list.requiredStake), "Not enough to recommit item");

    item.commitTimestamp = uint32(block.timestamp);

    emit ItemRecommitted(_itemId);
  }

  /**
   * @notice Challenge an item, with the intent of removing it and obtaining a reward.
   * @param _itemId Item to challenge.
   * @param _editionTimestamp The challenge is made upon the edition available at this timestamp.
   * @param _reason IPFS uri containing the evidence for the challenge.
   */
  function challengeItem(
    uint64 _itemId,
    uint32 _editionTimestamp,
    string calldata _reason
  ) external payable returns (uint64 id) {
    require(
      _editionTimestamp + stakeCurateSettings.challengeWindow >= block.timestamp,
      "Too late to challenge that edition"
    );
    Item storage item = items[_itemId];
    Account storage account = accounts[item.accountId];
    List memory list = lists[item.listId];

    // editions of outdated versions are unincluded and thus cannot be challenged
    // this require covers the edge case: item owner updates before the challenge window
    require(_editionTimestamp >= list.versionTimestamp, "This edition belongs to an outdated list version");

    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    // challenger must cover challengerStake + arbitrationCost
    // todo refactor when erc20 stakes, as challengerStake will be expressed in tokens
    require(msg.value >= 
      Cint32.decompress(list.challengerStake)
      + arbSetting.arbitrator.arbitrationCost(arbSetting.arbitratorExtraData),
      "Not covering the full cost"
    );
    
    // Item can be challenged if: Young, Included, Retracting
    ItemState dynamicState = getItemState(_itemId);
    require(
      dynamicState == ItemState.Young
      || dynamicState == ItemState.Included
      || dynamicState == ItemState.Retracting
    , "Item cannot be challenged");

    // All requirements met, begin
    unchecked {id = disputeCount++;}

    // create dispute
    uint256 arbitratorDisputeId =
      arbSetting.arbitrator.createDispute{
        value: arbSetting.arbitrator.arbitrationCost(arbSetting.arbitratorExtraData)}(
        RULING_OPTIONS, arbSetting.arbitratorExtraData
      );
    require(arbitratorAndDisputeIdToLocal
      [address(arbSetting.arbitrator)][arbitratorDisputeId] == 0, "disputeId already in use");

    arbitratorAndDisputeIdToLocal
      [address(arbSetting.arbitrator)][arbitratorDisputeId] = id;

    item.state = ItemState.Disputed;

    account.lockedStake =
        Cint32.compress(Cint32.decompress(account.lockedStake)
        + Cint32.decompress(list.requiredStake));

    disputes[id] = DisputeSlot({
      arbitratorDisputeId: arbitratorDisputeId,
      itemId: _itemId,
      challengerId: accountRoutine(msg.sender),
      arbitrationSetting: list.arbitrationSettingId,
      state: DisputeState.Used,
      itemStake: list.requiredStake,
      challengerStake: list.challengerStake,
      freespace: 0
    });

    emit ItemChallenged(_itemId, _editionTimestamp, _reason);
    // ERC 1497
    uint256 evidenceGroupId = _itemId;
    emit Dispute(
      arbSetting.arbitrator, arbitratorDisputeId,
      stakeCurateSettings.currentMetaEvidenceId, evidenceGroupId
    );
    emit Evidence(arbSetting.arbitrator, evidenceGroupId, msg.sender, _reason);
  }

  /**
   * @dev Submits evidence to potentially any dispute or item.
   * @param _itemId Id of the item to submit evidence to.
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
  function submitEvidence(uint64 _itemId, IArbitrator _arbitrator, string calldata _evidence) external {
    emit Evidence(_arbitrator, _itemId, msg.sender, _evidence);
  }

  /**
   * @dev External function for the arbitrator to decide the result of a dispute. TRUSTED
   * @param _disputeId External id of the dispute
   * @param _ruling Ruling of the dispute. If 0 or 1, submitter wins. Else (2) challenger wins
   */
  function rule(uint256 _disputeId, uint256 _ruling) external override {
    // 1. get slot from dispute
    uint64 localDisputeId = arbitratorAndDisputeIdToLocal[msg.sender][_disputeId];
    DisputeSlot storage dispute =
      disputes[localDisputeId];
    ArbitrationSetting storage arbSetting = arbitrationSettings[dispute.arbitrationSetting];
    require(msg.sender == address(arbSetting.arbitrator), "Only arbitrator can rule");
    // require above removes the need to require disputeSlot != 0.
    // because disputes[0] has arbitrationSettings[0] which has arbitrator == address(0)
    // and no one will be able to call from address(0)

    // 2. refunds gas. having reached this step means
    // dispute.state == DisputeState.Used
    // deleting the mapping makes the arbitrator unable to recall
    // this function*
    // * bad arbitrator can rule this, and then reuse the disputeId.
    arbitratorAndDisputeIdToLocal[msg.sender][_disputeId] = 0;

    Item storage item = items[dispute.itemId];
    Account storage account = accounts[item.accountId];
    // 3. apply ruling. what to do when refuse to arbitrate?
    // just default towards keeping the item.
    // 0 refuse, 1 staker, 2 challenger.
    if (_ruling == 1 || _ruling == 0) {
      // staker won.
      // 4a. return item to used, not disputed.
      if (item.retractionTimestamp != 0) {
        item.retractionTimestamp = uint32(block.timestamp);
      }
      item.state = ItemState.Included;
      // free the locked stake
      uint256 lockedAmount = Cint32.decompress(account.lockedStake);
      unchecked {
        uint256 updatedLockedAmount = lockedAmount - Cint32.decompress(dispute.itemStake);
        account.lockedStake = Cint32.compress(updatedLockedAmount);
      }
      // pay the challengerStake to the submitter
      payable(account.owner).send(Cint32.decompress(dispute.challengerStake));
    } else {
      // challenger won.
      // 4b. slot is now Removed
      item.state = ItemState.Removed;
      // now, award the dispute stake to challenger
      uint256 amount = Cint32.decompress(dispute.itemStake) + Cint32.decompress(dispute.challengerStake);
      // remove amount from the account
      account.fullStake = Cint32.compress(Cint32.decompress(account.fullStake) - amount);
      account.lockedStake = Cint32.compress(Cint32.decompress(account.lockedStake) - amount);
      // is it dangerous to send before the end of the function? please answer on audit
      payable(accounts[dispute.challengerId].owner).send(amount);
    }
    // destroy the disputeSlot information, to trigger refunds
    disputes[localDisputeId] = DisputeSlot({
      arbitratorDisputeId: 0,
      itemId: 0,
      challengerId: 0,
      arbitrationSetting: 0,
      state: DisputeState.Free,
      itemStake: 0,
      challengerStake: 0,
      freespace: 0
    });

    emit Ruling(arbSetting.arbitrator, _disputeId, _ruling);
  }

  function getItemState(uint64 _itemId) public view returns (ItemState) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    if (
        item.state == ItemState.Removed
        || item.state == ItemState.Disputed
        || item.state == ItemState.Nothing
    ) {
      // these states are returned as they are.
      return (item.state);
    } else if (
        // gone fully through retraction
        item.retractionTimestamp != 0
        && item.retractionTimestamp + list.retractionPeriod <= block.timestamp
    ) {
      return (ItemState.Retracted);
    } else if (!listLegalCheck(item.listId)) {
      return (ItemState.IllegalList);
    } else if (
        // not held by the required stake
        (
          accounts[item.accountId].withdrawingTimestamp != 0
          && accounts[item.accountId].withdrawingTimestamp
            + stakeCurateSettings.withdrawalPeriod <= block.timestamp
        )
        || getFreeStake(accounts[item.accountId]) < Cint32.decompress(list.requiredStake)
    ) {
      return (ItemState.Uncollateralized);
    } else if (item.commitTimestamp <= list.versionTimestamp) {
      return (ItemState.Outdated);
    } else if (item.retractionTimestamp != 0) {
      return (ItemState.Retracting);
    } else if (
        // todo check account balances
        // to figure out the latest moment in which collateralization was interrupted
        item.commitTimestamp + list.ageForInclusion < block.timestamp
    ) {
      return (ItemState.Young);
    } else {
      return (ItemState.Included);
    }
  }

  // todo redo with getItemState
  // also make it a public view, with _itemId
  function itemIsInAdoption(Item memory _item, List memory _list, Account memory _account) internal view returns (bool) {
    // check if any of the 5 conditions for adoption is met:
    bool beingRetracted = _item.retractionTimestamp != 0;
    bool accountWithdrawing = _account.withdrawingTimestamp != 0;
    bool noCommitAfterListUpdate = _item.commitTimestamp <= _list.versionTimestamp
      && block.timestamp >= _list.versionTimestamp + _list.upgradePeriod;
    bool notEnoughFreeStake = getFreeStake(_account) < Cint32.decompress(_list.requiredStake);
    return (
      beingRetracted
      || accountWithdrawing
      || noCommitAfterListUpdate
      || notEnoughFreeStake
      || _list.freeAdoptions
    );
  }

  function arbitrationCost(uint64 _itemId) external view returns (uint256 cost) {
    ArbitrationSetting memory setting =
      arbitrationSettings[lists[items[_itemId].listId].arbitrationSettingId];
    return (setting.arbitrator.arbitrationCost(setting.arbitratorExtraData));
  }

  function listLegalCheck(uint64 _listId) public view returns (bool isLegal) {
    List memory list = lists[_listId];
    // todo check ageForInclusion is below maximum
    // todo check challenger stake is over minimum ratio
    isLegal = true;
  }

  // ----- PURE FUNCTIONS -----

  function getFreeStake(Account memory _account) internal pure returns (uint256) {
    unchecked {
      return (Cint32.decompress(_account.fullStake) - Cint32.decompress(_account.lockedStake));
    }
  }
}