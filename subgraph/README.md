This repo defines a subgraph which is used by Stake Curate.

## Set up

First make sure you have node v12. Install The Graph:

`yarn global add @graphprotocol/graph-cli`

`yarn`

`yarn codegen`

To set your access token:

`npx graph auth --product hosted-service <access-token>`

## Dev

To deploy to your own instance on a testnet, modify the script to use your own subgraph instance. For example, change `deploy:kovan` to `graph deploy --product hosted-service <your-username>/curate-kovan`.
