/**
 * @authors: [@greenlucid, @shotaronowhere]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8;

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
    uint256 shiftedShift = shiftAmount << 23;
    return (uint32(significantPart + shiftedShift));
  }

  function decompress(uint32 _cint32) internal pure returns (uint256) {
      if(_cint32 < 16_777_216) // 2**24
        return _cint32;
    uint256 shift = _cint32 >> 23;
    // black magic, don't ask
    return  (1 << (shift + 22)) + (1 << (shift - 1))*(_cint32-(shift << 23));
  }
}