/**
 * @authors: [@greenlucid]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8.11;

/**
 * @title Cint32
 * @author Green
 * @dev Lossy compression library for turning uint256 into uint32
 */
library Cint32 {

  function compress(uint256 _amount) internal pure returns (uint32) {
    // maybe binary search to find ndigits? there should be a better way
    uint8 digits = 0;
    uint256 clone = _amount;
    while (clone != 0) {
      clone = clone >> 1;
      digits++;
    }
    // if digits < 24, don't shift it!
    uint256 shiftAmount = (digits < 24) ? 0 : (digits - 24);
    uint256 significantPart = _amount >> shiftAmount;
    uint256 shiftedShift = shiftAmount << 24;
    return (uint32(significantPart + shiftedShift));
  }

  function decompress(uint32 _cint32) internal pure returns (uint256) {
    uint256 shift = _cint32 >> 24;
    uint256 significantPart = _cint32 & 16_777_215; // 2^24 - 1
    return(significantPart << shift);
  }
}