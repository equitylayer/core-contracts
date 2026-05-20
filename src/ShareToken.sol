// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

// CMTAT core (light): no DocumentEngine, no ERC20Enforcement/ERC-7943, no ExtraInformation
import {CMTATBaseCore} from "CMTAT/contracts/modules/0_CMTATBaseCore.sol";
import {SnapshotEngineModule} from "CMTAT/contracts/modules/wrapper/extensions/SnapshotEngineModule.sol";
import {
    ValidationModuleRuleEngine
} from "CMTAT/contracts/modules/wrapper/extensions/ValidationModule/ValidationModuleRuleEngine.sol";
import {ICMTATConstructor} from "CMTAT/contracts/interfaces/technical/ICMTATConstructor.sol";
import {ISnapshotEngine} from "CMTAT/contracts/interfaces/engine/ISnapshotEngine.sol";
import "CMTAT/contracts/interfaces/engine/IRuleEngine.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BaseModule} from "CMTAT/contracts/modules/wrapper/core/ERC20BaseModule.sol";
import {ERC20MintModuleInternal} from "CMTAT/contracts/modules/internal/ERC20MintModuleInternal.sol";
import {ERC20BurnModuleInternal} from "CMTAT/contracts/modules/internal/ERC20BurnModuleInternal.sol";
import {ValidationModuleCore} from "CMTAT/contracts/modules/wrapper/core/ValidationModuleCore.sol";
import {ShareholderRegistry} from "./ShareholderRegistry.sol";

