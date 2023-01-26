# User Flow

Please go [read the frontend ux/spec](../frontend/docs.md) to get an idea of how users can interact with Stake Curate. This section will expand on what sequence of transactions will take place in the smart contract for these actions.

# Data structure

```
Account                    List

   1                        1
   │                        │
   │                        │
   │                        │
   │                        │   ┌─────1  ArbitrationSetting
   │                        │   │
   │                        │   │
   N                        N   1

  Item  N────────────1  ListVersion           ChallengeCommit

   1 1─────────────────────────────────────────┐     1
   │                                           │     │
   │                                           │     │
   │                                           │     │
   │                                           │     │
   N                                           │   {0,1}
                                               │
Edition                                        N  Dispute
```

# Main Entities

## List

Lists contain Items. Lists have the following settings:

- `governorId`, who can update the list
- `requiredStake`, the minimum ERC20 stake required to include an item
- `retractionPeriod`, the amount of time an item takes to be removed by its owner
- `arbitrationSettingId`
- `versionTimestamp`
- `maxStake`, the maximum ERC20 stake that can collateralize an item
- `token`, the ERC20 token address used to check stakes
- `challengerStakeRatio`, the amount of ERC20 stake a challlenger puts, to be awarded to submitter if challenge fails
- `ageForInclusion`, how much time is it needed for an item to be fully collateralized and challengeable to be considered included
- `outbidRate`, how much stake does a different party need to put in, in order to adopt an item

When Lists are created or edited, they also emit a `MetaList`, in the form of an IPFS string. This is a JSON file that contains:

### MetaList

- Regular List metadata such as name, description, logo, itemName...
- Policy
- Schema, that is, the list of columns it accepts. They are supposed to be elaborated upon by the Policy. The schema describes whether if a field is mandatory or not, what type is it, etc.
- Optionally, challenger types. If none exist, then there's only 1 challenger type, for incorrect item.
- Other info such as, whether if it accepts harddata, whether if this is a list of lists or not... etc.
---

Now, all this information can be edited, so, at the subgraph level, we will consider a snapshot of all these settings as a `ListVersion`. Updating a ListVersion will render all items last updated before or at the `versionTimestamp`, as `Outdated`, which renders them impossible to challenge until they are updated, and thus, unincluded.

## Item

Items are contained in Lists. They are identified by an `itemId`, and will always belong to the same List. They are owned by an Account, which is liable for the item. Items can hold various states, and these states need to be computed dynamically. Items contain properties, and can be challenged if they don't belong to the list they're included in.

Items can also contain `harddata`, this is, an array meant to hold arbitrary on-chain data. This emulates the behaviour of Classic Curate, and allows on-chain interoperability. 

### Edition

Items can be edited, and we will consider a snapshot of the properties of the Item as an Edition, at the subgraph level. Editions contain properties, which are objects consisting on a key and value. In order for the Edition to be correct, all mandatory fields in the List's schema must be covered within these properties, and also, all fields must have a key contained inside the List's schema. There are other arbitrary acceptance conditions that can be set either by the Policy, or by other settings in the MetaList.

## Account

Addresses are identified with Accounts in a 1:1 relation. Accounts allow addresses to be referenced with less bits, and store information related to the stakes, such as the `withdrawingTimestamp`, which is the time at which the Account can begin withdrawals, and the Balance Records.

### Balance Split Records

For each account and token, there is an array of records that stores the balance the account had at a given timestamp. Their purpose is to be able to tell whether if an item has been collateralized for a given period, or not. This information could be figured out off-chain, but, to ensure on-chain functionality, it was chosen to be implemented on-chain, as it should not be excessively expensive to read. It has been highly optimized and packed to maximize hot storage reads and writes.

Additionally, accounts can also store native tokens, and they are identified by the `address(0)` token.

## Dispute

Challenges in Stake Curate create Disputes. All Disputes are about removing an Item from a List.

