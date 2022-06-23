// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { readFileSync } from "fs"
import { ethers, run } from "hardhat"

const sleep = (seconds: number): Promise<void> => {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000))
}

// seed stake curate with a bunch of stuff
async function main() {
  await run("compile")

  // We get the contract to deploy
  const provider = new ethers.providers.JsonRpcProvider(process.env.KOVAN_URL)
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider)
  // get stake curate abi. dont know how to get it properly.
  const StakeCurateArtifact =
    JSON.parse(readFileSync("./artifacts/contracts/StakeCurate.sol/StakeCurate.json").toString())
  const StakeCurateInterface = new ethers.utils.Interface(StakeCurateArtifact.abi)
  const stakeCurate = new ethers.Contract(process.env.STAKE_CURATE_ADDRESS, StakeCurateInterface, wallet)
  
  /// start calling stuff

  console.log("make an account")
  await stakeCurate.createAccount({value: 1_000_000})
  await sleep(30)
  console.log("create arb setting with centralized arbitrator")
  await stakeCurate.createArbitrationSetting("0xd2cfD0DE28287C5C9a57C3021E6b65cfF28034eA", "0x")
  await sleep(30)
  console.log("create list with you as governor")
  await stakeCurate.createList(
    0, 1000, 300, 300, false, 0, 0,
    "/ipfs/Qmb7NDPafW7DFYYjHt5691d6TMzDJTQ5QS1eqXoywh3egZ/metalist-list.json",
    {gasLimit: 1_000_000}
  )
  await sleep(30)
  console.log("submit item")
  await stakeCurate.addItem(0, 0, 0,
    "/ipfs/QmVUixGdQFEqMXThfzZgBeQofS4jQHU1wrRtGqL5p4jTHQ/item.json",
    "0x"
  )
  await sleep(30)
  console.log("challenge item")
  await stakeCurate.challengeItem(0, 0, 0, Math.floor(new Date().getTime() / 1000), 0, 
    "/ipfs/QmYmfrUVjPZsNLygbmFE8J2jmFF1SU8h4Ju6gf3WsRfxJu/list-0-reason-a.json",
    {value: 1_000_000_000, gasLimit: 1_000_000,}
  )

  await sleep(30)
  console.log("submit evidence")
  await stakeCurate.submitEvidence(
    0, "0xd2cfD0DE28287C5C9a57C3021E6b65cfF28034eA",
    "/ipfs/QmWwpTQaoeq6ivULmi8XBbbEm7ur2DxWwjAe1duQcm3hS2/list-0-evidence.json"
  )
  console.log("finished")
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
