// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers, run } from "hardhat"

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  await run("compile")

  const withdrawalPeriod = 300
  // We get the contract to deploy
  const StakeCurate = await ethers.getContractFactory("StakeCurate")
  const stakeCurate = await StakeCurate.deploy(withdrawalPeriod) // withdrawalPeriod: 5min

  await stakeCurate.deployed()

  console.log("Deployed to:", stakeCurate.address)

  // verify in etherscan
  const etherscanResponse = await run("verify:verify", {
    address: stakeCurate.address,
    constructorArguments: [withdrawalPeriod],
  })

  console.log("Verified in etherscan", etherscanResponse)
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
