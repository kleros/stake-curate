/**
 * @custom:authors: [@greenlucid, @shotaronowhere]
 * @custom:reviewers: []
 * @custom:auditors: []
 * @custom:bounties: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8.14;

/**
 * @title Cint32
 * @author Green
 * @dev Lossy compression library for turning uint256 into uint32
 */
library Cint32 {

  // https://gist.github.com/sambacha/f2d56948602575132574e73578778a41
  function mostSignificantBit(uint256 x) private pure returns (uint8 r) {
    unchecked {
      if (x >= 0x100000000000000000000000000000000) {
        x >>= 128;
        r += 128;
      }
      if (x >= 0x10000000000000000) {
        x >>= 64;
        r += 64;
      }
      if (x >= 0x100000000) {
        x >>= 32;
        r += 32;
      }
      if (x >= 0x10000) {
        x >>= 16;
        r += 16;
      }
      if (x >= 0x100) {
        x >>= 8;
        r += 8;
      }
      if (x >= 0x10) {
        x >>= 4;
        r += 4;
      }
      if (x >= 0x4) {
        x >>= 2;
        r += 2;
      }
      if (x >= 0x2) r += 1;
    }
  }

  function compress(uint256 _amount) internal pure returns (uint32) {
    unchecked {
      if (_amount == 0) {
        return 0;
      }
      uint digits = mostSignificantBit(_amount);
      // if digits < 24, don't shift it!
      uint256 shiftAmount = (digits < 24) ? 0 : (digits - 24);
      uint256 significantPart = _amount >> shiftAmount;
      uint256 shiftedShift = shiftAmount << 24;
      return (uint32(significantPart + shiftedShift));
    }
  }

  function decompress(uint32 _cint32) internal pure returns (uint256) {
    unchecked {
      if (_cint32 < 33_554_432) { // 2**25
        return _cint32;
      }
      uint256 shift = _cint32 >> 24;
      return (1 << (shift + 23)) + (1 << (shift - 1))*(_cint32-(shift << 24));
    }
  }
}
