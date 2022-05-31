import { BigInt } from "@graphprotocol/graph-ts"
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
  MetaEvidence,
  Evidence,
  GeneralCounter,
  Item,
  List,
  ListVersion,
} from "../generated/schema"
import { decompress } from "./cint32"

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
  // we can figure out the MetaEvidence id, but it doesn't exist yet
  listVersion.metaEvidence = `0@${list.id}`
  listVersion.save()

  list.currentVersion = listVersion.id
  list.save()

  counter.listCount = counter.listCount.plus(BigInt.fromI32(1))
  counter.save()
}

export function handleListUpdated(event: ListUpdated): void {
  let list = List.load(event.params._listId.toString()) as List

  let listVersion = new ListVersion(
    `${list.versionCount.toString()}@${list.id}`
  )
  listVersion.list = list.id
  listVersion.versionId = list.versionCount
  listVersion.governor = event.params._governorId.toString()
  listVersion.arbitrationSetting = event.params._arbitrationSettingId.toString()
  listVersion.removalPeriod = event.params._removalPeriod
  listVersion.requiredStake = decompress(event.params._requiredStake)
  // we can figure out the MetaEvidence id, but it doesn't exist yet
  listVersion.metaEvidence = `${list.versionCount.toString()}@${list.id}`
  listVersion.save()

  list.versionCount = list.versionCount.plus(BigInt.fromI32(1))
  list.currentVersion = listVersion.id
  list.save()
}

export function handleMetaEvidence(event: MetaEvidenceEvent): void {
  // metaEvidenceId points to the list
  let list = List.load(event.params._metaEvidenceID.toString()) as List

  // if the events are handled in the correct order, list or list update
  // were handled before MetaEvidence. so, versionId already incremented.
  let versionId = list.versionCount.minus(BigInt.fromI32(1))
  let metaEvidence = new MetaEvidence(`${versionId.toString()}@${list.id}`)

  metaEvidence.version = `${versionId.toString()}@${list.id}`
  metaEvidence.versionId = versionId
  metaEvidence.ipfsUri = event.params._evidence
}

export function handleRuling(event: Ruling): void {}
