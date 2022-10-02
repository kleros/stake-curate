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
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
  enum AdoptionState { Unavailable, OnlyOwner, FullAdoption }

  /**
   * @dev "+" means the state can be stored. Else, is dynamic. Meanings:
   * +Nothing: does not exist yet.
   * Young: item is not considered included, but can be challenged.
   * +Included: the item is considered included, can be challenged.
   * +Disputed: currently under a Dispute.
   * +Removed: a Dispute ruled to remove this item.
   * IllegalList: item belongs to a list with bad parameters.
   * * interaction is purposedly discouraged.
   * Uncollateralized: owner doesn't have enough collateral,
   * * also triggers if owner can withdraw.
   * Outdated: item was committed before the last list version.
   * Retracting: owner is currently retracting the item.
   * * can still be challenged.
   * Retracted: owner made it go through the retraction period.
   * Withdrawing: item can be challenged, but the owner is in a
   * * withdrawing period.
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
    Retracted,
    Withdrawing
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
    // --- 2nd slot
    // prevents relevant historical balance checks from being too long
    uint32 maxAgeForInclusion;
    
    // minimum challengerStake/requiredStake ratio, in basis points
    uint32 minChallengerStakeRatio;
    // burn rate in basis points. applied in "flash withdrawals",
    // requiredStakes on good challenge, challengerStake in bad challenge.
    uint32 burnRate;
    // receives the burns, could be an actual burn address like address(0)
    // could alternatively act as some kind of public goods funding, or rent.
    address burner;
    // --- 3rd slot
    // maximum size, in time, of a balance record. they are kept in order to
    // dynamically find out the age of items.
    uint32 balanceSplitPeriod;
  }

  struct Account {
    address owner;
    // todo count of items owned, for erc-721 visibility
  }

  struct Stake {
    uint32 free;
    uint32 locked;
    uint32 withdrawingTimestamp;
  }

  struct BalanceSplit {
    // moment the split begins
    // a split ends at start + balanceSplitPeriod
    uint32 startTime;
    // minimum amount there was, from the startTime, to the end of the split.
    uint32 min;
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
    IERC20 token;
    bool freeAdoptions; // all items are in adoption all the time
    uint32 challengerStake; // how much challenger puts as stake to be awarded on failure to owner
    uint32 ageForInclusion; // how much time from Young to Included, in seconds
  }

  struct Item {
    // account that owns the item
    uint64 accountId;
    // list under which the item is submitted. immutable after creation.
    uint64 listId;
    // if not zero, marks the start of a retraction process.
    uint32 retractionTimestamp;
    // hard state of the item, some states can be written in storage.
    ItemState state;
    // last explicit committal to collateralize the item.
    uint32 commitTimestamp;

    uint64 freeSpace;
    // arbitrary, optional data for on-chain consumption
    bytes harddata;
  }

  struct DisputeSlot {
    // todo remove, this property is never used, since it's accessed through mapping.
    // this was probably added back in the days appeals were included here.
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
    IERC20 token;
  }

  struct ArbitrationSetting {
    bytes arbitratorExtraData;
    IArbitrator arbitrator;
  }

  // ----- EVENTS -----

  // Used to initialize counters in the subgraph
  event StakeCurateCreated();
  event ChangedStakeCurateSettings(StakeCurateSettings _settings);

  event AccountCreated(address _owner);
  event AccountFunded(uint64 _accountId, IERC20 _token, uint32 _freeStake);
  event AccountStartWithdraw(IERC20 _token);
  event AccountStopWithdraw(IERC20 _token);
  event AccountWithdrawn(IERC20 _token, uint32 _freeStake);

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
  mapping(uint64 => mapping(address => Stake)) public stakes;
  mapping(uint64 => mapping(address => BalanceSplit[])) public splits;

  mapping(uint64 => List) public lists;
  mapping(uint64 => Item) public items;
  mapping(uint64 => DisputeSlot) public disputes;
  mapping(address => mapping(uint256 => uint64)) public arbitratorAndDisputeIdToLocal;
  mapping(uint64 => ArbitrationSetting) public arbitrationSettings;

  /** 
   * @dev Constructs the StakeCurate contract.
   * @param _settings Initial StakeCurate Settings.
   * @param _metaEvidence IPFS uri of the initial MetaEvidence
   */
  constructor(StakeCurateSettings memory _settings, string memory _metaEvidence) {
    _settings.currentMetaEvidenceId = 0; // make sure it's set to zero
    stakeCurateSettings = _settings;

    // purpose: prevent dispute zero from being used.
    // this dispute has the ArbitrationSetting = 0. it will be
    // made impossible to rule with, and kept with arbitrator = address(0) forever,
    // so, it cannot be ruled. thus, requiring the disputeSlot != 0 on rule is not needed.
    arbitrationSettingCount = 1;
    disputes[0].state = DisputeState.Used;
    disputeCount = 1; // since disputes are incremental, prevent local dispute 0
    accountCount = 1; // accounts[0] cannot be used either

    emit StakeCurateCreated();
    emit ChangedStakeCurateSettings(_settings);
    emit MetaEvidence(0, _metaEvidence);
    emit ArbitrationSettingCreated(address(0), "");
  }

  // ----- PUBLIC FUNCTIONS -----

  /**
   * @dev Governor changes the general settings of Stake Curate
   * @param _settings New settings. The currentMetaEvidenceId is not used
   * @param _metaEvidence IPFS uri to the new MetaEvidence
   */
  function changeStakeCurateSettings(
    StakeCurateSettings memory _settings,
    string calldata _metaEvidence
  ) external {
    require(msg.sender == stakeCurateSettings.governor, "Only governor can change these settings");
    // currentMetaEvidenceId must be incremental, so preserve previous one.
    _settings.currentMetaEvidenceId = stakeCurateSettings.currentMetaEvidenceId;
    stakeCurateSettings = _settings;
    emit ChangedStakeCurateSettings(_settings);
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
        owner: _owner
      });
      emit AccountCreated(_owner);
    }
  }

  /**
   * @dev Funds an existing account.
   * @param _recipient Address of the account that receives the funds.
   * @param _token Token to fund the account with.
   * @param _amount How much token to fund with.
   */
  function fundAccount(address _recipient, IERC20 _token, uint256 _amount) external {
    require(_token.transferFrom(msg.sender, address(this), _amount), "Fund: transfer failed");
    uint64 accountId = accountRoutine(_recipient);

    Stake storage stake = stakes[accountId][address(_token)];
    uint256 freeStake = Cint32.decompress(stake.free) + _amount;
    stake.free = Cint32.compress(freeStake);
    balanceRecordRoutine(accountId, address(_token), freeStake);
    emit AccountFunded(accountId, _token, stake.free);
  }

  /**
   * @dev Starts a withdrawal process on your account, for a token.
   * Withdrawals are not instant to prevent frontrunning.
   * @param _token Token to start withdrawing.
   */
  function startWithdraw(IERC20 _token) external {
    uint64 accountId = accountRoutine(msg.sender);
    stakes[accountId][address(_token)].withdrawingTimestamp = uint32(block.timestamp);
    emit AccountStartWithdraw(_token);
  }
  /**
   * @dev Stops a withdrawal process on your account, for a token.
   * @param _token Token to stopwithdrawing.
   */
  function stopWithdraw(IERC20 _token) external {
    uint64 accountId = accountRoutine(msg.sender);
    stakes[accountId][address(_token)].withdrawingTimestamp = 0;
    emit AccountStopWithdraw(_token);
  }

  /**
   * @dev Withdraws any amount of held token for your account.
   * calling after withdrawing period entails to a full withdraw.
   * Otherwise, a part of the requested amount will be burnt.
   * @param _token Token to withdraw.
   * @param _amount The amount to be withdrawn.
   */
  function withdrawAccount(IERC20 _token, uint256 _amount) external {
    uint64 accountId = accountRoutine(msg.sender);
    uint256 toSender;
    uint256 toBurn = 0;
    Stake storage stake = stakes[accountId][address(_token)];
    if (
      (stake.withdrawingTimestamp + stakeCurateSettings.withdrawalPeriod)
      <= block.timestamp
    ) {
      // no burn, since the period was completed.
      toSender = _amount;
    } else {
      // burn. round the burn up.
      toSender = _amount * (10_000 - stakeCurateSettings.burnRate) / 10_000;
      toBurn = _amount - toSender;
    }

    uint256 freeStake = Cint32.decompress(stake.free);
    require(freeStake >= _amount, "Cannot afford this withdraw");
    // guard
    stake.free = Cint32.compress(freeStake - _amount);
    balanceRecordRoutine(accountId, address(_token), freeStake - _amount);
    stake.withdrawingTimestamp = 0;
    if (toBurn != 0) {
      _token.transfer(stakeCurateSettings.burner, toBurn);
    }
    // withdraw
    _token.transfer(msg.sender, toSender);
    emit AccountWithdrawn(_token, stake.free);
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
   * @param _governor The governor of the list.
   * @param _list The list to create.
   * @param _metalist IPFS uri with additional data pertaining to the list.
   */
  function createList(
      address _governor,
      List memory _list,
      string calldata _metalist
  ) external returns (uint64 id) {
    require(_list.arbitrationSettingId < arbitrationSettingCount, "ArbitrationSetting must exist");
    unchecked {id = listCount++;}
    _list.governorId = accountRoutine(_governor);
    lists[id] = _list;
    require(listLegalCheck(id), "Cannot create illegal list");
    emit ListCreated(_list, _metalist);
  }

  /**
   * @dev Updates an existing list. Can only be called by its governor.
   * @param _governor The governor of the list.
   * @param _listId Id of the list to be updated.
   * @param _list New list data to replace current one.
   * @param _metalist IPFS uri with additional data pertaining to the list.
   */
  function updateList(
    address _governor,
    uint64 _listId,
    List memory _list,
    string calldata _metalist
  ) external {
    require(_list.arbitrationSettingId < arbitrationSettingCount, "ArbitrationSetting must exist");
    require(accounts[lists[_listId].governorId].owner == msg.sender, "Only governor can update list");
    _list.governorId = accountRoutine(_governor);
    lists[_listId] = _list;
    require(listLegalCheck(_listId), "Cannot make list illegal");
    emit ListUpdated(_listId, _list, _metalist);
  }

  /**
   * @notice Adds an item to a list.
   * @param _listId Id of the list the item will be included in
   * @param _forListVersion Timestamp of the version this action is intended for.
   * If list governor were to frontrun a version change, then it reverts.
   * @param _ipfsUri IPFS uri that links to the content of the item
   * @param _harddata Optional data that is stored on-chain
   */
  function addItem(
    uint64 _listId,
    uint32 _forListVersion,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external returns (uint64 id) {
    require(listLegalCheck(_listId), "Cannot add item to illegal list");
    uint64 accountId = accountRoutine(msg.sender);
    unchecked {id = itemCount++;}
    require(_forListVersion == lists[_listId].versionTimestamp, "Different list version");

    // we create the item, then check if it's valid.
    items[id] = Item({
      accountId: accountId,
      listId: _listId,
      retractionTimestamp: 0,
      state: ItemState.Included,
      commitTimestamp: uint32(block.timestamp),
      freeSpace: 0,
      harddata: _harddata
    });
    // if not Young or Included, something went wrong so it's reverted
    ItemState newState = getItemState(id);
    require(
      newState == ItemState.Included || newState == ItemState.Young,
      "Revert item creation: would be invalid"
    );

    emit ItemAdded(_listId, _ipfsUri, _harddata);
  }

  function editItem(
    uint64 _itemId,
    uint32 _forListVersion,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external {
    Item memory preItem = items[_itemId];
    require(
      _forListVersion == lists[preItem.listId].versionTimestamp,
      "Different list version"
    );
    AdoptionState adoption = getAdoptionState(_itemId);
    require(adoption != AdoptionState.Unavailable, "Item cannot be edited");


    uint64 senderId = accountRoutine(msg.sender);
    // if not current owner: can only edit if FullAdoption
    require(
      adoption == AdoptionState.FullAdoption || senderId == preItem.accountId,
      "Unauthorized edit"
    );
    
    // instead of further checks, just edit the item and do a status check.
    items[_itemId] = Item({
      accountId: senderId,
      listId: preItem.listId,
      retractionTimestamp: 0,
      state: ItemState.Included,
      commitTimestamp: uint32(block.timestamp),
      freeSpace: 0,
      harddata: _harddata
    });
    // if not Young or Included, something went wrong so it's reverted
    ItemState newState = getItemState(_itemId);
    require(
      newState == ItemState.Included || newState == ItemState.Young,
      "No edit: would be invalid"
    );    

    emit ItemEdited(_itemId, _ipfsUri, _harddata);
  }

  /**
   * @dev Starts an item retraction process.
   * @param _itemId Item to retract.
   */
   // todo fix, this is wrong rn
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
    require(getItemState(_itemId) == ItemState.Retracting, "Item is not being retracted");
    item.retractionTimestamp = 0;
    emit ItemStopRetraction(_itemId);
  }

  /**
   * @dev Updates commit timestamp of an item. It also reclaims the item if
   * sender is different from previous owner, according to adoption rules.
   * The difference with editItem is that recommitItem doesn't create a new edition.
   * @param _itemId Item to recommit.
   * @param _forListVersion Timestamp of the version this action is intended for.
   * If list governor were to frontrun a version change, then it reverts.
   */
  function recommitItem(uint64 _itemId, uint32 _forListVersion) external {
    Item memory preItem = items[_itemId];
    require(
      _forListVersion == lists[preItem.listId].versionTimestamp,
      "Different list version"
    );
    AdoptionState adoption = getAdoptionState(_itemId);
    require(adoption != AdoptionState.Unavailable, "Item cannot be recommitted");
    uint64 senderId = accountRoutine(msg.sender);
    // if not current owner: can only recommit if FullAdoption
    require(
      adoption == AdoptionState.FullAdoption || senderId == preItem.accountId,
      "Unauthorized recommit"
    );

    // instead of further checks, just change the item and do a status check.
    Item storage item = items[_itemId];
    // to recommit, we change values directly to avoid "rebuilding" the harddata
    item.accountId = senderId;
    item.retractionTimestamp = 0;
    // item.lastRuledTimestamp = 0; is more "correct", but won't affect anything.
    item.state = ItemState.Included;
    item.commitTimestamp = uint32(block.timestamp);

    // if not Young or Included, something went wrong so it's reverted
    ItemState newState = getItemState(_itemId);
    require(
      newState == ItemState.Included || newState == ItemState.Young,
      "No recommit: would be invalid"
    );

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
    List memory list = lists[item.listId];
    Stake storage stake = stakes[item.accountId][address(list.token)];

    // editions of outdated versions are unincluded and thus cannot be challenged
    // this require covers the edge case: item owner updates before the challenge window
    // it also protects challenger from malicious list updates snatching the challengerStake
    require(_editionTimestamp >= list.versionTimestamp, "This edition belongs to an outdated list version");

    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    // challenger must cover arbitrationCost in value
    require(msg.value >= arbSetting.arbitrator.arbitrationCost(arbSetting.arbitratorExtraData),
      "Not covering the arbitration cost"
    );

    // and challengerStake in allowed tokens. try to get them
    require(
      list.token.transferFrom(
        msg.sender,
        address(this),
        Cint32.decompress(list.challengerStake)
      ),
      "Challenger stake not covered"
    );
    
    // Item can be challenged if: Young, Included, Retracting, Withdrawing
    ItemState dynamicState = getItemState(_itemId);
    require(
      dynamicState == ItemState.Young
      || dynamicState == ItemState.Included
      || dynamicState == ItemState.Retracting
      || dynamicState == ItemState.Withdrawing
    , "Item cannot be challenged");

    // All requirements met, begin
    unchecked {id = disputeCount++;}

    // create dispute
    uint256 arbitratorDisputeId =
      arbSetting.arbitrator.createDispute{
        value: msg.value}(
        RULING_OPTIONS, arbSetting.arbitratorExtraData
      );
    require(arbitratorAndDisputeIdToLocal
      [address(arbSetting.arbitrator)][arbitratorDisputeId] == 0, "disputeId already in use");

    arbitratorAndDisputeIdToLocal
      [address(arbSetting.arbitrator)][arbitratorDisputeId] = id;

    item.state = ItemState.Disputed;
    
    uint256 toLock = Cint32.decompress(list.requiredStake);
    uint256 newFreeStake = Cint32.decompress(stake.free) - toLock;
    uint64 challengerId = accountRoutine(msg.sender);
    balanceRecordRoutine(challengerId, address(list.token), newFreeStake);

    stake.free = Cint32.compress(Cint32.decompress(stake.free) - toLock);
    stake.locked = Cint32.compress(Cint32.decompress(stake.locked) + toLock);

    disputes[id] = DisputeSlot({
      arbitratorDisputeId: arbitratorDisputeId,
      itemId: _itemId,
      challengerId: challengerId,
      arbitrationSetting: list.arbitrationSettingId,
      state: DisputeState.Used,
      itemStake: list.requiredStake,
      challengerStake: list.challengerStake,
      freespace: 0,
      token: list.token
    });

    emit ItemChallenged(_itemId, _editionTimestamp, _reason);
    // ERC 1497
    // evidenceGroupId is the itemId, since it's unique per item
    emit Dispute(
      arbSetting.arbitrator, arbitratorDisputeId,
      stakeCurateSettings.currentMetaEvidenceId, _itemId
    );
    emit Evidence(arbSetting.arbitrator, _itemId, msg.sender, _reason);
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
   // todo refactor to support Resolver evidence interface?
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
    // * bad arbitrator can reuse a disputeId after ruling.
    arbitratorAndDisputeIdToLocal[msg.sender][_disputeId] = 0;

    Item storage item = items[dispute.itemId];
    Account storage account = accounts[item.accountId];
    Stake storage stake = stakes[item.accountId][address(dispute.token)];
    uint256 award;
    address awardee;
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
      uint256 toUnlock = Cint32.decompress(dispute.itemStake);
      uint256 newFreeStake = Cint32.decompress(stake.free) + toUnlock;
      balanceRecordRoutine(item.accountId, address(dispute.token), newFreeStake);

      stake.free = Cint32.compress(newFreeStake);
      stake.locked = Cint32.compress(Cint32.decompress(stake.locked) - toUnlock);
      
      award = Cint32.decompress(dispute.challengerStake);
      awardee = account.owner;
    } else {
      // challenger won.
      // 4b. slot is now Removed
      item.state = ItemState.Removed;

      award = Cint32.decompress(dispute.itemStake);
      awardee = accounts[dispute.challengerId].owner;

      // remove amount from the locked stake of the account
      stake.locked = Cint32.compress(Cint32.decompress(stake.locked) - award);
    }

    uint256 toAccount = award * (10_000 - stakeCurateSettings.burnRate) / 10_000;
    uint256 toBurn = award - toAccount;
    // todo should do try catch, to prevent items from being stuck?
    // also how to prevent bad arbitrators from getting rules stuck?
    dispute.token.transfer(account.owner, toAccount);
    dispute.token.transfer(stakeCurateSettings.burner, toBurn);
    // destroy the disputeSlot information, to trigger refunds
    disputes[localDisputeId] = DisputeSlot({
      arbitratorDisputeId: 0,
      itemId: 0,
      challengerId: 0,
      arbitrationSetting: 0,
      state: DisputeState.Free,
      itemStake: 0,
      challengerStake: 0,
      freespace: 0,
      token: IERC20(address(0))
    });

    emit Ruling(arbSetting.arbitrator, _disputeId, _ruling);
  }

  function getItemState(uint64 _itemId) public view returns (ItemState) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    Stake memory stake = stakes[item.accountId][address(list.token)];
    if (item.state == ItemState.Disputed) {
      // if item is disputed, no matter if list is illegal, the dispute predominates.
      return (ItemState.Disputed);
    } else if (!listLegalCheck(item.listId)) {
      // list legality is then checked, to prevent meaningful interaction
      // with illegal lists.
      return (ItemState.IllegalList);
    } else if (
        item.state == ItemState.Removed
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
    } else if (
        // has gone through Withdrawing period,
        // or not held by the required stake
        (
          stake.withdrawingTimestamp != 0
          && stake.withdrawingTimestamp
            + stakeCurateSettings.withdrawalPeriod <= block.timestamp
        )
        || Cint32.decompress(stake.free) < Cint32.decompress(list.requiredStake)
    ) {
      return (ItemState.Uncollateralized);
    } else if (item.commitTimestamp <= list.versionTimestamp) {
      return (ItemState.Outdated);
    } else if (item.retractionTimestamp != 0) {
      // Retracting is checked at the end, because it signals that the
      // item is currently collateralized. 
      return (ItemState.Retracting);
    } else if (stake.withdrawingTimestamp != 0) {
      return (ItemState.Withdrawing);
    } else if (
        item.commitTimestamp + list.ageForInclusion > block.timestamp
        || !continuousBalanceCheck(_itemId) 
    ) {
      return (ItemState.Young);
    } else {
      return (ItemState.Included);
    }
  }

  // even though it's "Adoption", this is also an umbrella term for "recommitting"
  function getAdoptionState(uint64 _itemId) public view returns (AdoptionState) {
    ItemState state = getItemState(_itemId);
    // only these two ItemStates cannot be adopted in any circumstance
    // Disputed, you need to wait for the Dispute to be resolved first.
    // IllegalList, because, no matter the conditions of the item,
    // the illegality of the list prevents further interaction with the item.
    if (state == ItemState.Disputed || state == ItemState.IllegalList) {
      return (AdoptionState.Unavailable);
    }

    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    if (list.freeAdoptions) {
      // now, any kind of adoption is allowed with freeAdoptions
      return (AdoptionState.FullAdoption);
    }
    // adoption in Removed or Outdated depend on the time.
    // todo do same for uncollateralized??
    // when item is ruled to be Removed, a commitTimestamp is set for this purpose.
    if (state == ItemState.Removed) {
      if ((item.commitTimestamp + list.upgradePeriod) >= block.timestamp) {
        // not enough time ellapsed for item to be in full adoption
        return (AdoptionState.OnlyOwner);
      } else {
        // item is removed + it's gone through the upgrade period, so it can be adopted.
        return (AdoptionState.FullAdoption);
      }
    }
    // when item is Outdated, the timestamp of the version is compared
    if (state == ItemState.Outdated) {
      if ((list.versionTimestamp + list.upgradePeriod) >= block.timestamp) {
        return (AdoptionState.OnlyOwner);
      } else {
        return (AdoptionState.FullAdoption);
      }
    }
    // Young and Included imply intent on keeping the item
    if (state == ItemState.Young || state == ItemState.Included) {
      return (AdoptionState.OnlyOwner);
    }
    // anything else is a state in which owner neglects (e.g. Uncollateralized)
    // or purposedly wants to get rid of it (e.g. Retracting)
    return (AdoptionState.FullAdoption);
  }

  function arbitrationCost(uint64 _itemId) external view returns (uint256 cost) {
    ArbitrationSetting memory setting =
      arbitrationSettings[lists[items[_itemId].listId].arbitrationSettingId];
    return (setting.arbitrator.arbitrationCost(setting.arbitratorExtraData));
  }

  function listLegalCheck(uint64 _listId) public view returns (bool isLegal) {
    List memory list = lists[_listId];
    if (list.ageForInclusion > stakeCurateSettings.maxAgeForInclusion) {
      isLegal = false;
    } else if (
      ((Cint32.decompress(list.challengerStake) * 10_000)
      / Cint32.decompress(list.requiredStake)) < stakeCurateSettings.minChallengerStakeRatio
    ) {
      isLegal = false;
    } else {
      isLegal = true;
    }
  }

  function balanceRecordRoutine(uint64 _accountId, address _token, uint256 _freeStake) internal {
    uint256 len = splits[_accountId][_token].length;
    BalanceSplit storage pastSplit = splits[_accountId][_token][len - 1];
    uint256 pastAmount = Cint32.decompress(pastSplit.min);
    if (_freeStake <= pastAmount) {
      // when lower, always rewrite split down.
      pastSplit.min = Cint32.compress(_freeStake);
    } else {
      // since it's higher, check last record time to consider appending.
      if (block.timestamp >= pastSplit.startTime + stakeCurateSettings.balanceSplitPeriod) {
        // out of the period. a new split will be made.
        splits[_accountId][_token].push(BalanceSplit({
          startTime: uint32(block.timestamp),
          min: Cint32.compress(_freeStake)
        }));
      }
      // if it's higher and within the split, don't update. 
    }
  }

  function continuousBalanceCheck(uint64 _itemId) internal view returns (bool) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    uint256 requiredStake = Cint32.decompress(list.requiredStake);
    uint256 targetTime = block.timestamp - list.ageForInclusion;
    uint64 accountId = item.accountId;
    address token = address(list.token);
    uint256 splitPointer = splits[accountId][token].length - 1;
    // keep track of the amount of the immediately later split (or, current free).
    uint256 laterAmount = Cint32.decompress(stakes[accountId][token].free);
    
    if (requiredStake > laterAmount) return (false);

    uint256 period = stakeCurateSettings.balanceSplitPeriod;

    // we want to process pointer 0, so go until we overflow
    while (splitPointer != type(uint256).max) {
      BalanceSplit memory split = splits[accountId][token][splitPointer];
      // todo make a drawing of this so that people understand.
      // basically: we want to check that the item was continuously collateralized
      // during the period. there are periods during which we know
      // that there was a certain minimum amount at some time.
      // there are also dark ages in between splits during which
      // we don't know how much stake there was, but, it was either
      // equal or greater than previous.

      // when we land in a dark age, if that's earlier than target,
      // since we survived so far, we naively assume it was collateralized.
      // this can be wrong, but here it's better to err on inclusion.
      if ((split.startTime + period) <= targetTime) return (true);
      // otherwise, we test if we can pass the split.
      if (requiredStake > split.min) return (false);
      // we survived, and now check within the split.
      if (split.startTime <= targetTime) return (true);
      
      unchecked { splitPointer--; }
    }

    // target is beyong the earliest record, not enough time for collateralization.
    return (false);
  }
}