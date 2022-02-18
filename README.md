# Stake Curate

A contract to allow submitting items into lists. These items have some amount of stake associated with them, which serves as an incentive for challengers to dispute the validity of the item. Inspired by Curate, and more precisely on [Slot Curate](https://github.com/kleros/slot-curate) architecture.

## Features

- Slot system. Items and Disputes are stored in "slots", reusable storage that makes rewriting cheaper. Note that, unlike Slot Curate, if Stake Curate usage growth, reusing Item slots is actually rare, but it's still nice to have. Otherwise, Dispute slots should still be useful.
- Storing the ipfsUris that hold the content of the items, list policies, etc, is outsourced to the subgraph.

## Development

Clone the repo, then run:

`npm i`

Run tests with:

`npm test`

If you want to see gas costs, do:

`npm run test:gas`

Check the size of the contracts:

`npx hardhat size-contracts`