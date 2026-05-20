// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {
    IEAS,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "@eas/contracts/IEAS.sol";
import {Attestation} from "@eas/contracts/Common.sol";
import {ISchemaRegistry} from "@eas/contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "@eas/contracts/resolver/ISchemaResolver.sol";
import {ProviderRegistry} from "./ProviderRegistry.sol";
import {ShareholderSchemas} from "./ShareholderSchemas.sol";
import {IAttestationProvider} from "../interfaces/IAttestationProvider.sol";

/// @title AttestationProvider
/// @notice Official D01 attestation provider for shareholder verification
/// @dev Three attestation types grouped by update frequency:
///      1. D01Identity - Stable (country, KYC, sanctions) - 1-2 years
///      2. D01Accreditation - Expires (accreditation, QP) - 90 days
///      3. D01Tax - Annual (tax residency)
contract AttestationProvider is Ownable, ERC165, IAttestationProvider {
    string public constant VERSION = "0.9.0";

    IEAS public immutable eas;
    ProviderRegistry public immutable registry;

    /// @notice Schema UIDs
    bytes32 public identitySchema;
    bytes32 public accreditationSchema;
    bytes32 public taxSchema;

    /// @notice Operators (backend wallets that can issue attestations on behalf of this provider)
    mapping(address => bool) public operators;

    event SchemaRegistered(string indexed schemaType, bytes32 schemaUID);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event IdentityAttested(bytes32 indexed uid, address indexed recipient, string providerId);
    event AccreditationAttested(bytes32 indexed uid, address indexed recipient, string providerId, uint64 expiresAt);
    event TaxAttested(bytes32 indexed uid, address indexed recipient, string providerId);
    event AttestationRevoked(bytes32 indexed uid, bytes32 indexed schemaUID);

    error NotAuthorized();
    error SchemaNotSet();
    error InvalidSchema();
    error ZeroAddress();

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) {
            revert NotAuthorized();
        }
        _;
    }

    constructor(
        address _eas,
        address _registry,
        address _owner,
        bytes32 _identitySchema,
        bytes32 _accreditationSchema,
        bytes32 _taxSchema
    ) Ownable(_owner) {
        if (_eas == address(0) || _registry == address(0)) revert ZeroAddress();
        eas = IEAS(_eas);
        registry = ProviderRegistry(_registry);
        identitySchema = _identitySchema;
        accreditationSchema = _accreditationSchema;
        taxSchema = _taxSchema;
    }

    // ============ Schema Registration ============

    /// @notice Register all three schemas with EAS (always revocable). Idempotent.
    function registerSchemas() external onlyOwner {
        ISchemaRegistry schemaRegistry = eas.getSchemaRegistry();

        if (identitySchema == bytes32(0) || schemaRegistry.getSchema(identitySchema).uid == bytes32(0)) {
            identitySchema =
                schemaRegistry.register(ShareholderSchemas.IDENTITY_SCHEMA, ISchemaResolver(address(0)), true);
            emit SchemaRegistered("identity", identitySchema);
        }

        if (accreditationSchema == bytes32(0) || schemaRegistry.getSchema(accreditationSchema).uid == bytes32(0)) {
            accreditationSchema =
                schemaRegistry.register(ShareholderSchemas.ACCREDITATION_SCHEMA, ISchemaResolver(address(0)), true);
            emit SchemaRegistered("accreditation", accreditationSchema);
        }

        if (taxSchema == bytes32(0) || schemaRegistry.getSchema(taxSchema).uid == bytes32(0)) {
            taxSchema = schemaRegistry.register(ShareholderSchemas.TAX_SCHEMA, ISchemaResolver(address(0)), true);
            emit SchemaRegistered("tax", taxSchema);
        }
    }

    // ============ Operator Management ============

    function addOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = true;
        emit OperatorAdded(operator);
    }

    function removeOperator(address operator) external onlyOwner {
        operators[operator] = false;
        emit OperatorRemoved(operator);
    }

    // ============ Attestations ============

    /// @notice Create identity attestation (country, KYC, sanctions)
    /// @param recipient Shareholder address
    /// @param data Identity data
    /// @param expirationTime EAS expiration (0 = never)
    function attestIdentity(address recipient, ShareholderSchemas.IdentityData calldata data, uint64 expirationTime)
        external
        override
        onlyOperator
        returns (bytes32 uid)
    {
        return _attestIdentity(recipient, data, expirationTime);
    }

    /// @notice Create accreditation attestation (accreditation type, QP).
    /// @param recipient Shareholder address
    /// @param data Accreditation data (includes expiresAt; 0 = never expires)
    function attestAccreditation(address recipient, ShareholderSchemas.AccreditationData calldata data)
        external
        onlyOperator
        returns (bytes32 uid)
    {
        return _attestAccreditation(recipient, data);
    }

    /// @notice Create tax attestation (tax country, form type)
    /// @param recipient Shareholder address
    /// @param data Tax data
    /// @param expirationTime EAS expiration (typically 1 year)
    function attestTax(address recipient, ShareholderSchemas.TaxData calldata data, uint64 expirationTime)
        external
        onlyOperator
        returns (bytes32 uid)
    {
        return _attestTax(recipient, data, expirationTime);
    }

    /// @notice Create all three attestations at once.
    /// @dev Accreditation expiry is read from `accreditationData.expiresAt`; identity and tax take
    ///      explicit `expirationTime` args since their payloads don't carry an expiry field.
    function attestFull(
        address recipient,
        ShareholderSchemas.IdentityData calldata identityData,
        ShareholderSchemas.AccreditationData calldata accreditationData,
        ShareholderSchemas.TaxData calldata taxData,
        uint64 identityExpiration,
        uint64 taxExpiration
    ) external onlyOperator returns (bytes32 identityUid, bytes32 accreditationUid, bytes32 taxUid) {
        identityUid = _attestIdentity(recipient, identityData, identityExpiration);
        accreditationUid = _attestAccreditation(recipient, accreditationData);
        taxUid = _attestTax(recipient, taxData, taxExpiration);
    }

    // ============ Internal Attestation Helpers ============

    function _attestIdentity(address recipient, ShareholderSchemas.IdentityData calldata data, uint64 expirationTime)
        internal
        returns (bytes32 uid)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (identitySchema == bytes32(0)) revert SchemaNotSet();

        ShareholderSchemas.IdentityData memory d = data;
        d.verifiedAt = uint64(block.timestamp);

        uid = eas.attest(
            AttestationRequest({
                schema: identitySchema,
                data: AttestationRequestData({
                    recipient: recipient,
                    expirationTime: expirationTime,
                    revocable: true,
                    refUID: bytes32(0),
                    data: ShareholderSchemas.encodeIdentity(d),
                    value: 0
                })
            })
        );

        registry.recordAttestation(identitySchema, recipient, uid);
        emit IdentityAttested(uid, recipient, data.providerId);
    }

    function _attestAccreditation(address recipient, ShareholderSchemas.AccreditationData calldata data)
        internal
        returns (bytes32 uid)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (accreditationSchema == bytes32(0)) revert SchemaNotSet();

        ShareholderSchemas.AccreditationData memory d = data;
        d.verifiedAt = uint64(block.timestamp);

        uid = eas.attest(
            AttestationRequest({
                schema: accreditationSchema,
                data: AttestationRequestData({
                    recipient: recipient,
                    expirationTime: data.expiresAt,
                    revocable: true,
                    refUID: bytes32(0),
                    data: ShareholderSchemas.encodeAccreditation(d),
                    value: 0
                })
            })
        );

        registry.recordAttestation(accreditationSchema, recipient, uid);
        emit AccreditationAttested(uid, recipient, data.providerId, data.expiresAt);
    }

    function _attestTax(address recipient, ShareholderSchemas.TaxData calldata data, uint64 expirationTime)
        internal
        returns (bytes32 uid)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (taxSchema == bytes32(0)) revert SchemaNotSet();

        ShareholderSchemas.TaxData memory d = data;
        d.verifiedAt = uint64(block.timestamp);

        uid = eas.attest(
            AttestationRequest({
                schema: taxSchema,
                data: AttestationRequestData({
                    recipient: recipient,
                    expirationTime: expirationTime,
                    revocable: true,
                    refUID: bytes32(0),
                    data: ShareholderSchemas.encodeTax(d),
                    value: 0
                })
            })
        );

        registry.recordAttestation(taxSchema, recipient, uid);
        emit TaxAttested(uid, recipient, data.providerId);
    }

    // ============ Revocation ============

    function revokeAttestation(bytes32 schemaUID, bytes32 uid) external override onlyOperator {
        if (schemaUID != identitySchema && schemaUID != accreditationSchema && schemaUID != taxSchema) {
            revert InvalidSchema();
        }
        Attestation memory att = eas.getAttestation(uid);
        eas.revoke(RevocationRequest({schema: schemaUID, data: RevocationRequestData({uid: uid, value: 0})}));
        registry.clearAttestation(schemaUID, att.recipient, uid);
        emit AttestationRevoked(uid, schemaUID);
    }

    // ============ View ============

    function getSchemas() external view override returns (bytes32 identity, bytes32 accreditation, bytes32 tax) {
        return (identitySchema, accreditationSchema, taxSchema);
    }

    // ============ ERC-165 ============

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAttestationProvider).interfaceId || super.supportsInterface(interfaceId);
    }
}
