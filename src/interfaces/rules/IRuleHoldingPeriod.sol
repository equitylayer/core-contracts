// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleHoldingPeriod
/// @notice Identity interface for the holding-period rule family (Rule 144 and jurisdictional
///         equivalents). Shares issued under the rule cannot be transferred until the per-lot
///         holding period expires.
interface IRuleHoldingPeriod {
    /// @notice Record that `amount` shares were just issued to `account`. Starts a new lot with
    ///         the current `holdingPeriodSeconds`. Callable by the Company (i.e. the issuer path).
    function recordIssuance(address account, uint256 amount) external;

    /// @notice Adjust the holding period for future lots. Existing lots are unaffected.
    function setHoldingPeriod(uint32 newPeriodSeconds) external;
}
