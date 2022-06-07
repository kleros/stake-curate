import { BigInt, log } from "@graphprotocol/graph-ts"
import {
  StakeCurate,
  StakeCurateCreated,
  AccountCreated,
  AccountFunded,
  AccountStartWithdraw,
  AccountWithdrawn,
  ArbitrationSettingCreated,
  Dispute,
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
} from "../generated/schema"
import { decompress } from "./cint32"
// funcs made shorter because otherwise they take multiple lines
import {
  ipfsToJsonObjOrNull,
  JSONValueToString as jstr,
  JSONValueToBool as jbool,
  JSONValueToBigInt as jbig,
  JSONValueToObject as jobj,
  JSONValueToArray as jarr
} from "./utils"

export function handleStakeCurateCreated(event: StakeCurateCreated): void {
  let counter = GeneralCounter.load("0")
  if (!counter) {
    counter = new GeneralCounter("0")
    counter.accountCount = BigInt.fromI32(0)
    counter.listCount = BigInt.fromI32(0)
    counter.arbitrationSettingCount = BigInt.fromI32(0)
    counter.save()
  }
}

export function handleAccountCreated(event: AccountCreated): void {
  let counter = GeneralCounter.load("0") as GeneralCounter

  let account = new Account(counter.accountCount.toString())

  account.accountId = counter.accountCount
  account.owner = event.params._owner
  account.fullStake = decompress(event.params._fullStake)
  account.freeStake = decompress(event.params._fullStake)
  account.lockedStake = BigInt.fromI32(0)
  account.withdrawing = false
  account.withdrawingTimestamp = BigInt.fromI32(0)
  account.save()
  // increment accountCount
  counter.accountCount = counter.accountCount.plus(BigInt.fromI32(1))
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
  account.withdrawingTimestamp = BigInt.fromI32(0)
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
    BigInt.fromI32(1)
  )
  counter.save()
}

export function handleDispute(event: Dispute): void {}

export function handleEvidence(event: Evidence): void {}

export function handleItemAdded(event: ItemAdded): void {
  let id = `${event.block.number}@${event.params._itemSlot}`
  let item = new Item(id)
  // todo
}

export function handleItemAdopted(event: ItemAdopted): void {}

export function handleItemChallenged(event: ItemChallenged): void {}

export function handleItemEdited(event: ItemEdited): void {}

export function handleItemRecommitted(event: ItemRecommitted): void {}

export function handleItemStartRemoval(event: ItemStartRemoval): void {}

export function handleItemStopRemoval(event: ItemStopRemoval): void {}

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
  let obj = ipfsToJsonObjOrNull(metaListUri)

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
    isListOfLists === null ||
    hasHarddata === null ||
    (hasHarddata && !harddataDescription)
  ) {
    log.warning("metadata missing mandatory fields. metaList id: {}", [
      metaList.id,
    ])
    metaList.isMalformatted = true
  }

  metaList.policyUri = policyUri
  metaList.defaultAgeForInclusion = defaultAgeForInclusion
  metaList.listTitle = listTitle
  metaList.listDescription = listDescription
  metaList.itemName = itemName
  metaList.itemNamePlural = itemNamePlural
  metaList.logoUri = logoUri
  metaList.isListOfLists = !!isListOfLists
  metaList.hasHarddata = !!hasHarddata
  metaList.harddataDescription = harddataDescription

  // process the columns
  let columns = jarr(obj.get("columns"))

  if (!columns) {
    log.warning("wrong columns object. metaList id: {}", [
      metaList.id,
    ])
    metaList.isMalformatted = true
  } else {
    // go through the columns and create entities
    for (let i = 0; i < columns.length; i++) {
      let columnObj = jobj(columns[i])
      if (!columnObj) {
        log.warning("bad column. metaList id: {}, column index: {}", [
          metaList.id, i.toString()
        ])
        metaList.isMalformatted = true
        break
      }
      let type = jstr(obj.get("type"))
      let label = jstr(obj.get("label"))
      let description = jstr(obj.get("description"))
      let required = jbool(obj.get("required"))
      let isIdentifier = jbool(obj.get("isIdentifier"))
      if (type === null || label === null || description === null) {
        log.warning("column has null mandatory value. metaList id: {}, column index: {}", [
          metaList.id, i.toString()
        ])
        metaList.isMalformatted = true
        break
      }
      // column is fine. create entity
      let column = new Column(`${label}@${metaList.id}`)
      column.metaList = metaList.id
      column.type = type
      column.label = label
      column.description = description
      column.required = !!required
      column.isIdentifier = !!isIdentifier

      column.save()
    }
  }

  metaList.save()
}

export function handleListCreated(event: ListCreated): void {
  let counter = GeneralCounter.load("0") as GeneralCounter

  let list = new List(counter.listCount.toString())
  list.listId = counter.listCount
  list.itemCount = BigInt.fromI32(0)
  list.versionCount = BigInt.fromI32(1)

  let listVersion = new ListVersion(`0@${list.id}`)
  listVersion.list = list.id
  listVersion.versionId = BigInt.fromI32(0)
  listVersion.governor = event.params._governorId.toString()
  listVersion.arbitrationSetting = event.params._arbitrationSettingId.toString()
  listVersion.removalPeriod = event.params._removalPeriod
  listVersion.requiredStake = decompress(event.params._requiredStake)
  // we can figure out the MetaList id, but it doesn't exist yet
  listVersion.metaList = listVersion.id
  listVersion.save()

  list.currentVersion = listVersion.id
  list.save()

  processMetaList(listVersion, event.params._metalist)

  counter.listCount = counter.listCount.plus(BigInt.fromI32(1))
  counter.save()

}

export function handleListUpdated(event: ListUpdated): void {
  let list = List.load(event.params._listId.toString()) as List

  let listVersion = new ListVersion(`${list.versionCount.toString()}@${list.id}`)
  listVersion.list = list.id
  listVersion.versionId = list.versionCount
  listVersion.governor = event.params._governorId.toString()
  listVersion.arbitrationSetting = event.params._arbitrationSettingId.toString()
  listVersion.removalPeriod = event.params._removalPeriod
  listVersion.requiredStake = decompress(event.params._requiredStake)
  // we can figure out the MetaList id, but it doesn't exist yet
  listVersion.metaList = listVersion.id
  listVersion.save()

  processMetaList(listVersion, event.params._metalist)

  list.versionCount = list.versionCount.plus(BigInt.fromI32(1))
  list.currentVersion = listVersion.id
  list.save()
}

export function handleMetaEvidence(event: MetaEvidenceEvent): void {
  // metaevidence is not handled atm
  return
}

export function handleRuling(event: Ruling): void {}
