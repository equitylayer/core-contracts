// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleOFAC
/// @notice Identity interface for the OFAC sanctions rule family.
interface IRuleOFAC {
    function setOracle(address newOracle) external;
}
