// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {Attestation} from "@eas/contracts/Common.sol";
import {IAttestationProvider} from "../interfaces/IAttestationProvider.sol";

/// @title ProviderRegistry
/// @notice Global registry of approved service providers for the D01 platform
/// TODO no service providers integrated yet
/// Provider Types (Attestation - issue EAS credentials):
/// - KYC_AML: Identity verification, sanctions screening
/// - ACCREDITED_INVESTOR: SEC accredited investor verification
/// - QUALIFIED_PURCHASER: QP verification for certain exemptions
/// - JURISDICTION: Jurisdiction/residency verification
///
/// Provider Types (Service - perform actions on company contracts):
/// - VALUATION: FMV valuation firms (e.g., 409A for US, HMRC for UK)
/// - CFO_SERVICE: Fractional CFO / bookkeeping
/// - TAX_ADVISOR: Tax planning / compliance
/// - LEGAL: Legal counsel
/// - COMPLIANCE: Regulatory compliance
/// - TRANSFER_AGENT: Transfer agent services
contract ProviderRegistry is OwnableUpgradeable, UUPSUpgradeable {
    string public constant VERSION = "0.9.0";

    enum ProviderType {
        NONE, // Sentinel value — no capability assigned
        // KYC
        KYC_AML,
        ACCREDITED_INVESTOR,
        QUALIFIED_PURCHASER,
        JURISDICTION,
        // Service providers
        VALUATION,
        CFO_SERVICE,
        TAX_ADVISOR,
        LEGAL,
        COMPLIANCE,
        TRANSFER_AGENT
    }

    struct Provider {
        address providerAddress;
        string name;
        string metadataUri;
        uint256 registeredAt;
        uint256 deactivatedAt; // 0 = active, >0 = deactivated at timestamp
    }

    mapping(address => Provider) public providers;
    mapping(address => mapping(ProviderType => bool)) public providerCapabilities;

    /// @notice Attestation index: schemaUID => recipient => attestationUID
    mapping(bytes32 => mapping(address => bytes32)) public attestations;

    /// @notice Required capability per schema (schemaUID => ProviderType)
    mapping(bytes32 => ProviderType) public schemaCapabilities;

    address[] private _providerList;

    /// @notice Mapping to track index in _providerList (1-indexed, 0 means not in list)
    mapping(address => uint256) private _providerIndex;
    address public eas;

    event ProviderRegistered(address indexed provider, string name, string metadataUri);
    event ProviderActivated(address indexed provider);
    event ProviderDeactivated(address indexed provider, string reason);
    event ProviderMetadataUpdated(address indexed provider, string metadataUri);
    event ProviderCapabilitySet(address indexed provider, ProviderType providerType, bool enabled);
    event AttestationRecorded(
        bytes32 indexed schemaUID, address indexed recipient, bytes32 attestationUID, address indexed provider
    );
    event SchemaCapabilitySet(bytes32 indexed schemaUID, ProviderType providerType);
    event SchemaCapabilityRemoved(bytes32 indexed schemaUID);
    event AttestationCleared(bytes32 indexed schemaUID, address indexed recipient, address indexed provider);
    event EASUpdated(address indexed newEAS);

    error ProviderAlreadyRegistered(address provider);
    error ProviderNotRegistered(address provider);
    error ProviderNotActive(address provider);
    error ZeroAddress();
    error EmptyName();
    error AttestationSchemaMismatch();
    error AttestationRecipientMismatch();
    error AttestationAttesterMismatch();
    error ProviderMissingCapability(address provider, ProviderType required);
    error ArrayLengthMismatch();
    error SchemaCapabilityNotSet(bytes32 schemaUID);
    error NotAContract(address provider);
    error InvalidProviderInterface(address provider);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the registry
    /// @param _owner Owner address
    /// @param _eas EAS contract address
    function initialize(address _owner, address _eas) external initializer {
        if (_eas == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        eas = _eas;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Provider Management ============

    /// @notice Register and activate a provider
    /// @param provider Address of the provider
    /// @param name Display name
    /// @param metadataUri IPFS URI
    /// @param capabilities Array of capabilities
    function addProvider(
        address provider,
        string calldata name,
        string calldata metadataUri,
        ProviderType[] calldata capabilities
    ) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        if (providers[provider].registeredAt != 0) {
            revert ProviderAlreadyRegistered(provider);
        }
        if (bytes(name).length == 0) revert EmptyName();

        providers[provider] = Provider({
            providerAddress: provider,
            name: name,
            metadataUri: metadataUri,
            registeredAt: block.timestamp,
            deactivatedAt: 0
        });

        bool attestationChecked;
        for (uint256 i = 0; i < capabilities.length; i++) {
            if (!attestationChecked && _isAttestationType(capabilities[i])) {
                _validateAttestationProvider(provider);
                attestationChecked = true;
            }
            providerCapabilities[provider][capabilities[i]] = true;
            emit ProviderCapabilitySet(provider, capabilities[i], true);
        }

        _providerList.push(provider);
        _providerIndex[provider] = _providerList.length;

        emit ProviderRegistered(provider, name, metadataUri);
    }

    /// @notice Activate a previously deactivated provider
    /// @param provider Address of the provider to activate
    function activateProvider(address provider) external onlyOwner {
        if (providers[provider].registeredAt == 0) {
            revert ProviderNotRegistered(provider);
        }

        providers[provider].deactivatedAt = 0;
        emit ProviderActivated(provider);
    }

    /// @notice Deactivate a provider by revoking approval
    /// @param provider Address of the provider to deactivate
    /// @param reason Reason for deactivation
    function deactivateProvider(address provider, string calldata reason) external onlyOwner {
        if (providers[provider].registeredAt == 0) {
            revert ProviderNotRegistered(provider);
        }

        providers[provider].deactivatedAt = block.timestamp;
        emit ProviderDeactivated(provider, reason);
    }

    /// @notice Set provider capability
    /// @param provider Address of the provider
    /// @param providerType The capability type
    /// @param enabled Whether to enable or disable
    function setProviderCapability(address provider, ProviderType providerType, bool enabled) external onlyOwner {
        if (providers[provider].registeredAt == 0) {
            revert ProviderNotRegistered(provider);
        }

        if (enabled && _isAttestationType(providerType)) {
            _validateAttestationProvider(provider);
        }

        providerCapabilities[provider][providerType] = enabled;
        emit ProviderCapabilitySet(provider, providerType, enabled);
    }

    /// @notice Update provider metadata
    /// @param provider Address of the provider
    /// @param metadataUri New IPFS URI
    function updateMetadata(address provider, string calldata metadataUri) external onlyOwner {
        if (providers[provider].registeredAt == 0) {
            revert ProviderNotRegistered(provider);
        }

        providers[provider].metadataUri = metadataUri;
        emit ProviderMetadataUpdated(provider, metadataUri);
    }

    /// @notice Update the EAS contract address
    /// @param _eas New EAS contract address
    function setEAS(address _eas) external onlyOwner {
        if (_eas == address(0)) revert ZeroAddress();
        eas = _eas;
        emit EASUpdated(_eas);
    }

    // ============ Schema Capability Gating ============

    /// @notice Require specific capabilities for providers recording attestations under schemas
    /// @param schemaUIDs The EAS schema UIDs
    /// @param providerTypes The required capabilities (same length as schemaUIDs)
    function setSchemaCapabilities(bytes32[] calldata schemaUIDs, ProviderType[] calldata providerTypes)
        external
        onlyOwner
    {
        if (schemaUIDs.length != providerTypes.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < schemaUIDs.length; i++) {
            schemaCapabilities[schemaUIDs[i]] = providerTypes[i];
            emit SchemaCapabilitySet(schemaUIDs[i], providerTypes[i]);
        }
    }

    /// @notice Remove capability requirements for schemas
    /// @param schemaUIDs The EAS schema UIDs
    function removeSchemaCapabilities(bytes32[] calldata schemaUIDs) external onlyOwner {
        for (uint256 i = 0; i < schemaUIDs.length; i++) {
            delete schemaCapabilities[schemaUIDs[i]];
            emit SchemaCapabilityRemoved(schemaUIDs[i]);
        }
    }

    // ============ Attestation Index ============

    /// @notice Record an attestation in the index (called by providers after issuing)
    /// @dev Only active providers with the required capability can record attestations.
    /// @param schemaUID The EAS schema UID
    /// @param recipient The address that received the attestation
    /// @param attestationUID The EAS attestation UID
    function recordAttestation(bytes32 schemaUID, address recipient, bytes32 attestationUID) external {
        if (providers[msg.sender].registeredAt == 0 || providers[msg.sender].deactivatedAt != 0) {
            revert ProviderNotActive(msg.sender);
        }

        ProviderType required = schemaCapabilities[schemaUID];
        if (required == ProviderType.NONE) revert SchemaCapabilityNotSet(schemaUID);
        if (!providerCapabilities[msg.sender][required]) {
            revert ProviderMissingCapability(msg.sender, required);
        }

        Attestation memory att = IEAS(eas).getAttestation(attestationUID);
        if (att.schema != schemaUID) revert AttestationSchemaMismatch();
        if (att.recipient != recipient) revert AttestationRecipientMismatch();
        if (att.attester != msg.sender) revert AttestationAttesterMismatch();

        attestations[schemaUID][recipient] = attestationUID;
        emit AttestationRecorded(schemaUID, recipient, attestationUID, msg.sender);
    }

    /// @notice Clear an attestation from the index (called by providers after revoking).
    /// @param schemaUID The EAS schema UID
    /// @param recipient The address whose attestation to clear
    /// @param revokingUid The UID being revoked. Must match the currently-indexed UID; otherwise
    ///        the call no-ops so a stale revoke doesn't wipe a newer live record. Pass `bytes32(0)`
    ///        to skip the match check (idempotent empty-slot cleanup).
    function clearAttestation(bytes32 schemaUID, address recipient, bytes32 revokingUid) external {
        if (providers[msg.sender].registeredAt == 0 || providers[msg.sender].deactivatedAt != 0) {
            revert ProviderNotActive(msg.sender);
        }

        ProviderType required = schemaCapabilities[schemaUID];
        if (required == ProviderType.NONE) revert SchemaCapabilityNotSet(schemaUID);
        if (!providerCapabilities[msg.sender][required]) {
            revert ProviderMissingCapability(msg.sender, required);
        }

        bytes32 storedUid = attestations[schemaUID][recipient];
        if (storedUid == bytes32(0)) {
            // Nothing indexed — idempotent no-op.
            return;
        }
        if (revokingUid != bytes32(0) && storedUid != revokingUid) {
            // Revoking a superseded attestation; don't wipe the newer live record.
            return;
        }

        Attestation memory att = IEAS(eas).getAttestation(storedUid);
        if (att.attester != msg.sender) revert AttestationAttesterMismatch();

        delete attestations[schemaUID][recipient];
        emit AttestationCleared(schemaUID, recipient, msg.sender);
    }

    // ============ Query Functions ============

    /// @notice Check if a provider is registered
    function isRegistered(address provider) external view returns (bool) {
        return providers[provider].registeredAt != 0;
    }

    /// @notice Check if a provider is active (approved by D01)
    function isActive(address provider) external view returns (bool) {
        return providers[provider].deactivatedAt == 0 && providers[provider].registeredAt != 0;
    }

    /// @notice Check if a provider has a specific capability
    function hasCapability(address provider, ProviderType providerType) external view returns (bool) {
        return providerCapabilities[provider][providerType];
    }

    /// @notice Check if a provider is active and has a specific capability
    function canProvideService(address provider, ProviderType providerType) external view returns (bool) {
        return providers[provider].deactivatedAt == 0 && providers[provider].registeredAt != 0
            && providerCapabilities[provider][providerType];
    }

    /// @notice Get full provider details
    function getProvider(address provider) external view returns (Provider memory) {
        return providers[provider];
    }

    /// @notice Get total number of registered providers
    function getProviderCount() external view returns (uint256) {
        return _providerList.length;
    }

    /// @notice Get paginated list of all registered providers
    /// @param offset Starting index
    /// @param limit Maximum number of results (0 = no limit, use with caution)
    /// @return result Array of provider addresses
    /// @return total Total number of registered providers
    function getProvidersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory result, uint256 total)
    {
        total = _providerList.length;
        if (offset >= total || limit == 0) {
            return (new address[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        result = new address[](end - offset);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = _providerList[offset + i];
        }
    }

    /// @notice Get paginated list of active providers
    /// @param offset Starting index (in the filtered active list)
    /// @param limit Maximum number of results
    /// @return result Array of active provider addresses
    /// @return total Total number of active providers
    function getActiveProvidersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory result, uint256 total)
    {
        // First pass: count active providers
        total = 0;
        for (uint256 i = 0; i < _providerList.length; i++) {
            if (providers[_providerList[i]].deactivatedAt == 0) {
                total++;
            }
        }

        if (offset >= total || limit == 0) {
            return (new address[](0), total);
        }

        uint256 resultSize = limit;
        if (offset + limit > total) {
            resultSize = total - offset;
        }

        result = new address[](resultSize);

        // Second pass: collect results
        uint256 activeIndex = 0;
        uint256 resultIndex = 0;
        for (uint256 i = 0; i < _providerList.length && resultIndex < resultSize; i++) {
            if (providers[_providerList[i]].deactivatedAt == 0) {
                if (activeIndex >= offset) {
                    result[resultIndex] = _providerList[i];
                    resultIndex++;
                }
                activeIndex++;
            }
        }
    }

    /// @notice Get paginated list of active providers with a specific capability
    /// @param providerType The capability type to filter by
    /// @param offset Starting index (in the filtered list)
    /// @param limit Maximum number of results
    /// @return result Array of matching provider addresses
    /// @return total Total number of matching providers
    function getActiveProvidersByTypePaginated(ProviderType providerType, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory result, uint256 total)
    {
        // First pass: count matching providers
        total = 0;
        for (uint256 i = 0; i < _providerList.length; i++) {
            address p = _providerList[i];
            if (providers[p].deactivatedAt == 0 && providerCapabilities[p][providerType]) {
                total++;
            }
        }

        if (offset >= total || limit == 0) {
            return (new address[](0), total);
        }

        uint256 resultSize = limit;
        if (offset + limit > total) {
            resultSize = total - offset;
        }

        result = new address[](resultSize);

        // Second pass: collect results
        uint256 matchIndex = 0;
        uint256 resultIndex = 0;
        for (uint256 i = 0; i < _providerList.length && resultIndex < resultSize; i++) {
            address p = _providerList[i];
            if (providers[p].deactivatedAt == 0 && providerCapabilities[p][providerType]) {
                if (matchIndex >= offset) {
                    result[resultIndex] = p;
                    resultIndex++;
                }
                matchIndex++;
            }
        }
    }

    /// @notice Get a provider address by index
    /// @param index Index in the provider list
    function getProviderAt(uint256 index) external view returns (address) {
        return _providerList[index];
    }

    /// @notice Get attestation UID for a recipient and schema
    /// @param schemaUID The EAS schema UID
    /// @param recipient The address to look up
    /// @return attestationUID The attestation UID (bytes32(0) if none)
    function getAttestation(bytes32 schemaUID, address recipient) external view returns (bytes32) {
        return attestations[schemaUID][recipient];
    }

    // ============ Interface Validation ============

    /// @dev Attestation types issue EAS credentials and must implement `IAttestationProvider`.
    ///      Service types (VALUATION, CFO_SERVICE, etc.) can be EOAs or multisigs.
    function _isAttestationType(ProviderType providerType) internal pure returns (bool) {
        return providerType == ProviderType.KYC_AML || providerType == ProviderType.ACCREDITED_INVESTOR
            || providerType == ProviderType.QUALIFIED_PURCHASER || providerType == ProviderType.JURISDICTION;
    }

    /// @dev Enforce that the provider is a contract implementing `IAttestationProvider`.
    function _validateAttestationProvider(address provider) internal view {
        if (provider.code.length == 0) revert NotAContract(provider);
        try IERC165(provider).supportsInterface(type(IAttestationProvider).interfaceId) returns (bool ok) {
            if (!ok) revert InvalidProviderInterface(provider);
        } catch {
            revert InvalidProviderInterface(provider);
        }
    }
}
