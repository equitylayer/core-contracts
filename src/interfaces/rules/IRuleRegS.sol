// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleRegS
/// @notice Identity interface for the Reg S (offshore offering) rule family.
interface IRuleRegS {
    function setComplianceEnd(uint64 complianceEnd) external;
}
