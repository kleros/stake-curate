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

- In order to be included, items need to be collateralized
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
- Adoptions
- Posts and threads

## Why ERC20 stakes

It's better to not assume the users will agree with using native tokens for everything. Plenty of users and projects will instead prefer using stables. ERC20 are also a proven standard, and some projects just avoid using native tokens altogether (e.g. Opensea).

## Why native token as stake

Was suggested by William to ease UX in some aspects, and make the app more solid in others. Previous to this, challenger paid for the arbitration fees as an unavoidable cost. If the reward for winning a challenge was under this cost, the List would have to be considered useless, as it provided no incentive for challenging.

If instead of doing this, you consider the native token as part of the stake (as it is the case in all Kleros arbitrables), then the challenger is guaranteed profit 
It comes with the added complexity of handling burns in the native token, checking for native token balance records (in order to check if the optimistic periods have been satisfied).

## Why Challenge Types

For some removal use cases, it makes sense for challengers to obtain a smaller reward, especially for items that should be removed due to honest mistakes. A human submission that would never have possibly passed through because of a mirrored video should not be punished like an attacker trying to enter the registry twice claiming he's his twin. It is relatively easy to implement as well, just requiring an extra parameter to commit, reveal, store, and distribute around. The challenger still has to send the same deposit. Challenge Types are stored in the MetaList.

## Why adoptions

Adoptions mean that a different user can take liability over the inclusion of an item. Not having adoptions could allow accounts to squat and prevent others from fixing issues with an item, or reincluding it. So, this is mostly a safety feature. It also can be comfortable to just provide this as an option.

There are two types of adoptions considered:
- *Revive Adoptions*, in which items that are non-included, become included.
- *MatchOrRaise Adoptions*, in which items that are either Disputed or whose owner is performing actions that signal neglect (retracting the item, or withdrawing their stake), are up to auction. New owners can obtain ownership over it by either matching or raising the stake that is collateralizing the item.

*Adopting* an already *Collateralized* Item is **not** allowed, because it would allow griefers to take ownership over the item and then self-challenge. This would prevent honest submitters from having the guarantee of the grief being capped to a maximmum of `log(n) * log(n)` denial time, and prevent them from obtaining compensation for the damage caused.

Reasons why having adoptions is preferrable:

- If squatting is to be expected, for items that suffer the consequences (the item removed, and its `itemId` innaccessible), the history (editions, challenges, evidence...) of a single item could become dispersed across different `itemIds`.
- Some List use cases can become easier if Items are expected to live under one slot. Two examples:
  - On-chain usage, in which a proxy will track and id items based on their `itemId`. These proxies will have to look for lookarounds if squatting is possible.
  - A List in which duplicate items are not allowed. This flow can be simpler if each Item forever relates 1-1 with an `itemId` the moment it's first submitted.

Some examples on when this would be useful:

- List updates to a new version, rendering all items outdated, and many item owners don't bother refreshing their items, so they stop being included. Parties interested in preserving the curated items could review them and batch "adopt" them, taking liability over them and getting them to be included again.
  - Without adoptions, this actor may have to call `addItem` and it would consume extra calldata to resubmit everything. Also, history (previous editions, disputes, references, and the thread) for the previous item would disjoin.
- An item continues being grief challenged, and the current owner doesn't raise the stakes. Someone takes ownership over the item and raises the stakes, so that the griefing attack is too expensive to continue.

Adoptions is ingrained in the logic and it wouldn't save much code or complexity to remove it. This is because similar comparisons need to be made anyway to cover edge cases around raising stakes. It's a "nice to have".

But, since Stake Curate will be upgradable by proxy, it could be removed now and added later if needed. Or the other way around.

## Why posts and threads

Some context here: since ArbitratorV2, `Evidence` is meant to be submitted on the Arbitrator itself.

They're just events meant to submit information related to an item. While submitting `Evidence` in the arbitrator can provide useful information regarding a dispute, these threads can be useful:

- could be used to provide suplementary or contextual information that shouldn't be part of the item itself
- the information posted does not necessarily have to relate to a specific dispute
- information that could relate to multiple disputes does not need to be specifically submitted in all disputes

Since implementation only requires an event and a method to emit it, it can fit in the main contract.

# Why

