// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IArbitrator.sol";

/** @title IPost
 *  Inspired in ERC-1497: Evidence Standard
 */
interface IPost {
    /**
     * @dev To be raised when post is submitted. Should point to the resource.
     * @param _threadId Unique identifier of the thread the post belongs to.
     * @param _post IPFS path to post, example: '/ipfs/Qmarwkf7C9RuzDEJNnarT3WZ7kem5bk8DZAzx78acJjMFH/evidence.json'
     */
    event Post(uint256 indexed _threadId, string _post);
}
