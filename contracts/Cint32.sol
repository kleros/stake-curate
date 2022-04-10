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
library Cint32 {

  // https://gist.github.com/sambacha/f2d56948602575132574e73578778a41
  function mostSignificantBit(uint256 x) private pure returns (uint8 r) {
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

  function compress(uint256 _amount) internal pure returns (uint32) {
    // base = 2^29 - 2^27 - 2^0
    // complement = 2^24
    // base + complement = 419_430_399
    if (_amount <= 419_430_399) {
      return uint32(_amount);
    }
    // base - complement = 385_875_967
    uint256 translation = 385_875_967;
    _amount = _amount - translation;
    uint digits = mostSignificantBit(_amount);
    // if digits < 24, don't shift it!
    uint256 shiftAmount = (digits < 24) ? 0 : (digits - 24);
    uint256 significantPart = _amount >> shiftAmount;
    uint256 shiftedShift = shiftAmount << 24;
    return (uint32(significantPart + shiftedShift+ translation));
  }

  function decompress(uint32 _cint32) internal pure returns (uint256) {
    // base = 2^29 - 2^27 - 2^0
    // complement = 2^24
    // base + complement = 419_430_399
    if (_cint32 <= 419_430_399) {
      return uint32(_cint32);
    }
    // base - complement = 385_875_967
    uint32 translation = 385_875_967;

    // special case to avoid 2**32-1 overflows under line 84
    if(_cint32 == 4_294_967_295){
      return 115792089237316195423570985008687907853269984665640564039457584007913129639935;
    }
    _cint32 = _cint32 - translation;
    uint256 shift = _cint32 >> 24;
    return translation + (1 << (shift + 23)) + (1 << (shift - 1))*(_cint32-(shift << 24));
  }
}
