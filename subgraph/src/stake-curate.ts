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
  Evidence,
  ItemAdded,
  ItemAdopted,
  ItemChallenged,
  ItemEdited,
  ItemRecommitted,
  ItemStartRemoval,
  ItemStopRemoval,
  ListCreated,
  ListUpdated,
  MetaEvidence,
  Ruling
} from "../generated/StakeCurate/StakeCurate"
import { Account, GeneralCounter } from "../generated/schema"
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
  let account = Account.load(event.params._accountId.toString())
}

export function handleAccountStartWithdraw(event: AccountStartWithdraw): void {}

export function handleAccountWithdrawn(event: AccountWithdrawn): void {}

export function handleArbitrationSettingCreated(
  event: ArbitrationSettingCreated
): void {}

export function handleDispute(event: Dispute): void {}

export function handleEvidence(event: Evidence): void {}

export function handleItemAdded(event: ItemAdded): void {}

export function handleItemAdopted(event: ItemAdopted): void {}

export function handleItemChallenged(event: ItemChallenged): void {}

export function handleItemEdited(event: ItemEdited): void {}

export function handleItemRecommitted(event: ItemRecommitted): void {}

export function handleItemStartRemoval(event: ItemStartRemoval): void {}

export function handleItemStopRemoval(event: ItemStopRemoval): void {}

export function handleListCreated(event: ListCreated): void {}

export function handleListUpdated(event: ListUpdated): void {}

export function handleMetaEvidence(event: MetaEvidence): void {}

export function handleRuling(event: Ruling): void {}