Only one Dispute can go through an Item simultaneously. To challenge, the user commits and reveals. The challenger must provide a clear reason for why the item should be removed. For example, quoting an infringed clause from the List Policy.

Items should not be considered included while they are being Disputed.

### MetaEvidence

This is similar to `MetaEvidence`. The reason we don't use `MetaEvidence` for List metadata is that it is reserved for Stake Curate, in general. Stake Curate uses the same MetaEvidence for all Disputes. Disallowing Lists from setting the MetaEvidence is a feature, and it ensures that they cannot tamper with the human readable meaning of rulings. It also allows to provide a General Policy for Stake Curate, that enforces some rules and sets some sane default assumptions for the Arbitrator to follow.

### DoS Attacks

Since an item is not considered Included while it is enduring a challenge, actors could consider making purposely incorrect challenges in order to either:
- Deny another user the challenging deposit, by self-challenging.
- Temporarily remove the item from the list, to cause damage on apps depending on the list, or cause damage to the owner of the item.

Self-challenging is addressed below, in sections for *Challenger Stake*, *Burns* and *Commit Reveal*. Temporarily removing the items (*griefing* or *DoS*) will be addressed here.

In order to make the challenge in the first place, the challenger needs to pass a `challengerStake`. If the challenge fails, then this deposit will be awarded to the owner of the item. If this owner uses this deposit to increase the stake collateralizing the item, then the challenger will have to, instead, put `challengerStake` + `challengerStake * challengerStakeRatio`.

By using the resources the attacker is providing to the item owner, the cost of denying the inclusion of the item raises exponentially every step. So, the attacker can only do this `log(n)` times. Since every step requires a response from an arbitrator, that itself takes `log(n)` time to respond, so that means the maximum delay a griefer can obtain is `log(n) * log(n)` time. This also produces the side effect of awarding the resources to the item owner, which will likely be considered more valuable than the inclusion of the item.

# Rationale

Let's first lay down the constraints:

- In order to be included, items need to be continuously collateralized
- Edits
- Commit reveal for challenges
- Contains (mostly) Classic and Light Curate
- Secure
  - no drain attacks
  - no baiting
  - desincentivize camping strategies (challenging yourself)
- Cheap
- Easy UX

These are some things that came up on the way, but were not fundamental. As they are unneeded complexity, they will be elaborated upon below:

- ERC20 tokens for stakes, instead of value.
- Value also used as stake, to make loser pay arbitration fee
- Challenge types
- Multiple Arbitrators
- Adoptions

## Why ERC20 stakes

It's better to not assume the users will agree with using native tokens for everything. Plenty of users and projects will instead prefer using stables. ERC20 are also a proven standard, and some projects just avoid using native tokens altogether (e.g. Opensea).

## Why native token as stake

Was suggested by William to ease UX in some aspects, and make the app more solid in others. Previous to this, challenger paid for the arbitration fees as an unavoidable cost. If the reward for winning a challenge was under this cost, the List would have to be considered useless, as it provided no incentive for challenging.

If instead of doing this, you consider the native token as part of the stake (as it is the case in all Kleros arbitrables), then the challenger is guaranteed profit 
It comes with the added complexity of handling burns in the native token, checking for native token balance records (in order to check if the optimistic periods have been satisfied).

## Why Challenge Types

For some removal use cases, it makes sense for challengers to obtain a smaller reward, especially for items that should be removed due to honest mistakes. A human submission that would never have possibly passed through because of a mirrored video should not be punished like an attacker trying to enter the registry twice claiming he's his twin. It is relatively easy to implement as well, just requiring an extra parameter to commit, reveal, store, and distribute around. The challenger still has to send the same deposit. Challenge Types are stored in the MetaList.

## Why multiple arbitrators

Stake Curate allows to use Arbitrators if they are compatible with kleros-v2 Arbitrator Interface. This was chosen so that:

