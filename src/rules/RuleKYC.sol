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
import {IRuleKYC} from "../interfaces/rules/IRuleKYC.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {Attestation} from "@eas/contracts/Common.sol";

/// @title RuleKYC
/// @notice Transfer restriction rule that requires recipients to have valid KYC attestations
contract RuleKYC is Initializable, ERC165, RuleValidateTransfer, RuleCommonInvariantStorage, IRuleCloneable, IRuleKYC {
    string public constant VERSION = "0.9.0";

    uint8 public constant CODE_RECIPIENT_NOT_VERIFIED = 20;
    uint8 public constant CODE_ATTESTATION_EXPIRED = 21;
    uint8 public constant CODE_ATTESTATION_REVOKED = 22;
    uint8 public constant CODE_INSUFFICIENT_KYC_LEVEL = 23;
    uint8 public constant CODE_SCHEMA_MISMATCH = 24;
    uint8 public constant CODE_SANCTIONS_NOT_CLEARED = 25;

    ICompany public company;
    ProviderRegistry public registry;
    bytes32 public idSchema;
    uint8 public requiredKycLevel;

    event RequiredKycLevelUpdated(uint8 oldLevel, uint8 newLevel);

    error OnlyBoard();
    error InvalidKycLevel();
    error ZeroAddress();
    error ZeroSchema();

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRuleCloneable
    /// @param initData `abi.encode(address providerRegistry, bytes32 idSchema, uint8 requiredKycLevel)`
    /// @param _company Company contract (board queried dynamically)
    function initialize(bytes calldata initData, address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();

        (address _registry, bytes32 _idSchema, uint8 _requiredKycLevel) =
            abi.decode(initData, (address, bytes32, uint8));

        if (_registry == address(0)) revert ZeroAddress();
        if (_idSchema == bytes32(0)) revert ZeroSchema();
        if (_requiredKycLevel > ShareholderSchemas.KYC_ENHANCED) revert InvalidKycLevel();

        company = ICompany(_company);
        registry = ProviderRegistry(_registry);
        idSchema = _idSchema;
        requiredKycLevel = _requiredKycLevel;
    }

    /// @dev Advertises {IRuleCloneable} (for the registry's publish probe) and {IRuleKYC} (for callers
    ///      that want to detect rule type via ERC-165 rather than by probing method names).
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IRuleCloneable).interfaceId || interfaceId == type(IRuleKYC).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Update the required KYC level
    /// @param _requiredKycLevel New minimum KYC level (0=None, 1=Basic, 2=Enhanced)
    function setRequiredKycLevel(uint8 _requiredKycLevel) external onlyBoard {
        if (_requiredKycLevel > ShareholderSchemas.KYC_ENHANCED) revert InvalidKycLevel();
        uint8 oldLevel = requiredKycLevel;
        requiredKycLevel = _requiredKycLevel;
        emit RequiredKycLevelUpdated(oldLevel, _requiredKycLevel);
    }

    /// @notice Check if an address has a valid KYC attestation at the required level
    /// @param account Address to check
    /// @return True if the address has a valid, non-expired, non-revoked attestation at required level
    function isVerified(address account) public view returns (bool) {
        return _checkVerification(account) == uint8(REJECTED_CODE_BASE.TRANSFER_OK);
    }

    /// @notice Get detailed verification status
    /// @param account Address to check
    /// @return code Restriction code (TRANSFER_OK if verified)
    /// @return kycLevel The account's KYC level (0 == rule off)
    function getVerificationStatus(address account) external view returns (uint8 code, uint8 kycLevel) {
        if (requiredKycLevel == 0) return (uint8(REJECTED_CODE_BASE.TRANSFER_OK), 0);

        bytes32 uid = registry.getAttestation(idSchema, account);
        if (uid == bytes32(0)) {
            return (CODE_RECIPIENT_NOT_VERIFIED, 0);
        }

        Attestation memory att = IEAS(registry.eas()).getAttestation(uid);

        if (att.schema != idSchema) {
            return (CODE_SCHEMA_MISMATCH, 0);
        }

        if (att.revocationTime != 0) {
            return (CODE_ATTESTATION_REVOKED, 0);
        }

        if (att.expirationTime != 0 && att.expirationTime < block.timestamp) {
            return (CODE_ATTESTATION_EXPIRED, 0);
        }

        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.decodeIdentity(att.data);

        if (data.kycLevel < requiredKycLevel) {
            return (CODE_INSUFFICIENT_KYC_LEVEL, data.kycLevel);
        }

        if (!data.sanctionsCleared) {
            return (CODE_SANCTIONS_NOT_CLEARED, data.kycLevel);
        }

        return (uint8(REJECTED_CODE_BASE.TRANSFER_OK), data.kycLevel);
    }

    /// @notice Internal verification check returning restriction code
    /// @param account Address to check
    /// @return Restriction code
    function _checkVerification(address account) internal view returns (uint8) {
        if (requiredKycLevel == 0) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);

        bytes32 uid = registry.getAttestation(idSchema, account);
        if (uid == bytes32(0)) {
            return CODE_RECIPIENT_NOT_VERIFIED;
        }

        Attestation memory att = IEAS(registry.eas()).getAttestation(uid);

        if (att.schema != idSchema) {
            return CODE_SCHEMA_MISMATCH;
        }

        if (att.revocationTime != 0) {
            return CODE_ATTESTATION_REVOKED;
        }

        if (att.expirationTime != 0 && att.expirationTime < block.timestamp) {
            return CODE_ATTESTATION_EXPIRED;
        }

        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.decodeIdentity(att.data);

        if (data.kycLevel < requiredKycLevel) {
            return CODE_INSUFFICIENT_KYC_LEVEL;
        }

        if (!data.sanctionsCleared) {
            return CODE_SANCTIONS_NOT_CLEARED;
        }

        return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
    }

    /// @notice Detect transfer restriction based on KYC status
    /// @param from Origin address (not checked - sender doesn't need KYC to send)
    /// @param to Destination address (must have valid KYC to receive)
    /// @param value Amount to transfer (not used)
    /// @return restrictionCode Restriction code or TRANSFER_OK
    function detectTransferRestriction(address from, address to, uint256 value) public view override returns (uint8) {
        (from, value);
        // Skip check for burns
        if (to == address(0)) {
            return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
        }
        return _checkVerification(to);
    }

    /// @notice Detect transfer restriction for transferFrom
    /// @param spender Address initiating the transfer (not checked)
    /// @param from Origin address
    /// @param to Destination address
    /// @param value Amount to transfer
    /// @return restrictionCode Same as detectTransferRestriction
    function detectTransferRestrictionFrom(address spender, address from, address to, uint256 value)
        public
        view
        override
        returns (uint8)
    {
        (spender);
        return detectTransferRestriction(from, to, value);
    }

    /// @notice Check if this rule can return the given restriction code
    /// @param restrictionCode Code to check
    /// @return True if this rule uses the code
    function canReturnTransferRestrictionCode(uint8 restrictionCode) external pure override returns (bool) {
        return restrictionCode == CODE_RECIPIENT_NOT_VERIFIED || restrictionCode == CODE_ATTESTATION_EXPIRED
            || restrictionCode == CODE_ATTESTATION_REVOKED || restrictionCode == CODE_INSUFFICIENT_KYC_LEVEL
            || restrictionCode == CODE_SCHEMA_MISMATCH || restrictionCode == CODE_SANCTIONS_NOT_CLEARED;
    }

    /// @notice Get the message for a restriction code
    /// @param restrictionCode Code to get message for
    /// @return message Human-readable error message
    function messageForTransferRestriction(uint8 restrictionCode)
        external
        pure
        override
        returns (string memory message)
    {
        if (restrictionCode == CODE_RECIPIENT_NOT_VERIFIED) {
            return "Recipient does not have KYC verification";
        }
        if (restrictionCode == CODE_ATTESTATION_EXPIRED) {
            return "KYC attestation has expired";
        }
        if (restrictionCode == CODE_ATTESTATION_REVOKED) {
            return "KYC attestation has been revoked";
        }
        if (restrictionCode == CODE_INSUFFICIENT_KYC_LEVEL) {
            return "Recipient KYC level is insufficient";
        }
        if (restrictionCode == CODE_SCHEMA_MISMATCH) {
            return "Attestation schema mismatch";
        }
        if (restrictionCode == CODE_SANCTIONS_NOT_CLEARED) {
            return "Recipient sanctions not cleared";
        }
        return TEXT_CODE_NOT_FOUND;
    }
}
