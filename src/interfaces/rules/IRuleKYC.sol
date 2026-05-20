// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleKYC
/// @notice Identity interface for the KYC rule family.
interface IRuleKYC {
    function setRequiredKycLevel(uint8 requiredKycLevel) external;
}