- Allows having faster Dispute process for some items, like going through a reality.eth compatible with Arbitrator interface for faster results in low value lists.
- Allows S.C. to be a more credibly neutral public good, if other projects want to try to create Arbitrators and compete
- Having a hardcoded Arbitrator could be an issue if Kleros V2 is not upgradable
  - however, if Stake Curate is upgradable by proxy, then adding a new hardcoded Arbitrator could be simple

Previously, arbitrators went through `arbitratorAllowance`, in which the S.C. governor would whitelist Arbitrators. After burns were added to the native token, malicious arbitrators are not such a big problem, and this feature required checking for List Legality. To remove expensive and cumbersome List Legality checks, it was removed. So, malicious arbitrators can be used now.

Some caveats multiple arbitrators has:

- They could refuse to rule, keeping an Item locked forever. It would only happen in malicious Lists. A way out of this is setting up a maximum amount of time an item can be challenged (like, a year) so that, in the case of a critical mistake, at least there's a way to recover the funds.
- extra gas expenses to read the arbitrator on storage on challenge reveals and rulings, and to keep track of the arbitrator for the Dispute (because, lists could change the arbitrator)
- mapping to get localId requires arbitrator

## Why adoptions

Adoptions mean that a different party can take liability over the inclusion of an item. Not having adoptions could allow accounts to squat and prevent others from fixing issues with an item, or reincluding it. So, this is mostly a safety feature. It also can be comfortable to just provide this as an option. Reasons why having adoptions is preferrable:

- If squatting is to be expected, for items that suffer the consequences (the item removed, and its `itemId` innaccessible), the history (editions, challenges, evidence...) of a single item could become dispersed across different `itemIds`.
- Some List use cases can become easier if Items are expected to live under one slot. Two examples:
  - On-chain usage, in which a proxy will track and id items based on their `itemId`. These proxies will have to look for lookarounds if squatting is possible.
  - A List in which duplicate items are not allowed. This flow can be simpler if each Item forever relates 1-1 with an `itemId` the moment it's first submitted.

Some examples on when this would be useful:

- List updates to a new version, rendering all items outdated, and many item owners don't bother refreshing their items, so they stop being included. Parties interested in preserving the curated items could review them and batch "adopt" them, taking liability over them and getting them to be included again.
  - Without adoptions, this actor may have to call `addItem` and it would consume extra calldata to resubmit everything.
- An item continues being grief challenged, and the current owner doesn't raise the stakes. Someone takes ownership over the item and raises the stakes, so that the griefing attack is too expensive to continue.

Adoptions is not a particularly difficult feature to implement, it's ingrained in the logic and it wouldn't save much code or complexity to remove it. Nothing close to adoptions was possible in the previous Curate applications, as the items essentially belong to no-one after they completed the period. It's a "nice to have" that we might regret not to have if we didn't have it.

But, since Stake Curate will be upgradable by proxy, it could be removed now and added later if needed. Or the other way around.

---

# Why

I am going through the contract top to bottom and writing notes here on things that look notable.

### Outbid Rate

Some Lists may not want to allow adoptions, or may want new owners to significantly raise the item stake in order to justify disallowing the current user from owning the item. This was added as a defense mechanism

Actually I believe Stake Curate could still work despite the Outbid Rate, since malicious actors could be drained of funds from squatting, if they refused to fix their items or maintain them (under some Policy requirements). "Defense mechanism"? Against funds from other users?

### Settings hardcoded as constants

Read https://github.com/kleros/stake-curate/issues/45

### ArbitrationSettings

They are immutable and lists reference them, saving gas on creation. Originally they had to be immutable because appeals were handled internally, and appeals had to pass the `arbitratorExtraData`, even if it wasn't used. With V2, appeals are no longer handled internally.

But, referencing a `bytes` array still makes sense from the perspective of gas costs compared to editing it in the List, since various Lists will use the same.

### Withdrawing Period

Prevents item owners to frontrun withdrawing their stake in response to a challenge reveal. Doing so would render the item uncollateralized and leave no stake for the challenger.

