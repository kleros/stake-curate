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

describe("Stake Curate", async () => {
  let deployer: SignerWithAddress, challenger: SignerWithAddress, interloper: SignerWithAddress, governor: SignerWithAddress
  let arbitrator: Contract, stakeCurate: Contract
  before("Deploying", async () => {
    [deployer, challenger, governor, interloper] = await ethers.getSigners();
    ({ arbitrator, stakeCurate } = await deployContracts(deployer))
  })

  describe("should...", () => {
    const ACCOUNT_WITHDRAW_PERIOD = 604_800 // 1 week
    const LIST_REMOVAL_PERIOD = 60
    const CHALLENGE_FEE = 1_000_000_000 // also used for appeals

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

      await expect(stakeCurate.connect(deployer).withdrawAccount(...args))
        .to.be.revertedWith("Withdraw period didn't pass")
    })

    it("Cannot withdraw more than full stake", async () => {
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

    it("An item added to a taken slot goes to the next free slot", async () => {
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

    it("Revert adding if not enough free stake", async () => {
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
      const args = [0, 0, 0, "reason"] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.emit(stakeCurate, "ItemChallenged").withArgs(0, 0)
        .to.emit(stakeCurate, "Dispute") // how to encodePacked in js? todo
        .to.emit(stakeCurate, "Evidence") // to get evidenceGroupId
    })

    it("You cannot challenge a disputed item", async () => {
      const args = [0, 0, 0, "reason"] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a free item slot", async () => {
      const args = [10, 0, 0, "reason"] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("You cannot challenge a removed item", async () => {
      const args = [1, 0, 0, "reason"] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(deployer).startRemoveItem(1))
        .to.emit(stakeCurate, "ItemStartRemoval")
        .withArgs(1)
      await ethers.provider.send("evm_increaseTime", [LIST_REMOVAL_PERIOD + 1])
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.be.revertedWith("Item cannot be challenged")
    })

    it("Challenging to a taken slot goes to next valid slot", async () => {
      await stakeCurate.connect(deployer).addItem(1, 0, 0, "item3")
      const args = [1, 0, 0, "reason"] // itemSlot, disputeSlot, minAmount, reason
      const value = CHALLENGE_FEE
      await expect(stakeCurate.connect(challenger).challengeItem(...args, { value }))
        .to.emit(stakeCurate, "ItemChallenged").withArgs(1, 1) // itemSlot, disputeSlot
    })

    it("You cannot start removal of a disputed item", async () => {
      const args = [0] // itemSlot
      await expect(stakeCurate.connect(deployer).startRemoveItem(...args))
        .to.be.revertedWith("ItemSlot must be Used")
    })

    it("Submit evidence", async () => {
      const args = [0, "evidence"]
      await expect(stakeCurate.connect(deployer).submitEvidence(...args))
        .to.emit(stakeCurate, "Evidence")
        .withArgs(arbitrator.address, 0, deployer.address, "evidence")
    })

    it("Make a contribution", async () => {
      // Mock ruling
      await arbitrator.connect(deployer).giveRuling(0, 2, 3_600) // disputeId, ruling, appealWindow
      const args = [0, 0] // disputeSlot, party 
      const value = 500_000_000
      await expect(stakeCurate.connect(deployer).contribute(...args, {value}))
        .to.emit(stakeCurate, "Contribute")
        .withArgs(...args)
    })

    it("Cannot start next round without enough funds", async () => {
      const args = [0] // disputeSlot
      await expect(stakeCurate.connect(deployer).startNextRound(...args))
        .to.be.revertedWith("Not enough to fund round")
    })

    it("Cannot start next round in unused Dispute", async () => {
      const args = [10] // disputeSlot
      await expect(stakeCurate.connect(deployer).startNextRound(...args))
        .to.be.revertedWith("Dispute must be Used")
    })

    it("Start next round", async () => {
      // contribute enough first.
      const contribArgs = [0, 1]
      const value = 550_000_000 // I overdo it due to lossy compression
      for (let i = 0; i < 3; i++) {
        await expect(stakeCurate.connect(challenger).contribute(...contribArgs, {value}))
          .to.emit(stakeCurate, "Contribute")
          .withArgs(...contribArgs)
      }

      const args = [0] // disputeSlot
      await expect(stakeCurate.connect(deployer).startNextRound(...args))
        .to.emit(stakeCurate, "NextRound")
        .withArgs(...args)
    })

    it("Rule for challenger", async () => {
      // Mock ruling
      await arbitrator.connect(deployer).giveRuling(0, 2, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      const args = [0] // disputeId
      await expect(arbitrator.connect(deployer).executeRuling(...args))
        .to.emit(stakeCurate, "DisputeSuccessful")
        .withArgs(0) // disputeSlot
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, 0, 2)
    })

    it("Cannot withdraw more than free stake", async () => {
      // Also this test reuses a dispute slot to check how cheap it is

      // add a new item to rechallenge it
      await stakeCurate.connect(deployer).startWithdrawAccount(0)
      await stakeCurate.connect(deployer).addItem(0, 0, 0, "item4")
      // note this dispute is in slot 2 (because 0 and 1) 
      await stakeCurate.connect(challenger).challengeItem(0, 1, 0, "reason2", {value: CHALLENGE_FEE})
      await ethers.provider.send("evm_increaseTime", [ACCOUNT_WITHDRAW_PERIOD + 1])

      // Now deployer has another 100 locked. If math is right he has 900 full, with 100 locked, so 800 free.
      await expect(stakeCurate.connect(deployer).withdrawAccount(0, 900))
        .to.be.revertedWith("You can't afford to withdraw that much")
    })

    it("Interloper cannot call rule", async () => {
      const args = [0, 1]

      await expect(stakeCurate.connect(interloper).rule(...args))
        .to.be.revertedWith("Only arbitrator can rule")
    })

    it("Withdraw one contribution", async () => {
      const args = [0, 1] // disputeSlot, contribSlot

      await expect(stakeCurate.connect(deployer).withdrawOneContribution(...args))
        .to.emit(stakeCurate, "WithdrawnContribution")
        .withArgs(...args)
      // test the ether balance changes? todo
    })

    it("Cannot withdraw from losing side", async () => {
      const args = [0, 0] // disputeSlot, contribSlot

      await expect(stakeCurate.connect(deployer).withdrawOneContribution(...args))
        .to.be.revertedWith("That side lost the dispute")
    })

    it("Cannot withdraw from Used dispute slot", async () => {
      const args = [1, 0] // disputeSlot, contribSlot

      await expect(stakeCurate.connect(deployer).withdrawOneContribution(...args))
        .to.be.revertedWith("DisputeSlot must be in withdraw")
    })

    it("Cannot withdraw a contribution that was never made", async () => {
      const args = [0, 10] // disputeSlot, contribSlot

      await expect(stakeCurate.connect(deployer).withdrawOneContribution(...args))
        .to.be.revertedWith("DisputeSlot lacks that contrib")
    })

    it("Cannot withdraw an already withdrawn contribution", async () => {
      const args = [0, 1] // disputeSlot, contribSlot

      await expect(stakeCurate.connect(deployer).withdrawOneContribution(...args))
        .to.be.revertedWith("Contribution withdrawn already")
    })

    it("Withdrawing all contributions frees the disputeSlot", async () => {
      const args = [0] // disputeSlot

      await expect(stakeCurate.connect(deployer).withdrawAllContributions(...args))
        .to.emit(stakeCurate, "FreedDisputeSlot")
        .withArgs(...args)
        // test balances? todo
    })

    it("Cannot withdraw all contributions from non-withdrawing disputeSlot", async () => {
      // Free dispute
      await expect(stakeCurate.connect(deployer).withdrawAllContributions(0))
        .to.be.revertedWith("Dispute must be in withdraw")
      // Used dispute
      await expect(stakeCurate.connect(deployer).withdrawAllContributions(1))
        .to.be.revertedWith("Dispute must be in withdraw")
    })

    it("Dispute in Withdrawing doesn't count as Free dispute, won't be overwritten", async () => {
      // get a dispute to withdrawing first
      await stakeCurate.connect(deployer).addItem(15, 0, 0, "item4")
      await stakeCurate.connect(challenger).challengeItem(15, 0, 0, "challenge3", {value: CHALLENGE_FEE})
      await arbitrator.connect(deployer).giveRuling(3, 2, 3_600) // disputeId, ruling, appealWindow
      await stakeCurate.connect(deployer).contribute(0, 0, {value: 3_000_000_000})
      await stakeCurate.connect(deployer).startNextRound(0)
      await arbitrator.connect(deployer).giveRuling(3, 1, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])
      await arbitrator.connect(deployer).executeRuling(3)

      await expect(stakeCurate.connect(deployer).addItem(10, 0, 0, "item5"))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(10, 0, 0, "item5")

      await expect(stakeCurate.connect(deployer).challengeItem(10, 0, 0, "challenge4", {value: CHALLENGE_FEE}))
        .to.emit(stakeCurate, "ItemChallenged")
        .withArgs(10, 3) // because in this test 0 is taken and 1 and 2 were taken in prev tests.
    })

    it("Withdrawing last contribution frees the disputeSlot", async () => {
      const args = [0, 0] // disputeSlot, contribSlot

      await expect(stakeCurate.connect(deployer).withdrawOneContribution(...args))
        .to.emit(stakeCurate, "WithdrawnContribution")
        .withArgs(0, 0)
        .to.emit(stakeCurate, "FreedDisputeSlot")
        .withArgs(0)
    })

    it("Ruling a dispute without contribs frees the slot automatically", async () => {
      // note: disputeSlot is 3, disputeId is 4
      const args = [3]

      await arbitrator.connect(deployer).giveRuling(4, 2, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      await expect(arbitrator.connect(deployer).executeRuling(4))
        .to.emit(stakeCurate, "DisputeSuccessful")
        .withArgs(3)
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, 4, 2)
        .to.emit(stakeCurate, "FreedDisputeSlot")
        .withArgs(3)
    })

    it("Rule for submitter", async () => {
      // get a dispute to withdrawing first
      await stakeCurate.connect(deployer).addItem(20, 0, 0, "item20")
      await stakeCurate.connect(challenger).challengeItem(20, 4, 0, "challenge5", {value: CHALLENGE_FEE})
      await arbitrator.connect(deployer).giveRuling(5, 1, 3_600) // disputeId, ruling, appealWindow
      await ethers.provider.send("evm_increaseTime", [3_600 + 1])

      await expect(arbitrator.connect(deployer).executeRuling(5))
        .to.emit(stakeCurate, "DisputeFailed")
        .to.emit(stakeCurate, "Ruling")
        .withArgs(arbitrator.address, 5, 1)

      // check if slot is overwritten (it shouldn't since item won dispute)
      await expect(stakeCurate.connect(deployer).addItem(20, 0, 0, "item21"))
        .to.emit(stakeCurate, "ItemAdded")
        .withArgs(21, 0, 0, "item21")
    })

    // balance from contribs from last unappealed round
  })
})
