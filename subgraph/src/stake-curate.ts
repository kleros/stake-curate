import { BigInt, Bytes, ethereum, log } from "@graphprotocol/graph-ts"
import {
  StakeCurate,
  StakeCurateCreated,
  AccountCreated,
  AccountFunded,
  AccountStartWithdraw,
  AccountWithdrawn,
  ArbitrationSettingCreated,
  Dispute as DisputeEvent,
  Evidence as EvidenceEvent,
  ItemAdded,
  ItemAdopted,
  ItemChallenged,
  ItemEdited,
  ItemRecommitted,
  ItemStartRemoval,
  ItemStopRemoval,
  ListCreated,
  ListUpdated,
  MetaEvidence as MetaEvidenceEvent,
  Ruling,
  ChangedStakeCurateSettings,
} from "../generated/StakeCurate/StakeCurate"
import {
  Account,
  ArbitrationSetting,
  MetaList,
  Evidence,
  GeneralCounter,
  Item,
  List,
  ListVersion,
  Column,
  EvidenceThread,
  Edition,
  Prop,
  ItemSlot,
  Dispute,
  DisputeCheckpoint,
  MetaEvidence,
} from "../generated/schema"
import { decompress } from "./cint32"
// funcs made shorter because otherwise they take multiple lines
import {
  ipfsToJsonValueOrNull,
  JSONValueToString as jstr,
  JSONValueToBool as jbool,
  JSONValueToBigInt as jbig,
  JSONValueToObject as jobj,
  JSONValueToArray as jarr,
} from "./utils"

export function handleStakeCurateCreated(event: StakeCurateCreated): void {
  let counter = new GeneralCounter("0")
  counter.accountCount = BigInt.fromU32(0)
  counter.listCount = BigInt.fromU32(0)
  counter.arbitrationSettingCount = BigInt.fromU32(0)
  // these two will be overwritten by first setting
  counter.withdrawalPeriod = BigInt.fromU32(0) 
  counter.governor = event.transaction.from

  counter.save()
  
  /// hack below. consider reverting so this doesn't happen in the first place todo
  // the contract allows to submit evidence to unexistant item slots,
  // they will have evidenceGroupId "0", so create a thread for it
  // to avoid crashing.
  let thread = new EvidenceThread("0")
  thread.evidenceGroupId = BigInt.fromU32(0)
  thread.evidenceCount = BigInt.fromU32(0)
  thread.item = `0@0` // needs to point somewhere, so, item 0 of list 0.
  thread.save()
}

export function handleChangedStakeCurateSettings(
  event: ChangedStakeCurateSettings
): void {
  // stake curate was deployed
  let counter = new GeneralCounter("0") as GeneralCounter
  counter.withdrawalPeriod = event.params._withdrawalPeriod
  counter.governor = event.params._governor
  counter.save()
}

export function handleAccountCreated(event: AccountCreated): void {
  let counter = GeneralCounter.load("0") as GeneralCounter

  let account = new Account(counter.accountCount.toString())

  account.accountId = counter.accountCount
  account.owner = event.params._owner
  account.fullStake = decompress(event.params._fullStake)
  account.freeStake = decompress(event.params._fullStake)
  account.lockedStake = BigInt.fromU32(0)
  account.withdrawing = false
  account.withdrawingTimestamp = BigInt.fromU32(0)
  account.save()
  // increment accountCount
  counter.accountCount = counter.accountCount.plus(BigInt.fromU32(1))
  counter.save()
}

export function handleAccountFunded(event: AccountFunded): void {
  let account = Account.load(event.params._accountId.toString()) as Account

  let fullStake = decompress(event.params._fullStake)
  account.fullStake = fullStake
  account.freeStake = fullStake.minus(account.lockedStake)
  account.save()
}

export function handleAccountStartWithdraw(event: AccountStartWithdraw): void {
  let account = Account.load(event.params._accountId.toString()) as Account

  account.withdrawing = true
  account.withdrawingTimestamp = event.block.timestamp
  account.save()
}

