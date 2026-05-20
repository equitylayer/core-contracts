// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SnapshotModuleBase} from "CMTAT/contracts/mocks/library/snapshot/SnapshotModuleBase.sol";
import {ISnapshotEngine} from "CMTAT/contracts/interfaces/engine/ISnapshotEngine.sol";

/// @title SnapshotEngine
/// @notice Production snapshot engine for tracking token balances at specific timestamps
/// @dev Implements CMTAT's ISnapshotEngine interface for dividend record dates
contract SnapshotEngine is SnapshotModuleBase, AccessControlUpgradeable, ISnapshotEngine {
    string public constant VERSION = "0.9.0";

    /* ============ State Variables ============ */
    ERC20Upgradeable public token;
    bytes32 public constant SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");

    /* ============ Initializer ============ */
    /// @notice Initialize the snapshot engine
    /// @param token_ The ERC20 token to track
    /// @param admin_ The admin address (gets DEFAULT_ADMIN_ROLE)
    function initialize(ERC20Upgradeable token_, address admin_) external initializer {
        require(address(token_) != address(0), "SnapshotEngine: invalid token address");
        token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /* ============ Modifiers ============ */
    /// @notice Restrict function to only be callable by the tracked token
    modifier onlyToken() {
        require(msg.sender == address(token), "SnapshotEngine: caller must be token");
        _;
    }

    /* ============ Access Control Override ============ */
    /// @dev Returns `true` if `account` has been granted `role`.
    /// @dev The Default Admin has all roles
    function hasRole(bytes32 role, address account)
        public
        view
        virtual
        override(AccessControlUpgradeable)
        returns (bool)
    {
        // The Default Admin has all roles
        if (AccessControlUpgradeable.hasRole(DEFAULT_ADMIN_ROLE, account)) {
            return true;
        }
        return AccessControlUpgradeable.hasRole(role, account);
    }

    /* ============ ISnapshotEngine Implementation ============ */
    /// @notice Update balance and/or total supply snapshots before values are modified
    /// @dev Called by the token contract on transfer/mint/burn operations
    /// @param from Sender address (address(0) for mint)
    /// @param to Recipient address (address(0) for burn)
    /// @param balanceFrom Sender's balance after the transfer
    /// @param balanceTo Recipient's balance after the transfer
    /// @param totalSupply_ Total supply after the transfer
    function operateOnTransfer(address from, address to, uint256 balanceFrom, uint256 balanceTo, uint256 totalSupply_)
        external
        override
        onlyToken
    {
        _setCurrentSnapshot();
        if (from != address(0)) {
            // for both burn and transfer
            _updateAccountSnapshot(from, balanceFrom);
            if (to != address(0)) {
                // transfer
                _updateAccountSnapshot(to, balanceTo);
            } else {
                // burn
                _updateTotalSupplySnapshot(totalSupply_);
            }
        } else {
            // mint
            _updateAccountSnapshot(to, balanceTo);
            _updateTotalSupplySnapshot(totalSupply_);
        }
    }

    /* ============ Query Functions ============ */
    /// @notice Return snapshotBalanceOf and snapshotTotalSupply in one call
    /// @param time The snapshot timestamp
    /// @param owner The address to query
    /// @return ownerBalance The balance at the snapshot time
    /// @return totalSupply_ The total supply at the snapshot time
    function snapshotInfo(uint256 time, address owner)
        external
        view
        returns (uint256 ownerBalance, uint256 totalSupply_)
    {
        ownerBalance = snapshotBalanceOf(time, owner);
        totalSupply_ = snapshotTotalSupply(time);
    }

    /// @notice Return snapshotBalanceOf for each address and the total supply
    /// @param time The snapshot timestamp
    /// @param addresses Array of addresses to query
    /// @return ownerBalances Array of balances at the snapshot time
    /// @return totalSupply_ The total supply at the snapshot time
    function snapshotInfoBatch(uint256 time, address[] calldata addresses)
        external
        view
        returns (uint256[] memory ownerBalances, uint256 totalSupply_)
    {
        ownerBalances = new uint256[](addresses.length);
        for (uint256 i = 0; i < addresses.length; ++i) {
            ownerBalances[i] = snapshotBalanceOf(time, addresses[i]);
        }
        totalSupply_ = snapshotTotalSupply(time);
    }

    /// @notice Return snapshotBalanceOf for each address at multiple times
    /// @param times Array of snapshot timestamps
    /// @param addresses Array of addresses to query
    /// @return ownerBalances 2D array of balances at each snapshot time
    /// @return totalSupply_ Array of total supplies at each snapshot time
    function snapshotInfoBatch(uint256[] calldata times, address[] calldata addresses)
        external
        view
        returns (uint256[][] memory ownerBalances, uint256[] memory totalSupply_)
    {
        ownerBalances = new uint256[][](times.length);
        totalSupply_ = new uint256[](times.length);
        for (uint256 iT = 0; iT < times.length; ++iT) {
            ownerBalances[iT] = new uint256[](addresses.length);
            for (uint256 iA = 0; iA < addresses.length; ++iA) {
                ownerBalances[iT][iA] = snapshotBalanceOf(times[iT], addresses[iA]);
            }
            totalSupply_[iT] = snapshotTotalSupply(times[iT]);
        }
    }

    /// @notice Get the balance of an account at a specific snapshot time
    /// @param time The snapshot timestamp
    /// @param owner The address to query
    /// @return The balance at the snapshot time, or current balance if no snapshot exists
    function snapshotBalanceOf(uint256 time, address owner) public view returns (uint256) {
        return _snapshotBalanceOf(time, owner, token.balanceOf(owner));
    }

    /// @notice Get the total supply at a specific snapshot time
    /// @param time The snapshot timestamp
    /// @return The total supply at the snapshot time, or current supply if no snapshot exists
    function snapshotTotalSupply(uint256 time) public view returns (uint256) {
        return _snapshotTotalSupply(time, token.totalSupply());
    }

    /// @notice Check if a snapshot exists at the given time and return its total supply
    /// @param time The snapshot timestamp
    /// @return exists Whether a snapshot record exists at this time
    /// @return totalSupply_ The total supply at the snapshot (only valid if exists == true)
    function snapshotTotalSupplyStrict(uint256 time) external view returns (bool exists, uint256 totalSupply_) {
        (exists, totalSupply_) = _valueAt(time, _getSnapshotModuleBaseStorage()._totalSupplySnapshots);
    }

    /* ============ Snapshot Scheduling Functions ============ */
    /// @notice Schedule a snapshot at the given timestamp (must be chronologically after last snapshot)
    /// @param time The timestamp for the snapshot (must be in the future and after last scheduled snapshot)
    /// @dev Only callable by accounts with SNAPSHOOTER_ROLE
    /// @dev Gas optimized: O(1) - only allows adding snapshots at the end of the list
    function scheduleSnapshot(uint256 time) external onlyRole(SNAPSHOOTER_ROLE) {
        _scheduleSnapshot(time);
    }

    /// @notice Create and activate a snapshot at the current block timestamp
    /// @dev Bypasses CMTAT's future-only restriction so dividends can snapshot "now"
    /// @dev Total supply is recorded immediately; account balances are captured lazily on their next transfer
    function createInstantSnapshot() external onlyRole(SNAPSHOOTER_ROLE) {
        SnapshotModuleBaseStorage storage $ = _getSnapshotModuleBaseStorage();
        uint256 time = block.timestamp;
        uint256 len = $._scheduledSnapshots.length;

        // Idempotent: snapshot already exists at this timestamp
        if (len > 0 && $._scheduledSnapshots[len - 1] == time) return;

        // Cannot create instant snapshot before a future-scheduled one
        require(len == 0 || $._scheduledSnapshots[len - 1] < time, "SnapshotEngine: snapshot exists after this time");

        // Push to scheduled array and immediately activate
        $._scheduledSnapshots.push(time);
        _setCurrentSnapshot();

        // Eagerly record total supply so it's available before any transfer
        _updateTotalSupplySnapshot(token.totalSupply());

        emit SnapshotSchedule(0, time);
    }

    /// @notice Reschedule an existing snapshot to a new time
    /// @param oldTime The current scheduled time
    /// @param newTime The new scheduled time
    /// @dev Only callable by accounts with SNAPSHOOTER_ROLE
    function rescheduleSnapshot(uint256 oldTime, uint256 newTime) external onlyRole(SNAPSHOOTER_ROLE) {
        _rescheduleSnapshot(oldTime, newTime);
    }

    /// @notice Cancel the last scheduled snapshot
    /// @param time The time of the snapshot to cancel (must be the last scheduled snapshot)
    /// @dev Only callable by accounts with SNAPSHOOTER_ROLE
    /// @dev Gas optimized: O(1) - only allows removing the last snapshot
    function unscheduleLastSnapshot(uint256 time) external onlyRole(SNAPSHOOTER_ROLE) {
        _unscheduleLastSnapshot(time);
    }
}
