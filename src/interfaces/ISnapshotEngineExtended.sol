// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ISnapshotEngine} from "CMTAT/contracts/interfaces/engine/ISnapshotEngine.sol";

/// @title ISnapshotEngineExtended
/// @notice Extended snapshot engine interface with scheduling capabilities
interface ISnapshotEngineExtended is ISnapshotEngine {
    /// @notice Schedule a snapshot at the specified time
    /// @param time The timestamp for the snapshot
    function scheduleSnapshot(uint256 time) external;

    /// @notice Reschedule an existing snapshot
    /// @param oldTime The current snapshot time
    /// @param newTime The new snapshot time
    function rescheduleSnapshot(uint256 oldTime, uint256 newTime) external;

    /// @notice Check if a snapshot exists at the given time and return its total supply
    /// @param time The snapshot timestamp
    /// @return exists Whether a snapshot record exists at this time
    /// @return totalSupply_ The total supply at the snapshot (only valid if exists == true)
    function snapshotTotalSupplyStrict(uint256 time) external view returns (bool exists, uint256 totalSupply_);

    /// @notice Create and activate a snapshot at the current block timestamp
    /// @dev Bypasses CMTAT's future-only restriction for dividend record dates
    /// @dev Records total supply immediately; account balances captured lazily on next transfer
    function createInstantSnapshot() external;
}
