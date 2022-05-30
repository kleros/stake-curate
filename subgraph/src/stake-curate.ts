import { BigInt } from "@graphprotocol/graph-ts"
import {
  StakeCurate,
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
import { ExampleEntity } from "../generated/schema"

export function handleAccountCreated(event: AccountCreated): void {
  // Entities can be loaded from the store using a string ID; this ID
  // needs to be unique across all entities of the same type
  
  let entity = ExampleEntity.load(event.transaction.from.toHex())

  // Entities only exist after they have been saved to the store;
  // `null` checks allow to create entities on demand
  if (!entity) {
    entity = new ExampleEntity(event.transaction.from.toHex())

    // Entity fields can be set using simple assignments
    entity.count = BigInt.fromI32(0)
  }

  // BigInt and BigDecimal math are supported
  entity.count = entity.count.plus(BigInt.fromI32(1))

  // Entity fields can be set based on event parameters
  entity._accountId = event.params._accountId
  entity._owner = event.params._owner

  // Entities can be written to the store with `.save()`
  entity.save()

  // Note: If a handler doesn't require existing field values, it is faster
  // _not_ to load the entity from the store. Instead, create it fresh with
  // `new Entity(...)`, set the fields that should be updated and save the
  // entity back to the store. Fields that were not set or unset remain
  // unchanged, allowing for partial updates to be applied.

  // It is also possible to access smart contracts from mappings. For
  // example, the contract that has emitted the event can be connected to
  // with:
  //
  // let contract = Contract.bind(event.address)
  //
  // The following functions can then be called on this contract to access
  // state variables and other data:
  //
  // - contract.ACCOUNT_WITHDRAW_PERIOD(...)
  // - contract.accountCount(...)
  // - contract.accounts(...)
  // - contract.arbitrationSettingCount(...)
  // - contract.arbitrationSettings(...)
  // - contract.arbitratorAndDisputeIdToDisputeSlot(...)
  // - contract.disputes(...)
  // - contract.getEvidenceGroupId(...)
  // - contract.items(...)
  // - contract.listCount(...)
  // - contract.lists(...)
}

export function handleAccountFunded(event: AccountFunded): void {}

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
