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
   * @dev What happens when an challenge fails on an item you own. Meanings:
   * Send: Send the challenger stake to the owner
   * Stake: Automatically deposit the challengerStake
   * StakeAndRise: Automatically deposit the challengerStake and increase the stake
   *  of the item.
   */
  enum KeepRoutine {
    Send,
    Stake,
    StakeAndRise
  }

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
    // seconds until a challenge reveal can be accepted
    uint32 minTimeForReveal;
    // seconds until a challenge commit is too old
    uint32 maxTimeForReveal;
    // burn rate that affects some failed challenge reveals before refund
    // in order to desincentivize camping
    uint32 smallBurnRate;
    // burn that affects an account when it withdraws. under regular circumstances,
    // this should just be zero (withdrawals impose no penalty). unfortunately there
    // is an elaborate botting attack that could ensure a camping challenger only loses
    // the big burn to secure their stake. in this scenario, setting it to a very small
    // value (~0.1%) could stop the issue (with honest participants later reimbursed).
    uint32 withdrawalBurnRate;
    // min seconds for retraction in any list
    // if a list were to allow having a retractionPeriod that is too low
    // compared to the minimum time for revealing a commit, that would make
    // having an item be retracted unpredictable at commit time. 
    // usually retractions should be in the order of 1 or 2 days,
    // hours at the bare minimum
    // and minTimeForReveal should be in the order of minutes
    uint32 minRetractionPeriod;
  }

  struct Account {
    address owner;
    uint32 withdrawingTimestamp;
    // todo count of items owned, for erc-721 visibility

    KeepRoutine keepRoutine;
    uint88 freeSpace;
  }

  struct BalanceSplit {
    // moment the split begins
    // a split ends when the following split starts, or block.timestamp if last.
    uint32 startTime;
    // minimum amount there was, from the startTime, to the end of the split.
    uint32 min;
  }

  struct List {
    uint56 governorId; // governor needs an account
    uint32 requiredStake;
    uint32 retractionPeriod; 
    uint56 arbitrationSettingId;
    uint32 versionTimestamp;
    uint32 maxStake; // protects from some frontrun attacks
    uint16 freespace;
    // ----
    IERC20 token;
    uint32 challengerStakeRatio; // (basis points) challenger stake in proportion to the item stake
    uint32 ageForInclusion; // how much time from Young to Included, in seconds
    uint32 outbidRate; // how much is needed for a different owner to adopt an item.
  }

  struct Item {
    // account that owns the item
    uint56 accountId;
    // list under which the item is submitted. immutable after creation.
    uint56 listId;
    // if not zero, marks the start of a retraction process.
    uint32 retractionTimestamp;
    // hard state of the item, some states can be written in storage.
    ItemState state;
    // last explicit committal to collateralize the item.
    uint32 commitTimestamp;
    // how much stake is backing up the item. will be equal or greater than list.requiredStake
    uint32 stake;
    uint40 freeSpace;
    // arbitrary, optional data for on-chain consumption
    bytes harddata;
  }

  struct ChallengeCommit {
    // h(salt, itemId, editionTimestamp, ratio, reason)
    bytes32 commitHash;
    ///
    uint32 timestamp;
    uint32 tokenAmount;
    uint32 valueAmount;
    IERC20 token;
    /// we require a 3rd slot since we index all commits in the same array.
    // it's still better since less calldata is required to reveal.
    uint56 challengerId;
    uint200 freespace;
  }

  struct DisputeSlot {
    uint56 challengerId;
    uint56 itemId;
    uint56 arbitrationSetting;
    DisputeState state;
    uint32 itemStake; // unlocks to submitter if Keep, sent to challenger if Remove
    uint32 arbFees; // to be awarded to the side that wins the dispute. 
    uint16 freespace;
    // ----
    IERC20 token;
    uint32 challengerStake; // put by the challenger, sent to whoever side wins.
    uint56 itemOwnerId; // items may change hands during the dispute, you need to store
    // the owner at dispute time.
    uint8 freespace2;
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
  event AccountFunded(uint56 _accountId, IERC20 _token, uint32 _freeStake);
  event AccountStartWithdraw();
  event AccountStopWithdraw();
  event AccountWithdrawn(IERC20 _token, uint32 _freeStake);
  event AccountChangeKeepRoutine(KeepRoutine _keepRoutine);

  event ArbitrationSettingCreated(address _arbitrator, bytes _arbitratorExtraData);

  event ListCreated(List _list, string _metalist);
  event ListUpdated(uint56 _listId, List _list, string _metalist);

  event ItemAdded(uint56 _listId, uint32 _stake, string _ipfsUri, bytes _harddata);
  event ItemEdited(uint56 _itemId, uint32 _stake, string _ipfsUri, bytes _harddata);
  event ItemStartRetraction(uint56 _itemId);
  event ItemStopRetraction(uint56 _itemId);
  // there's no need for "ItemRetracted"
  // since it will automatically be considered retracted after the period.
  event ItemRecommitted(uint56 _itemId, uint32 _stake);
  // no need for event for adopt. new owner can be read from sender.
  // this is the case for Recommit or Edit.

  event ChallengeCommitted(
    uint256 indexed _commitIndex, bytes32 _commitHash, IERC20 _token,
    uint32 _tokenAmount, uint32 _valueAmount, uint56 _challengerId
  );

  event CommitReveal(
    uint256 indexed _commitIndex, bytes32 _salt, uint56 _itemId,
    uint32 _editionTimestamp, uint16 _ratio, string _reason
  );

  // if CommitReveal exists for an index, it was refunded (or small burn). o.w. fully revoked.
  event CommitRevoked(uint256 indexed _commitIndex);
  // all info about a challenge can be accessed via the CommitReveal event
  event ItemChallenged(uint56 indexed _disputeId, uint256 indexed _commitIndex, uint56 indexed _itemId);

  // ----- CONTRACT STORAGE -----
  
  StakeCurateSettings public stakeCurateSettings;

  // todo get these counts in a single struct?
  uint56 public itemCount;
  uint56 public listCount;
  uint56 public disputeCount;
  uint56 public accountCount;
  uint56 public arbitrationSettingCount;

  mapping(address => uint56) public accountIdOf;
  mapping(uint56 => Account) public accounts;
  mapping(uint56 => mapping(address => BalanceSplit[])) public splits;

  mapping(uint56 => List) public lists;
  mapping(uint56 => Item) public items;
  ChallengeCommit[] public challengeCommits;
  mapping(uint56 => DisputeSlot) public disputes;
  mapping(address => mapping(uint256 => uint56)) public arbitratorAndDisputeIdToLocal;
  mapping(uint56 => ArbitrationSetting) public arbitrationSettings;
  mapping(IArbitrator => bool) public arbitratorAllowance;


  /**
   * @dev This is a hack, you want the loser side to pay for the arbFees
   *  So you need to keep track of native value amounts from item owner. 
   *  You need to ensure amounts are sufficient for the optional period.
   *  So you need balance records. We can reuse balance records for
   *  values without rewriting code, for that, treat "valueToken" == IERC20(0)
   *  as the placeholder for native value amounts.
   */
  IERC20 constant valueToken = IERC20(address(0)); 

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
    require(msg.sender == stakeCurateSettings.governor);
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
    require(msg.sender == stakeCurateSettings.governor);
    arbitratorAllowance[_arbitrator] = _allowance;
    emit ArbitratorAllowance(_arbitrator, _allowance);
  }

  /**
   * @dev If account already exists, returns its id.
   * If not, it creates an account for a given address and returns the id.
   * @param _owner The address of the account.
   */
  function accountRoutine(address _owner) public returns (uint56 id) {
    if (accountIdOf[_owner] != 0) {
      id = accountIdOf[_owner];
    } else {
      id = accountCount++;
      accountIdOf[_owner] = id;
      accounts[id] = Account({
        owner: _owner,
        withdrawingTimestamp: 0,
        keepRoutine: KeepRoutine.Send,
        freeSpace: 0
      });
      emit AccountCreated(_owner);
    }
  }

  /**
   * @dev Funds an existing account.
   *  It can receive value as well, that will be stored separatedly.
   * @param _recipient Address of the account that receives the funds.
   * @param _token Token to fund the account with.
   * @param _amount How much token to fund with.
   */
  function fundAccount(address _recipient, IERC20 _token, uint256 _amount) external payable {
    require(_token.transferFrom(msg.sender, address(this), _amount));
    uint56 accountId = accountRoutine(_recipient);

    uint256 newFreeStake = Cint32.decompress(getCompressedFreeStake(accountId, _token)) + _amount;
    balanceRecordRoutine(accountId, address(_token), newFreeStake);
    emit AccountFunded(accountId, _token, Cint32.compress(newFreeStake));
    // if the sender passes value, we update the value of the accountId
    if (msg.value > 0) {
      newFreeStake = Cint32.decompress(getCompressedFreeStake(accountId, valueToken)) + msg.value;
      balanceRecordRoutine(accountId, address(_token), newFreeStake);
      emit AccountFunded(accountId, valueToken, Cint32.compress(newFreeStake));
    }
  }

  /**
   * @dev Starts a withdrawal process on your account.
   *  Withdrawals are not instant to prevent frontrunning.
   *  As soon as you can withdraw, you will be able to withdraw anything
   *  without getting exposed to burns. While you wait for withdraw, you cannot
   *  own new items.
   */
  function startWithdraw() external {
    uint56 accountId = accountRoutine(msg.sender);
    accounts[accountId].withdrawingTimestamp =
      uint32(block.timestamp) + stakeCurateSettings.withdrawalPeriod;
    emit AccountStartWithdraw();
  }
  /**
   * @dev Stops a withdrawal process on your account.
   */
  function stopWithdraw() external {
    uint56 accountId = accountRoutine(msg.sender);
    accounts[accountId].withdrawingTimestamp = 0;
    emit AccountStopWithdraw();
  }

  /**
   * @dev Withdraws any amount of held token for your account.
   *  calling after withdrawing period entails to a full withdraw.
   *  You can withdraw as many tokens as you want during this period.
   * 
   * There exists a "withdrawalBurnRate" that could be toggled on for
   *  emergency purposes. But, under any regular circumstance, it should
   *  just be zero.
   * @param _token Token to withdraw.
   * @param _amount The amount to be withdrawn.
   */
  function withdrawAccount(IERC20 _token, uint256 _amount) external {
    uint56 accountId = accountRoutine(msg.sender);
    Account memory account = accounts[accountId];
    // account needs to start withdrawing process first.
    require(
      account.withdrawingTimestamp > 0
      && account.withdrawingTimestamp <= block.timestamp
    );

    uint256 freeStake = Cint32.decompress(getCompressedFreeStake(accountId, _token));
    require(freeStake >= _amount); // cannot afford to withdraw that much
    // guard
    balanceRecordRoutine(accountId, address(_token), freeStake - _amount);
    // withdraw
    processWithdrawal(msg.sender, _token, _amount, stakeCurateSettings.withdrawalBurnRate);
    emit AccountWithdrawn(_token, Cint32.compress(freeStake - _amount));
  }

  /**
   * @dev Changes the keep routine (behaviour that occurs to owner when dispute rules to keep)
   * @param _keepRoutine The routine to set
   */
  function setKeepRoutine(KeepRoutine _keepRoutine) external {
    uint56 accountId = accountRoutine(msg.sender);
    accounts[accountId].keepRoutine = _keepRoutine;
    emit AccountChangeKeepRoutine(_keepRoutine);
  }

  /**
   * @dev Create arbitrator setting. Will be immutable, and assigned to an id.
   * @param _arbitrator The address of the IArbitrator
   * @param _arbitratorExtraData The extra data
   */
  function createArbitrationSetting(address _arbitrator, bytes calldata _arbitratorExtraData)
      external returns (uint56 id) {
    unchecked {id = arbitrationSettingCount++;}
    // address 0 cannot be arbitrator. makes id overflow attacks more expensive.
    require(_arbitrator != address(0));
    // arbitrator may be malicious, needs to be allowed.
    require(arbitratorAllowance[IArbitrator(_arbitrator)]);
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
  ) external returns (uint56 id) {
    require(_list.arbitrationSettingId < arbitrationSettingCount);
    unchecked {id = listCount++;}
    _list.governorId = accountRoutine(_governor);
    lists[id] = _list;
    require(listLegalCheck(id));
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
    uint56 _listId,
    List memory _list,
    string calldata _metalist
  ) external {
    require(_list.arbitrationSettingId < arbitrationSettingCount);
    // only governor can update a list
    require(accounts[lists[_listId].governorId].owner == msg.sender);
    _list.governorId = accountRoutine(_governor);
    lists[_listId] = _list;
    require(listLegalCheck(_listId));
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
    uint56 _listId,
    uint32 _stake,
    uint32 _forListVersion,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external returns (uint56 id) {
    uint56 accountId = accountRoutine(msg.sender);
    // vvv this require is redundant due to the getItemState check. todo remove.
    require(accounts[accountId].withdrawingTimestamp == 0);
    unchecked {id = itemCount++;}
    require(_forListVersion == lists[_listId].versionTimestamp);
    require(_stake >= lists[_listId].requiredStake);
    require(_stake <= lists[_listId].maxStake);

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
    require(newState == ItemState.Included || newState == ItemState.Young);

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
    uint56 _itemId,
    uint32 _stake,
    uint32 _forListVersion,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external {
    Item memory preItem = items[_itemId];
    List memory list = lists[preItem.listId];
    require(_forListVersion == list.versionTimestamp);
    AdoptionState adoption = getAdoptionState(_itemId);
    uint56 senderId = accountRoutine(msg.sender);

    if (adoption == AdoptionState.FullAdoption) {
      require(_stake >= list.requiredStake);
    } else {
      // outbidding is needed.
      if (senderId == preItem.accountId) {
        // it's enough if you match
        require(_stake >= preItem.stake);
      } else {
        // outbidding by rate is required
        uint256 decompressedCurrentStake = Cint32.decompress(preItem.stake);
        uint256 neededStake = decompressedCurrentStake  * list.outbidRate / 10_000;
        require(Cint32.decompress(_stake) >= neededStake);
      }
    }

    require(_stake <= list.maxStake);
    require(accounts[senderId].withdrawingTimestamp == 0);
    
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
    require(newState == ItemState.Included || newState == ItemState.Young || newState == ItemState.Disputed);    

    emit ItemEdited(_itemId, _stake, _ipfsUri, _harddata);
  }

  /**
   * @dev Starts an item retraction process.
   * @param _itemId Item to retract.
   */
  function startRetractItem(uint56 _itemId) external {
    Item storage item = items[_itemId];
    Account memory account = accounts[item.accountId];
    require(account.owner == msg.sender);
    ItemState state = getItemState(_itemId);
    require(
      state != ItemState.IllegalList
      && state != ItemState.Outdated
      && state != ItemState.Removed
      && state != ItemState.Retracted
    );
    require(item.retractionTimestamp == 0);

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
  function recommitItem(uint56 _itemId, uint32 _stake, uint32 _forListVersion) external {
    Item memory preItem = items[_itemId];
    List memory list = lists[preItem.listId];
    require(_forListVersion == list.versionTimestamp);

    uint56 senderId = accountRoutine(msg.sender);
    AdoptionState adoption = getAdoptionState(_itemId);

    if (adoption == AdoptionState.FullAdoption) {
      require(_stake >= list.requiredStake);
    } else {
      // outbidding is needed.
      if (senderId == preItem.accountId) {
        // it's enough if you match
        require(_stake >= preItem.stake);
      } else {
        // outbidding by rate is required
        uint256 decompressedCurrentStake = Cint32.decompress(preItem.stake);
        uint256 neededStake = decompressedCurrentStake  * list.outbidRate / 10_000;
        require(Cint32.decompress(_stake) >= neededStake);
      }
    }

    require(_stake <= list.maxStake);
    require(accounts[senderId].withdrawingTimestamp == 0);

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
    require(newState == ItemState.Included || newState == ItemState.Young || newState == ItemState.Disputed);    

    emit ItemRecommitted(_itemId, _stake);
  }

  // since eip-712 is not necessary to build the hash, we won't use it.
  // this saves the user the process of doing a wallet signature.
  // even though it's an standard, we don't care about signing.
  // so we'll use a regular hashing operation to build the _commitHash
  function commitChallenge(
    IERC20 _token,
    uint32 _compressedTokenAmount,
    bytes32 _commitHash
  ) external payable returns (uint256 _commitId) {
    // if attacker tries to pass _token == 0x0, the require below should fail.
    require(
      _token.transferFrom(
        msg.sender, address(this), Cint32.decompress(_compressedTokenAmount)
      )
    );
    uint32 compressedvalue = Cint32.compress(msg.value);
    uint56 challengerId = accountRoutine(msg.sender);
    challengeCommits.push(ChallengeCommit({
      commitHash: _commitHash,
      timestamp: uint32(block.timestamp),
      tokenAmount: _compressedTokenAmount,
      valueAmount: compressedvalue,
      token: _token,
      challengerId: challengerId,
      freespace: 0
    }));
    emit ChallengeCommitted(
      challengeCommits.length - 1, _commitHash, _token, _compressedTokenAmount,
      compressedvalue, challengerId
    );
    return (challengeCommits.length - 1);
  }

  function revealChallenge(
    uint256 _commitIndex,
    bytes32 _salt,
    uint56 _itemId,
    uint32 _editionTimestamp,
    uint16 _ratio,
    string calldata _reason
  ) external returns (uint56 id) {
    ChallengeCommit memory commit = challengeCommits[_commitIndex];
    delete challengeCommits[_commitIndex];

    require(commit.timestamp + stakeCurateSettings.minTimeForReveal < block.timestamp);
    require(commit.timestamp + stakeCurateSettings.maxTimeForReveal > block.timestamp);

    // illegal ratios are not allowed, and will result in this commit being revoked eventually.
    require(_ratio <= 10_000 && _ratio > 0);

    // verify hash here, revert otherwise.
    bytes32 obtainedHash = keccak256(
      abi.encodePacked(_salt, _itemId, _editionTimestamp, _ratio, _reason)
    );
    require(commit.commitHash == obtainedHash);

    emit CommitReveal(_commitIndex, _salt, _itemId, _editionTimestamp, _ratio, _reason);

    Item storage item = items[_itemId];
    ItemState itemState = getItemState(_itemId);
    List memory list = lists[item.listId];

    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    uint256 arbFees = arbSetting.arbitrator.arbitrationCost(arbSetting.arbitratorExtraData);

    uint256 ownerValueAmount = Cint32.decompress(getCompressedFreeStake(item.accountId, valueToken));
    uint256 ownerTokenAmount = Cint32.decompress(getCompressedFreeStake(item.accountId, list.token));
    uint256 challengerValueAmount = Cint32.decompress(commit.valueAmount);
    uint256 challengerTokenAmount = Cint32.decompress(commit.tokenAmount);

    uint256 itemStake = Cint32.decompress(item.stake);
    uint256 challengerTokenStakeNeeded = itemStake * list.challengerStakeRatio / 10_000;
    uint256 itemStakeAfterRatio = itemStake * _ratio / 10_000;
  
    // go here through all the conditions that would make this challenge
    // reveal unable to be processed.
    // there are distinct classes:

    if (
      // refund + small burn checks
      // a. edition timestamp is too early compared to listVersion timestamp.
      // editions of outdated versions are unincluded and thus cannot be challenged
      // this also protects challenger from malicious list updates snatching the challengerStake
      // this has to burn, otherwise self-challengers can camp challenges by using a bogus list
      _editionTimestamp < list.versionTimestamp
      // b. illegal list
      || itemState == ItemState.IllegalList
      // c. retracted, a well timed sequence of bogus items could trigger these refunds.
      // when an item becomes retracted is completely predictable and should cause no ux issues.
      || itemState == ItemState.Retracted
      // d. a challenge towards an item that doesn't even exist
      || itemState == ItemState.Nothing
    ) {
      // small burn here
      address challenger = accounts[commit.challengerId].owner;
      processWithdrawal(
        challenger, commit.token, Cint32.decompress(commit.tokenAmount), stakeCurateSettings.smallBurnRate
      );
      processWithdrawal(
        challenger, valueToken, Cint32.decompress(commit.valueAmount), stakeCurateSettings.smallBurnRate
      );
      emit CommitRevoked(_commitIndex);
    } else if (
      // full refund checks
      // a. not enough tokenAmount for item.stake * challengerRatio
      challengerTokenAmount < challengerTokenStakeNeeded
      // b. not enough valueAmount for arbitrationCost
      || challengerValueAmount < arbFees
      // c. editionTimestamp compared with commit inclusion time is over window.
      || (_editionTimestamp + stakeCurateSettings.challengeWindow) < commit.timestamp
      // d. wrong token
      || commit.token != list.token
      // e. item is not either Uncollateralized, Young or Included
      || !(
        itemState == ItemState.Included
        || itemState == ItemState.Uncollateralized
        || itemState == ItemState.Young
      )
      // f. owner doesn't have enough value for arbFees
      || ownerValueAmount < arbFees
      // g. owner doesn't have enough freeStake for item.stake * ratio
      || ownerTokenAmount < itemStakeAfterRatio
    ) {
      // full refund here
      address challenger = accounts[commit.challengerId].owner;
      commit.token.transfer(challenger, challengerTokenAmount);
      payable(challenger).send(challengerValueAmount);
      emit CommitRevoked(_commitIndex);
    } else {
      // proceed with the challenge
      unchecked {id = disputeCount++;}
      // create dispute
      uint256 arbitratorDisputeId =
        arbSetting.arbitrator.createDispute{
          value: arbFees}(
          RULING_OPTIONS, arbSetting.arbitratorExtraData
        );
      // if this reverts, the arbitrator is malfunctioning. the commit will revoke
      require(arbitratorAndDisputeIdToLocal[address(arbSetting.arbitrator)][arbitratorDisputeId] == 0);
      arbitratorAndDisputeIdToLocal
        [address(arbSetting.arbitrator)][arbitratorDisputeId] = id;

      item.state = ItemState.Disputed;

      // we lock the amounts in owner's account
      balanceRecordRoutine(item.accountId, address(list.token), ownerTokenAmount - itemStakeAfterRatio);
      balanceRecordRoutine(item.accountId, address(valueToken), ownerValueAmount - arbFees);

      // refund leftovers to challenger, in practice leftovers > 0 (due to Cint32 noise)
      address challenger = accounts[commit.challengerId].owner;
      commit.token.transfer(challenger, challengerTokenAmount - challengerTokenStakeNeeded);
      payable(challenger).send(challengerValueAmount - arbFees);

      // store the dispute
      disputes[id] = DisputeSlot({
        itemId: _itemId,
        challengerId: commit.challengerId,
        arbitrationSetting: list.arbitrationSettingId,
        state: DisputeState.Used,
        itemStake: Cint32.compress(itemStakeAfterRatio),
        challengerStake: Cint32.compress(challengerTokenStakeNeeded),
        freespace: 0,
        token: list.token,
        itemOwnerId: item.accountId,
        arbFees: Cint32.compress(arbFees),
        freespace2: 0
      });

      emit ItemChallenged(id, _commitIndex, _itemId);
      // ERC 1497
      // evidenceGroupId is the itemId, since it's unique per item
      emit Dispute(
        arbSetting.arbitrator, arbitratorDisputeId,
        stakeCurateSettings.currentMetaEvidenceId, _itemId
      );
      emit Evidence(arbSetting.arbitrator, _itemId, msg.sender, _reason);
    }
  }

  function revokeCommit(uint256 _commitIndex) external {
    ChallengeCommit memory commit = challengeCommits[_commitIndex];
    delete challengeCommits[_commitIndex];

    // since deleting a commit sets its timestamp to zero, in practice they will always
    // revert here. so, this require is enough.
    require(commit.timestamp + stakeCurateSettings.maxTimeForReveal < block.timestamp);
    address challenger = accounts[commit.challengerId].owner;
    // apply the big burn to the token amount.
    processWithdrawal(
      challenger, commit.token, Cint32.decompress(commit.tokenAmount), stakeCurateSettings.burnRate
    );
    // apply the big burn to the value.
    processWithdrawal(
      challenger, valueToken, Cint32.decompress(commit.valueAmount), stakeCurateSettings.burnRate
    );
  
    emit CommitRevoked(_commitIndex);
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
  function submitEvidence(uint56 _itemId, IArbitrator _arbitrator, string calldata _evidence) external {
    emit Evidence(_arbitrator, _itemId, msg.sender, _evidence);
  }

  /**
   * @dev External function for the arbitrator to decide the result of a dispute. TRUSTED
   * @param _disputeId External id of the dispute
   * @param _ruling Ruling of the dispute. If 0 or 1, submitter wins. Else (2) challenger wins
   */
  function rule(uint256 _disputeId, uint256 _ruling) external override {
    // 1. get slot from dispute
    uint56 localDisputeId = arbitratorAndDisputeIdToLocal[msg.sender][_disputeId];
    DisputeSlot memory dispute =
      disputes[localDisputeId];
    require(msg.sender == address(arbitrationSettings[dispute.arbitrationSetting].arbitrator));
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
    Account memory ownerAccount = accounts[dispute.itemOwnerId];
    List memory list = lists[item.listId];
    uint32 compressedFreeStake = getCompressedFreeStake(dispute.itemOwnerId, dispute.token);
    uint32 compressedValueFreeStake = getCompressedFreeStake(dispute.itemOwnerId, valueToken);
    
    // destroy the disputeSlot information, to trigger refunds, and guard from reentrancy.
    delete disputes[localDisputeId];

    // we still remember the original dispute fields.

    // 3. apply ruling. what to do when refuse to arbitrate?
    // just default towards keeping the item.
    // 0 refuse, 1 staker, 2 challenger.

    if (_ruling == 2) {
      // challenger won
      item.state = ItemState.Removed;
      // transfer to challenger
      address challenger = accounts[dispute.challengerId].owner;
      processWithdrawal(
        challenger, dispute.token, Cint32.decompress(dispute.itemStake), stakeCurateSettings.burnRate
      );
      // return the arbFees to challenger
      payable(accounts[dispute.challengerId].owner).send(Cint32.decompress(dispute.arbFees));
    } else {
      // item owner won.
      if (item.retractionTimestamp != 0) {
        item.retractionTimestamp = uint32(block.timestamp);
      }
      item.state = ItemState.Included;
      // if list is not outdated, set commitTimestamp
      if (item.commitTimestamp > list.versionTimestamp) {
        // since _ratio was introduced to challenges,
        // you can no longer make the assumption that the item will become
        // Young or Included if the list hasn't updated,
        // as the item owner may have lost more tokens in the process,
        // and the unlocked tokens are no longer enough by themselves to collateralize.
        // but it shouldn't be a problem anyway, since it will just become
        // uncollateralized and unchallengeable.
        item.commitTimestamp = uint32(block.timestamp);
      }
      // free the locked stake
      uint256 newFreeStake = Cint32.decompress(compressedFreeStake) + Cint32.decompress(dispute.itemStake);
      balanceRecordRoutine(dispute.itemOwnerId, address(dispute.token), newFreeStake);
      // return the arbFees to valueStake
      uint256 newValueFreeStake = Cint32.decompress(compressedValueFreeStake) + Cint32.decompress(dispute.arbFees);
      balanceRecordRoutine(dispute.itemOwnerId, address(valueToken), newValueFreeStake);

      uint256 award = Cint32.decompress(dispute.challengerStake);
      uint256 toAccount = award * (10_000 - stakeCurateSettings.burnRate) / 10_000;
      uint256 toBurn = award - toAccount;
      dispute.token.transfer(stakeCurateSettings.burner, toBurn);

      // now we go through the keepRoutine.
      if (ownerAccount.keepRoutine == KeepRoutine.Send) {
        dispute.token.transfer(ownerAccount.owner, toAccount);
      } else {
        // in both Stake and StakeAndRise we will do the following
        uint256 afterRoutineStake =
          Cint32.decompress(getCompressedFreeStake(dispute.itemOwnerId, dispute.token))
          + toAccount;
        balanceRecordRoutine(dispute.itemOwnerId, address(dispute.token), afterRoutineStake);
        if (ownerAccount.keepRoutine == KeepRoutine.StakeAndRise) {
          // attempt to stake extra on the item.
          uint32 newCompressedItemStake = Cint32.compress(
            Cint32.decompress(item.stake) + toAccount
          );
          // if fail, don't do it. this will fail if:
          if (
            // item wont be included after rule (outdated, illegallist...)
            listLegalCheck(item.listId)
            || item.commitTimestamp > list.versionTimestamp
            // the item owner is different from the disputed owner
            || item.accountId == dispute.itemOwnerId
            // raising the stake will make it go beyond max
            || newCompressedItemStake <= list.maxStake
          ) {
            item.stake = newCompressedItemStake;
          }
        }
      }
    }

    emit Ruling(
      arbitrationSettings[dispute.arbitrationSetting].arbitrator,
      _disputeId,
      _ruling
    );
  }

  function getItemState(uint56 _itemId) public view returns (ItemState) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    uint32 compressedFreeStake = getCompressedFreeStake(item.accountId, list.token);
    uint32 compressedValueFreeStake = getCompressedFreeStake(item.accountId, valueToken);
    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    // compressions are lossy, rounding down. since it's a liability, comparisons
    // must be strictly higher.
    uint32 compressedArbitrationCost =
      Cint32.compress(arbSetting.arbitrator.arbitrationCost(arbSetting.arbitratorExtraData));
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
    } else if (item.commitTimestamp <= list.versionTimestamp) {
      return (ItemState.Outdated);
    } else if (
        // has gone through Withdrawing period,
        (
          accounts[item.accountId].withdrawingTimestamp != 0
          && accounts[item.accountId].withdrawingTimestamp <= block.timestamp
        )
        // not enough to pay arbFees. cost has been rounded down so value must
        // be strictly higher.
        || compressedValueFreeStake <= compressedArbitrationCost
        // or not held by the stake
        || compressedFreeStake < item.stake
    ) {
      return (ItemState.Uncollateralized);
    } else if (
        item.commitTimestamp + list.ageForInclusion > block.timestamp
        || !continuousBalanceCheck(item.accountId, address(list.token), item.stake, uint32(block.timestamp) - list.ageForInclusion)
        // we pass +1 here to prevent draining attacks, since a liability is being
        // rounded down.
        || !continuousBalanceCheck(item.accountId, address(valueToken), compressedArbitrationCost+1, uint32(block.timestamp) - list.ageForInclusion)
    ) {
      return (ItemState.Young);
    } else {
      return (ItemState.Included);
    }
  }

  // even though it's "Adoption", this is also an umbrella term for "recommitting"
  function getAdoptionState(uint56 _itemId) public view returns (AdoptionState) {
    ItemState state = getItemState(_itemId);
    if (state == ItemState.Removed || state == ItemState.Retracted || state == ItemState.Uncollateralized || state == ItemState.Outdated) {
      return (AdoptionState.FullAdoption);
    }
    return (AdoptionState.NeedsOutbid);
  }

  function arbitrationCost(uint56 _itemId) external view returns (uint256 cost) {
    ArbitrationSetting memory setting =
      arbitrationSettings[lists[items[_itemId].listId].arbitrationSettingId];
    return (setting.arbitrator.arbitrationCost(setting.arbitratorExtraData));
  }

  function listLegalCheck(uint56 _listId) public view returns (bool isLegal) {
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
    } else if (list.outbidRate < 10_000) {
      isLegal = false;
    } else if (list.retractionPeriod < stakeCurateSettings.minRetractionPeriod) {
      isLegal = false;
    } else {
      isLegal = true;
    }
  }

  function processWithdrawal(
    address _beneficiary, IERC20 _token, uint256 _amount, uint32 _burnRate
  ) internal {
    uint256 toBeneficiary = _amount * (10_000 - _burnRate) / 10_000;
    if (_token == valueToken) {
      // value related withdrawal. it is beneficiary responsability to accept value
      if (_burnRate != 0) {
        payable(stakeCurateSettings.burner).send(_amount - toBeneficiary);
      }
      payable(_beneficiary).send(_amount);
    } else {
      if (_burnRate != 0) {
        _token.transfer(stakeCurateSettings.burner, _amount - toBeneficiary);
      }
      _token.transfer(_beneficiary, toBeneficiary);
    }
  }

  function balanceRecordRoutine(uint56 _accountId, address _token, uint256 _freeStake) internal {
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

  function continuousBalanceCheck(
    uint56 _accountId, address _token, uint32 _requiredStake, uint32 _targetTime
  ) internal view returns (bool) {
    uint256 splitPointer = splits[_accountId][_token].length - 1;

    // we want to process pointer 0, so go until we overflow
    while (splitPointer != type(uint256).max) {
      BalanceSplit memory split = splits[_accountId][_token][splitPointer];
      // we test if we can pass the split.
      // we don't decompress because comparisons work without decompressing
      if (_requiredStake > split.min) return (false);
      // we survived, and now check within the split.
      if (split.startTime <= _targetTime) return (true);
      
      unchecked { splitPointer--; }
    }

    // target is beyong the earliest record, not enough time for collateralization.
    return (false);
  }

  function getCompressedFreeStake(uint56 _accountId, IERC20 _token) public view returns (uint32) {
    uint256 len = splits[_accountId][address(_token)].length;
    if (len == 0) return (0);

    return (splits[_accountId][address(_token)][len - 1].min);
  }
}