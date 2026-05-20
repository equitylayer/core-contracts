// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleAccredited
/// @notice Identity interface for the accredited-investor rule family.
interface IRuleAccredited {
    function setAcceptedTypes(uint8[] calldata types) external;
}