I am going through the contract top to bottom and writing notes here on things that look notable.

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

This period should, at the very least, be equal to the `MAX_TIME_FOR_REVEAL`. I hardcoded it as a constant that makes it three times this amount, after concerns over potential attacks compared to just making it equal to `MAX_TIME_FOR_REVEAL`.

> Imagine a list in which, under circumstances, a certain address is the only one allowed to challenge. For example, a list governed by Kleros Moderate in which only the reporter is allowed to initiate a report. This right to be the challenger has a 5 minutes timeout from the time the report occurs. If retraction period equals this amount of time, then the submitter of the
malicious item could get away with retracting it.

This case presented may be niche, but there might be other reasons why the retraction period should be stricly larger than the time for reveal, and it doesn't create complexity as it's just a constant.

### Outdated Items

Whenever a list updates to a new version, a timestamp is set. All items submitted before or within that timestamp are considered *Outdated*. This renders them unchallengeable. The reason being, list governors are **not** trusted, and they could push malicious updates, such as changing the Policy and enable challenges against Editions that were previously correct, changing the token used by the list, or changing the arbitration settings.

In other words, without this security feature or something similar, list governors can drain the funds of submitters.

Instantly excluding all previous editions can have serious bad UX implications. Adoptions allows third parties to take ownership and collateralize the items back, if needed. If there is no interest from third parties to become liable for the items (e.g. social media account curation), then the users themselves are expected to refresh their items. List governors will be reminded of the consequences that updating the list has upon the users, and the frontend will recommend them to alert the users with an advance notice.

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

There are two degrees of burns: failed commit burns, and dispute burns.

Failed commit burns are rather low (currently 2%), you can read more on the rationale below in section *Commit Reveal for Challenges*.

Dispute burns are higher (5%), the reason being, applying a small burn on disputes could result in attacks that might warrant a bigger burn to discourage.

> Example, an user trolls in a Telegram group, having prepared a commit towards the Item that allows him to be in there. Some users in the group become exposed to the attack, that lasts 1 minute. Before any of the users can reveal a challenge towards him, he reveals a challlenge towards himself, paying a small burn plus arbitration fees. 

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

Some targets for these constants I chose:

- Burn rate should be small, but it's already estimated to be 2%, so this should be low enough.
- Min challenger stake should be low. Ideally 20% or lower.
- Max reveal time being large gives more time to reveal, to protect them against their commit being timed out. I thought 5 minutes was enough.

With the respective warnings to the users, that they must reveal within 5 min or they will get burned. This would force campers to waste 120% daily instead.

### Commit Reveal being mandatory

> Isn't it bad UX?

It's currently hardcoded at [1 min, 5 min), so, it might be a bit tight.

> Shouldn't it then be optional?

Due to how Stake Curate is structured, with stakes being shared across all lists, it would be a security hazard to allow for challenges to be instantaneous. Forcing users to go through commit reveal is necessary to prevent frontrunning attacks. This is why in order to commit, you also put a deposit then.

> Why not overwrite the current challenger to the earliest challenger who committed before?

There's a technicality around `challengerType` that prevents this. Basically, a Challenge Type that only targets a small % of the item stake, will only lock that percentage from the owner. So, the earlier challenge would have to update this value, which might become too large. The item owner did not necessarily have to fully collateralize the item in order for it to be challengeable.

There are also other conditions that might be different: maybe at the time the earlier commit was revealed, the retraction period of the item had went off. Should the item owner be saved? Or, the withdrawing period had went off. Should the item be fully uncollateralized then? This behaviour is currently undefined and defining it would increase complexity severely.

But mostly, there's a more important underlying reason. Stakes are shared, so if I get a challenge towards item A, I could frontrun a challenge towards item B (which I also control). Being able to backtrack the history of the collateral across items is either unfeasible, or complex enough to delay launch enough for it to not be worth it.

> But the UX is still bad, and bad UX can mean no users.

In this case, the frontend could just support an autoreveal feature. Have the commits be revealed automatically by a bot. You have a toggle for autoreveal, this feature could be supported in cheap chains. The feature needs to be toggled on, because the commit information would be sent to a trusted server, but for low value use cases, the risk should be acceptable. The server could batch these reveals together to make them even cheaper.

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