### Retraction Period

Prevents item owners to frontrun retracting their stake in response to a challenge reveal. This is equivalent to removing an item from yourself.

Users can be interested in stop being held liable from certain items, without having to uninclude every single item at the same time. The alternative from this would be to, if the item was wrong, to direct a challenge towards themselves, but then they would lose funds from the burns, and from paying the arbitration fees.

### Challenger Stake

Challenger puts an ERC20 token stake as well. This stake covers two functions:

- backs up a committed challenge with something.
  - otherwise, commits could be spammed.
- rewards the owner of the item if the challenge was incorrect. reasons why:
  - due to limitations in the contract, an item cannot endure two challenges simultaneously.
  - owners can suffer damage, because during this challenge their item stops being included.
  - if the challenge failed and the list uses periods, the item needs to go through the period all over again. 
  - the owner may need to defend themselves

### Burns

Stakes can be shared across items. There's a single instant way of losing `freeStake`, and that is enduring a challenge. Item owners could get protection from challenges by challenging themselves, which would lock some of their stake. If enough of this stake is locked, then the revealed challenge will fail.

By abusing this, item owners could frontrun a challenge towards themselves and only need to pay for the arbitration fee. Moreover, this challenged Item can be in a List under their control, so this arbitration fee could be paid to an Arbitrator under their control as well.

But if you burn some of it, then it doesn't matter if both sides and the Arbitrator is controlled by the same party, they are guaranteed a loss.

Why burns are proposed to be so low (2%) is related to commit reveal.

### Challenge Reason

It's not realistic to expect arbitrators to compute inclusion or exclusion of an item in absolute terms. They should be directed to a specific clause in the List Policy that clearly states why the item should be removed, and the challenger should be the party responsible for providing this rationale.

This arguably is not a fundamental part of Stake Curate, but I thought that it is an essential part of every arbitrable. Providing wrong or unclear reasons should result in a failed challenge, even if the item is not actually correct. UI will make this clear to challengers. Current way of challenging is "guilty until proven innocent" style, in which the challengers and jurors can, after the fact, figure out why is something wrong.

### Commit Reveal for Challenges

You want to prevent frontrunners from stealing challenges. Theoretically, that shouldn't be a problem since honest challengers could inject bait, invalid challenges, but this would result in an arms race that, in practice, would filter most users from being able to participate. So, commit reveal is used.

Issues that commit reveal solves:

- Owner of an item cannot previsibly challenge their own item in anticipation of a challenge, because by creating the commit and not revealing it, they suffer a burn. And if they reveal, they will get burned as well.
- Owner of an item cannot previsibly challenge other items they themselves own, for the same reason. This strategy is better for the owner, because they could perform it in a list with the lowest `challengerStakeRatio` possible, and endure the smallest possible burn.

To calculate the daily % burn a commit camper would have to use, compared to the amount they are trying to secure, the following formula can be used:

`burnRate` * `minChallengerStake` * (`1 days` / `maxRevealTime`)

The target I thought that was gentle enough to allow was, to force them to burn 10% every day, of the value they want to be able to frontrun. This would mean that, after 10 days of sustaining this attack, they will have lost the entire value of the item. Maybe 

Some targets for these constants I chose:

- Burn rate should be small, but it's already estimated to be 2%, so this should be low enough.
- Min challenger stake should be low. Ideally 20% or lower.
- Max reveal time should be large enough to not be too punishing to users. Currently it's 1h, but it could go lower.

I think Max Reveal Time could go to 30 minutes, with the respective warnings to the users, that they must reveal within 30min or they will get burned. This would force campers to waste 20% daily instead.

### Balance Split Records

These are used to track whether if an item has been continously collateralized from the present to the required amount of time. They track, per address and per token, records of time and balance. Functions interacting with them have a lot of comments, so I suggest just taking a look.

This is required to make Stake Curate able to include items like Classic Curate or Light Curate, that is, with a period.