export function handleAccountWithdrawn(event: AccountWithdrawn): void {
  let account = Account.load(event.params._accountId.toString()) as Account

  let fullStake = decompress(event.params._fullStake)
  account.fullStake = fullStake
  account.freeStake = fullStake.minus(account.lockedStake)
  account.withdrawing = false
  account.withdrawingTimestamp = BigInt.fromU32(0)
}

export function handleArbitrationSettingCreated(
  event: ArbitrationSettingCreated
): void {
  let counter = GeneralCounter.load("0") as GeneralCounter

  let arbSetting = new ArbitrationSetting(
    counter.arbitrationSettingCount.toString()
  )
  arbSetting.arbitrationSettingId = counter.arbitrationSettingCount
  arbSetting.arbitrator = event.params._arbitrator
  arbSetting.arbitratorExtraData = event.params._arbitratorExtraData
  arbSetting.save()

  // increment arbitrationSettingCount
  counter.arbitrationSettingCount = counter.arbitrationSettingCount.plus(
    BigInt.fromU32(1)
  )
  counter.save()
}

export function handleDispute(event: DisputeEvent): void {
  // add arbitratorDisputeId and metaEvidence to our Dispute entity.
  // get the dispute by using the evidenceGroupID
  // the dispute already exists because it's created at handleItemChallenge
  let thread = EvidenceThread.load(event.params._evidenceGroupID.toString()) as EvidenceThread
  let item = Item.load(thread.item) as Item
  let dispute = Dispute.load(item.currentDispute as string) as Dispute

  dispute.arbitratorDisputeId = event.params._disputeID
  dispute.metaEvidence = event.params._metaEvidenceID.toString()
  dispute.save()

  let listVersion = ListVersion.load(dispute.listVersion) as ListVersion
  let arbitrationSetting = ArbitrationSetting.load(listVersion.arbitrationSetting) as ArbitrationSetting
  // this entity is made to find the Dispute on Ruling
  let checkpointId = `${event.params._disputeID.toString()}@${arbitrationSetting.arbitrator.toHexString()}`
  let disputeCheckpoint = DisputeCheckpoint.load(checkpointId)
  if (disputeCheckpoint !== null) {
    // it shouldn't exist.
    log.warning("arbitrator didn't respect disputeID uniqueness, ignoring dispute. checkpoint {}", [
      disputeCheckpoint.id,
    ])
    return
  }

  disputeCheckpoint = new DisputeCheckpoint(checkpointId)
  disputeCheckpoint.dispute = dispute.id
  disputeCheckpoint.save()
}

export function handleEvidence(event: EvidenceEvent): void {
  let thread = EvidenceThread.load(event.params._evidenceGroupID.toString()) as EvidenceThread
  let localId = thread.evidenceCount
  thread.evidenceCount = thread.evidenceCount.plus(BigInt.fromU32(1))
  thread.save()

  let evidence = new Evidence(`${localId.toString()}@${thread.id}`)
  // start with the sure data
  evidence.localId = localId
  evidence.thread = thread.id
  evidence.rawUri = event.params._evidence
  evidence.party = event.params._party
  evidence.arbitrator = event.params._arbitrator
  evidence.isMalformatted = false // optimistic

  // commence ipfs parsing
  let obj = jobj(ipfsToJsonValueOrNull(evidence.rawUri))

  if (!obj) {
    log.warning("Error acquiring json from ipfs. evidence id: {}", [
      evidence.id,
    ])
    evidence.isMalformatted = true
    evidence.save()
    return
  }
  // parse the fields. note that no longer does a null result in malformat
  evidence.name = jstr(obj.get("name"))
  evidence.description = jstr(obj.get("description"))
  evidence.fileUri = jstr(obj.get("fileUri"))
  evidence.fileTypeExtension = jstr(obj.get("fileTypeExtension"))
  evidence.save()
}

