// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./CompanyStorage.sol";
import {RuleCloning} from "../libraries/RuleCloning.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {IRuleRegistry} from "../interfaces/rules/IRuleRegistry.sol";

/// @dev Minimal surface of CMTAT's RuleEngine we need, avoids pulling the concrete contract into Company's dependency graph.
interface IRuleEngineOperator {
    function addRuleValidation(IRuleValidation rule_) external;
    function removeRuleValidation(IRuleValidation rule_, uint256 index) external;
    function getRuleIndexValidation(IRuleValidation rule_) external view returns (uint256);
}

/// @title CompanyShareClasses
/// @notice Handles share class creation + rule attach/detach.
abstract contract CompanyShareClasses is CompanyStorage {
    uint8 public constant MAX_SHARE_CLASSES = 10;

    event ShareClassCreated(
        string indexed className,
        address indexed token,
        uint256 authorizedShares,
        uint32 liquidationPreference,
        uint8 votingWeight,
        uint256 parValue,
        string documentRef
    );
    event ShareClassAuthorizedSharesIncreased(
        string indexed className, uint256 previousAmount, uint256 newAmount, string documentRef
    );
    event RuleDeployed(address indexed token, address indexed clone, address indexed impl, string className);
    event RuleDetached(address indexed token, address indexed clone, address indexed impl, string className);

    error RuleNotCloneable(address rule);
    error RuleNotApprovedForJurisdiction(address rule, uint16 countryCode, uint8 entityType);
    error RuleAlreadyAttached(address rule);
    error RuleNotAttached(address rule);

    // ============================================================
    // Share-class lifecycle
    // ============================================================

    /// @notice Deploy a new ShareToken and register it as a share class
    /// @param className Name of the share class (e.g., "Preferred Series A", "Class B")
    /// @param tokenName Full token name (e.g., "Acme Corp Preferred A")
    /// @param tokenSymbol Token symbol (e.g., "ACME-PA")
    /// @param authorizedShares Initial authorized shares for this class
    /// @param liquidationPreference Liquidation preference multiplier (1e6 = 1x, 1.5e6 = 1.5x, 2e6 = 2x)
    /// @param votingWeight Voting weight multiplier (1 = 1x, 10 = 10x super-voting, 0 = non-voting)
    /// @param parValue Par/nominal value per share in wei (0 = no-par, required in UK/CH/DE)
    function createShareClassWithToken(
        string memory className,
        string memory tokenName,
        string memory tokenSymbol,
        uint256 authorizedShares,
        uint32 liquidationPreference,
        uint8 votingWeight,
        uint256 parValue,
        string calldata documentRef
    ) external payable onlyBoard {
        if (authorizedShares == 0) revert InvalidInput();

        address tokenAddress = factory.deployShareClass{value: msg.value}(
            authorizedShares,
            tokenName,
            tokenSymbol,
            board // Company address becomes admin
        );

        _createShareClass(
            className, ShareToken(tokenAddress), liquidationPreference, votingWeight, parValue, documentRef
        );
    }

    /// @notice Increase authorized shares for a specific share class
    /// @param className The share class name
    /// @param amount The amount to increase by
    /// @param documentRef Optional doc (obolos:// URI or hash) authorizing the increase
    function increaseAuthorizedShares(string memory className, uint256 amount, string calldata documentRef)
        external
        onlyBoard
    {
        if (amount == 0) revert ZeroAmount();
        if (address(shares[className].token) == address(0)) revert NotFound();

        ShareClass storage class = shares[className];
        uint256 previousAmount = class.token.authorizedShares();
        class.token.increaseAuthorizedShares(amount);

        emit ShareClassAuthorizedSharesIncreased(className, previousAmount, class.token.authorizedShares(), documentRef);
    }

    // ============================================================
    // Compliance rules
    // ============================================================

    /// @notice Deploy a fresh clone of a cloneable rule impl and attach it to a share class's RuleEngine.
    /// @param className Share class to attach the new rule to
    /// @param impl Cloneable rule implementation
    /// @param initData ABI-encoded args forwarded to the clone's `initialize`
    /// @return clone Address of the freshly-deployed, initialized, and attached rule instance
    function deployAndAttachRule(string memory className, address impl, bytes calldata initData)
        external
        onlyBoard
        returns (address clone)
    {
        ShareToken token = shares[className].token;
        if (address(token) == address(0)) revert NotFound();
        if (impl == address(0)) revert ZeroAddress();
        if (!RuleCloning.supportsRuleCloneable(impl)) revert RuleNotCloneable(impl);

        IRuleRegistry registry = factory.ruleRegistry();
        if (address(registry) != address(0) && !registry.isApprovedFor(countryCode, entityType, impl)) {
            revert RuleNotApprovedForJurisdiction(impl, countryCode, entityType);
        }

        if (attachedRules[address(token)][impl] != address(0)) revert RuleAlreadyAttached(impl);

        clone = RuleCloning.cloneAndInitialize(impl, initData, address(this));
        IRuleEngineOperator(address(token.ruleEngine())).addRuleValidation(IRuleValidation(clone));
        attachedRules[address(token)][impl] = clone;

        emit RuleDeployed(address(token), clone, impl, className);
    }

    /// @notice Detach a previously-attached rule clone from a share class.
    /// @param className Share class the rule is attached to
    /// @param impl The rule implementation whose clone should be removed
    function detachRule(string memory className, address impl) external onlyBoard {
        ShareToken token = shares[className].token;
        if (address(token) == address(0)) revert NotFound();

        address clone = attachedRules[address(token)][impl];
        if (clone == address(0)) revert RuleNotAttached(impl);

        IRuleEngineOperator engine = IRuleEngineOperator(address(token.ruleEngine()));
        engine.removeRuleValidation(IRuleValidation(clone), engine.getRuleIndexValidation(IRuleValidation(clone)));
        delete attachedRules[address(token)][impl];

        emit RuleDetached(address(token), clone, impl, className);
    }

    // ============================================================
    // Internal
    // ============================================================

    function _createShareClass(
        string memory className,
        ShareToken token,
        uint32 liquidationPreference,
        uint8 votingWeight,
        uint256 parValue,
        string memory documentRef
    ) internal {
        if (bytes(className).length == 0) revert InvalidInput();
        if (address(token) == address(0)) revert ZeroAddress();
        if (address(shares[className].token) != address(0)) revert AlreadyExists();
        if (shareClassNames.length >= MAX_SHARE_CLASSES) revert InsufficientCapacity();

        shares[className] = ShareClass({
            className: className,
            token: token,
            liquidationPreference: liquidationPreference,
            votingWeight: votingWeight,
            parValue: parValue
        });

        shareClassNames.push(className);
        shareholderRegistry.registerToken(address(token));

        emit ShareClassCreated(
            className,
            address(token),
            token.authorizedShares(),
            liquidationPreference,
            votingWeight,
            parValue,
            documentRef
        );
    }

    // ============================================================
    // Views
    // ============================================================

    /// @notice Get a share class by name
    function getShareClass(string memory className) external view returns (ShareClass memory) {
        return shares[className];
    }

    /// @notice Get all share class names
    function getShareClassNames() external view returns (string[] memory) {
        return shareClassNames;
    }

    /// @notice Get the count of share classes
    function getShareClassCount() external view returns (uint256) {
        return shareClassNames.length;
    }

    /// @inheritdoc ICompany
    function getShareToken(string memory className) external view returns (ShareToken) {
        if (address(shares[className].token) == address(0)) revert NotFound();
        return shares[className].token;
    }

    /// @inheritdoc ICompany
    /// @dev Used for SAFE conversion calculations (post-money SAFE formula).
    function getTotalSharesOutstanding() public view returns (uint256 total) {
        uint256 len = shareClassNames.length;
        for (uint256 i = 0; i < len; i++) {
            total += shares[shareClassNames[i]].token.totalSupply();
        }
    }

    /// @inheritdoc ICompany
    /// @dev Includes: minted shares (incl. vesting), full option-pool reservation, granted-but-unexercised options.
    ///      Excludes: unconverted SAFEs/Notes (share count unknown until a priced round sets the price).
    ///      For pro-forma estimates that include convertibles, make cap-based assumptions off-chain.
    function getFullyDilutedShares() public view returns (uint256 total) {
        uint256 len = shareClassNames.length;
        for (uint256 i = 0; i < len; i++) {
            address token = address(shares[shareClassNames[i]].token);
            total += ShareToken(token).totalSupply();
            total += optionPool.getPoolSize(token);
            total += optionPool.getOutstandingOptions(token);
        }
    }
}
