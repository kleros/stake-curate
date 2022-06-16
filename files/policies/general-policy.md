# General Policy

## Definitions

- **General Policy**: this document.
- **List**: entity that holds *Items* according to a Policy.
- **List Version**: one of the historical settings of a list, defined by its parameters and its *MetaList*.
- **MetaList**: JSON file holding metadata about a *List*, its *Columns*, as well as an url to a *List Policy*.
- **Column**: definition of a field an *Item* may include, that can be required.
- **List Policy**: document that describes the criteria to determine if an *Item* is to be included.
- **Item**: entity included under a *List*.
- **Edition**: one of the versions of the *Item*, created whenever an *Item* is created or edited. Contains an array of *Props*.
- **Prop**: object that contains a label and a value.
- **Challenge**: process in which the inclusion of an *Item*, in regards to an *Edition*, is put into question, and it creates a *Dispute*.
- **Author**: party that submitted the *Edition*.
- **Challenger**: party that created the *Challenge* over the item.
- **Dispute**: event in which an *Arbitrator* decides whether if an item should be Kept or Removed from the *List*.
- **Arbitrator**: smart contract that receives *Disputes* and returns *Rulings*.

## Coherence

The Arbitrator must rule interpreting the General Policy.

## Universality

All disputes under any list are under the effect of this General Policy, even if the List Policy states otherwise.

## List Policy

The List Policy is shown to the Arbitrator in the Dispute display. It is the policy included in the MetaList of the List Version that was available at the time of the creation of the Dispute.

For anything not explicitly stated in the General Policy, this policy delegates its authority to the List Policy, which must be the basis of interpretation in those matters. As a consequence, in the case there was any contradiction between statements in the General Policy and the List Policy, the General Policy will be the basis of interpretation in matters related to those contradictory statements.

This document will refer to the General Policy as *Policy* from this point onwards. This also refers to all documents this Policy holds authority over.

## RFC2119 for Requirement Levels

The terms **must**, **must not**, **shall**, **shall not**, **should**, **should not**, **may**, **required**, **recommended**, **not recommended** and **optional**, have their meaning specified in [RFC2119](https://datatracker.ietf.org/doc/html/rfc2119).

To ease understanding, the Policy may only use the following subset of terms: **must**, **must not**, **should**, **should not** and **may**.

## Valid Challenge Reason

Upon creation of the Dispute, the Challenger must give a reason for removing the Item. It must be a valid reason according to the Policy. If this reason is not valid, the Arbitrator must rule to **Keep the Item**. This is the case even if the Item does not belong for **any other reason**, even if implied otherwise on the following clauses.

The reason should be clear and exhaustive. The reason must not be ambiguous or open to interpretation. 

## Required Props

An Item must be removed if it lacks Props whose Column is marked as *required*.

## Intrusive Props

An Item must be removed if it is *intrusive*, this means, contains Props that do not match with a Column.

## Frontrunning, baiting and Editions

In order to prevent a number of attacks, the Edition the Arbitrator will rule upon must be chosen depending on the immediately previous block (known as *Previous Block*) in which the Challenge was created (known as *Challenge Block*), according to the following instructions:

### Item could be challenged

If, in the Previous Block, the Item could be challenged, the Edition to consider must be the **latest Edition** of the Item. That is, the latest Edition that was available in the Challenge Block.

### Item could not be challenged

If, in the Previous Block, the Item could not be challenged, the Edition to consider must be the latest Edition that was available in the Previous Block.

But, on the rare exception all the Editions of the Item had been published on that same block, that is, the Item did not exist in the Previous Block, then, the Edition to consider must be the latest Edition that was available in the Challenge Block.

## Challenge Cooldown

A MetaList may include a value labeled as `challengeCooldown`, expressed in seconds. If the amount of seconds between the block timestamps of the blocks in which the following two events took place: ...
- the Item that is being ruled upon had its last previous Dispute resolve
- the currently ongoing Dispute was created

... is strictly lower than the `challengeCooldown` of the MetaList of the List Version that was available at the creation of the Dispute, then the Arbitrator must rule to **Keep the item**.

This condition to Keep the item can be expressed in simpler terms as:

`(currentDispute.creationTimestamp - previousDispute.resolutionTimestamp) < metaList.challengeCooldown`
