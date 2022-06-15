// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers, run } from "hardhat"

const sleep = (seconds: number): Promise<void> => {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000))
}

const WITHDRAWAL_PERIOD = 300
const METAEVIDENCE = "/ipfs/QmRapgPnC9HM7CueMmJhMMdrh5J9YePBn6SxmS5G3xjwcL/metaevidence.json"

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  await run("compile")

  // We get the contract to deploy
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY)
  const StakeCurate = await ethers.getContractFactory("StakeCurate")
  const stakeCurate = await StakeCurate.deploy(WITHDRAWAL_PERIOD, wallet.address, METAEVIDENCE)

  await stakeCurate.deployed()

  console.log("Deployed to:", stakeCurate.address)

  // giving time for etherscan to keep up
  await sleep(100)

  // verify in etherscan
  const etherscanResponse = await run("verify:verify", {
    address: stakeCurate.address,
    constructorArguments: [WITHDRAWAL_PERIOD, wallet.address, METAEVIDENCE],
  })

  // if you mess this up:
  // npx hardhat verify --network kovan DEPLOYED_CONTRACT_ADDRESS 300 {governor} "/ipfs/QmRapgPnC9HM7CueMmJhMMdrh5J9YePBn6SxmS5G3xjwcL/metaevidence.json"

  console.log("Verified in etherscan", etherscanResponse)
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
