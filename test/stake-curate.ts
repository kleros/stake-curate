import { use, expect } from "chai"
import { ethers } from "hardhat"
import { waffleChai } from "@ethereum-waffle/chai"
import { Contract, Signer } from "ethers"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"

use(waffleChai)

const deployContracts = async (deployer: Signer) => {
  const Arbitrator = await ethers.getContractFactory("Arbitrator", deployer)
  const arbitrator = await Arbitrator.deploy()
  await arbitrator.deployed()

  const StakeCurate = await ethers.getContractFactory("StakeCurate", deployer)
  const stakeCurate = await StakeCurate.deploy(arbitrator.address)
  await stakeCurate.deployed()

  return {
    arbitrator,
    stakeCurate: stakeCurate,
  }
}

describe("Stake Curate", async () => {
  let [deployer, challenger, interloper, governor, hobo, adopter]: SignerWithAddress[] = []
  let [arbitrator, stakeCurate]: Contract[] = []

  const ACCOUNT_WITHDRAW_PERIOD = 604_800 // 1 week
  const LIST_REMOVAL_PERIOD = 60
  const CHALLENGE_FEE = 1_000_000_000 // also used for appeals

  // to get realistic gas costs
  const IPFS_URI = "/ipfs/Qme7ss3ARVgxv6rXqVPiikMJ8u2NLgmgszg13pYrDKEoiu/item.json"

  describe("account, withdraws...", () => {
    let [deployer, challenger, interloper, governor, hobo, adopter]: SignerWithAddress[] = []
    let [arbitrator, stakeCurate]: Contract[] = []

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
      await stakeCurate.connect(deployer).createAccount({ value: 100 })
    })
  
    it("Create account", async () => {
      const args = []
      const value = 100
      // can you get value/sender out of an event that doesn't emit it?
      await expect(stakeCurate.connect(deployer).createAccount(...args, { value }))
        .to.emit(stakeCurate, "AccountCreated")
      // get an acc for interloper too (to see the realistic account creation cost)
      await expect(stakeCurate.connect(interloper).createAccount(...args, { value }))
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
      await stakeCurate.connect(deployer).startWithdrawAccount(0)
      
      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.be.revertedWith("Withdraw period didn't pass")
    })
  
    it("Cannot withdraw more than full stake", async () => {
      const args = [0, 2000] // accountId = 0, amount = 2000
      await stakeCurate.connect(deployer).startWithdrawAccount(0)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.be.revertedWith("You can't afford to withdraw that much")
    })
  
    it("Withdraws funds", async () => {
      const args = [0, 100] // accountId = 0, amount = 100
      await stakeCurate.connect(deployer).startWithdrawAccount(0)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await expect(await stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.emit(stakeCurate, "AccountWithdrawn")
        .withArgs(...args)
        .to.changeEtherBalance(deployer, 100)
    })
  
    it("Withdrawal timestamp resets after successful withdrawal", async () => {
      const args = [0, 100] // accountId = 0, amount = 100
      await stakeCurate.connect(deployer).startWithdrawAccount(0)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await stakeCurate.connect(deployer).withdrawAccount(...args)
      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.be.revertedWith("Withdrawal didn't start")
    })

    it("Cannot withdraw more than free stake", async () => {
      await stakeCurate.connect(deployer).startWithdrawAccount(0)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await expect(stakeCurate.connect(deployer).withdrawAccount(0, 900))
        .to.be.revertedWith("You can't afford to withdraw that much")
    })
  })

  describe("lists...", () => {

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
    })

    it("Create arbitratorExtraData", async () => {
      const args = ["0x00"]
      await expect(stakeCurate.connect(deployer).createArbitratorExtraData(...args))
        .to.emit(stakeCurate, "ArbitratorExtraDataCreated")
        .withArgs("0x00")
    })

    it("Creates a list", async () => {
      await stakeCurate.connect(governor).createAccount({value: 500})
      // governorId, requiredStake, removalPeriod, arbitratorExtraDataId, metaEvidence
      const args = [0, 100, LIST_REMOVAL_PERIOD, 0, "list_policy"]
      await expect(stakeCurate.connect(deployer).createList(...args))
        .to.emit(stakeCurate, "ListCreated")
        .withArgs(0, 100, LIST_REMOVAL_PERIOD, 0)
        .to.emit(stakeCurate, "MetaEvidence")
        .withArgs(0, "list_policy")
    })

    it("Updates a list", async () => {
      await stakeCurate.connect(governor).createAccount({value: 500})
      // listId, governorId, requiredStake, removalPeriod, arbitratorExtraDataId, metaEvidence
      const args = [0, 0, 100, LIST_REMOVAL_PERIOD, 0, "list_policy"]
      await stakeCurate.connect(deployer).createList(0, 100, LIST_REMOVAL_PERIOD, 0, "list_policy")
      await expect(stakeCurate.connect(governor).updateList(...args))
        .to.emit(stakeCurate, "ListUpdated")
        .withArgs(0, 0, 100, LIST_REMOVAL_PERIOD, 0)
        .to.emit(stakeCurate, "MetaEvidence")
        .withArgs(0, "list_policy")
    })

    it("Interloper cannot update the list", async () => {
      await stakeCurate.connect(governor).createAccount({value: 500})
      // listId, governorId, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      const args = [0, 0, 100, LIST_REMOVAL_PERIOD, 0, "list_policy"]
      await expect(stakeCurate.connect(interloper).updateList(...args))
        .to.be.revertedWith("Only governor can update list")
    })
  })

  describe("items...", () => {

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
      await stakeCurate.connect(deployer).createAccount({ value: 200 })
      await stakeCurate.connect(governor).createAccount({ value: 200 })
      await stakeCurate.connect(deployer).createList(1, 100, LIST_REMOVAL_PERIOD, 0, "list_policy")
    })

    it("Adds an item", async () => {
      const args = [0, 0, 0, IPFS_URI] // fromItemSlot, listId, accountId, ipfsUri
      await expect(stakeCurate.connect(deployer).addItem(...args))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(...args)
    })

    it("An item added to a taken slot goes to the next free slot", async () => {
      const args = [0, 0, 0, IPFS_URI] // fromItemSlot, listId, accountId, ipfsUri
      await stakeCurate.connect(deployer).addItem(...args)
      await expect(stakeCurate.connect(deployer).addItem(...args))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(1, ...args.slice(1))
    })

    it("Interloper cannot add an item", async () => {
      const args = [0, 0, 0, IPFS_URI] // fromItemSlot, listId, accountId, ipfsUri
      await expect(stakeCurate.connect(interloper).addItem(...args))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Revert adding if not enough free stake", async () => {
      // listId, governorId, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      const updateListArgs = [0, 1, 2000, 60, 0, IPFS_URI]
      await stakeCurate.connect(governor).updateList(...updateListArgs)

      const addItemArgs = [0, 0, 0, IPFS_URI] // fromItemSlot, listId, accountId, ipfsUri
      await expect(stakeCurate.connect(deployer).addItem(...addItemArgs))
      .to.be.revertedWith("Not enough free stake")
    })

    it("You can start removing an item", async () => {
      const args = [0] // itemSlot
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await expect(stakeCurate.connect(deployer).startRemoveItem(...args))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(...args)
    })

    it("You can cancel the removal of an item", async () => {
      const args = [0] // itemSlot
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await stakeCurate.connect(deployer).startRemoveItem(...args)
      await expect(stakeCurate.connect(deployer).cancelRemoveItem(...args))
        .to.emit(stakeCurate, "ItemStopRemoval")
        .withArgs(...args)
    })

    it("Interloper cannot start removal of an item", async () => {
      const args = [0] // itemSlot
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await expect(stakeCurate.connect(interloper).startRemoveItem(...args))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Interloper cannot cancel removal of an item", async () => {
      const removeArgs = [0] // itemSlot
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await expect(stakeCurate.connect(deployer).startRemoveItem(...removeArgs))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(...removeArgs)

      const cancelArgs = [0] // itemSlot
      await expect(stakeCurate.connect(interloper).cancelRemoveItem(...cancelArgs))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("You cannot request removal of an item already being removed", async () => {
      const args = [0] // itemSlot
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await stakeCurate.connect(deployer).startRemoveItem(...args)
      await expect(stakeCurate.connect(deployer).startRemoveItem(...args))
        .to.be.revertedWith("Item is already being removed")
    })

    it("You can add an item into a removed slot", async () => {
      const args = [0, 0, 0, IPFS_URI] // fromItemSlot, listId, accountId, ipfsUri
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await stakeCurate.connect(deployer).startRemoveItem(0)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD + 1])
      await expect(stakeCurate.connect(deployer).addItem(...args))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(...args)
    })

    it("Cannot recommit item that's being removed", async () => {
      await stakeCurate.connect(deployer).addItem(50, 0, 0, IPFS_URI)
      await stakeCurate.connect(deployer).startRemoveItem(50)
      await expect(stakeCurate.connect(deployer).recommitItem(50))
        .to.be.revertedWith("Item is being removed")
    })

    it("Cannot recommit without enough", async () => {
      await stakeCurate.connect(hobo).createAccount({value: 100}) // acc Id: 2
      await stakeCurate.connect(hobo).addItem(0, 0, 2, IPFS_URI)
      await stakeCurate.connect(governor).updateList(0, 1, 200, 3_600, 0, IPFS_URI)
      await expect(stakeCurate.connect(hobo).recommitItem(0))
        .to.be.revertedWith("Not enough to recommit item")
    })

    it("Recommit the stake of an item", async () => {
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      // governor, requiredStake, removalPeriod, arbitratorExtraDataId, ipfsUri
      await stakeCurate.connect(governor).updateList(0, 1, 200, LIST_REMOVAL_PERIOD, 0, IPFS_URI)

      await expect(stakeCurate.connect(deployer).recommitItem(0))
        .to.emit(stakeCurate, "ItemRecommitted")
        .withArgs(0)
    })

    it("Interloper cannot recommit item", async () => {
      await expect(stakeCurate.connect(interloper).recommitItem(0))
        .to.be.revertedWith("Only account owner can invoke account")
    })

    it("Cannot recommit in non-Used ItemSlot", async () => {
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, {value: CHALLENGE_FEE})
      await expect(stakeCurate.connect(deployer).recommitItem(0))
        .to.be.revertedWith("ItemSlot must be Used")
    })
  })

  describe("adopts...", () => {

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
      await stakeCurate.connect(deployer).createAccount({ value: 100 })
      await stakeCurate.connect(governor).createAccount({ value: 200 })
      await stakeCurate.connect(deployer).createList(1, 100, LIST_REMOVAL_PERIOD, 0, "list_policy")
    })

    it("Cannot adopt item if slot is not Used", async () => {
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await stakeCurate.connect(adopter).createAccount({value: 500})
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, {value: CHALLENGE_FEE})
      await expect(stakeCurate.connect(adopter).adoptItem(0, 2))
      .to.be.revertedWith("Item slot must be Used")
    })

    it("Cannot adopt if item is not adoptable", async () => {
      await stakeCurate.connect(adopter).createAccount({value: 500})
      await stakeCurate.connect(deployer).addItem(104, 0, 0, IPFS_URI)
      await expect(stakeCurate.connect(adopter).adoptItem(104, 2))
        .to.be.revertedWith("Item is not in adoption")
    })

    it("Cannot adopt in another account's name", async () => {
      await stakeCurate.connect(interloper).createAccount({value: 500})
      await stakeCurate.connect(deployer).addItem(105, 0, 0, IPFS_URI)
      await expect(stakeCurate.connect(interloper).adoptItem(105, 0))
        .to.be.revertedWith("Only adopter owner can adopt")
    })

    it("Can adopt item whose committed is under required", async () => {
      await stakeCurate.connect(adopter).createAccount({value: 500})
      await stakeCurate.connect(deployer).addItem(102, 0, 0, IPFS_URI)
      await stakeCurate.connect(governor).updateList(0, 1, 200, 3_600, 0, IPFS_URI)
      await expect(stakeCurate.connect(adopter).adoptItem(102, 2))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(102, 2)
    })

    it("Can adopt item whose account has free stake under required", async () => {
      await stakeCurate.connect(adopter).createAccount({value: 500})
      await stakeCurate.connect(hobo).createAccount({value: 500})
      await stakeCurate.connect(hobo).addItem(103, 0, 3, IPFS_URI)
      await stakeCurate.connect(hobo).startWithdrawAccount(3)
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await stakeCurate.connect(hobo).withdrawAccount(3, 500)
      await expect(stakeCurate.connect(adopter).adoptItem(103, 2))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(103, 2)
    })

    it("Can adopt item in removal", async () => {
      // make acc for adopter
      await stakeCurate.connect(adopter).createAccount({value: 500})
      await stakeCurate.connect(deployer).addItem(100, 0, 0, IPFS_URI)
      await stakeCurate.connect(deployer).startRemoveItem(100)
      await expect(stakeCurate.connect(adopter).adoptItem(100, 2))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(100, 2)
    })

    it("Can adopt item whose account is withdrawing", async () => {
      // make acc for adopter
      await stakeCurate.connect(adopter).createAccount({value: 500})
      await stakeCurate.connect(deployer).addItem(101, 0, 0, IPFS_URI)
      await stakeCurate.connect(deployer).startWithdrawAccount(0)
      await expect(stakeCurate.connect(adopter).adoptItem(101, 2))
        .to.emit(stakeCurate, "ItemAdopted")
        .withArgs(101, 2)
      // stop deployer from withdrawing for later
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])
      await stakeCurate.connect(deployer).withdrawAccount(0, 0)
    })
  })

  describe("challenges...", () => {

    beforeEach("Deploying", async () => {
      [deployer, challenger, governor, interloper, hobo, adopter] = await ethers.getSigners();
      ({ arbitrator, stakeCurate } = await deployContracts(deployer))
      await stakeCurate.connect(deployer).createAccount({ value: 400 })
      await stakeCurate.connect(governor).createAccount({ value: 200 })
      await stakeCurate.connect(deployer).createList(1, 100, LIST_REMOVAL_PERIOD, 0, IPFS_URI)
      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
    })

    it("You can challenge an item", async () => {
      const args = [0, 0, 0, IPFS_URI] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(await stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.emit(stakeCurate, "ItemChallenged").withArgs(0, 0)
        .to.emit(stakeCurate, "Dispute") // how to encodePacked in js? todo
        .to.emit(stakeCurate, "Evidence") // to get evidenceGroupId
        .to.changeEtherBalance(challenger, -value)
    })

    it("You cannot challenge a disputed item", async () => {
      const args = [0, 0, 0, IPFS_URI] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await await stakeCurate.connect(challenger).challengeItem(...args, { value })
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a free item slot", async () => {
      const args = [10, 0, 0, IPFS_URI] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a removed item", async () => {
      const args = [0, 0, 0, IPFS_URI] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(deployer).startRemoveItem(0))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(0)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD + 1])
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge when committedStake < requiredStake", async () => {
      await stakeCurate.connect(governor).updateList(0, 1, 200, LIST_REMOVAL_PERIOD, 0, "list_policy")
      await expect(stakeCurate.connect(challenger).challengeItem(0, 100, 0, "list_policy", {value: CHALLENGE_FEE}))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("Challenge reverts if minAmount is over freeStake", async () => {
      await expect(stakeCurate.connect(challenger).challengeItem(0, 100, 2000, "list_policy", {value: CHALLENGE_FEE}))
        .to.be.revertedWith("Not enough free stake to satisfy minAmount")
    })

    it("Challenging to a taken slot goes to next valid slot", async () => {
      const args = [1, 0, 0, IPFS_URI] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await stakeCurate.connect(deployer).addItem(1, 0, 0, IPFS_URI)
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, { value })
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.emit(stakeCurate, "ItemChallenged").withArgs(1, 1) // itemSlot, disputeSlot
    })

    it("You cannot start removal of a disputed item", async () => {
      const args = [0] // itemSlot
      const value = CHALLENGE_FEE
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, { value })
      await expect(stakeCurate.connect(deployer).startRemoveItem(...args))
        .to.be.revertedWith("ItemSlot must be Used")
    })

    it("Submit evidence", async () => {
      const args = [0, IPFS_URI]
      const value = CHALLENGE_FEE
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, { value })
      await expect(stakeCurate.connect(deployer).submitEvidence(...args))
        .to.emit(stakeCurate, "Evidence")
        .withArgs(arbitrator.address, 0, deployer.address, IPFS_URI)
    })

    it("Rule for challenger", async () => {
      // Mock ruling
      const value = CHALLENGE_FEE
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, { value })
      await arbitrator.connect(deployer).giveRuling(0, 2, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      const args = [0] // disputeId
      await expect(arbitrator.connect(deployer).executeRuling(...args))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, 0, 2)
    })

    it("Dispute slot can be reused after resolution", async () => {
      const value = CHALLENGE_FEE
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, { value })
      await arbitrator.connect(deployer).giveRuling(0, 2, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      const args = [0] // disputeId
      await expect(arbitrator.connect(deployer).executeRuling(...args))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, 0, 2)

      await stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI)
      await expect(stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, { value }))
        .to.emit(stakeCurate, "ItemChallenged")
    })

    it("Interloper cannot call rule", async () => {
      const args = [0, 1]

      await expect(stakeCurate.connect(interloper).rule(...args))
        .to.be.revertedWith("Only arbitrator can rule")
    })

    it("Rule for submitter", async () => {
      // get a dispute to withdrawing first
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, {value: CHALLENGE_FEE})
      await arbitrator.connect(deployer).giveRuling(0, 1, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      await expect(arbitrator.connect(deployer).executeRuling(0))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, 0, 1)

      // check if slot is overwritten (it shouldn't since item won dispute)
      await expect(stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(1, 0, 0, IPFS_URI)
    })

    it("Unsuccessful dispute on removing item makes item renew removalTimestamp", async () => {
      await stakeCurate.connect(deployer).startRemoveItem(0)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD/2])
      await stakeCurate.connect(challenger).challengeItem(0, 0, 0, IPFS_URI, {value: CHALLENGE_FEE})
      await arbitrator.connect(deployer).giveRuling(0, 0, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])
      await expect(arbitrator.connect(deployer).executeRuling(0))
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, 0, 0)
      // shouldn't been removed yet (since it reset), so adding gets into the next available slot
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD/2 + 1])
      await expect(stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(1, 0, 0, IPFS_URI)
      // should've been removed, so adding gets there
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD/2 + 1])
      await expect(stakeCurate.connect(deployer).addItem(0, 0, 0, IPFS_URI))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(0, 0, 0, IPFS_URI)
    })
  })
})