function processEdition(
  item: Item,
  ipfsUri: string,
  harddata: Bytes,
  block: ethereum.Block
): void {
  let editionNumber = item.editionCount
  let edition = new Edition(`${editionNumber.toString()}@${item.id}`)
  item.editionCount = item.editionCount.plus(BigInt.fromU32(1))
  item.currentEdition = edition.id
  item.save()

  edition.localId = editionNumber
  edition.item = item.id
  edition.author = item.account
  edition.ipfsUri = ipfsUri
  // edition.props is taken care of at the end.
  edition.harddata = harddata
  // consider it well formatted initially, set it to true if we fail parsing.
  edition.isMalformatted = false
  edition.missingRequired = false
  edition.hasIntrusion = false
  edition.timestamp = block.timestamp
  edition.blockNumber = block.number
  // get listVersion
  let list = List.load(item.list) as List
  edition.listVersion = list.currentVersion

  // get props. the json contains the props at the top level
  let props = jarr(ipfsToJsonValueOrNull(ipfsUri))
  if (!props) {
    log.error("Error acquiring props from ipfs. edition id: {}", [edition.id])
    edition.isMalformatted = true
    edition.save()
    return
  }

  let requiredCount = 0

  for (let i = 0; i < props.length; i++) {
    let propObj = jobj(props[i])
    if (!propObj) {
      log.warning("bad prop, breaking. edition id: {}, prop index: {}", [
        edition.id,
        i.toString(),
      ])
      edition.isMalformatted = true
      break
    }
    let label = jstr(propObj.get("label"))
    let value = jstr(propObj.get("value"))
    if (label === null) {
      log.warning(
        "prop has null label, breaking. edition id: {}, prop index: {}",
        [edition.id, i.toString()]
      )
      edition.isMalformatted = true
      break
    }
    // check if prop is dupe.
    let propId = `${label}@${edition.id}`
    let prop = Prop.load(propId)
    if (prop) {
      log.warning("dupe prop. edition id: {}, prop index: {}", [
        edition.id,
        i.toString(),
      ])
      edition.isMalformatted = true
      edition.save()
      return
    }
    // prop is fine. create entity
    prop = new Prop(propId)
    prop.edition = edition.id
    prop.label = label
    prop.value = value
    prop.missing = false // optimistic
    prop.intrusive = false // optimistic

    // check if it was uncalled for, or required and null. to do so, get the mapped column.
    let column = Column.load(`${label}@${list.currentVersion}`)
    if (!column) {
      edition.hasIntrusion = true
      prop.intrusive = true
    } else if (column.required) {
      if (prop.value === null) {
        edition.missingRequired = true
        prop.missing = true
      } else {
        requiredCount++
      }
    }
    prop.save()
  }

  // need metaList to check how many required columns there were
  let metaList = MetaList.load(list.currentVersion) as MetaList

  if (requiredCount < metaList.requiredCount) {
    edition.missingRequired = true
  }

  edition.save()
}

export function handleItemAdded(event: ItemAdded): void {
  let list = List.load(event.params._listId.toString()) as List
  let itemLocalId = list.itemCount
  list.itemCount = list.itemCount.plus(BigInt.fromU32(1))
  list.save()
  let item = new Item(`${itemLocalId}@${list.id}`)
  item.localId = itemLocalId
  item.itemSlot = event.params._itemSlot
  item.submissionBlock = event.block.number
  item.status = "Included"
  item.commitTimestamp = event.block.timestamp

  item.removing = false
  item.removalTimestamp = BigInt.fromU32(0)
  item.account = event.params._accountId.toString()

  item.list = list.id

  item.editionCount = BigInt.fromU32(0) // will be incremented when edition is processed

  item.disputeCount = BigInt.fromU32(0)
  item.currentDispute = null

  // evidenceThread is created on item creation
  let evidenceGroupId = item.itemSlot.leftShift(32).plus(item.submissionBlock)
  let evidenceThread = new EvidenceThread(evidenceGroupId.toString())
  evidenceThread.evidenceGroupId = evidenceGroupId
  evidenceThread.item = item.id
  evidenceThread.evidenceCount = BigInt.fromU32(0)
  evidenceThread.save()

  item.thread = evidenceThread.id
  // item.save() will be done on the processEdition below

  let itemSlot = new ItemSlot(event.params._itemSlot.toString())
  itemSlot.item = item.id
  itemSlot.save()

  processEdition(
    item,
    event.params._ipfsUri,
    event.params._harddata,
    event.block
  )
}

