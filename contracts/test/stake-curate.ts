import { use, expect, assert } from "chai"
import { ethers } from "hardhat"
import { waffleChai } from "@ethereum-waffle/chai"
import { Bytes, Contract, Signer } from "ethers"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"

const IPFS_URI = "/ipfs/Qme7ss3ARVgxv6rXqVPiikMJ8u2NLgmgszg13pYrDKEoiu/item.json"


use(waffleChai)
const ACCOUNT_WITHDRAW_PERIOD = 604_800 // 1 week

const deployContracts = async (deployer: SignerWithAddress) => {
  const Arbitrator = await ethers.getContractFactory("Arbitrator", deployer)
  const arbitrator = await Arbitrator.deploy()
  await arbitrator.deployed()

  const StakeCurate = await ethers.getContractFactory("StakeCurate", deployer)
  const stakeCurate = await StakeCurate.deploy(ACCOUNT_WITHDRAW_PERIOD, deployer.address, IPFS_URI)
  await stakeCurate.deployed()
  await stakeCurate.connect(deployer).createArbitrationSetting(arbitrator.address, "0x")

  return {
    arbitrator,
    stakeCurate: stakeCurate,
  }
}

describe("Stake Curate", async () => {
  let [deployer, challenger, interloper, governor, hobo, adopter]: SignerWithAddress[] = []
  let [arbitrator, stakeCurate]: Contract[] = []

  const LIST_REQUIRED_STAKE = 100
  const LIST_REMOVAL_PERIOD = 60
  const LIST_UPGRADE_PERIOD = 60
  const FREE_ADOPTIONS = false
  const CHALLENGE_FEE = 1_000_000_000 // also used for appeals

  // to get realistic gas costs
  const noBytes: Bytes = []

  const [deployerId, governorId, challengerId, hoboId, interloperId, adopterId] = [0, 1, 2, 3, 4, 5]
  const listId = 0
  const itemSlot = 0
  const minAmount = 0
  const disputeSlot = 0
  const arbitratorSettingId = 0
  const addItemArgs = [itemSlot, listId, deployerId, IPFS_URI, noBytes]
  const challengeItemArgs = [challengerId, itemSlot, disputeSlot, minAmount, IPFS_URI, {value: CHALLENGE_FEE}]
  const createListArgs = [governorId, LIST_REQUIRED_STAKE, LIST_REMOVAL_PERIOD,
    LIST_UPGRADE_PERIOD, FREE_ADOPTIONS,
    arbitratorSettingId, IPFS_URI
  ]

  describe("deployment and settings", () => {
    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
    })

    // i dont know how to test deployment
    // it should emit a "ChangedStakeCurateSettings"
    // and a MetaEvidence with metaEvidenceId == 0

    it("Change settings", async () => {
      await expect(stakeCurate.connect(deployer)
        .changeStakeCurateSettings(ACCOUNT_WITHDRAW_PERIOD, deployer.address, IPFS_URI))
        .to.emit(stakeCurate, "ChangedStakeCurateSettings")
        .withArgs(ACCOUNT_WITHDRAW_PERIOD, deployer.address)
        .to.emit(stakeCurate, "MetaEvidence")
        .withArgs(1, IPFS_URI)
    })

    it("Interloper cannot change settings", async () => {
      await expect(stakeCurate.connect(interloper)
        .changeStakeCurateSettings(ACCOUNT_WITHDRAW_PERIOD, deployer.address, IPFS_URI))
        .to.revertedWith("Only governor can change these settings")
    })
  })

  describe("account, withdraws...", () => {
    let [arbitrator, stakeCurate]: Contract[] = []

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
    })
  
    it("Create account", async () => {
      const value = 100
      // can you get value/sender out of an event that doesn't emit it?
      await expect(stakeCurate.connect(deployer).createAccount({ value }))
        .to.emit(stakeCurate, "AccountCreated")
        .withArgs(deployer.address, value)
      // get an acc for interloper too (to see the realistic account creation cost)
      await expect(stakeCurate.connect(interloper).createAccount({ value }))
        .to.emit(stakeCurate, "AccountCreated")
        .withArgs(interloper.address, value)
    })

    it("Create account for a given address", async () => {
      const value = 100
      // can you get value/sender out of an event that doesn't emit it?
      await expect(stakeCurate.connect(deployer).createAccountForAddress(deployer.address, { value }))
        .to.emit(stakeCurate, "AccountCreated")
        .withArgs(deployer.address, value)
      // get an acc for interloper too (to see the realistic account creation cost)
      await expect(stakeCurate.connect(deployer).createAccountForAddress(interloper.address, { value }))
        .to.emit(stakeCurate, "AccountCreated")
        .withArgs(interloper.address, value)
    })
  
    it("Fund account", async () => {
      await stakeCurate.connect(deployer).createAccount({ value: 100 })
      await expect(stakeCurate.connect(deployer).fundAccount(deployerId, { value: 1000 }))
        .to.emit(stakeCurate, "AccountFunded")
        .withArgs(deployerId, 1100)
    })
  
    it("Reverts unprepared withdraws", async () => {
      const amount = 100
      await stakeCurate.connect(deployer).createAccount({ value: amount })
      await expect(stakeCurate.connect(deployer).withdrawAccount(deployerId, amount))
        .to.be.revertedWith("Withdrawal didn't start")
    })
  
    it("Reverts interloper withdraws", async () => {
      const amount = 100
      await stakeCurate.connect(deployer).createAccount({ value: amount })
      await expect(stakeCurate.connect(interloper).withdrawAccount(deployerId, amount))
        .to.be.revertedWith("Only account owner can invoke account")
    })
  
    it("Reverts interloper starting withdraws", async () => {
      const amount = 100
      await stakeCurate.connect(deployer).createAccount({ value: amount })
      await expect(stakeCurate.connect(interloper).startWithdrawAccount(deployerId))
        .to.be.revertedWith("Only account owner can invoke account")
    })
  
    it("Start withdraw account", async () => {
      const amount = 100
      await stakeCurate.connect(deployer).createAccount({ value: amount })
      await expect(stakeCurate.connect(deployer).startWithdrawAccount(deployerId))
        .to.emit(stakeCurate, "AccountStartWithdraw")
        .withArgs(deployerId)
    })
  
    it("Reverts early withdraws", async () => {
      const amount = 100
      await stakeCurate.connect(deployer).createAccount({ value: amount })
      await stakeCurate.connect(deployer).startWithdrawAccount(deployerId)
      
      await expect(stakeCurate.connect(deployer).withdrawAccount(deployerId, amount))
        .to.be.revertedWith("Withdraw period didn't pass")
    })
  
    it("Cannot withdraw more than free stake", async () => {
      await stakeCurate.connect(deployer).createAccount({ value: 100 })
      await stakeCurate.connect(deployer).startWithdrawAccount(deployerId)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await expect(stakeCurate.connect(deployer).withdrawAccount(deployerId, 2000))
        .to.be.revertedWith("You can't afford to withdraw that much")
    })
  
    it("Withdraws funds", async () => {
      const amount = 100
      await stakeCurate.connect(deployer).createAccount({ value: amount })
      await stakeCurate.connect(deployer).startWithdrawAccount(deployerId)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await expect(await stakeCurate.connect(deployer).withdrawAccount(deployerId, amount))
        .to.emit(stakeCurate, "AccountWithdrawn")
        .withArgs(deployerId, amount)
        .to.changeEtherBalance(deployer, amount)
    })
  
    it("Withdrawal timestamp resets after successful withdrawal", async () => {
      await stakeCurate.connect(deployer).createAccount({ value: 200 })
      await stakeCurate.connect(deployer).startWithdrawAccount(deployerId)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await stakeCurate.connect(deployer).withdrawAccount(deployerId, 100)
      await expect(stakeCurate.connect(deployer).withdrawAccount(deployerId, 100))
        .to.be.revertedWith("Withdrawal didn't start")
    })
  })

  describe("lists...", () => {
    

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))

      await stakeCurate.connect(deployer).createAccount({value: 500})
      await stakeCurate.connect(governor).createAccount({value: 500})
    })

    it("Create arbitrationSetting", async () => {
      await expect(stakeCurate.connect(deployer).createArbitrationSetting(arbitrator.address, "0x00"))
        .to.emit(stakeCurate, "ArbitrationSettingCreated")
        .withArgs(arbitrator.address, "0x00")
    })

    it("Creates a list", async () => {
      await expect(stakeCurate.connect(deployer).createList(...createListArgs))
        .to.emit(stakeCurate, "ListCreated")
        .withArgs(...createListArgs)
    })

    it("Updates a list", async () => {
      await stakeCurate.connect(deployer).createList(...createListArgs)
      await expect(stakeCurate.connect(governor).updateList(listId, ...createListArgs))
        .to.emit(stakeCurate, "ListUpdated")
        .withArgs(listId, ...createListArgs)
    })

    it("Interloper cannot update the list", async () => {
      await stakeCurate.connect(deployer).createList(...createListArgs)
      await expect(stakeCurate.connect(interloper).updateList(listId, ...createListArgs))
        .to.be.revertedWith("Only governor can update list")
    })

    it("Cannot create or update a list with a governorId that doesn't exist", async () => {
      await expect(stakeCurate.connect(deployer).createList(100, ...createListArgs.slice(1)))
      .to.be.revertedWith("Account must exist")
      await stakeCurate.connect(deployer).createList(...createListArgs)
      const argsUpdate = [listId, 100, LIST_REQUIRED_STAKE,
        LIST_REMOVAL_PERIOD, LIST_UPGRADE_PERIOD, FREE_ADOPTIONS, arbitratorSettingId, IPFS_URI]
      await expect(stakeCurate.connect(governor).updateList(...argsUpdate))
        .to.be.revertedWith("Account must exist")
    })
  })

  describe("items...", () => {

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
      await stakeCurate.connect(deployer).createAccount({ value: 200 })
      await stakeCurate.connect(governor).createAccount({ value: 200 })
      await stakeCurate.connect(challenger).createAccount({ value: 200 })
      await stakeCurate.connect(hobo).createAccount({ value: 100 })
      await stakeCurate.connect(interloper).createAccount({ value: 200 })
      await stakeCurate.connect(deployer).createList(...createListArgs)
    })

    it("Adds an item", async () => {
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(...addItemArgs)
    })

    it("An item added to a taken slot goes to the next free slot", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(1, ...addItemArgs.slice(1))
    })

    it("Interloper cannot add an item", async () => {
      await expect(stakeCurate.connect(interloper).addItem(...addItemArgs))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Revert adding if not enough free stake", async () => {
      const updateListArgs = [
        listId, governorId, LIST_REQUIRED_STAKE * 100,
        LIST_REMOVAL_PERIOD, LIST_UPGRADE_PERIOD, FREE_ADOPTIONS,
        arbitratorSettingId, IPFS_URI
      ]
      await stakeCurate.connect(governor).updateList(...updateListArgs)

      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
      .to.be.revertedWith("Not enough free stake")
    })

    it("You can start removing an item", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(deployer).startRemoveItem(itemSlot))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(itemSlot)
    })

    it("You can cancel the removal of an item", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(deployer).startRemoveItem(itemSlot)
      await expect(stakeCurate.connect(deployer).cancelRemoveItem(itemSlot))
        .to.emit(stakeCurate, "ItemStopRemoval")
        .withArgs(itemSlot)
    })

    it("Interloper cannot start removal of an item", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(interloper).startRemoveItem(itemSlot))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Interloper cannot cancel removal of an item", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(deployer).startRemoveItem(itemSlot))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(itemSlot)

      await expect(stakeCurate.connect(interloper).cancelRemoveItem(itemSlot))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("You cannot request removal of an item already being removed", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(deployer).startRemoveItem(itemSlot)
      await expect(stakeCurate.connect(deployer).startRemoveItem(itemSlot))
        .to.be.revertedWith("Item is already being removed")
    })

    it("You can add an item into a removed slot", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(deployer).startRemoveItem(itemSlot)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD + 1])
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(...addItemArgs)
    })

    it("Cannot recommit item that's being removed", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(deployer).startRemoveItem(itemSlot)
      await expect(stakeCurate.connect(deployer).recommitItem(itemSlot))
        .to.be.revertedWith("Item is being removed")
    })

    it("Cannot recommit without enough", async () => {
      await stakeCurate.connect(hobo).addItem(itemSlot, listId, hoboId, IPFS_URI, noBytes)
      await stakeCurate.connect(governor)
        .updateList(listId, governorId, LIST_REQUIRED_STAKE * 2,
          LIST_REMOVAL_PERIOD, LIST_UPGRADE_PERIOD, FREE_ADOPTIONS,
          arbitratorSettingId, IPFS_URI
        )
      await expect(stakeCurate.connect(hobo).recommitItem(itemSlot))
        .to.be.revertedWith("Not enough to recommit item")
    })

    it("Recommit an item", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      // governor, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      await stakeCurate.connect(governor)
        .updateList(listId, governorId, LIST_REQUIRED_STAKE * 2,
          LIST_REMOVAL_PERIOD,LIST_UPGRADE_PERIOD, FREE_ADOPTIONS,
          arbitratorSettingId, IPFS_URI
        )

      await expect(stakeCurate.connect(deployer).recommitItem(itemSlot))
        .to.emit(stakeCurate, "ItemRecommitted")
        .withArgs(itemSlot)
    })

    it("Interloper cannot recommit item", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(interloper).recommitItem(itemSlot))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Cannot recommit in non-Used ItemSlot", async () => {
      await stakeCurate.connect(deployer)
        .addItem(...addItemArgs)
      await stakeCurate.connect(challenger)
        .challengeItem(...challengeItemArgs)
      await expect(stakeCurate.connect(deployer).recommitItem(itemSlot))
        .to.be.revertedWith("ItemSlot must be Used")
    })

    it("harddata can be read", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      const item = await stakeCurate.connect(deployer).items(itemSlot)
      assert(item.harddata === "0x")
      await stakeCurate.connect(deployer).addItem(itemSlot + 1, listId, deployerId, IPFS_URI, "0x1234")
      const item2 = await stakeCurate.connect(deployer).items(itemSlot + 1)
      assert(item2.harddata === "0x1234")
    })

    it("Edit an item", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(deployer).editItem(itemSlot, IPFS_URI, noBytes))
        .to.emit(stakeCurate, "ItemEdited")
        .withArgs(itemSlot, IPFS_URI, noBytes)
      const item = await stakeCurate.connect(deployer).items(itemSlot)
      assert(item.harddata == "0x")
      await expect(stakeCurate.connect(deployer).editItem(itemSlot, IPFS_URI, "0x1234"))
        .to.emit(stakeCurate, "ItemEdited")
        .withArgs(itemSlot, IPFS_URI, "0x1234")
      const item2 = await stakeCurate.connect(deployer).items(itemSlot)
      assert(item2.harddata == "0x1234")
    })

    it("Cannot edit item if not account owner", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(interloper).editItem(itemSlot, IPFS_URI, noBytes))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Cannot edit item if it's being removed", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(deployer).startRemoveItem(itemSlot)
      await expect(stakeCurate.connect(deployer).editItem(itemSlot, IPFS_URI, noBytes))
        .to.be.revertedWith("Item is being removed")
    })

    it("Cannot edit item if itemSlot is not Used (it's being disputed or was challenged out)", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(challenger)
        .challengeItem(challengerId, itemSlot, disputeSlot, minAmount, IPFS_URI, {value: CHALLENGE_FEE})
      await expect(stakeCurate.connect(deployer).editItem(itemSlot, IPFS_URI, noBytes))
        .to.be.revertedWith("ItemSlot must be Used")

      await arbitrator.connect(deployer).giveRuling(0, 2, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])
      await arbitrator.connect(deployer).executeRuling(0)

      await expect(stakeCurate.connect(deployer).editItem(itemSlot, IPFS_URI, noBytes))
        .to.be.revertedWith("ItemSlot must be Used")
    })
  })

  describe("adopts...", () => {

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
      await stakeCurate.connect(deployer).createAccount({ value: 100 })
      await stakeCurate.connect(governor).createAccount({ value: 200 })
      await stakeCurate.connect(challenger).createAccount({ value: 200 })
      await stakeCurate.connect(hobo).createAccount({ value: 500 })
      await stakeCurate.connect(interloper).createAccount({ value: 200 })
      await stakeCurate.connect(adopter).createAccount({ value: 500 })
      await stakeCurate.connect(deployer).createList(...createListArgs)
    })

    it("Cannot adopt item if slot is not Used", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
      .to.be.revertedWith("Item slot must be Used")
    })

    it("Cannot adopt if item is not adoptable", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
        .to.be.revertedWith("Item is not in adoption")
    })

    it("Cannot adopt in another account's name", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(interloper).adoptItem(itemSlot, deployerId))
        .to.be.revertedWith("Only adopter owner can adopt")
    })

    it("Can adopt item whose account has free stake under required", async () => {
      await stakeCurate.connect(hobo).addItem(itemSlot, listId, hoboId, IPFS_URI, noBytes)
      await stakeCurate.connect(hobo).startWithdrawAccount(hoboId)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await stakeCurate.connect(hobo).withdrawAccount(hoboId, 500)
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(itemSlot, adopterId)
    })

    it("Can adopt item in removal", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(deployer).startRemoveItem(itemSlot)
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(itemSlot, adopterId)
    })

    it("Can adopt item whose account is withdrawing", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(deployer).startWithdrawAccount(deployerId)
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(itemSlot, adopterId)
    })

    it("Can adopt item unincluded due to list version", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])
      await stakeCurate.connect(governor).updateList(listId, ...createListArgs)
      // pass the time to get to go over the list upgrade period
      await ethers.provider.send("evm_increaseTime", [LIST_UPGRADE_PERIOD + 1])
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(itemSlot, adopterId)
    })

    it("Cannot adopt item if unincluded during upgrade period", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])
      await stakeCurate.connect(governor).updateList(listId, ...createListArgs)
      // not pass the time to go over the upgrade period, should revert.
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
        .to.be.revertedWith("Item is not in adoption")
    })

    it("Can adopt item if free adoptions", async () => {
      // except free adoptions, there is no condition to allow for an adoption.
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(governor).updateList(listId, governorId,
        LIST_REQUIRED_STAKE * 2, LIST_REMOVAL_PERIOD, LIST_UPGRADE_PERIOD,
        true, arbitratorSettingId, IPFS_URI)
      await expect(stakeCurate.connect(adopter).adoptItem(itemSlot, adopterId))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(itemSlot, adopterId)
    })
  })

  describe("challenges...", () => {

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
      await stakeCurate.connect(deployer).createAccount({ value: 400 })
      await stakeCurate.connect(governor).createAccount({ value: 200 })
      await stakeCurate.connect(challenger).createAccount({ value: 200 })
      await stakeCurate.connect(deployer).createList(...createListArgs)
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
    })

    it("You can challenge an item", async () => {
      await expect(await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs))
        .to.emit(stakeCurate, "ItemChallenged").withArgs(itemSlot, disputeSlot)
        .to.emit(stakeCurate, "Dispute") // how to encodePacked in js? todo
        .to.emit(stakeCurate, "Evidence") // to get evidenceGroupId
        .to.changeEtherBalance(challenger, -CHALLENGE_FEE)
    })

    it("You cannot challenge a disputed item", async () => {
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      await expect(stakeCurate.connect(challenger).challengeItem(...challengeItemArgs))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a free item slot", async () => {
      await expect(stakeCurate.connect(challenger)
        .challengeItem(challengerId, itemSlot + 1, disputeSlot, minAmount,
          IPFS_URI, {value: CHALLENGE_FEE})
        )
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a removed item", async () => {
      await expect(stakeCurate.connect(deployer).startRemoveItem(itemSlot))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(itemSlot)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD + 1])
      await expect(stakeCurate.connect(challenger).challengeItem(...challengeItemArgs))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("Cannot challenge an item unincluded due to version", async () => {
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])
      await stakeCurate.connect(governor)
        .updateList(listId, ...createListArgs)
      await expect(stakeCurate.connect(challenger)
        .challengeItem(...challengeItemArgs))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("Challenge reverts if minAmount is over freeStake", async () => {
      await expect(stakeCurate.connect(challenger)
        .challengeItem(challengerId, itemSlot, disputeSlot, 2000,
            IPFS_URI, {value: CHALLENGE_FEE})
          )
        .to.be.revertedWith("Not enough free stake to satisfy minAmount")
    })

    it("Challenging to a taken slot goes to next valid slot", async () => {
      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      await expect(stakeCurate.connect(challenger).challengeItem(
        challengerId, itemSlot + 1, disputeSlot, minAmount, IPFS_URI, { value: CHALLENGE_FEE }
      ))
        .to.emit(stakeCurate, "ItemChallenged").withArgs(itemSlot + 1, disputeSlot + 1)
    })

    it("You cannot start removal of a disputed item", async () => {
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      await expect(stakeCurate.connect(deployer).startRemoveItem(itemSlot))
        .to.be.revertedWith("ItemSlot must be Used")
    })

    it("Submit evidence", async () => {
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      // todo use block numbers instead of timestamps, then test the hash properly.
      await expect(stakeCurate.connect(deployer).submitEvidence(0, arbitrator.address, IPFS_URI))
        .to.emit(stakeCurate, "Evidence")
        //.withArgs(arbitrator.address, evidenceGroupId, deployer.address, IPFS_URI)
    })

    it("Rule for challenger", async () => {
      // Mock ruling
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      const disputeId = 0
      await arbitrator.connect(deployer).giveRuling(disputeId, 2, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      await expect(arbitrator.connect(deployer).executeRuling(disputeId))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, disputeId, 2)
    })

    it("Dispute slot can be reused after resolution", async () => {
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      const disputeId = 0
      await arbitrator.connect(deployer).giveRuling(disputeId, 2, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      await expect(arbitrator.connect(deployer).executeRuling(disputeId))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, disputeId, 2)

      await stakeCurate.connect(deployer).addItem(...addItemArgs)
      await expect(stakeCurate.connect(challenger).challengeItem(...challengeItemArgs))
        .to.emit(stakeCurate, "ItemChallenged")
    })

    it("Interloper cannot call rule", async () => {
      await expect(stakeCurate.connect(interloper).rule(0, 1))
        .to.be.revertedWith("Only arbitrator can rule")
    })

    it("Rule for submitter", async () => {
      // get a dispute to withdrawing first
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      const disputeId = 0
      await arbitrator.connect(deployer).giveRuling(disputeId, 1, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      await expect(arbitrator.connect(deployer).executeRuling(disputeId))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, disputeId, 1)

      // check if slot is overwritten (it shouldn't since item won dispute)
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(itemSlot + 1, listId, deployerId, IPFS_URI, noBytes)
    })

    it("Unsuccessful dispute on removing item makes item renew removalTimestamp", async () => {
      await stakeCurate.connect(deployer).startRemoveItem(itemSlot)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD/2])
      await stakeCurate.connect(challenger).challengeItem(...challengeItemArgs)
      const disputeId = 0
      await arbitrator.connect(deployer).giveRuling(disputeId, 0, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])
      await expect(arbitrator.connect(deployer).executeRuling(disputeId))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, disputeId, 0)
      // shouldn't been removed yet (since it reset), so adding gets into the next available slot
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD/2 + 1])
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(1, listId, deployerId, IPFS_URI, noBytes)
      // should've been removed, so adding gets there
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD/2 + 1])
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(...addItemArgs)
    })

  })
})
