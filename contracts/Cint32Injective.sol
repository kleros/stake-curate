/**
 * @authors: [@greenlucid, @shotaronowhere]
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
library Cint32Injective {

  function compress(uint256 _amount) internal pure returns (uint32) {
    // maybe binary search to find ndigits? there should be a better way
    uint8 digits = 0;
    if (_amount == 0) {
        return (0);
    }
    uint256 clone = _amount;
    while (clone != 1) {
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
      if(_cint32 < 33_554_432) // 2**25
        return _cint32;
    uint256 shift = _cint32 >> 24;
    // black magic, don't ask
    return  (1 << (shift + 23)) + (1 << (shift - 1))*(_cint32-(shift << 24));
  }
}
