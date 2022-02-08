const { expect } = require("chai")
const { ethers } = require("hardhat")

async function deployContracts(deployer) {
  const Arbitrator = await ethers.getContractFactory("Arbitrator", deployer)
  const arbitrator = await Arbitrator.deploy()
  await arbitrator.deployed()

  const StakeCurate = await ethers.getContractFactory("StakeCurate", deployer)
  const stakeCurate = await StakeCurate.deploy(
    arbitrator.address,
    "metaEvidence"
  )
  await stakeCurate.deployed()

  return {
    arbitrator,
    stakeCurate: stakeCurate,
  }
}

describe("Stake Curate", () => {
  before("Deploying", async () => {
    [deployer, challenger, governor, anotherGovernor, interloper] = await ethers.getSigners()
    ({ arbitrator, stakeCurate } = await deployContracts(deployer))
    requesterAddress = await requester.getAddress()
  })

  describe("should...", () => {
    const ACCOUNT_WITHDRAW_PERIOD = 604_800 // 1 week
    const LIST_REMOVAL_PERIOD = 60
    const CHALLENGE_FEE = 1_000_000_000

    it("Create account", async () => {
      const args = []
      const value = 100
      // can you get value/sender out of an event that doesn't emit it?
      await expect(stakeCurate.connect(deployer).createAccount(...args, { value }))
        .to.emit(stakeCurate, "AccountCreated")
    })

    it("Fund account", async () => {
      const args = [0] // accountId = 0
      const value = 1000
      await expect(stakeCurate.connect(deployer).fundAccount(...args, { value }))
        .to.emit(stakeCurate, "AccountFunded")
        .withArgs(0, 1100) // accountId, fullStake
    })

    it("Reverts unprepared withdraws", async () => {
      const args = [0, 100] // accountId = 0, amount = 100

      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.be.revertedWith("Withdrawal didn't start")
    })

    it("Reverts interloper withdraws", async () => {
      const args = [0, 100] // accountId = 0, amount = 100

      await expect(stakeCurate.connect(interloper).withdrawAccount(...args))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Reverts interloper starting withdraws", async () => {
      const args = [0] // accountId = 0

      await expect(stakeCurate.connect(interloper).startWithdrawAccount(...args))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Start withdraw account", async () => {
      const args = [0] // accountId = 0

      await expect(stakeCurate.connect(deployer).startWithdrawAccount(...args))
        .to.emit(stakeCurate, "AccountStartWithdraw")
        .withArgs(0) // accountId
    })

    it("Reverts early withdraws", async () => {
      const args = [0, 100] // accountId = 0, amount = 100

      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.be.revertedWith("Withdraw period didn't pass")
    })

    it("Cannot withdraw more than free stake", async () => {
      const args = [0, 2000] // accountId = 0, amount = 2000
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.be.revertedWith("You can't afford to withdraw that much")
    })

    it("Withdraws funds", async () => {
      const args = [0, 100] // accountId = 0, amount = 100
      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.emit(stakeCurate, "AccountWithdrawn")
        .withArgs(...args)
    })

    it("Create arbitratorExtraData", async () => {
      const args = ["0x00"]
      await expect(stakeCurate.connect(deployer).createArbitratorExtraData(...args))
        .to.emit(stakeCurate, "ArbitratorExtraDataCreated")
        .withArgs("0x00")
    })

    it("Creates a list", async () => { 
      // governor, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      const args = [governor.address, 100, LIST_REMOVAL_PERIOD, 0, "list_policy"]
      await expect(stakeCurate.connect(deployer).createList(...args))
        .to.emit(stakeCurate, "ListCreated")
        .withArgs(...args)
    })

    it("Updates a list", async () => {
      // listId, governor, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      const args = [0, governor.address, 100, LIST_REMOVAL_PERIOD, 0, "list_policy"]
      await expect(stakeCurate.connect(governor).updateList(...args))
        .to.emit(stakeCurate, "ListUpdated")
        .withArgs(...args)
    })

    it("Interloper cannot update the list", async () => {
      // listId, governor, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      const args = [0, governor.address, 100, LIST_REMOVAL_PERIOD, 0, "list_policy"]
      await expect(stakeCurate.connect(interloper).updateList(...args))
        .to.be.revertedWith("Only governor can update list")
    })

    it("Adds an item", async () => {
      const args = [0, 0, 0, "item_uri"] // fromItemSlot, listId, accountId, ipfsUri
      await expect(stakeCurate.connect(deployer).addItem(...args))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(...args)
    })

    it("An item added to the same slot goes to the next free slot", async () => {
      const args = [0, 0, 0, "item_uri"] // fromItemSlot, listId, accountId, ipfsUri
      await expect(stakeCurate.connect(deployer).addItem(...args))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(1, ...args.slice(1))
    })

    it("Interloper cannot add an item", async () => {
      const args = [0, 0, 0, "item_uri"] // fromItemSlot, listId, accountId, ipfsUri
      await expect(stakeCurate.connect(interloper).addItem(...args))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Revert if not enough free stake", async () => {
      // governor, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      const createListArgs = [governor.address, 2000, 60, 0, "list_policy2"]
      await expect(stakeCurate.connect(deployer).createList(...createListArgs))
        .to.emit(stakeCurate, "ListCreated")
        .withArgs(...createListArgs)

      const addItemArgs = [0, 1, 0, "item_uri"] // fromItemSlot, listId, accountId, ipfsUri
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
        .to.be.revertedWith("Not enough free stake")
    })

    it("You can start removing an item", async () => {
      const args = [0] // itemSlot
      await expect(stakeCurate.connect(deployer).startRemoveItem(...args))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(...args)
    })

    it("You can cancel the removal of an item", async () => {
      const args = [0] // itemSlot
      await expect(stakeCurate.connect(deployer).cancelRemoveItem(...args))
        .to.emit(stakeCurate, "ItemStopRemoval")
        .withArgs(...args)
    })

    it("Interloper cannot start removal of an item", async () => {
      const args = [0] // itemSlot
      await expect(stakeCurate.connect(interloper).startRemoveItem(...args))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Interloper cannot cancel removal of an item", async () => {
      const removeArgs = [0] // itemSlot
      await expect(stakeCurate.connect(deployer).startRemoveItem(...removeArgs))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(...removeArgs)

      const cancelArgs = [0] // itemSlot
      await expect(stakeCurate.connect(interloper).cancelRemoveItem(...cancelArgs))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("You cannot request removal of an item already being removed", async () => {
      const args = [0] // itemSlot
      await expect(stakeCurate.connect(deployer).startRemoveItem(...args))
        .to.be.revertedWith("Item is already being removed")
    })

    it("You can add an item into a removed slot", async () => {
      const args = [0, 0, 0, "item_uri"] // fromItemSlot, listId, accountId, ipfsUri
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD + 1])
      await expect(stakeCurate.connect(deployer).addItem(...args))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(...args)
    })

    it("You can challenge an item", async () => {
      const args = [0, 0, "reason"] // itemSlot, disputeSlot, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.emit("ItemChallenged").withArgs(...args)
        .emit("Dispute") // how to encodePacked in js? todo
        .emit("Evidence") // to get evidenceGroupId
    })

    it("You cannot challenge a disputed item", async () => {
      const args = [0, 0, "reason"] // itemSlot, disputeSlot, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a virgin item slot", async () => {
      const args = [10, 0, "reason"] // itemSlot, disputeSlot, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a removed item", async () => {
      const args = [1, 0, "reason"] // itemSlot, disputeSlot, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(deployer).startRemoveItem(1))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(1)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD + 1])
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    // you cant challenge a disputed item

    // you cant challenge a removed item

    // test dispute frontrunning

    // test that you can only request removal of an item if it's "Used" (later, when you dispute)
  })
})
