// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleRegistry
/// @notice Protocol registry of compliance rules keyed by `(countryCode, entityType)`.
interface IRuleRegistry {
    /// @notice A single rule entry for a jurisdiction.
    /// @param impl Cloneable rule implementation (must implement {IRuleCloneable})
    /// @param initData ABI-encoded args forwarded to `initialize(bytes, company)` on each clone
    struct RuleConfig {
        address impl;
        bytes initData;
    }

    event RulesSet(uint16 indexed countryCode, uint8 indexed entityType, RuleConfig[] rules);
    event RuleAdded(uint16 indexed countryCode, uint8 indexed entityType, address indexed impl);
    event RuleRemoved(uint16 indexed countryCode, uint8 indexed entityType, address indexed impl);

    /// @notice Atomically replace the rule list for a jurisdiction.
    /// @param countryCode ISO 3166-1 numeric country code
    /// @param entityType Jurisdiction-specific entity type identifier
    /// @param rules New rule list (pass empty to clear)
    function setRules(uint16 countryCode, uint8 entityType, RuleConfig[] calldata rules) external;

    /// @notice Append a single rule to the jurisdiction list.
    function addRule(uint16 countryCode, uint8 entityType, RuleConfig calldata rule) external;

    /// @notice Remove a rule from the jurisdiction list by impl address.
    function removeRule(uint16 countryCode, uint8 entityType, address impl) external;

    /// @notice Fetch the full rule list for a jurisdiction.
    function getRules(uint16 countryCode, uint8 entityType) external view returns (RuleConfig[] memory);

    function isApprovedFor(uint16 countryCode, uint8 entityType, address impl) external view returns (bool);
}