export function handleItemEdited(event: ItemEdited): void {
  // editing an item also recommits stake.
  let itemSlot = ItemSlot.load(event.params._itemSlot.toString()) as ItemSlot
  let item = Item.load(itemSlot.item) as Item
  item.commitTimestamp = event.block.timestamp
  // item.save() will be done on the processEdition below
  processEdition(
    item,
    event.params._ipfsUri,
    event.params._harddata,
    event.block
  )
}

export function handleItemAdopted(event: ItemAdopted): void {
  let itemSlot = ItemSlot.load(event.params._itemSlot.toString()) as ItemSlot
  let item = Item.load(itemSlot.item) as Item
  // adopting recommits timestamp
  item.commitTimestamp = event.block.timestamp
  // regular adoption flow
  item.account = event.params._adopterId.toString()
  item.removing = false
  item.removalTimestamp = BigInt.fromU32(0)
  item.save()
}

export function handleItemRecommitted(event: ItemRecommitted): void {
  let itemSlot = ItemSlot.load(event.params._itemSlot.toString()) as ItemSlot
  let item = Item.load(itemSlot.item) as Item
  item.commitTimestamp = event.block.timestamp
  item.save()
}

export function handleItemStartRemoval(event: ItemStartRemoval): void {
  let itemSlot = ItemSlot.load(event.params._itemSlot.toString()) as ItemSlot
  let item = Item.load(itemSlot.item) as Item
  // there's nothing else to it, is it?
  item.removing = true
  item.removalTimestamp = event.block.timestamp
  item.save()
}

export function handleItemStopRemoval(event: ItemStopRemoval): void {
  let itemSlot = ItemSlot.load(event.params._itemSlot.toString()) as ItemSlot
  let item = Item.load(itemSlot.item) as Item
  // there's nothing else to it, is it?
  item.removing = false
  item.removalTimestamp = BigInt.fromU32(0)
  item.save()
}

export function handleItemChallenged(event: ItemChallenged): void {
  let itemSlot = ItemSlot.load(event.params._itemSlot.toString()) as ItemSlot
  let item = Item.load(itemSlot.item) as Item
  // put item in "dispute" mode
  let disputeLocalId = item.disputeCount
  item.status = "Disputed"
  item.disputeCount = item.disputeCount.plus(BigInt.fromU32(1))

  let dispute = new Dispute(`${disputeLocalId.toString()}@${item.id}`)
  item.currentDispute = dispute.id

  // mind this is dubious and may be changed in StakeCurate.sol to reset on failed challenge
  // todo
  item.removalTimestamp = BigInt.fromU32(0)

  // create the dispute
  dispute.localId = disputeLocalId
  dispute.disputeSlot = event.params._disputeSlot
  // dispute.arbitratorDisputeId is truly set at handleDispute. writing to stop crash
  dispute.arbitratorDisputeId = BigInt.fromU32(0)

  dispute.status = "Ongoing"
  dispute.ruling = null
  dispute.item = item.id
  dispute.challenger = event.transaction.from
  let list = List.load(item.list) as List
  let listVersion = ListVersion.load(list.currentVersion) as ListVersion
  dispute.listVersion = listVersion.id
  // getting the stake of the dispute is a bit involved:
  // 1. the stake is equal to min(listVersion.requiredStake, account.freeStake)
  let account = Account.load(item.account) as Account
  let stake = BigInt.compare(listVersion.requiredStake, account.freeStake) === -1
    ? listVersion.requiredStake
    : account.freeStake
  // 2. update the freeStake and lockedStake amounts on the account
  account.lockedStake = account.lockedStake.plus(stake)
  account.freeStake = account.freeStake.minus(stake)
  account.save()
  // 3. set the dispute stake
  dispute.stake = stake

  dispute.creationTimestamp = event.block.timestamp
  dispute.resolutionTimestamp = null
  // dispute.metaEvidence is truly set on DisputeEvent. writing to stop crash
  dispute.metaEvidence = "id"

  dispute.save()
  item.save()
}

