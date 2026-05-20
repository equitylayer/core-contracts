// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {RuleValidateTransfer} from "Rules/rules/validation/abstract/RuleValidateTransfer.sol";
import {RuleCommonInvariantStorage} from "Rules/rules/validation/abstract/RuleCommonInvariantStorage.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ProviderRegistry} from "../attestations/ProviderRegistry.sol";
import {ShareholderSchemas} from "../attestations/ShareholderSchemas.sol";
import {ICompany} from "../interfaces/ICompany.sol";
import {IRuleCloneable} from "../interfaces/rules/IRuleCloneable.sol";
import {IRuleRegS} from "../interfaces/rules/IRuleRegS.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {Attestation} from "@eas/contracts/Common.sol";

/// @title RuleRegS
/// @notice Enforces Reg S offshore-offering restrictions during a distribution-compliance period.
/// @dev During the period (`block.timestamp < complianceEnd`), transfers to US persons are blocked.
///      After the period, the rule becomes a no-op — Reg S shares are "seasoned" and freely
///      transferable. Fail-closed during the window: recipients without a valid D01Identity
///      attestation are rejected, since we can't verify non-US status.
///      Category timings (admin's responsibility to pick the right `complianceEnd`):
///        - Cat 1: 40 days from offering close
///        - Cat 2: 40 days
///        - Cat 3 (reporting issuer): 6 months; (non-reporting): 1 year
contract RuleRegS is
    Initializable,
    ERC165,
    RuleValidateTransfer,
    RuleCommonInvariantStorage,
    IRuleCloneable,
    IRuleRegS
{
    string public constant VERSION = "0.9.0";

    uint8 public constant CODE_RECIPIENT_IS_US_PERSON = 55;
    uint8 public constant CODE_RECIPIENT_NOT_VERIFIED = 56;
    uint8 public constant CODE_ATTESTATION_REVOKED = 57;
    uint8 public constant CODE_SCHEMA_MISMATCH = 58;
    uint8 public constant CODE_ATTESTATION_EXPIRED = 59;

    ICompany public company;
    ProviderRegistry public registry;
    bytes32 public idSchema;
    /// @notice Timestamp after which the rule becomes a no-op (distribution-compliance period ends).
    uint64 public complianceEnd;

    event ComplianceEndUpdated(uint64 oldEnd, uint64 newEnd);

    error OnlyBoard();
    error ZeroAddress();
    error ZeroSchema();
    error InvalidComplianceEnd();

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRuleCloneable
    /// @param initData `abi.encode(address providerRegistry, bytes32 idSchema, uint64 complianceEnd)`
    function initialize(bytes calldata initData, address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();

        (address _registry, bytes32 _idSchema, uint64 _complianceEnd) = abi.decode(initData, (address, bytes32, uint64));

        if (_registry == address(0)) revert ZeroAddress();
        if (_idSchema == bytes32(0)) revert ZeroSchema();
        if (_complianceEnd == 0) revert InvalidComplianceEnd();

        company = ICompany(_company);
        registry = ProviderRegistry(_registry);
        idSchema = _idSchema;
        complianceEnd = _complianceEnd;
    }

    /// @dev Advertises {IRuleCloneable} and {IRuleRegS}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IRuleCloneable).interfaceId || interfaceId == type(IRuleRegS).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ============ Board management ============

    /// @notice Adjust the distribution-compliance period end (e.g., extend if offering window shifts).
    function setComplianceEnd(uint64 newEnd) external onlyBoard {
        if (newEnd == 0) revert InvalidComplianceEnd();
        uint64 old = complianceEnd;
        complianceEnd = newEnd;
        emit ComplianceEndUpdated(old, newEnd);
    }

    // ============ Views ============

    /// @notice True if the distribution-compliance period is still active.
    function isActive() public view returns (bool) {
        return block.timestamp < complianceEnd;
    }

    // ============ Transfer validation ============

    /// @notice Reject transfers to US persons during the compliance period.
    function detectTransferRestriction(address from, address to, uint256 value) public view override returns (uint8) {
        (from, value);
        // Burns are unaffected.
        if (to == address(0)) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
        // Post-compliance: Reg S shares are seasoned → rule is a no-op.
        if (!isActive()) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);

        bytes32 uid = registry.getAttestation(idSchema, to);
        if (uid == bytes32(0)) return CODE_RECIPIENT_NOT_VERIFIED;

        Attestation memory att = IEAS(registry.eas()).getAttestation(uid);
        if (att.schema != idSchema) return CODE_SCHEMA_MISMATCH;
        if (att.revocationTime != 0) return CODE_ATTESTATION_REVOKED;
        if (att.expirationTime != 0 && att.expirationTime < block.timestamp) return CODE_ATTESTATION_EXPIRED;

        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.decodeIdentity(att.data);
        if (data.isUSPerson) return CODE_RECIPIENT_IS_US_PERSON;

        return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
    }

    /// @notice Same as `detectTransferRestriction`; spender residency isn't part of the Reg S test.
    function detectTransferRestrictionFrom(address spender, address from, address to, uint256 value)
        public
        view
        override
        returns (uint8)
    {
        spender;
        return detectTransferRestriction(from, to, value);
    }

    function canReturnTransferRestrictionCode(uint8 restrictionCode) external pure override returns (bool) {
        return restrictionCode == CODE_RECIPIENT_IS_US_PERSON || restrictionCode == CODE_RECIPIENT_NOT_VERIFIED
            || restrictionCode == CODE_ATTESTATION_REVOKED || restrictionCode == CODE_SCHEMA_MISMATCH
            || restrictionCode == CODE_ATTESTATION_EXPIRED;
    }

    function messageForTransferRestriction(uint8 restrictionCode) external pure override returns (string memory) {
        if (restrictionCode == CODE_RECIPIENT_IS_US_PERSON) return "Reg S: recipient is a US person";
        if (restrictionCode == CODE_RECIPIENT_NOT_VERIFIED) return "Reg S: recipient identity not verified";
        if (restrictionCode == CODE_ATTESTATION_REVOKED) return "Reg S: identity attestation has been revoked";
        if (restrictionCode == CODE_ATTESTATION_EXPIRED) return "Reg S: identity attestation has expired";
        if (restrictionCode == CODE_SCHEMA_MISMATCH) return "Attestation schema mismatch";
        return TEXT_CODE_NOT_FOUND;
    }

    /// @dev Reserved storage for future variables without shifting slot layout.
    uint256[48] private __gap;
}
