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
  /**
   * @dev "Adoption" pretty much means "you can / cannot edit or recommit".
   *  To avoid redundancy, this applies either if new owner is different or not.
   */
  enum AdoptionState { FullAdoption, NeedsOutbid }

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
    uint32 withdrawingTimestamp;
    // todo count of items owned, for erc-721 visibility
    // todo bankrun protection #2 preference (receive, stake as free, stake as free and increase item)
  }

  struct BalanceSplit {
    // moment the split begins
    // a split ends when the following split starts, or block.timestamp if last.
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
    uint32 maxStake; // protects from some frontrun attacks
    // ----
    IERC20 token;
    uint32 challengerStakeRatio; // (basis points) challenger stake in proportion to the item stake
    uint32 ageForInclusion; // how much time from Young to Included, in seconds
    uint32 freeSpace2;
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
    // how much stake is backing up the item. will be equal or greater than list.requiredStake
    uint32 stake;
    uint32 freeSpace;
    // arbitrary, optional data for on-chain consumption
    bytes harddata;
  }

  struct DisputeSlot {
    uint64 challengerId;
    uint64 itemId;
    uint64 arbitrationSetting;
    DisputeState state;
    uint32 itemStake; // unlocks to submitter if Keep, sent to challenger if Remove
    uint24 freespace;
    // ----
    IERC20 token;
    uint32 challengerStake; // put by the challenger, sent to whoever side wins.
    uint64 itemOwnerId; // since items may change hands during the dispute, you need to store
    // the owner at dispute time.
  }

  struct ArbitrationSetting {
    bytes arbitratorExtraData;
    IArbitrator arbitrator;
  }

  // ----- EVENTS -----

  // Used to initialize counters in the subgraph
  event StakeCurateCreated();
  event ChangedStakeCurateSettings(StakeCurateSettings _settings);
  event ArbitratorAllowance(IArbitrator _arbitrator, bool _allowance);

  event AccountCreated(address _owner);
  event AccountFunded(uint64 _accountId, IERC20 _token, uint32 _freeStake);
  event AccountStartWithdraw();
  event AccountStopWithdraw();
  event AccountWithdrawn(IERC20 _token, uint32 _freeStake);

  event ArbitrationSettingCreated(address _arbitrator, bytes _arbitratorExtraData);

  event ListCreated(List _list, string _metalist);
  event ListUpdated(uint64 _listId, List _list, string _metalist);

  event ItemAdded(uint64 _listId, uint32 _stake, string _ipfsUri, bytes _harddata);
  event ItemEdited(uint64 _itemId, uint32 _stake, string _ipfsUri, bytes _harddata);
  event ItemStartRetraction(uint64 _itemId);
  event ItemStopRetraction(uint64 _itemId);
  // there's no need for "ItemRetracted"
  // since it will automatically be considered retracted after the period.
  event ItemRecommitted(uint64 _itemId, uint32 _stake);
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
  mapping(uint64 => mapping(address => BalanceSplit[])) public splits;

  mapping(uint64 => List) public lists;
  mapping(uint64 => Item) public items;
  mapping(uint64 => DisputeSlot) public disputes;
  mapping(address => mapping(uint256 => uint64)) public arbitratorAndDisputeIdToLocal;
  mapping(uint64 => ArbitrationSetting) public arbitrationSettings;
  mapping(IArbitrator => bool) public arbitratorAllowance;

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
   * @dev Governor allows or disallows arbitrator to be used in Stake Curate.
   *  This is intended to prevent harmful use or arbitrators (bad periods, no arbFees...)
   *  and it should prevent a bunch of attacks, since stakes are shared across lists.
     @param _arbitrator The arbitrator to allow / disallow
     @param _allowance Whether if it will be allowed or disallowed
   */
  function allowArbitrator(IArbitrator _arbitrator, bool _allowance) public {
    require(msg.sender == stakeCurateSettings.governor, "Only governor can allow arbitrators");
    arbitratorAllowance[_arbitrator] = _allowance;
    emit ArbitratorAllowance(_arbitrator, _allowance);
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
        withdrawingTimestamp: 0
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

    uint256 newFreeStake = Cint32.decompress(getCompressedFreeStake(accountId, _token)) + _amount;
    balanceRecordRoutine(accountId, address(_token), newFreeStake);
    emit AccountFunded(accountId, _token, Cint32.compress(newFreeStake));
  }

  /**
   * @dev Starts a withdrawal process on your account.
   *  Withdrawals are not instant to prevent frontrunning.
   *  As soon as you can withdraw, you will be able to withdraw anything
   *  without getting exposed to burns. While you wait for withdraw, you cannot
   *  own new items.
   */
  function startWithdraw() external {
    uint64 accountId = accountRoutine(msg.sender);
    accounts[accountId].withdrawingTimestamp =
      uint32(block.timestamp) + stakeCurateSettings.withdrawalPeriod;
    emit AccountStartWithdraw();
  }
  /**
   * @dev Stops a withdrawal process on your account.
   */
  function stopWithdraw() external {
    uint64 accountId = accountRoutine(msg.sender);
    accounts[accountId].withdrawingTimestamp = 0;
    emit AccountStopWithdraw();
  }

  /**
   * @dev Withdraws any amount of held token for your account.
   *  calling after withdrawing period entails to a full withdraw.
   *  You can withdraw as many tokens as you want during this period.
   *  Otherwise, a part of the requested amount will be burnt, to prevent
   *  frontrunning withdrawal shenanigans against challenge reveals.
   * 
   *  Flash withdrawals are allowed because, without them, users could
   *  device ways to submit wrong items in lists and commit self challenges
   *  to frontrun, exposing them to the same burn.
   *  todo: actually... in doing so they would have to endure even more,
   *  as failed challeges have burns associated with them as well, so
   *  maybe flash withdrawals shouldn't be allowed after all.
   * @param _token Token to withdraw.
   * @param _amount The amount to be withdrawn.
   */
  function withdrawAccount(IERC20 _token, uint256 _amount) external {
    uint64 accountId = accountRoutine(msg.sender);
    Account memory account = accounts[accountId];
    uint256 toSender;
    uint256 toBurn = 0;
    if (account.withdrawingTimestamp <= block.timestamp) {
      // no burn, since the period was completed.
      toSender = _amount;
    } else {
      // burn. round the burn up.
      toSender = _amount * (10_000 - stakeCurateSettings.burnRate) / 10_000;
      toBurn = _amount - toSender;
    }

    uint256 freeStake = Cint32.decompress(getCompressedFreeStake(accountId, _token));
    require(freeStake >= _amount, "Cannot afford this withdraw");
    // guard
    balanceRecordRoutine(accountId, address(_token), freeStake - _amount);
    if (toBurn != 0) {
      _token.transfer(stakeCurateSettings.burner, toBurn);
    }
    // withdraw
    _token.transfer(msg.sender, toSender);
    emit AccountWithdrawn(_token, Cint32.compress(freeStake - _amount));
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
    require(arbitratorAllowance[IArbitrator(_arbitrator)], "Arbitrator not allowed");
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
   * @param _stake How much collateral backs up the item, compressed.
   * @param _forListVersion Timestamp of the version this action is intended for.
   * If list governor were to frontrun a version change, then it reverts.
   * @param _ipfsUri IPFS uri that links to the content of the item
   * @param _harddata Optional data that is stored on-chain
   */
  function addItem(
    uint64 _listId,
    uint32 _stake,
    uint32 _forListVersion,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external returns (uint64 id) {
    require(listLegalCheck(_listId), "Cannot add item to illegal list");
    uint64 accountId = accountRoutine(msg.sender);
    require(accounts[accountId].withdrawingTimestamp == 0, "Cannot add items while withdrawing");
    unchecked {id = itemCount++;}
    require(_forListVersion == lists[_listId].versionTimestamp, "Different list version");
    require(_stake >= lists[_listId].requiredStake, "Not enough stake");
    require(_stake <= lists[_listId].maxStake, "Too much stake");

    // we create the item, then check if it's valid.
    items[id] = Item({
      accountId: accountId,
      listId: _listId,
      retractionTimestamp: 0,
      state: ItemState.Included,
      commitTimestamp: uint32(block.timestamp),
      stake: _stake,
      freeSpace: 0,
      harddata: _harddata
    });
    // if not Young or Included, something went wrong so it's reverted
    ItemState newState = getItemState(id);
    require(
      newState == ItemState.Included || newState == ItemState.Young,
      "Revert item creation: would be invalid"
    );

    emit ItemAdded(_listId, _stake, _ipfsUri, _harddata);
  }

  /**
   * @notice Edits an item, adopts it if not owned by this account and able.
   * @param _itemId Id of the item to edit.
   * @param _stake How much collateral backs up the item, compressed.
   * @param _forListVersion Timestamp of the version this action is intended for.
   * If list governor were to frontrun a version change, then it reverts.
   * @param _ipfsUri IPFS uri that links to the content of the item
   * @param _harddata Optional data that is stored on-chain
   */
  function editItem(
    uint64 _itemId,
    uint32 _stake,
    uint32 _forListVersion,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external {
    Item memory preItem = items[_itemId];
    List memory list = lists[preItem.listId];
    require(
      _forListVersion == list.versionTimestamp,
      "Different list version"
    );
    AdoptionState adoption = getAdoptionState(_itemId);
    uint64 senderId = accountRoutine(msg.sender);

    if (adoption == AdoptionState.FullAdoption) {
      require(_stake >= list.requiredStake, "Not enough stake");
    } else {
      // outbidding is needed.
      if (senderId == preItem.accountId) {
        // it's enough if you match
        require(_stake >= preItem.stake, "Match or increase stake");
      } else {
        // strict increase
        require(_stake > preItem.stake, "Increase stake to adopt");
      }
    }

    require(_stake <= list.maxStake, "Too much stake");
    require(accounts[senderId].withdrawingTimestamp == 0, "Cannot edit items while withdrawing");
    
    // instead of further checks, just edit the item and do a status check.
    items[_itemId] = Item({
      accountId: senderId,
      listId: preItem.listId,
      retractionTimestamp: 0,
      state: preItem.state == ItemState.Disputed ? ItemState.Disputed : ItemState.Included,
      commitTimestamp: uint32(block.timestamp),
      stake: _stake,
      freeSpace: 0,
      harddata: _harddata
    });
    // if not Young or Included, something went wrong so it's reverted.
    // you can also edit items while they are Disputed, as that doesn't change
    // anything about the Dispute in place.
    ItemState newState = getItemState(_itemId);
    require(
      newState == ItemState.Included || newState == ItemState.Young || newState == ItemState.Disputed,
      "No edit: would be invalid"
    );    

    emit ItemEdited(_itemId, _stake, _ipfsUri, _harddata);
  }

  /**
   * @dev Starts an item retraction process.
   * @param _itemId Item to retract.
   */
  function startRetractItem(uint64 _itemId) external {
    Item storage item = items[_itemId];
    Account memory account = accounts[item.accountId];
    require(account.owner == msg.sender, "Only account owner can invoke account");
    ItemState state = getItemState(_itemId);
    require(
      state != ItemState.IllegalList
      && state != ItemState.Outdated
      && state != ItemState.Removed
      && state != ItemState.Retracted,
      "Item is already gone"
    );
    require(item.retractionTimestamp == 0, "Item is already being retracted");

    item.retractionTimestamp = uint32(block.timestamp);
    emit ItemStartRetraction(_itemId);
  }

  /**
   * @dev Updates commit timestamp of an item. It also reclaims the item if
   * sender is different from previous owner, according to adoption rules.
   * The difference with editItem is that recommitItem doesn't create a new edition.
   * @param _itemId Item to recommit.
   * @param _stake How much collateral backs up the item, compressed.
   * @param _forListVersion Timestamp of the version this action is intended for.
   * If list governor were to frontrun a version change, then it reverts.
   */
  function recommitItem(uint64 _itemId, uint32 _stake, uint32 _forListVersion) external {
    Item memory preItem = items[_itemId];
    List memory list = lists[preItem.listId];
    require(
      _forListVersion == list.versionTimestamp,
      "Different list version"
    );

    uint64 senderId = accountRoutine(msg.sender);
    AdoptionState adoption = getAdoptionState(_itemId);

    if (adoption == AdoptionState.FullAdoption) {
      require(_stake >= list.requiredStake, "Not enough stake");
    } else {
      // outbidding is needed.
      if (senderId == preItem.accountId) {
        // it's enough if you match
        require(_stake >= preItem.stake, "Match or increase stake");
      } else {
        // strict increase
        require(_stake > preItem.stake, "Increase stake to adopt");
      }
    }

    require(_stake <= list.maxStake, "Too much stake");
    require(accounts[senderId].withdrawingTimestamp == 0, "Cannot recommit items while withdrawing");

    // instead of further checks, just change the item and do a status check.
    Item storage item = items[_itemId];
    // to recommit, we change values directly to avoid "rebuilding" the harddata
    item.accountId = senderId;
    item.retractionTimestamp = 0;
    item.state = preItem.state == ItemState.Disputed ? ItemState.Disputed : ItemState.Included;
    item.commitTimestamp = uint32(block.timestamp);
    item.stake = _stake;

    // if not Young or Included, something went wrong so it's reverted.
    // you can also edit items while they are Disputed, as that doesn't change
    // anything about the Dispute in place.
    ItemState newState = getItemState(_itemId);
    require(
      newState == ItemState.Included || newState == ItemState.Young || newState == ItemState.Disputed,
      "No recommit: would be invalid"
    );    

    emit ItemRecommitted(_itemId, _stake);
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

    uint32 compressedFreeStake = getCompressedFreeStake(item.accountId, list.token);

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
    uint256 challengerStake = 
      Cint32.decompress(list.challengerStakeRatio)
      * Cint32.decompress(item.stake)
      / 10_000;

    require(
      list.token.transferFrom(
        msg.sender,
        address(this),
        challengerStake
      ),
      "Challenger stake not covered"
    );
    
    // Item can be challenged if: Young, Included
    ItemState dynamicState = getItemState(_itemId);
    require(
      dynamicState == ItemState.Young
      || dynamicState == ItemState.Included
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
    
    uint256 toLock = Cint32.decompress(item.stake);
    uint256 newFreeStake = Cint32.decompress(compressedFreeStake) - toLock;
    uint64 challengerId = accountRoutine(msg.sender);
    balanceRecordRoutine(challengerId, address(list.token), newFreeStake);

    disputes[id] = DisputeSlot({
      itemId: _itemId,
      challengerId: challengerId,
      arbitrationSetting: list.arbitrationSettingId,
      state: DisputeState.Used,
      itemStake: item.stake,
      challengerStake: Cint32.compress(challengerStake),
      freespace: 0,
      token: list.token,
      itemOwnerId: item.accountId
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
    Account storage ownerAccount = accounts[dispute.itemOwnerId];
    uint32 compressedFreeStake = getCompressedFreeStake(dispute.itemOwnerId, dispute.token);

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
      // if list is not outdated, set commitTimestamp
      if (getItemState(dispute.itemId) != ItemState.Outdated) {
        item.commitTimestamp = uint32(block.timestamp);
      }
      // free the locked stake
      uint256 toUnlock = Cint32.decompress(dispute.itemStake);
      uint256 newFreeStake = Cint32.decompress(compressedFreeStake) + toUnlock;
      balanceRecordRoutine(item.accountId, address(dispute.token), newFreeStake);
      
      award = Cint32.decompress(dispute.challengerStake);
      awardee = ownerAccount.owner;
    } else {
      // challenger won.
      // 4b. slot is now Removed
      item.state = ItemState.Removed;

      award = Cint32.decompress(dispute.itemStake);
      awardee = accounts[dispute.challengerId].owner;
    }

    uint256 toAccount = award * (10_000 - stakeCurateSettings.burnRate) / 10_000;
    uint256 toBurn = award - toAccount;    // destroy the disputeSlot information, to trigger refunds
    disputes[localDisputeId] = DisputeSlot({
      itemId: 0,
      challengerId: 0,
      arbitrationSetting: 0,
      state: DisputeState.Free,
      itemStake: 0,
      challengerStake: 0,
      freespace: 0,
      token: IERC20(address(0)),
      itemOwnerId: 0
    });

    emit Ruling(arbSetting.arbitrator, _disputeId, _ruling);
    dispute.token.transfer(awardee, toAccount);
    dispute.token.transfer(stakeCurateSettings.burner, toBurn);
  }

  function getItemState(uint64 _itemId) public view returns (ItemState) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    uint32 compressedFreeStake = getCompressedFreeStake(item.accountId, list.token);
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
        // or not held by the stake
        (
          accounts[item.accountId].withdrawingTimestamp != 0
          && accounts[item.accountId].withdrawingTimestamp <= block.timestamp
        )
        || compressedFreeStake < item.stake
    ) {
      return (ItemState.Uncollateralized);
    } else if (item.commitTimestamp <= list.versionTimestamp) {
      return (ItemState.Outdated);
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
    if (state == ItemState.Removed || state == ItemState.Retracted || state == ItemState.Uncollateralized || state == ItemState.Outdated) {
      return (AdoptionState.FullAdoption);
    }
    return (AdoptionState.NeedsOutbid);
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
      list.challengerStakeRatio < stakeCurateSettings.minChallengerStakeRatio
    ) {
      isLegal = false;
    } else if (
        !arbitratorAllowance[arbitrationSettings[list.arbitrationSettingId].arbitrator]
      ) {
        isLegal = false;
    } else {
      isLegal = true;
    }
  }

  function balanceRecordRoutine(uint64 _accountId, address _token, uint256 _freeStake) internal {
    BalanceSplit[] storage arr = splits[_accountId][_token];
    BalanceSplit memory curr = arr[arr.length-1];
    // the way Cint32 works, comparing values before or after decompression
    // will return the same result. so, we don't even compress / decompress the splits.
    uint32 compressedStake = Cint32.compress(_freeStake);
    if (compressedStake <= curr.min) {
      // when lower, initiate the following process:
      // starting from the end, go through all the splits, and remove all splits
      // such that have more or equal split.
      // after iterating through this, create a new split with the last timestamp
      while (arr.length > 0 && compressedStake <= curr.min) {
        curr = arr[arr.length-1];
        arr.pop();
      }
      arr.push(BalanceSplit({
          startTime: curr.startTime,
          min: compressedStake
        }));
    } else {
      // since it's higher, check last record time to consider appending.
      if (block.timestamp >= curr.startTime + stakeCurateSettings.balanceSplitPeriod) {
        // out of the period. a new split will be made.
        splits[_accountId][_token].push(BalanceSplit({
          startTime: uint32(block.timestamp),
          min: compressedStake
        }));
      // if it's higher and within the split, we override the amount.
      // qa : why not override the startTime as well?
      // because then, if someone were to frequently update their amounts,
      // the last record would non-stop get pushed to the future.
      // it would be a rare occurrance if the periods are small, but rather not
      // risk it. this compromise only reduces the guaranteed collateralization requirement
      // by the split period.
      } else {
        splits[_accountId][_token][arr.length-1].min = compressedStake;
      }
    }
  }

  function continuousBalanceCheck(uint64 _itemId) internal view returns (bool) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    uint32 requiredStake = item.stake;
    uint256 targetTime = block.timestamp - list.ageForInclusion;
    uint64 accountId = item.accountId;
    address token = address(list.token);
    uint256 splitPointer = splits[accountId][token].length - 1;

    // we want to process pointer 0, so go until we overflow
    while (splitPointer != type(uint256).max) {
      BalanceSplit memory split = splits[accountId][token][splitPointer];
      // we test if we can pass the split.
      // we don't decompress because comparisons work without decompressing
      if (requiredStake > split.min) return (false);
      // we survived, and now check within the split.
      if (split.startTime <= targetTime) return (true);
      
      unchecked { splitPointer--; }
    }

    // target is beyong the earliest record, not enough time for collateralization.
    return (false);
  }

  function getCompressedFreeStake(uint64 _accountId, IERC20 _token) public view returns (uint32) {
    uint256 len = splits[_accountId][address(_token)].length;
    if (len == 0) return (0);

    return (splits[_accountId][address(_token)][len - 1].min);
  }
}