/**
 * Used in both ListCreated and ListUpdated.
 * Contains all logic required to create the MetaList, that is,
 * IPFS, parsing, and saving the entity.
 */
function processMetaList(listVersion: ListVersion, metaListUri: string): void {
  let metaList = new MetaList(listVersion.id)

  metaList.version = listVersion.id
  metaList.versionId = listVersion.versionId
  metaList.ipfsUri = metaListUri
  // consider it well formatted initially,
  // set it to true as we fail parsing.
  metaList.isMalformatted = false

  // fetch the file
  let obj = jobj(ipfsToJsonValueOrNull(metaListUri))

  if (!obj) {
    log.error("Error acquiring json from ipfs. metaList id: {}", [
      listVersion.id,
    ])
    metaList.isMalformatted = true
    metaList.save()
    return
  }

  // get those fields
  let policyUri = jstr(obj.get("policyUri"))
  let defaultAgeForInclusion = jbig(obj.get("defaultAgeForInclusion"))
  let challengeCooldown = jbig(obj.get("challengeCooldown"))
  let listTitle = jstr(obj.get("listTitle"))
  let listDescription = jstr(obj.get("listDescription"))
  let itemName = jstr(obj.get("itemName"))
  let itemNamePlural = jstr(obj.get("itemNamePlural"))
  let logoUri = jstr(obj.get("logoUri"))
  let isListOfLists = jbool(obj.get("isListOfLists"))
  let hasHarddata = jbool(obj.get("hasHarddata"))
  let harddataDescription = jstr(obj.get("harddataDescription"))

  // these fields are considered mandatory. null -> malformatted
  if (
    !policyUri ||
    !listTitle ||
    !listDescription ||
    (hasHarddata && !harddataDescription)
  ) {
    log.warning("metadata missing mandatory fields. metaList id: {}", [
      metaList.id,
    ])
    metaList.isMalformatted = true
  }

  let zero = BigInt.fromU32(0)

  metaList.policyUri = policyUri
  metaList.defaultAgeForInclusion = defaultAgeForInclusion ? defaultAgeForInclusion : zero
  metaList.challengeCooldown = challengeCooldown ? challengeCooldown : zero
  metaList.listTitle = listTitle
  metaList.listDescription = listDescription
  metaList.itemName = itemName
  metaList.itemNamePlural = itemNamePlural
  metaList.logoUri = logoUri
  metaList.isListOfLists = isListOfLists
  metaList.hasHarddata = hasHarddata
  metaList.harddataDescription = harddataDescription

  // process the columns
  let columns = jarr(obj.get("columns"))
  let requiredCount = 0

  if (!columns) {
    log.warning("wrong columns object. metaList id: {}", [metaList.id])
    metaList.isMalformatted = true
  } else {
    // go through the columns and create entities
    for (let i = 0; i < columns.length; i++) {
      let columnObj = jobj(columns[i])
      if (!columnObj) {
        log.warning("bad column. metaList id: {}, column index: {}", [
          metaList.id,
          i.toString(),
        ])
        metaList.isMalformatted = true
        break
      }
      let type = jstr(columnObj.get("type"))
      let label = jstr(columnObj.get("label"))
      let description = jstr(columnObj.get("description"))
      let required = jbool(columnObj.get("required"))
      let isIdentifier = jbool(columnObj.get("isIdentifier"))
      if (type === null || label === null || description === null) {
        log.warning(
          "column has null mandatory value. metaList id: {}, column index: {}",
          [metaList.id, i.toString()]
        )
        metaList.isMalformatted = true
        break
      }
      // check if it existed previously, just to keep track of it.
      let columnId = `${label}@${metaList.id}`
      let column = Column.load(columnId)
      if (column) {
        log.warning("dupe column. metaList id: {}, column index: {}", [
          metaList.id,
          i.toString(),
        ])
        metaList.isMalformatted = true
        metaList.save()
        return
      }
      // column is fine, create entity
      column = new Column(`${label}@${metaList.id}`)
      column.metaList = metaList.id
      column.type = type
      column.label = label
      column.description = description
      column.required = required
      column.isIdentifier = isIdentifier
      if (required) requiredCount++
      column.save()
    }
  }

  metaList.requiredCount = requiredCount
  metaList.save()
}