/// @title ShareToken
/// @notice CMTAT-based security token with snapshots and compliance
/// @dev Extends CMTATBaseCore (light) + SnapshotEngineModule + ValidationModuleRuleEngine.
contract ShareToken is CMTATBaseCore, SnapshotEngineModule, ValidationModuleRuleEngine {
    string public constant VERSION = "0.9.0";

    error OnlyCompany();
    error OnlyIssuance();
    error ZeroAddress();
    error InvalidParameter();
    error ExceedsAuthorizedShares();
    error CompanyAddressLocked();
    error IssuanceAddressLocked();

    uint256 public authorizedShares;
    address public companyAddress;
    address public issuanceAddress;
    ShareholderRegistry public shareholderRegistry;
    bool public companyAddressLocked;
    bool public issuanceAddressLocked;

    event AuthorizedSharesIncreased(uint256 indexed previousAmount, uint256 indexed newAmount);
    event SharesIssued(address indexed to, uint256 indexed amount);
    event CompanyAddressUpdated(address indexed previous, address indexed next);
    event IssuanceAddressUpdated(address indexed previous, address indexed next);

    modifier onlyCompany() {
        if (msg.sender != companyAddress) revert OnlyCompany();
        _;
    }

    modifier onlyIssuance() {
        if (msg.sender != issuanceAddress) revert OnlyIssuance();
        _;
    }

    // ===== INITIALIZATION =====

    /// @notice Initialize the ShareToken (replaces constructor for EIP-1167 clones)
    function initialize(
        address _companyAddress,
        string memory _name,
        string memory _symbol,
        uint256 _initialAuthorizedShares,
        ISnapshotEngine _snapshotEngine,
        IRuleEngine _ruleEngine,
        ShareholderRegistry _shareholderRegistry
    ) external initializer {
        if (_companyAddress == address(0)) revert ZeroAddress();
        if (address(_snapshotEngine) == address(0)) revert ZeroAddress();
        if (address(_ruleEngine) == address(0)) revert ZeroAddress();
        if (address(_shareholderRegistry) == address(0)) revert ZeroAddress();
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert InvalidParameter();

        // Core CMTAT init (ERC20 + AccessControl + Pause/Enforce)
        __CMTAT_init(
            _companyAddress, ICMTATConstructor.ERC20Attributes({name: _name, symbol: _symbol, decimalsIrrevocable: 6})
        );

        __ValidationRuleEngine_init_unchained(_ruleEngine);
        __SnapshotEngineModule_init_unchained(_snapshotEngine);

        authorizedShares = _initialAuthorizedShares;
        companyAddress = _companyAddress;
        shareholderRegistry = _shareholderRegistry;
    }

    // ===== CAPITALIZATION =====

    function increaseAuthorizedShares(uint256 sharesToAdd) external onlyCompany {
        if (sharesToAdd == 0) revert InvalidParameter();
        uint256 previousAmount = authorizedShares;
        authorizedShares += sharesToAdd;
        emit AuthorizedSharesIncreased(previousAmount, authorizedShares);
    }

    function issueShares(address to, uint256 amount) external onlyIssuance {
        mint(to, amount);
        emit SharesIssued(to, amount);
    }

    function setCompanyAddress(address newCompanyAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (companyAddressLocked) revert CompanyAddressLocked();
        if (newCompanyAddress == address(0)) revert ZeroAddress();
        address previous = companyAddress;
        companyAddress = newCompanyAddress;
        companyAddressLocked = true;
        emit CompanyAddressUpdated(previous, newCompanyAddress);
    }

    /// @notice Set the EquityIssuance address authorized to mint. One time and lock.
    function setIssuanceAddress(address newIssuanceAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (issuanceAddressLocked) revert IssuanceAddressLocked();
        if (newIssuanceAddress == address(0)) revert ZeroAddress();
        address previous = issuanceAddress;
        issuanceAddress = newIssuanceAddress;
        issuanceAddressLocked = true;
        emit IssuanceAddressUpdated(previous, newIssuanceAddress);
    }

    // ===== TRANSFER OVERRIDES =====
    function transfer(address to, uint256 value) public virtual override returns (bool) {
        address from = _msgSender();
        _transferred(address(0), from, to, value);
        ERC20Upgradeable._transfer(from, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        _transferred(_msgSender(), from, to, value);
        return ERC20BaseModule.transferFrom(from, to, value);
    }

    function approve(address spender, uint256 value) public virtual override whenNotPaused returns (bool) {
        return ERC20Upgradeable.approve(spender, value);
    }

    function canTransfer(address from, address to, uint256 value)
        public
        view
        virtual
        override(ValidationModuleCore, ValidationModuleRuleEngine)
        returns (bool)
    {
        return ValidationModuleRuleEngine.canTransfer(from, to, value);
    }

    function canTransferFrom(address spender, address from, address to, uint256 value)
        public
        view
        virtual
        override(ValidationModuleCore, ValidationModuleRuleEngine)
        returns (bool)
    {
        return ValidationModuleRuleEngine.canTransferFrom(spender, from, to, value);
    }

    // ===== MINT/BURN OVERRIDES =====

    function _mintOverride(address account, uint256 value) internal virtual override {
        _transferred(address(0), address(0), account, value);
        ERC20MintModuleInternal._mintOverride(account, value);
    }

    function _burnOverride(address account, uint256 value) internal virtual override {
        _transferred(address(0), account, address(0), value);
        ERC20BurnModuleInternal._burnOverride(account, value);
    }

    function _minterTransferOverride(address from, address to, uint256 value) internal virtual override {
        _transferred(address(0), from, to, value);
        ERC20MintModuleInternal._minterTransferOverride(from, to, value);
    }

    // ===== SNAPSHOT + SHAREHOLDER REGISTRY =====

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) && totalSupply() + value > authorizedShares) revert ExceedsAuthorizedShares();

        // Snapshot hook: record balances before transfer
        ISnapshotEngine snapshotEngineLocal = snapshotEngine();
        if (address(snapshotEngineLocal) != address(0)) {
            uint256 fromBalanceBefore = balanceOf(from);
            uint256 toBalanceBefore = balanceOf(to);
            uint256 totalSupplyBefore = totalSupply();
            ERC20Upgradeable._update(from, to, value);
            snapshotEngineLocal.operateOnTransfer(from, to, fromBalanceBefore, toBalanceBefore, totalSupplyBefore);
        } else {
            ERC20Upgradeable._update(from, to, value);
        }

        shareholderRegistry.updateOnTransfer(
            address(this), from, to, from == address(0) ? 0 : balanceOf(from), to == address(0) ? 0 : balanceOf(to)
        );
    }

    // ===== ACCESS CONTROL =====

    function _authorizeRuleEngineManagement() internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
    function _authorizeSnapshots() internal virtual override onlyRole(SNAPSHOOTER_ROLE) {}
}
