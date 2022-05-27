/**
 * @authors: [@shotaronowhere]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8.14;

import "./../Cint32.sol";

contract Cint32Test{
    using Cint32 for uint256;
    using Cint32 for uint32;
    uint8 public digits;

    function compress(uint256 _val) public pure returns (uint32){
        return _val.compress();
    }

    function decompress(uint32 _val) public pure returns (uint256){
        return _val.decompress();
    }
}