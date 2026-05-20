// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleCloneable
/// @notice Common interface for rules that can be cloned (EIP-1167) and initialized per share class.
/// @dev Implementations MUST:
///      - Use `Initializable` (storage-compatible with clones — no constructor-set immutables).
///      - Bind to `company` and derive authority from `company.board()` dynamically (live lookup).
///        This way a {CompanyGovernance-executeBoardTransfer} rotation takes effect on every cloned
///        rule instance automatically, without needing per-rule role migration.
///      - Decode `initData` for rule-specific parameters (oracle address, schema UIDs, thresholds, etc.).
interface IRuleCloneable {
    /// @notice Initialize a cloned rule instance.
    /// @param initData ABI-encoded rule-specific parameters (layout decided by the rule).
    /// @param company Company contract that owns the share class this rule is attached to.
    function initialize(bytes calldata initData, address company) external;
}
