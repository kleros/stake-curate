/**
 * @custom:authors: [@greenlucid]
 * @custom:reviewers: []
 * @custom:auditors: []
 * @custom:bounties: []
 * SPDX-License-Identifier: Licenses are not real
 */

pragma solidity ^0.8.14;

/**
 * @title KlerosV2ExtraDataParser
 * @author Green
 * @dev Library related to packing and unpacking extradata
 */
library KlerosV2Helper {
  function arbSettingToExtraData(bytes32 _arbSetting) internal pure returns (bytes memory) {
    // stake curate will pack the data in the following way:

    // 32 bits for subcourtId
    // 32 bits for jurors
    // 32 bits for disputeKit
    // remaining 160 bits are left unused.

    // we start from the end
    uint32 disputeKitId =
      uint32(uint((_arbSetting & 0x0000000000000000ffffffff0000000000000000000000000000000000000000) >> 160));
    
    uint32 jurors =
      uint32(uint((_arbSetting & 0x00000000ffffffff000000000000000000000000000000000000000000000000) >> 192));

    uint32 subcourtId =
      uint32(uint((_arbSetting >> 224)));

    return abi.encode(subcourtId, jurors, disputeKitId);
  }
}
