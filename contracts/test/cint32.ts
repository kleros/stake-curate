import { use } from "chai"
import { ethers } from "hardhat"
import { waffleChai } from "@ethereum-waffle/chai"
import { Contract, Signer, BigNumber } from "ethers"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"
import { assert } from "console"

use(waffleChai)

const deployContracts = async (deployer: Signer) => {
  const Cint32Test = await ethers.getContractFactory("Cint32Test", deployer)
  const cint32Test = await Cint32Test.deploy()
  await cint32Test.deployed()
  return {
    cint32Test
  }
}

describe("Cint32", async () => {
  let [deployer, challenger, interloper, governor, hobo, adopter]: SignerWithAddress[] = []
  let [cint32Test]: Contract[] = []

  before("Deploying", async () => {
    [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
    ({ cint32Test } = await deployContracts(deployer))
  })

  it("should compress -> decompress correctly...", async () => {
    const numbers: Array<number | BigInt> = [
      0,
      (2**24)-1,
      2**24,
      (2**24)+1,
      (2**32)-1,
      2**32,
      (2**32)+1,
      (2n**255n)-1n,
      2n**255n,
      (2n**255n)+1n,
      (2n**256n)-1n
    ]
    
    for (const n of numbers) {
      const number = BigNumber.from(n)
      const lowerRange = number.sub(number.div(10_000_000))
      const compressedNumber = await cint32Test.connect(deployer).compress(number)
      const decompressedNumber = await cint32Test.connect(deployer).decompress(compressedNumber)
      assert(decompressedNumber.gte(lowerRange))
      assert(decompressedNumber.lte(number))
    }
  })
})