export function handleListCreated(event: ListCreated): void {
  let counter = GeneralCounter.load("0") as GeneralCounter

  let list = new List(counter.listCount.toString())
  list.listId = counter.listCount
  list.itemCount = BigInt.fromU32(0)
  list.versionCount = BigInt.fromU32(1)

  let listVersion = new ListVersion(`0@${list.id}`)
  listVersion.list = list.id
  listVersion.versionId = BigInt.fromU32(0)
  listVersion.timestamp = event.block.timestamp
  listVersion.governor = event.params._governorId.toString()
  listVersion.arbitrationSetting = event.params._arbitrationSettingId.toString()
  listVersion.removalPeriod = event.params._removalPeriod
  listVersion.upgradePeriod = event.params._upgradePeriod
  listVersion.requiredStake = decompress(event.params._requiredStake)
  // we can figure out the MetaList id, but it doesn't exist yet
  listVersion.metaList = listVersion.id
  listVersion.save()

  list.currentVersion = listVersion.id
  list.save()

  processMetaList(listVersion, event.params._metalist)

  counter.listCount = counter.listCount.plus(BigInt.fromU32(1))
  counter.save()
}

export function handleListUpdated(event: ListUpdated): void {
  let list = List.load(event.params._listId.toString()) as List

  let listVersion = new ListVersion(
    `${list.versionCount.toString()}@${list.id}`
  )
  listVersion.list = list.id
  listVersion.versionId = list.versionCount
  listVersion.timestamp = event.block.timestamp
  listVersion.governor = event.params._governorId.toString()
  listVersion.arbitrationSetting = event.params._arbitrationSettingId.toString()
  listVersion.removalPeriod = event.params._removalPeriod
  listVersion.upgradePeriod = event.params._upgradePeriod
  listVersion.requiredStake = decompress(event.params._requiredStake)
  // we can figure out the MetaList id, but it doesn't exist yet
  listVersion.metaList = listVersion.id
  listVersion.save()

  processMetaList(listVersion, event.params._metalist)

  list.versionCount = list.versionCount.plus(BigInt.fromU32(1))
  list.currentVersion = listVersion.id
  list.save()
}

export function handleMetaEvidence(event: MetaEvidenceEvent): void {
  let metaEvidence = new MetaEvidence(event.params._metaEvidenceID.toString())
  metaEvidence.uri = event.params._evidence
  metaEvidence.save()
  return
}

export function handleRuling(event: Ruling): void {
  let checkpointId = `${event.params._disputeID.toString()}@${event.params._arbitrator.toHexString()}`
  let checkpoint = DisputeCheckpoint.load(checkpointId) as DisputeCheckpoint

  let dispute = Dispute.load(checkpoint.dispute) as Dispute

  dispute.status = "Resolved"
  // ruling === 0 || ruling === 1 -> keep, otherwise remove.
  let ruling = event.params._ruling.lt(BigInt.fromU32(2)) ? "Keep" : "Remove"
  dispute.ruling = ruling
  dispute.resolutionTimestamp = event.block.timestamp
  dispute.save()

  // depending on the ruling, the logic is different. item and account endure changes
  let item = Item.load(dispute.item) as Item
  let account = Account.load(item.account) as Account

  item.currentDispute = null

  if (ruling === "Keep") {
    // free stake in account
    account.freeStake = account.freeStake.plus(dispute.stake)
    account.lockedStake = account.lockedStake.minus(dispute.stake)
    
    item.status = "Included"
    if (item.removing) {
      item.removalTimestamp = event.block.timestamp
    }
  } else {
    // send stake to challenger
    account.fullStake = account.fullStake.minus(dispute.stake)
    account.lockedStake = account.lockedStake.minus(dispute.stake)

    item.status = "Excluded"
  }

  item.save()
  account.save()
}
