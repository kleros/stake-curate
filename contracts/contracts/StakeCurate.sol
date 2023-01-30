/**
 * @custom:authors: [@greenlucid, @chotacabras]
 * @custom:reviewers: []
 * @custom:auditors: []
 * @custom:bounties: []
 * @custom:deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8;
import "./interfaces/IArbitrable.sol";
import "./interfaces/IArbitrator.sol";
import "./interfaces/IMetaEvidence.sol";
import "./interfaces/IPost.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Cint32.sol";

/**
 * @title Stake Curate
 * @author Green
 * @notice Curate with indefinitely held, capital-efficient stake.
 * @dev The stakes of the items are handled here. Handling arbitrary on-chain data is
 * possible, but many curation needs can be solved by keeping off-chain state availability.
 */
contract StakeCurate is IArbitrable, IMetaEvidence, IPost {

  enum Party { Staker, Challenger }
  enum DisputeState { Free, Used }
  /**
   * @dev "+" means the state can be stored. Else, is dynamic. Meanings:
   * +Nothing: does not exist yet.
   * Collateralized: item can be challenged. it could either be Included or Young.
   * * use the view isItemMature to discern that, if needed.
   * +Disputed: currently under a Dispute.
   * +Removed: a Dispute ruled to remove this item.
   * Uncollateralized: owner doesn't have enough collateral,
   * * also triggers if owner can withdraw. However, it could still be challenged
   * * if the owner had enough tokens.
   * Outdated: item was last updated before the last list version.
   * Retracted: owner made it go through the retraction period.
   */
  enum ItemState {
    Nothing,
    Collateralized,
    Disputed,
    Removed,
    Uncollateralized,
    Outdated,
    Retracted
  }

  /**
   * @dev "Adoption" is about changing the owner of the item.
   *  Revival: item is non-included, so it can change owner at any price.
   *  MatchOrRaise: item can be adopted, but the stake needs to be equal or greater.
   *   At the moment, this will only occur when item is Disputed. Since the item has
   *   been Disputed, that means the original owner can get compensated. 
   *  None: item can't be adopted at all. It can still be edited and handled by current owner.
   *
   * These restrictions are born due to a need to ensure compensation goes directly
   *  to owners. If items could be adopted freely, then griefers could just adopt the
   *  item away from them and self challenge. Then, there would be a lot of friction
   *  to move the burned funds towards the affected party in order for them to raise
   *  the stakes of the item and protect themselves.
   */
  enum AdoptionState { Revival, MatchOrRaise, None }

  /**
   * @dev Stores the governor, metaEvidenceId, and counters
   */
  struct StakeCurateSettings {
    // can change the governor and update metaEvidence
    address governor;
    uint56 itemCount;
    uint40 freespace2;
    //
    uint56 listCount;
    uint56 disputeCount;
    uint56 accountCount;
    uint56 arbitrationSettingCount;
    uint32 currentMetaEvidenceId;
  }

  struct Account {
    address owner;
    uint32 withdrawingTimestamp;
    uint32 couldWithdrawAt;
    uint32 freespace;
  }

  struct List {
    uint56 governorId; // governor needs an account
    uint32 requiredStake;
    uint32 retractionPeriod; 
    uint56 arbitrationSettingId;
    uint32 versionTimestamp;
    uint32 maxStake; // protects from some bankrun attacks
    uint16 freespace;
    // ----
    IERC20 token;
    uint32 challengerStakeRatio; // (basis points) challenger stake in proportion to the item stake
    uint32 ageForInclusion; // how much time from Young to Included, in seconds
    uint32 freespace2;
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
    uint32 lastUpdated;
    // how much stake is backing up the item. will be equal or greater than list.requiredStake
    uint32 regularStake;
    // refer to "getCanonItemStake" to understand how this works, as for why,
    // tldr: prevent some frontrun attacks related to raising item stakes
    // the raised item stake will become effective after a period.
    uint32 nextStake;
    uint8 freespace;
    // ---
    // last time item went from unchallengeable to challengeable
    uint32 liveSince;
    uint224 freespace2;
    // arbitrary, optional data for on-chain consumption
    bytes harddata;
  }

  struct ChallengeCommit {
    // h(salt, itemId, ratio, reason)
    bytes32 commitHash;
    ///
    uint32 timestamp;
    uint32 tokenAmount;
    uint32 valueAmount;
    IERC20 token;
    ///
    uint56 challengerId;
    uint200 freespace;
  }

  struct DisputeSlot {
    uint56 challengerId;
    uint56 itemId;
    uint56 arbitrationSetting;
    DisputeState state;
    uint32 itemStake; // unlocks to submitter if Keep, sent to challenger if Remove
    uint32 valueStake; // to be awarded to the side that wins the dispute. 
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
  }

  // ----- EVENTS -----

  // Used to initialize counters in the subgraph
  event StakeCurateCreated();
  event ChangedStakeCurateSettings(address _governor);
  event ArbitratorAllowance(IArbitrator _arbitrator, bool _allowance);

  event AccountCreated(uint56 indexed _accountId);
  // tokens that can possibly hold amounts between [2^255, 2^256-1] will break this offset.
  event AccountBalanceChange(uint56 indexed _accountId, IERC20 indexed _token, int256 _offset);
  event AccountStartWithdraw(uint56 indexed _accountId);
  event AccountStopWithdraw(uint56 indexed _accountId);

  event ArbitrationSettingCreated(uint56 indexed _arbSettingId, bytes _arbitratorExtraData);

  event ListUpdated(uint56 indexed _listId, List _list, string _metalist);

  event ItemAdded(
    uint56 indexed _itemId,
    uint56 indexed _listId,
    uint56 indexed _accountId,
    uint32 _stake,
    string _ipfsUri,
    bytes _harddata
  );

  event ItemEdited(
    uint56 indexed _itemId,
    uint56 indexed _accountId,
    uint32 _stake,
    string _ipfsUri,
    bytes _harddata
  );

  event ItemStartRetraction(uint56 indexed _itemId);
  event ItemStopRetraction(uint56 indexed _itemId);

  event ChallengeCommitted(
    uint256 indexed _commitIndex, uint56 indexed _challengerId,
    IERC20 _token, uint32 _tokenAmount, uint32 _valueAmount
  );

  event CommitReveal(
    uint256 indexed _commitIndex, uint56 indexed _itemId,
    uint16 _ratio, string _reason
  );

  // if CommitReveal exists for an index, it was refunded (or burned). o.w. fully revoked.
  event CommitRevoked(uint256 indexed _commitIndex);
  // all info about a challenge can be accessed via the CommitReveal event
  event ItemChallenged(uint56 indexed _disputeId, uint256 indexed _commitIndex, uint56 indexed _itemId);

  // ----- CONSTANTS -----

  uint256 internal constant RULING_OPTIONS = 2;

  IArbitrator internal constant ARBITRATOR = IArbitrator(0x988b3A538b618C7A603e1c11Ab82Cd16dbE28069);

  // these used to be variable settings, but due to edge cases they would cause
  // to previous lists if minimums were increased, or maximum decreased,
  // they were chosen to be constants instead.

  uint32 internal constant MIN_CHALLENGER_STAKE_RATIO = 2_083; // 20.83%
  uint16 internal constant BURN_RATE = 200; // 2%

  // receives the burns, could be an actual burn address like address(0)
  // could alternatively act as some kind of public goods funding, or rent.
  address internal constant BURNER = 0xe5bcEa6F87aAEe4a81f64dfDB4d30d400e0e5cf4;

  // prevents relevant historical balance checks from being too long
  uint32 internal constant MAX_AGE_FOR_INCLUSION = 40 days;
  // min seconds for retraction in any list
  // if a list were to allow having a retractionPeriod that is too low
  // compared to the minimum time for revealing a commit, that would make
  // having an item be retracted unpredictable at commit time. 
  uint32 internal constant MIN_RETRACTION_PERIOD = 1 days;
  uint32 internal constant WITHDRAWAL_PERIOD = 7 days;

  // maximum size, in time, of a balance record. they are kept in order to
  // dynamically find out the age of items.
  uint32 internal constant BALANCE_SPLIT_PERIOD = 6 hours;

  // seconds until a challenge reveal can be accepted
  uint32 internal constant MIN_TIME_FOR_REVEAL = 5 minutes;
  // seconds until a challenge commit is too old
  // this is also the amount of time it takes for an item to be held by the nextStake
  uint32 internal constant MAX_TIME_FOR_REVEAL = 1 hours;

  /**
   * @dev This is a hack, you want the loser side to pay for the arbFees
   *  So you need to keep track of native value amounts from item owner. 
   *  You need to ensure amounts are sufficient for the optional period.
   *  So you need balance records. We can reuse balance records for
   *  values without rewriting code, for that, treat "valueToken" == IERC20(0)
   *  as the placeholder for native value amounts.
   */
  IERC20 internal constant valueToken = IERC20(address(0)); 

  // ----- CONTRACT STORAGE -----

  StakeCurateSettings public stakeCurateSettings;

  mapping(address => uint56) public accountIdOf;
  mapping(uint56 => Account) public accounts;
  
  /**
   * @dev These are records of the balances that a certain account
   *  held of a certain token at a certain time.
   *  We track these to be able to compute
   *  whether if an item has passed through the optimistic period
   *  and stayed collateralized, or not.
   *
   * These are read in the following way:
   * - Each uint32[8] is known as a "pack"
   * - Each record contains a timestamp and a balance
   * - The first four uint32s are timestamps, the next four uint32s balances.
   * - If a timestamp is in [i], its balance lives in [i + 4]
   * - If a timestamp == 0, that means the previous record was the last.
   *
   * The contract will append and purge records under certain circumstances.
   *  Specifically, it will append when the balance is greater (and enough time passed)
   *  And it will purge when the balance is equal or lower. 
   */
  mapping(uint56 => mapping(IERC20 => uint32[8][])) public splits;

  mapping(uint56 => List) public lists;
  mapping(uint56 => Item) public items;
  ChallengeCommit[] public challengeCommits;
  mapping(uint56 => DisputeSlot) public disputes;
  mapping(uint256 => uint56) public disputeIdToLocal;
  mapping(uint56 => ArbitrationSetting) public arbitrationSettings;

  /** 
   * @dev Constructs the StakeCurate contract.
   * @param _governor Can change these settings
   * @param _metaEvidence IPFS uri of the initial MetaEvidence
   */
  constructor(address _governor, string memory _metaEvidence) {
    stakeCurateSettings.governor = _governor;

    stakeCurateSettings.arbitrationSettingCount = 1;
    disputes[0].state = DisputeState.Used;
    stakeCurateSettings.disputeCount = 1; // since disputes are incremental, prevent local dispute 0
    stakeCurateSettings.accountCount = 1; // accounts[0] cannot be used either
    // address(0) can still have an account, though

    emit StakeCurateCreated();
    emit ChangedStakeCurateSettings(_governor);
    emit MetaEvidence(0, _metaEvidence);
    emit ArbitrationSettingCreated(0, "");
  }

  // ----- PUBLIC FUNCTIONS -----

  /**
   * @dev Governor changes the general settings of Stake Curate
   * @param _governor Can change these settings
   * @param _metaEvidence IPFS uri of the initial MetaEvidence
   */
  function changeStakeCurateSettings(
    address _governor,
    string calldata _metaEvidence
  ) external {
    require(msg.sender == stakeCurateSettings.governor);
    // currentMetaEvidenceId must be incremental, so preserve previous one.
    stakeCurateSettings.governor = _governor;
    emit ChangedStakeCurateSettings(_governor);
    stakeCurateSettings.currentMetaEvidenceId++;
    emit MetaEvidence(stakeCurateSettings.currentMetaEvidenceId, _metaEvidence);
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
      id = stakeCurateSettings.accountCount++;
      accountIdOf[_owner] = id;
      accounts[id].owner = _owner;
      emit AccountCreated(id);
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
    balanceRecordRoutine(accountId, _token, newFreeStake);
    // if _amount > 2^255, the _amount below will break and appear negative.
    emit AccountBalanceChange(accountId, _token, int256(_amount));
    // if the sender passes value, we update the value of the accountId
    if (msg.value > 0) {
      newFreeStake = Cint32.decompress(getCompressedFreeStake(accountId, valueToken)) + msg.value;
      balanceRecordRoutine(accountId, _token, newFreeStake);
      emit AccountBalanceChange(accountId, _token, int256(msg.value));
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
      uint32(block.timestamp) + WITHDRAWAL_PERIOD;
    emit AccountStartWithdraw(accountId);
  }
  /**
   * @dev Stops a withdrawal process on your account.
   */
  function stopWithdraw() external {
    uint56 accountId = accountRoutine(msg.sender);
    if (
      accounts[accountId].withdrawingTimestamp > 0
      && accounts[accountId].withdrawingTimestamp <= block.timestamp
    ) {
      accounts[accountId].couldWithdrawAt = uint32(block.timestamp);
    }
    accounts[accountId].withdrawingTimestamp = 0;

    emit AccountStopWithdraw(accountId);
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
    balanceRecordRoutine(accountId, _token, freeStake - _amount);
    // withdraw
    processWithdrawal(msg.sender, _token, _amount, 0);
    emit AccountBalanceChange(accountId, _token, -int256(_amount));
  }

  /**
   * @dev Create arbitrator setting. Will be immutable, and assigned to an id.
   * @param _arbitratorExtraData The extra data
   */
  function createArbitrationSetting(bytes calldata _arbitratorExtraData)
      external returns (uint56 id) {
    unchecked {id = stakeCurateSettings.arbitrationSettingCount++;}
    arbitrationSettings[id] = ArbitrationSetting({
      arbitratorExtraData: _arbitratorExtraData
    });
    emit ArbitrationSettingCreated(id, _arbitratorExtraData);
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
    require(listLegalCheck(_list));
    unchecked {id = stakeCurateSettings.listCount++;}
    _list.governorId = accountRoutine(_governor);
    _list.versionTimestamp = uint32(block.timestamp);
    lists[id] = _list;
    emit ListUpdated(id, _list, _metalist);
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
    require(listLegalCheck(_list));
    // only governor can update a list
    require(accounts[lists[_listId].governorId].owner == msg.sender);
    _list.governorId = accountRoutine(_governor);
    _list.versionTimestamp = uint32(block.timestamp);
    lists[_listId] = _list;
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
    // this require below is needed, because going through withdrawing doesn't entail uncollateralized
    // but item additions or updates should not be allowed while going through.
    require(accounts[accountId].withdrawingTimestamp == 0);
    unchecked {id = stakeCurateSettings.itemCount++;}
    require(_forListVersion == lists[_listId].versionTimestamp);
    require(_stake >= lists[_listId].requiredStake);
    require(_stake <= lists[_listId].maxStake);

    // we create the item, then check if it's valid.
    items[id] = Item({
      accountId: accountId,
      listId: _listId,
      retractionTimestamp: 0,
      state: ItemState.Collateralized,
      lastUpdated: uint32(block.timestamp),
      regularStake: _stake,
      nextStake: _stake,
      freespace: 0,
      liveSince: 0,
      freespace2: 0,
      harddata: _harddata
    });
    // if not Collateralized, something went wrong
    ItemState newState = getItemState(id);
    require(newState == ItemState.Collateralized);

    emit ItemAdded(id, _listId, accountId, _stake, _ipfsUri, _harddata);
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
    uint32 _forItemAt,
    string calldata _ipfsUri,
    bytes calldata _harddata
  ) external {
    Item memory preItem = items[_itemId];
    List memory list = lists[preItem.listId];
    // todo you're not checking if the item even exists. you need to assert its not "nothing"
    require(_forListVersion == list.versionTimestamp);
    require(_forItemAt == preItem.lastUpdated);
    AdoptionState adoption = getAdoptionState(_itemId);
    uint56 senderId = accountRoutine(msg.sender);

    if (adoption == AdoptionState.Revival) {
      require(_stake >= list.requiredStake);
    } else {
      if (preItem.accountId == senderId || adoption == AdoptionState.MatchOrRaise) {
        // if sender is current owner, it's enough if they match
        // also, if item is currently challenged, to cover an edge case in which
        // item owner doesn't bother to raise stakes in a highly disputed item
        // that has a prohibitively high outbidRatio, anyone can take the item
        // if they match the bid.
        require(_stake >= preItem.nextStake);
      } else {
        // sender neither is current, neither can item be adopted.
        revert();
      }
    }

    require(_stake <= list.maxStake);
    require(accounts[senderId].withdrawingTimestamp == 0);
    
    // instead of further checks, just edit the item and do a status check.
    items[_itemId] = Item({
      accountId: senderId,
      listId: preItem.listId,
      retractionTimestamp: 0,
      state: preItem.state == ItemState.Disputed ? ItemState.Disputed : ItemState.Collateralized,
      lastUpdated: uint32(block.timestamp),
      /**
       * If the item wasn't included before this tx
       *  nothing was collateralizing it, so the canonItemStake doesn't serve
       *  any purpose and will be overwritten by the passed _stake.
       * Otherwise, we will make the regularStake be the stake that was
       *  considered to be collateralizing the item at the time of this function.
       */
      regularStake: adoption == AdoptionState.None ? getCanonItemStake(_itemId) : _stake,
      nextStake: _stake,
      freespace: 0,
      liveSince: adoption == AdoptionState.Revival ? uint32(block.timestamp) : preItem.liveSince,
      freespace2: 0,
      harddata: _harddata
    });
    // if not Collateralized, something went wrong so revert.
    // you can also edit items while they are Disputed, as that doesn't change
    // anything about the Dispute in place.
    ItemState newState = getItemState(_itemId);
    require(newState == ItemState.Collateralized || newState == ItemState.Disputed);    

    emit ItemEdited(_itemId, senderId, _stake, _ipfsUri, _harddata);
  }

  /**
   * @dev Starts an item retraction process.
   *  To stop this retraction, owner is supposed to refresh the item.
   * @param _itemId Item to retract.
   */
  function startRetractItem(uint56 _itemId) external {
    Item storage item = items[_itemId];
    require(accounts[item.accountId].owner == msg.sender);
    // itemState is not checked, to make this method cheaper.
    // no security issues if called on unincluded items.
    require(item.retractionTimestamp == 0);
    item.retractionTimestamp = uint32(block.timestamp);
    emit ItemStartRetraction(_itemId);
  }

  /**
   * @dev Prepares a challenge. The challenge will take place once it is revealed.
   *  the challenger places a deposit in order to make this commit.
   * @param _token Token to commit the challenge with.
   * @param _compressedTokenAmount How many tokens to commit.
   * @param _commitHash h(salt, itemId, ratio, reason)
   *  This is a regular hash, not a signature. eip-712 is not needed.
   */
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
      challengeCommits.length - 1, challengerId, _token,
      _compressedTokenAmount, compressedvalue
    );
    return (challengeCommits.length - 1);
  }

  /**
   * @dev Reveals a committed challenge. The dispute will take place if the
   *  challenge is successful, otherwise, the funds will be returned, possibly
   *  incurring a burn.
   * @param _commitIndex Index of the commit to reveal.
   * @param _salt Salt that was used for the hash
   * @param _itemId Item targeted for this challenge
   * @param _ratio Ratio linked with the challengeType invoked.
   *  if it was incorrect, then the arbitrator must reject the challenge.
   * @param _reason Ipfs with the reason behind the challenge.
   *  it also contains the challengeType targeted with the challenge.
   */
  function revealChallenge(
    uint256 _commitIndex,
    bytes32 _salt,
    uint56 _itemId,
    uint16 _ratio,
    string calldata _reason
  ) external returns (uint56 id) {
    ChallengeCommit memory commit = challengeCommits[_commitIndex];
    delete challengeCommits[_commitIndex];

    require(commit.timestamp + MIN_TIME_FOR_REVEAL < block.timestamp);
    require(commit.timestamp + MAX_TIME_FOR_REVEAL > block.timestamp);

    // illegal ratios are not allowed, and will result in this commit being revoked eventually.
    require(_ratio <= 10_000 && _ratio > 0);

    // verify hash here, revert otherwise.
    bytes32 obtainedHash = keccak256(
      abi.encodePacked(_salt, _itemId, _ratio, _reason)
    );
    require(commit.commitHash == obtainedHash);

    emit CommitReveal(_commitIndex, _itemId, _ratio, _reason);

    Item storage item = items[_itemId];
    ItemState itemState = getItemState(_itemId);
    List memory list = lists[item.listId];

    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    uint256 arbFees = ARBITRATOR.arbitrationCost(arbSetting.arbitratorExtraData);
    uint256 valueBurn = arbFees * BURN_RATE / 10_000;

    uint256 ownerValueAmount = Cint32.decompress(getCompressedFreeStake(item.accountId, valueToken));
    uint256 ownerTokenAmount = Cint32.decompress(getCompressedFreeStake(item.accountId, list.token));
    uint256 challengerValueAmount = Cint32.decompress(commit.valueAmount);
    uint256 challengerTokenAmount = Cint32.decompress(commit.tokenAmount);

    uint256 itemStake = Cint32.decompress(getCanonItemStake(_itemId));
    uint256 challengerTokenStakeNeeded = itemStake * list.challengerStakeRatio / 10_000;
    uint256 itemStakeAfterRatio = itemStake * _ratio / 10_000;
  
    // go here through all the conditions that would make this challenge
    // reveal unable to be processed.
    // there are distinct classes:

    if (
      // refund + small burn checks

      // a. timestamp is too early compared to listVersion timestamp.
      // editions of outdated versions are unincluded and thus cannot be challenged
      // this also protects challenger from malicious list updates snatching the challengerStake
      // this has to burn, otherwise self-challengers can camp challenges by using a bogus list
      // honest participants could become affected by this if unlucky, or interacting with
      // malicious list
  
      // > why not just check itemState == ItemState.Outdated ?
      // because: frontrun commit -> list update -> item edit -> reveal challenge.
      // Outdated is also a condition that would trigger this refund + burn.
      // but since ItemState.Outdated is only true if this check is true,
      // it would be redundant to check.
      commit.timestamp <= list.versionTimestamp
      // b. retracted, a well timed sequence of bogus items could trigger these refunds.
      // when an item becomes retracted is completely predictable and should cause no ux issues.
      || itemState == ItemState.Retracted
      // c. a challenge towards an item that doesn't even exist
      || itemState == ItemState.Nothing
      // d. a challenge towards an item that has been removed
      // a sniper controlling the arbitrator could otherwise conditionally
      // remove or keep an item on bogus lists, allowing themselves to trigger refunds.
      || itemState == ItemState.Removed
      // e. item owner can withdraw at reveal time.
      // this is predictable. the length of the period doesn't change.
      // another account could have taken ownership over the item, but
      // accounts with withdrawing timestamp > 0 cannot take ownership.
      || (
        accounts[item.accountId].withdrawingTimestamp > 0
        && accounts[item.accountId].withdrawingTimestamp <= block.timestamp
      )
    ) {
      // burn here
      address challenger = accounts[commit.challengerId].owner;
      processWithdrawal(
        challenger, commit.token, Cint32.decompress(commit.tokenAmount), BURN_RATE
      );
      processWithdrawal(
        challenger, valueToken, Cint32.decompress(commit.valueAmount), BURN_RATE
      );
      emit CommitRevoked(_commitIndex);
    } else if (
      // full refund checks
      // a. not enough tokenAmount for canonStake * challengerRatio
      challengerTokenAmount < challengerTokenStakeNeeded
      // b. not enough valueAmount for arbitrationCost
      || challengerValueAmount < (arbFees + valueBurn)
      // c. the item went from unincluded to included after the targeted edition
      || commit.timestamp < item.liveSince
      // d. wrong token
      || commit.token != list.token
      // e. item is not either Collateralized or Uncollateralized
      // even if not fully collateralized, if the ratio of the challenge type
      // is < 10_000, then there could still be enough to spare for challenger
      || !(
        itemState == ItemState.Collateralized
        || itemState == ItemState.Uncollateralized
      )
      // f. owner doesn't have enough value for arbFees
      || ownerValueAmount < (arbFees + valueBurn)
      // g. owner doesn't have enough freeStake for canonStake * ratio
      || ownerTokenAmount < itemStakeAfterRatio
    ) {
      // full refund here
      address challenger = accounts[commit.challengerId].owner;
      commit.token.transfer(challenger, challengerTokenAmount);
      payable(challenger).send(challengerValueAmount);
      emit CommitRevoked(_commitIndex);
    } else {
      // proceed with the challenge
      unchecked {id = stakeCurateSettings.disputeCount++;}

      // create dispute
      uint256 arbitratorDisputeId =
        ARBITRATOR.createDispute{
          value: arbFees}(
          RULING_OPTIONS, arbSetting.arbitratorExtraData
        );
      // if this reverts, the arbitrator is malfunctioning. the commit will revoke
      require(disputeIdToLocal[arbitratorDisputeId] == 0);
      disputeIdToLocal[arbitratorDisputeId] = id;

      item.state = ItemState.Disputed;

      // we lock the amounts in owner's account
      balanceRecordRoutine(item.accountId, list.token, ownerTokenAmount - itemStakeAfterRatio);
      balanceRecordRoutine(item.accountId, valueToken, ownerValueAmount - arbFees - valueBurn);

      // we send the burned value to burner
      payable(BURNER).send(valueBurn);

      // refund leftovers to challenger, in practice leftovers > 0 (due to Cint32 noise)
      address challenger = accounts[commit.challengerId].owner;
      commit.token.transfer(challenger, challengerTokenAmount - challengerTokenStakeNeeded);
      payable(challenger).send(challengerValueAmount - arbFees - valueBurn);

      // store the dispute
      disputes[id] = DisputeSlot({
        itemId: _itemId,
        challengerId: commit.challengerId,
        arbitrationSetting: list.arbitrationSettingId,
        state: DisputeState.Used,
        itemStake: Cint32.compress(itemStakeAfterRatio),
        valueStake: Cint32.compress(arbFees + valueBurn),
        freespace: 0,
        token: list.token,
        challengerStake: Cint32.compress(challengerTokenStakeNeeded),
        itemOwnerId: item.accountId,
        freespace2: 0
      });

      emit ItemChallenged(id, _commitIndex, _itemId);
      // ERC 1497
      // evidenceGroupId is the itemId, since it's unique per item
      emit Dispute(
        ARBITRATOR, arbitratorDisputeId,
        stakeCurateSettings.currentMetaEvidenceId, _itemId
      );
      // reason is not emitted as evidence, it was emitted in CommitReveal already.
    }
  }

  /**
   * @dev Revoke a commit that has timed out. It will burn tokens and value,
   *  and reimburse the rest to the challenger.
   * @param _commitIndex Index of the commit to reveal.
   */
  function revokeCommit(uint256 _commitIndex) external {
    ChallengeCommit memory commit = challengeCommits[_commitIndex];
    delete challengeCommits[_commitIndex];

    // since deleting a commit sets its timestamp to zero, in practice they will always
    // revert here. so, this require is enough.
    require(commit.timestamp + MAX_TIME_FOR_REVEAL < block.timestamp);
    address challenger = accounts[commit.challengerId].owner;
    // apply the big burn to the token amount.
    processWithdrawal(challenger, commit.token, Cint32.decompress(commit.tokenAmount), BURN_RATE);
    // apply the big burn to the value.
    processWithdrawal(challenger, valueToken, Cint32.decompress(commit.valueAmount), BURN_RATE);
  
    emit CommitRevoked(_commitIndex);
  }

  /**
   * @dev Submits post on an item. Posts can be emitted at any time.
   *  Item existence is not checked, since quality filtering would be done externally.
   *  For example, if the item did not exist at the time the Post was emitted, then
   *  it could be hidden.
   *  Assume this function will be the subject of spam and flood.
   * @param _itemId Id of the item to submit evidence to.
   * @param _post IPFS uri linking to the post.
   */
  function submitPost(uint56 _itemId, string calldata _post) external {
    emit Post(_itemId, _post);
  }

  /**
   * @dev External function for the arbitrator to decide the result of a dispute. TRUSTED
   * @param _disputeId External id of the dispute
   * @param _ruling Ruling of the dispute. If 0 or 1, submitter wins. Else (2) challenger wins
   */
  function rule(uint256 _disputeId, uint256 _ruling) external override {
    require(msg.sender == address(ARBITRATOR));
    require(disputeIdToLocal[_disputeId] != 0);
  
    // 1. get slot from dispute
    uint56 localDisputeId = disputeIdToLocal[_disputeId];
    DisputeSlot memory dispute = disputes[localDisputeId];
    // 2. refunds gas. having reached this step means
    // dispute.state == DisputeState.Used
    // deleting the mapping makes the arbitrator unable to recall
    // this function*
    // * bad arbitrator can reuse a disputeId after ruling.
    disputeIdToLocal[_disputeId] = 0;
    // destroy the disputeSlot information, to trigger refunds, and guard from reentrancy.
    delete disputes[localDisputeId];

    Item storage item = items[dispute.itemId];
    Account memory ownerAccount = accounts[dispute.itemOwnerId];
    List memory list = lists[item.listId];
    uint32 compressedFreeStake = getCompressedFreeStake(dispute.itemOwnerId, dispute.token);
    uint32 compressedValueFreeStake = getCompressedFreeStake(dispute.itemOwnerId, valueToken);

    // we still remember the original dispute fields.

    // 3. apply ruling. what to do when refuse to arbitrate?
    // just default towards keeping the item.
    // 0 refuse, 1 staker, 2 challenger.

    if (_ruling == 2) {
      // challenger won
      item.state = ItemState.Removed;
      // transfer token reward to challenger
      address challenger = accounts[dispute.challengerId].owner;
      processWithdrawal(challenger, dispute.token, Cint32.decompress(dispute.itemStake), BURN_RATE);
      // return the valueStake to challenger
      payable(accounts[dispute.challengerId].owner).send(Cint32.decompress(dispute.valueStake));
    } else {
      // item owner won.
      item.state = ItemState.Collateralized;
      // if list is not outdated, set item lastUpdated
      if (item.lastUpdated > list.versionTimestamp) {
        // since _ratio was introduced to challenges,
        // you can no longer make the assumption that the item will become
        // Collateralized if the list hasn't updated,
        // as the item owner may have lost more tokens in the process,
        // and the unlocked tokens are no longer enough by themselves to collateralize.
        // but it shouldn't be a problem anyway, since it will just become
        // uncollateralized and unchallengeable.
        
        // this is set here because item couldn't be challenged until now.
        // so it needs to go through the period again, in case it was
        // belonging to a list with ageForInclusion.
        item.lastUpdated = uint32(block.timestamp);
      }
      // free the locked stake
      uint256 newFreeStake = Cint32.decompress(compressedFreeStake) + Cint32.decompress(dispute.itemStake);
      balanceRecordRoutine(dispute.itemOwnerId, dispute.token, newFreeStake);
      // return the value to the item owner
      uint256 newValueFreeStake = Cint32.decompress(compressedValueFreeStake) + Cint32.decompress(dispute.valueStake);
      balanceRecordRoutine(dispute.itemOwnerId, valueToken, newValueFreeStake);
      // send challenger stake as compensation to item owner
      processWithdrawal(ownerAccount.owner, dispute.token, Cint32.decompress(dispute.challengerStake), BURN_RATE);
    }
    emit Ruling(ARBITRATOR, _disputeId, _ruling);
  }

  /**
   * @dev Get the state of an item. Some states need to be calculated dynamically.
   * @param _itemId Id of the item to check
   */
  function getItemState(uint56 _itemId) public view returns (ItemState) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];
    uint32 compressedItemStake = getCanonItemStake(_itemId);
    uint32 compressedFreeStake = getCompressedFreeStake(item.accountId, list.token);
    uint256 valueFreeStake = Cint32.decompress(getCompressedFreeStake(item.accountId, valueToken));

    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    uint256 valueNeeded =
      ARBITRATOR.arbitrationCost(arbSetting.arbitratorExtraData)
      * BURN_RATE / 10_000;

    if (
      item.state == ItemState.Disputed
      || item.state == ItemState.Removed
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
    } else if (item.lastUpdated <= list.versionTimestamp) {
      return (ItemState.Outdated);
    } else if (
        // has gone through Withdrawing period,
        (
          accounts[item.accountId].withdrawingTimestamp != 0
          && accounts[item.accountId].withdrawingTimestamp <= block.timestamp
        )
        // not enough to pay arbFees + burn
        || valueFreeStake < valueNeeded
        // or not held by the stake
        || compressedFreeStake < compressedItemStake
    ) {
      return (ItemState.Uncollateralized);
    } else {
      return (ItemState.Collateralized);
    }
  }

  /**
   * @dev For items that are known to be Collateralized, this function
   *  discerns whether if the item is "Young" or "Included".
   *
   *  Young means that the list states that items need to be collateralized
   *  within a given acceptance period, and that the item has not yet went through it.
   *
   *  Included means that it has gone through it, or, that the list doesn't
   *  check for this acceptance period.
   * @param _itemId Id of the item to check
   */
  function isItemMature(uint56 _itemId) public view returns (bool) {
    Item memory item = items[_itemId];
    List memory list = lists[item.listId];

    // list opted out of distinguishing "Young" and "Included"
    if (list.ageForInclusion == 0) {
      return true;
    }

    uint32 compressedItemStake = getCanonItemStake(_itemId);

    ArbitrationSetting memory arbSetting = arbitrationSettings[list.arbitrationSettingId];
    uint256 valueNeeded =
      ARBITRATOR.arbitrationCost(arbSetting.arbitratorExtraData)
      * BURN_RATE / 10_000;
    
    if (accounts[item.accountId].couldWithdrawAt + list.ageForInclusion > block.timestamp) {
      return false;
    } else if (item.lastUpdated + list.ageForInclusion > block.timestamp) {
      return false;
    } else if (!continuousBalanceCheck(item.accountId, list.token, compressedItemStake, uint32(block.timestamp) - list.ageForInclusion)) {
      return false;
    } else if (!continuousBalanceCheck(item.accountId, valueToken, Cint32.compress(valueNeeded), uint32(block.timestamp) - list.ageForInclusion)) {
      return false;
    } else {
      return true;
    }
  }

  /**
   * @dev Dynamically obtains the AdoptionState of an item.
   *  Refer to the definition of "AdoptionState" above.
   * @param _itemId Id of the item to check
   */
  function getAdoptionState(uint56 _itemId) public view returns (AdoptionState) {
    ItemState state = getItemState(_itemId);
    if (
      /** equivalent to:
        state == ItemState.Removed
        || state == ItemState.Retracted
        || state == ItemState.Uncollateralized
        || state == ItemState.Outdated
      */
      state > ItemState.Disputed
    ) {
      return (AdoptionState.Revival);
    }

    // before proceeding, we will check whether there's enough for nextStake.
    // doesn't matter if this nextStake is not into effect yet.
    Item memory item = items[_itemId];
    uint32 compressedFreeStake = getCompressedFreeStake(item.accountId, lists[item.listId].token);
    // if it's no longer collateralized then it's a revival.
    if (compressedFreeStake < item.nextStake) {
      return (AdoptionState.Revival);
    } 
    // we check whether if item satisfies some other conditions for adoption:
    // a. being Disputed
    if (state == ItemState.Disputed) {
      return (AdoptionState.MatchOrRaise);
    }
    // b. item is in retraction process
    if (item.retractionTimestamp != 0) {
      return (AdoptionState.MatchOrRaise);
    }
    // c. owner is within withdrawing process
    if (accounts[item.accountId].withdrawingTimestamp != 0) {
      return (AdoptionState.MatchOrRaise);
    }
    
    return (AdoptionState.None);
  }

  /**
   * @dev Withdraw funds or rewards, automatically applying burns if needed.
   * @param _beneficiary s.e.
   * @param _token Token to withdraw. It could be address(0), which means value.
   * @param _amount s.e.
   * @param _burnRate How much will be burnt, in basis points.
   */
  function processWithdrawal(
    address _beneficiary, IERC20 _token, uint256 _amount, uint32 _burnRate
  ) internal {
    uint256 toBeneficiary = _amount * (10_000 - _burnRate) / 10_000;
    if (_token == valueToken) {
      // value related withdrawal. it is beneficiary responsability to accept value
      if (_burnRate != 0) {
        payable(BURNER).send(_amount - toBeneficiary);
      }
      payable(_beneficiary).send(_amount);
    } else {
      if (_burnRate != 0) {
        _token.transfer(BURNER, _amount - toBeneficiary);
      }
      _token.transfer(_beneficiary, toBeneficiary);
    }
  }

  /**
   * @dev Internal procedure to add or remove balance records.
   * @param _accountId s.e.
   * @param _token Token to record. It could be address(0), which means value.
   * @param _freeStake The new latest balance.
   */
  function balanceRecordRoutine(uint56 _accountId, IERC20 _token, uint256 _freeStake) internal {
    uint32[8][] storage arr = splits[_accountId][_token];
    // the way Cint32 works, comparing values before or after decompression
    // will return the same result. so, we don't even compress / decompress the splits.
    uint32 compressedStake = Cint32.compress(_freeStake);
    
    // if len is zero, just append the first split.
    uint256 preLen = arr.length;
    if (preLen == 0) {
        uint32[8] memory pack;
        pack[0] = uint32(block.timestamp);
        pack[4] = compressedStake;
        arr.push(pack);
    } else {
        // we get to the last pack.
        (uint32[8] memory prepack, uint256 i) = loadPack(arr, preLen);

        uint32 balance = prepack[i + 4];
        uint32 startsAt;
        if (compressedStake <= balance) {
            // when lower, initiate the following process:
            // starting from the end, go through all the splits, and remove all splits
            // such that have more or equal split.
            // after iterating through this, create a new split with the last timestamp
            while (compressedStake <= balance) {
                startsAt = prepack[i];
                if (i > 0) {
                    i--;
                } else {
                    i = 3;
                    arr.pop();
                    preLen--;
                    if (preLen == 0) {
                        break;
                    }
                    prepack = arr[preLen - 1];
                }
                // if solidity reverts when you try to access an invalid element of array, this breaks.
                balance = prepack[i + 4];
            }
            oneCellUp(arr, preLen, i, startsAt, compressedStake);
        } else {
            // since it's higher, check last record time to consider appending.
            startsAt = prepack[i];
            if (block.timestamp >= startsAt + BALANCE_SPLIT_PERIOD) {
                // out of the period. a new split will be made.
                oneCellUp(arr, preLen, i, uint32(block.timestamp), compressedStake);
            } else {
                // if it's higher and within the split, we override the amount.
                // qa : why not override the startTime as well?
                // because then, if someone were to frequently update their amounts,
                // the last record would non-stop get pushed to the future.
                // it would be a rare occurrance if the periods are small, but rather not
                // risk it. this compromise only reduces the guaranteed collateralization requirement
                // by the split period.
                arr[preLen-1][i + 4] = compressedStake;
            }
        }
    }
  }

  /**
   * @dev Check whether if an account has held a certain amount for a certain time.
   * @param _accountId s.e.
   * @param _token Token to check. It could be address(0), which means value.
   * @param _requiredStake The amount to assert
   * @param _targetTime We check if the amount is enough at every point after this timestamp.
   */
  function continuousBalanceCheck(
    uint56 _accountId, IERC20 _token, uint32 _requiredStake, uint32 _targetTime
  ) public view returns (bool) {
    uint32[8][] storage arr = splits[_accountId][_token];
    uint256 len = arr.length;
    if (len == 0) return false;
    
    (uint32[8] memory pack, uint256 i) = loadPack(arr, len);

    while (len > 0) {
      pack = arr[len - 1];
      do {
        // we test if we can pass the split.
        // we don't decompress because comparisons work without decompressing
        if (_requiredStake > pack[i + 4]) return (false);
        // we survived, and now check if time is within the split.
        if (pack[i] <= _targetTime) return (true);
        unchecked {i--;}
      } while (i < 4);
      len--;
      i = 3;
    }

    // target is beyong the earliest record, not enough time for collateralization.
    return (false);
  }

  /**
   * @dev Get current balance of an account, of a particular token.
   * @param _accountId s.e.
   * @param _token Token to check. It could be address(0), which means value.
   */
  function getCompressedFreeStake(uint56 _accountId, IERC20 _token) public view returns (uint32) {
    // we get to the last pack.
    uint32[8][] storage arr = splits[_accountId][_token];
    uint256 len = arr.length;
    if (len == 0) return (0);

    (uint32[8] memory pack, uint256 i) = loadPack(arr, len);

    return pack[i + 4];
  }

    /**
   * @dev Get pack and i pointer for a pack.
   * @param _arr Array containing the balance split packs.
   * @param _len Length of this array, passed to skip a storage load.
   */
  function loadPack(uint32[8][] storage _arr, uint256 _len) internal view returns(uint32[8] memory pack, uint256 i) {
    pack = _arr[_len - 1];
    // we get the last split from this pack.
    // we may need to do up to 3 checks. if you get a cell with a 0, it's on the prev index.
    if (pack[1] == 0) {
        i = 0;
    } else if (pack[2] == 0) {
        i = 1;
    } else if (pack[3] == 0) {
        i = 2;
    } else {
        i = 3;
    }
  }

  /**
   * @dev Mutate the splits array to introduce a new split.
   *  Handles the logic required to either push new packs to the array, or mutate last pack.
   * @param _arr Array containing the balance split packs.
   * @param _len Length of this array, passed to skip a storage load.
   * @param _i "i" value of the current latest pack.
   * @param _startsAt value to append.
   * @param _balance value to append. 
   */
  function oneCellUp(uint32[8][] storage _arr, uint256 _len, uint256 _i, uint32 _startsAt, uint32 _balance) internal {
    if (_i == 3) {
        // out of space, create new pack
        uint32[8] memory newpack;
        newpack[0] = _startsAt;
        newpack[4] = _balance;
        _arr.push(newpack);
    } else {
        // write
        uint32[8] memory lastpack;
        lastpack[_i+1] = _startsAt;
        lastpack[_i+5] = _balance;
        // now write zeroes on spare timestamps
        // there are two cases this needs to be done, if i == 0 or i == 1.
        if (_i == 0) {
            lastpack[2] = 0;
            lastpack[3] = 0;
        } else if (_i == 1) {
            lastpack[3] = 0;
        }
        // you dont need to erase the balances.
        _arr[_len-1] = lastpack;
    }
  }

  function listLegalCheck(List memory _list) internal view returns (bool) {
    return (
      _list.arbitrationSettingId < stakeCurateSettings.arbitrationSettingCount
      && _list.challengerStakeRatio >= MIN_CHALLENGER_STAKE_RATIO
      && _list.ageForInclusion <= MAX_AGE_FOR_INCLUSION
      && _list.retractionPeriod >= MIN_RETRACTION_PERIOD
    );
  }

  /**
   * @dev Get the stake that is collateralizing an item in the present.
   *  This was needed to prevent item owners to instantly raise stakes
   *  and force challenges to revert due to undercollateralization.
   * @param _itemId s.e.
   */
  function getCanonItemStake(uint56 _itemId) public view returns (uint32) {
    if (items[_itemId].lastUpdated + MAX_TIME_FOR_REVEAL >= block.timestamp) {
      return (items[_itemId].nextStake);
    } else {
      return (items[_itemId].regularStake);
    }
  }
}