# Known Issues and Caveats

### Committing an accidental new Edition

When users commit a challenge, there's a slight possibility that an item ends up accidentally edited. Item owners cannot predictably do this on purpose* so it should stay a rare event. When this happens, the commit is targeting an edition that may have solved the issue the item was being challenged for.

*Item owners could manage to perform these edits on purpose if the commit was using a token that was collateralizing very few items. There is also no cost on editing, apart from gas expenses, so a malicious item owner could non-stop edit items just to have this happen to someone, in which case, the challenger may notice the pattern before even starting the commit. Stake Curate is intended to run in rollups or fast sidechains, where these events are even more unlikely.

If the challenger chooses to reveal, and the issue was solved in the accidentally targeted edition, they will lose the challenge. If they choose not to reveal, the commit will be revoked and they will get refunded but endure a burn on both the `tokenStake` and the `valueStake` they put with the commit.

This issue was addressed in the past by passing and storing a `uint32 _editionTimestamp` into the commit, that could allow the challenger to target a specific edition, without risk of accidentally targeting a different one. However, if this is done, the contract must enforce a limitation to ensure challengers don't commit challenges to editions too far into the past, as that would be unfair to the item owners as the mistakes in them have already been solved.

This feature was then removed after doing a risk reward analysis. Taking into account the rarity of this event, and the damages resulting from it, it's not worth it to enforce every commit to pass extra calldata, have the contract handle more computations and hold more bytecode. This is an example that illustrates the damage from this event, for a medium value use case:

```
Item is worth 100$ of tokens, and the cost of arbitration is 20$. The List requires a challengerStakeRatio of 50%. Burn rate is 2%.
Challengers commits passing 50$ worth of tokens, and 20.4$ worth of value.
They accidentally target the wrong edition, due to bad luck.
They wait until the commit is revoked. Now, it burns 2% of both amounts, so, challenger lost a total of 1.4$ in burns
```

This is a medium value use case, which should be rare and not the main source of volume in this app. The damage is small, and for an event that should seldom occur (maybe, once every 10_000 disputes? or once every 1_000_000?) the increase of complexity is not warranted. The burned funds could just be refunded to the affected challenger.

Another reason to accept this imperfection is that, there is another possible accident that will be detailed next, and should be orders of magnitude more frequent than this one.

### Committing to an accidentally Outdated Item

Revealing a challenge targeted towards an Outdated item results in the challenge failing, and a refund taking place after a burn.

Stake Curate attempts to minimize the power that List governor have over the users that included items on it. This is why there is a parameter, `uint32 _forListVersion`, that is passed in all functions that lead items to become included, to prevent malicious List governors from draining users funds.

Outdated items cannot be challenged, because:

- the token keeping the item included could have changed
- the Policy may have changed and have rendered them vulnerable to challenges.
- other fields in the MetaList may have changed and rendered them vulnerable to challenges

So, since they are not challengeable, and should be considered to be no longer included (although, this is under the discretion of the apps consuming this information), the challenge reveal must fail.

Failing a challenge reveal for this reason must result in a burn, because this is a condition that can be reproduced reliably and without cost (other than gas expenses). If it didn't burn, a malicious frontrunner could just, non-stop, prepare challenges towards bogus items in lists they control, to:

- frontrun a challenge reveal towards the bogus item, that conveniently would reduce their stake enough to stop collateralizing other items that were about to be affected by a real challenge
- if no challenge reveal is on sight and the commit is about to be revoked, update the list and then reveal the challenge, to obtain a full refund, and try again.

Unfortunately, this means that in the instances in which this occurs accidentally, the honest challenger will endure a burn. My proposal was that, legit lists should warn before giving those updates to minimize this accident from ocurring in the first place, and for those instances in which it ocurred, just return the burned funds to the users via governance.

Unlike the previous edge case described, there's no known way of preventing this edge case from ocurring within the contract, despite it being much more frequent.