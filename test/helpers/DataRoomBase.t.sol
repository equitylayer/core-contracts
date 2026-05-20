// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./BaseTest.sol";
import {DataRoom} from "../../src/DataRoom.sol";

/// @title DataRoomBaseTest
/// @notice Shared helpers for DataRoom unit and integration tests.
abstract contract DataRoomBaseTest is BaseTest {
    DataRoom room;

    function _wk(uint256 seed) internal view returns (bytes memory) {
        return abi.encodePacked(keccak256(abi.encode(seed, block.timestamp)));
    }

    function _addrs(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _addrs(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _s1(string memory a) internal pure returns (string[] memory r) {
        r = new string[](1);
        r[0] = a;
    }

    function _s2(string memory a, string memory b) internal pure returns (string[] memory r) {
        r = new string[](2);
        r[0] = a;
        r[1] = b;
    }

    function _s3(string memory a, string memory b, string memory c) internal pure returns (string[] memory r) {
        r = new string[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _b1(bytes memory a) internal pure returns (bytes[] memory r) {
        r = new bytes[](1);
        r[0] = a;
    }

    function _b2(bytes memory a, bytes memory b) internal pure returns (bytes[] memory r) {
        r = new bytes[](2);
        r[0] = a;
        r[1] = b;
    }

    function _b3(bytes memory a, bytes memory b, bytes memory c) internal pure returns (bytes[] memory r) {
        r = new bytes[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _u1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    /// @dev getDocument as board (avoids Unauthorized on private folders)
    function _getDoc(uint256 roomId, uint256 docIndex)
        internal
        returns (
            string memory cid,
            string memory name,
            uint256 createdAt,
            uint256 keyVersion,
            bytes memory wrappedKey,
            bytes memory metadata
        )
    {
        vm.prank(board);
        return room.getDocument(roomId, docIndex);
    }
}
