// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {RuleValidateTransfer} from "Rules/rules/validation/abstract/RuleValidateTransfer.sol";
import {RuleCommonInvariantStorage} from "Rules/rules/validation/abstract/RuleCommonInvariantStorage.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ICompany} from "../interfaces/ICompany.sol";
import {IRuleCloneable} from "../interfaces/rules/IRuleCloneable.sol";
import {IRuleOFAC} from "../interfaces/rules/IRuleOFAC.sol";

interface ISanctionsOracle {
    function isSanctioned(address addr) external view returns (bool);
}

/// @title RuleOFAC
/// @notice Per-company sanctions screening rule. Backed by an external oracle (typically Chainalysis).
contract RuleOFAC is
    Initializable,
    ERC165,
    RuleValidateTransfer,
    RuleCommonInvariantStorage,
    IRuleCloneable,
    IRuleOFAC
{
    string public constant VERSION = "0.9.0";

    uint8 public constant CODE_ADDRESS_FROM_IS_SANCTIONED = 31;
    uint8 public constant CODE_ADDRESS_TO_IS_SANCTIONED = 32;
    uint8 public constant CODE_ADDRESS_SPENDER_IS_SANCTIONED = 33;

    ICompany public company;
    ISanctionsOracle public oracle;

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    error OnlyBoard();
    error ZeroAddress();

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRuleCloneable
    /// @param initData `abi.encode(address oracle)`. Oracle may be zero — sanctions then inactive until the board sets one.
    /// @param _company Company contract; board is queried dynamically so rotations take effect immediately.
    function initialize(bytes calldata initData, address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();
        address _oracle = abi.decode(initData, (address));

        company = ICompany(_company);
        oracle = ISanctionsOracle(_oracle);
        emit OracleUpdated(address(0), _oracle);
    }

    /// @notice Update (or disable) the sanctions oracle for this share class.
    /// @param newOracle New oracle address. `address(0)` disables sanctions checks — all addresses pass.
    function setOracle(address newOracle) external onlyBoard {
        address old = address(oracle);
        oracle = ISanctionsOracle(newOracle);
        emit OracleUpdated(old, newOracle);
    }

    /// @notice Check if the `from`/`to` pair would be blocked by the sanctions oracle.
    /// @return restrictionCode One of CODE_ADDRESS_FROM/TO_IS_SANCTIONED, or TRANSFER_OK.
    function detectTransferRestriction(address from, address to, uint256 value) public view override returns (uint8) {
        value;
        if (address(oracle) == address(0)) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
        if (oracle.isSanctioned(from)) return CODE_ADDRESS_FROM_IS_SANCTIONED;
        if (oracle.isSanctioned(to)) return CODE_ADDRESS_TO_IS_SANCTIONED;
        return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
    }

    /// @notice Same as `detectTransferRestriction` plus a check that the `spender` is not sanctioned.
    function detectTransferRestrictionFrom(address spender, address from, address to, uint256 value)
        public
        view
        override
        returns (uint8)
    {
        if (address(oracle) == address(0)) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
        if (oracle.isSanctioned(spender)) return CODE_ADDRESS_SPENDER_IS_SANCTIONED;
        return detectTransferRestriction(from, to, value);
    }

    /// @notice Check if this rule can return the given restriction code.
    function canReturnTransferRestrictionCode(uint8 restrictionCode) external pure override returns (bool) {
        return restrictionCode == CODE_ADDRESS_FROM_IS_SANCTIONED || restrictionCode == CODE_ADDRESS_TO_IS_SANCTIONED
            || restrictionCode == CODE_ADDRESS_SPENDER_IS_SANCTIONED;
    }

    /// @notice Human-readable message for a restriction code.
    function messageForTransferRestriction(uint8 restrictionCode) external pure override returns (string memory) {
        if (restrictionCode == CODE_ADDRESS_FROM_IS_SANCTIONED) return "The sender is sanctioned";
        if (restrictionCode == CODE_ADDRESS_TO_IS_SANCTIONED) return "The recipient is sanctioned";
        if (restrictionCode == CODE_ADDRESS_SPENDER_IS_SANCTIONED) return "The spender is sanctioned";
        return TEXT_CODE_NOT_FOUND;
    }

    /// @dev Advertises {IRuleCloneable} (so RuleRegistry's publish probe accepts this impl)
    ///      and {IRuleOFAC} (so callers can detect rule type via ERC-165 rather than by probing
    ///      method names, which is brittle when different rules share method shapes).
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IRuleCloneable).interfaceId || interfaceId == type(IRuleOFAC).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @dev Reserved storage for future variables (e.g. per-address allowlist overrides) without
    ///      shifting slot layout on the implementation or existing clones.
    uint256[49] private __gap;
}
