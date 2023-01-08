// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IArbitrator.sol";

/** @title ISimpleEvidence
 *  Inspired in ERC-1497: Evidence Standard
 *  Arbitrator and party are not emitted to save gas.
 */
interface ISimpleEvidence {
    /**
     * @dev To be raised when evidence is submitted. Should point to the resource (evidences are not to be stored on chain due to gas considerations).
     * @param _evidenceGroupID Unique identifier of the evidence group the evidence belongs to.
     * @param _evidence IPFS path to evidence, example: '/ipfs/Qmarwkf7C9RuzDEJNnarT3WZ7kem5bk8DZAzx78acJjMFH/evidence.json'
     */
    event Evidence(uint256 indexed _evidenceGroupID, string _evidence);
}
