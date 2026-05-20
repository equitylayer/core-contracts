// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IRuleRegistry} from "./interfaces/rules/IRuleRegistry.sol";
import {RuleCloning} from "./libraries/RuleCloning.sol";

/// @title RuleRegistry
/// @notice Protocol-level registry of compliance rules keyed by `(countryCode, entityType)`.
contract RuleRegistry is IRuleRegistry, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    string public constant VERSION = "0.9.0";
    uint256 public constant MAX_RULES = 20;

    mapping(uint16 => mapping(uint8 => RuleConfig[])) private _rules;

    error ZeroAddress();
    error InvalidJurisdiction();
    error TooManyRules();
    error NotAContract();
    error DuplicateRule(address impl);
    error NotCloneable(address impl);
    error RuleNotFound(address impl);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the registry
    /// @param _owner Protocol admin that can set rule sets
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
    }

    /// @inheritdoc IRuleRegistry
    function setRules(uint16 countryCode, uint8 entityType, RuleConfig[] calldata rules) external onlyOwner {
        if (countryCode == 0) revert InvalidJurisdiction();
        if (rules.length > MAX_RULES) revert TooManyRules();

        // Validate before touching storage so partial writes aren't possible.
        for (uint256 i = 0; i < rules.length; i++) {
            _validateRule(rules[i].impl);
            for (uint256 j = 0; j < i; j++) {
                if (rules[j].impl == rules[i].impl) revert DuplicateRule(rules[i].impl);
            }
        }

        delete _rules[countryCode][entityType];
        RuleConfig[] storage stored = _rules[countryCode][entityType];
        for (uint256 i = 0; i < rules.length; i++) {
            stored.push(rules[i]);
        }

        emit RulesSet(countryCode, entityType, rules);
    }

    /// @inheritdoc IRuleRegistry
    function addRule(uint16 countryCode, uint8 entityType, RuleConfig calldata rule) external onlyOwner {
        if (countryCode == 0) revert InvalidJurisdiction();
        _validateRule(rule.impl);

        RuleConfig[] storage list = _rules[countryCode][entityType];
        if (list.length >= MAX_RULES) revert TooManyRules();
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].impl == rule.impl) revert DuplicateRule(rule.impl);
        }

        list.push(rule);
        emit RuleAdded(countryCode, entityType, rule.impl);
    }

    /// @inheritdoc IRuleRegistry
    function removeRule(uint16 countryCode, uint8 entityType, address impl) external onlyOwner {
        RuleConfig[] storage list = _rules[countryCode][entityType];

        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i].impl == impl) {
                if (i != len - 1) {
                    list[i] = list[len - 1];
                }
                list.pop();
                emit RuleRemoved(countryCode, entityType, impl);
                return;
            }
        }
        revert RuleNotFound(impl);
    }

    /// @inheritdoc IRuleRegistry
    function getRules(uint16 countryCode, uint8 entityType) external view returns (RuleConfig[] memory) {
        return _rules[countryCode][entityType];
    }

    /// @inheritdoc IRuleRegistry
    function isApprovedFor(uint16 countryCode, uint8 entityType, address impl) external view returns (bool) {
        RuleConfig[] storage list = _rules[countryCode][entityType];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].impl == impl) return true;
        }
        return false;
    }

    /// @dev Per-impl validation: contract check + IRuleCloneable advertisement.
    function _validateRule(address impl) internal view {
        if (impl == address(0)) revert ZeroAddress();
        if (impl.code.length == 0) revert NotAContract();
        if (!RuleCloning.supportsRuleCloneable(impl)) revert NotCloneable(impl);
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Reserved storage for future variables without shifting slot layout.
    uint256[48] private __gap;
}
