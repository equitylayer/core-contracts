// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProviderRegistry} from "../../src/attestations/ProviderRegistry.sol";
import {AttestationProvider} from "../../src/attestations/AttestationProvider.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {SchemaRegistry} from "@eas/contracts/SchemaRegistry.sol";
import {EAS} from "@eas/contracts/EAS.sol";
import {AttestationRequest, AttestationRequestData} from "@eas/contracts/IEAS.sol";
import {ISchemaResolver} from "@eas/contracts/resolver/ISchemaResolver.sol";

/// @dev Contract that does not implement ERC-165. Used to exercise the registry's negative path.
contract NotAnAttestationProvider {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Implements ERC-165 but does not advertise `IAttestationProvider`.
contract WrongInterfaceProvider is ERC165 {}

contract ProviderRegistryTest is Test {
    ProviderRegistry registry;
    SchemaRegistry schemaRegistry;
    EAS eas;
    bytes32 testSchema;

    address owner = address(0x1);
    address provider1; // deployed as MockAttestationProvider in setUp
    address provider2; // deployed as MockAttestationProvider in setUp
    address attacker = address(0xBAD);

    event ProviderRegistered(address indexed provider, string name, string metadataUri);
    event ProviderActivated(address indexed provider);
    event ProviderDeactivated(address indexed provider, string reason);
    event ProviderMetadataUpdated(address indexed provider, string metadataUri);
    event ProviderCapabilitySet(address indexed provider, ProviderRegistry.ProviderType providerType, bool enabled);
    event AttestationRecorded(
        bytes32 indexed schemaUID, address indexed recipient, bytes32 attestationUID, address indexed provider
    );
    event AttestationCleared(bytes32 indexed schemaUID, address indexed recipient, address indexed provider);
    event EASUpdated(address indexed newEAS);

    function setUp() public {
        schemaRegistry = new SchemaRegistry();
        eas = new EAS(schemaRegistry);

        testSchema = schemaRegistry.register("bytes32 data", ISchemaResolver(address(0)), true);

        ProviderRegistry impl = new ProviderRegistry();
        bytes memory initData = abi.encodeWithSelector(ProviderRegistry.initialize.selector, owner, address(eas));
        address proxy = address(new ERC1967Proxy(address(impl), initData));
        registry = ProviderRegistry(proxy);

        provider1 = address(_newAttestationProvider());
        provider2 = address(_newAttestationProvider());

        _bindSchema(testSchema, ProviderRegistry.ProviderType.KYC_AML);
    }

    // ==================
    // Constructor Tests
    // ==================

    function test_Constructor() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.eas(), address(eas));
    }

    function test_Initialize_RevertZeroEAS() public {
        ProviderRegistry impl = new ProviderRegistry();
        bytes memory initData = abi.encodeWithSelector(ProviderRegistry.initialize.selector, owner, address(0));
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    // ==================
    // AddProvider Tests
    // ==================

    function test_AddProvider() public {
        ProviderRegistry.ProviderType[] memory capabilities = new ProviderRegistry.ProviderType[](2);
        capabilities[0] = ProviderRegistry.ProviderType.KYC_AML;
        capabilities[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;

        vm.expectEmit(true, false, false, true);
        emit ProviderRegistered(provider1, "Test Provider", "ipfs://metadata");

        vm.prank(owner);
        registry.addProvider(provider1, "Test Provider", "ipfs://metadata", capabilities);

        ProviderRegistry.Provider memory p = registry.getProvider(provider1);
        assertEq(p.providerAddress, provider1);
        assertEq(p.name, "Test Provider");
        assertEq(p.metadataUri, "ipfs://metadata");
        assertEq(p.deactivatedAt, 0); // Active immediately
        assertTrue(p.registeredAt > 0);

        assertTrue(registry.isRegistered(provider1));
        assertTrue(registry.isActive(provider1));
        assertTrue(registry.hasCapability(provider1, ProviderRegistry.ProviderType.KYC_AML));
        assertTrue(registry.hasCapability(provider1, ProviderRegistry.ProviderType.ACCREDITED_INVESTOR));
        assertFalse(registry.hasCapability(provider1, ProviderRegistry.ProviderType.LEGAL));
    }

    function test_AddProvider_Validations() public {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](0);

        // Zero address
        vm.prank(owner);
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        registry.addProvider(address(0), "Provider", "ipfs://", caps);

        // Empty name
        vm.prank(owner);
        vm.expectRevert(ProviderRegistry.EmptyName.selector);
        registry.addProvider(provider1, "", "ipfs://", caps);

        // Not owner
        vm.prank(attacker);
        vm.expectRevert();
        registry.addProvider(provider1, "Provider", "ipfs://", caps);

        // Already registered
        vm.prank(owner);
        registry.addProvider(provider1, "Provider 1", "ipfs://", caps);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderAlreadyRegistered.selector, provider1));
        registry.addProvider(provider1, "Duplicate", "ipfs://", caps);
    }

    function test_AddProvider_EmptyCapabilities() public {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](0);

        vm.prank(owner);
        registry.addProvider(provider1, "No Caps Provider", "ipfs://metadata", caps);

        assertTrue(registry.isRegistered(provider1));
        assertTrue(registry.isActive(provider1));
        assertFalse(registry.hasCapability(provider1, ProviderRegistry.ProviderType.KYC_AML));
    }

    // ==================
    // Activate / Deactivate Tests
    // ==================

    function test_DeactivateAndReactivate() public {
        _addProvider(provider1, "Provider 1");
        assertTrue(registry.isActive(provider1));

        // Deactivate
        vm.expectEmit(true, false, false, true);
        emit ProviderDeactivated(provider1, "Compliance violation");
        vm.prank(owner);
        registry.deactivateProvider(provider1, "Compliance violation");

        assertFalse(registry.isActive(provider1));
        ProviderRegistry.Provider memory p = registry.getProvider(provider1);
        assertEq(p.deactivatedAt, block.timestamp);

        // Reactivate
        vm.expectEmit(true, false, false, false);
        emit ProviderActivated(provider1);
        vm.prank(owner);
        registry.activateProvider(provider1);

        assertTrue(registry.isActive(provider1));
        p = registry.getProvider(provider1);
        assertEq(p.deactivatedAt, 0);
    }

    function test_ActivateProvider_RevertNotOwner() public {
        _addProvider(provider1, "Provider 1");

        vm.expectRevert();
        vm.prank(attacker);
        registry.activateProvider(provider1);
    }

    function test_ActivateProvider_RevertNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotRegistered.selector, provider1));
        vm.prank(owner);
        registry.activateProvider(provider1);
    }

    function test_DeactivateProvider_RevertNotOwner() public {
        _addProvider(provider1, "Provider 1");

        vm.expectRevert();
        vm.prank(attacker);
        registry.deactivateProvider(provider1, "reason");
    }

    function test_DeactivateProvider_RevertNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotRegistered.selector, provider1));
        registry.deactivateProvider(provider1, "reason");
    }

    // ==================
    // Metadata Tests
    // ==================

    function test_UpdateMetadata() public {
        _addProvider(provider1, "Provider 1");

        vm.expectEmit(true, false, false, true);
        emit ProviderMetadataUpdated(provider1, "ipfs://new-metadata");

        vm.prank(owner);
        registry.updateMetadata(provider1, "ipfs://new-metadata");

        ProviderRegistry.Provider memory p = registry.getProvider(provider1);
        assertEq(p.metadataUri, "ipfs://new-metadata");
    }

    function test_UpdateMetadata_Validations() public {
        // Not registered
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotRegistered.selector, provider1));
        registry.updateMetadata(provider1, "ipfs://new");

        // Not owner
        _addProvider(provider1, "Provider 1");
        vm.prank(attacker);
        vm.expectRevert();
        registry.updateMetadata(provider1, "ipfs://malicious");
    }

    // ==================
    // Capability Tests
    // ==================

    function test_SetProviderCapability() public {
        _addProvider(provider1, "Provider 1");

        assertFalse(registry.hasCapability(provider1, ProviderRegistry.ProviderType.LEGAL));

        vm.prank(owner);
        registry.setProviderCapability(provider1, ProviderRegistry.ProviderType.LEGAL, true);

        assertTrue(registry.hasCapability(provider1, ProviderRegistry.ProviderType.LEGAL));

        vm.prank(owner);
        registry.setProviderCapability(provider1, ProviderRegistry.ProviderType.LEGAL, false);

        assertFalse(registry.hasCapability(provider1, ProviderRegistry.ProviderType.LEGAL));
    }

    function test_SetProviderCapability_RevertNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotRegistered.selector, provider1));
        registry.setProviderCapability(provider1, ProviderRegistry.ProviderType.KYC_AML, true);
    }

    function test_CanProvideService() public {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](1);
        caps[0] = ProviderRegistry.ProviderType.KYC_AML;

        vm.prank(owner);
        registry.addProvider(provider1, "Provider 1", "ipfs://", caps);

        // Active: has capability
        assertTrue(registry.canProvideService(provider1, ProviderRegistry.ProviderType.KYC_AML));

        // Active: doesn't have sepcific capability
        assertFalse(registry.canProvideService(provider1, ProviderRegistry.ProviderType.LEGAL));

        // Deactivate: has capability but not active
        vm.prank(owner);
        registry.deactivateProvider(provider1, "Suspended");
        assertFalse(registry.canProvideService(provider1, ProviderRegistry.ProviderType.KYC_AML));
    }

    // ==================
    // Attestation Index Tests
    // ==================

    function test_RecordAttestation() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);
        bytes32 uid = _createAttestation(testSchema, recipient, provider1);

        vm.expectEmit(true, true, true, true);
        emit AttestationRecorded(testSchema, recipient, uid, provider1);

        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid);

        assertEq(registry.getAttestation(testSchema, recipient), uid);
    }

    function test_RecordAttestation_Validations() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);
        _addProviderWithCap(provider2, "Provider 2", ProviderRegistry.ProviderType.KYC_AML);
        address recipient = address(0x999);

        // Not active (unregistered)
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotActive.selector, attacker));
        registry.recordAttestation(testSchema, recipient, keccak256("fake"));

        // Schema mismatch (use a bound schema so capability check passes)
        bytes32 otherSchema = schemaRegistry.register("uint256 val", ISchemaResolver(address(0)), true);
        _bindSchema(otherSchema, ProviderRegistry.ProviderType.KYC_AML);
        bytes32 uid = _createAttestation(testSchema, recipient, provider1);
        vm.prank(provider1);
        vm.expectRevert(ProviderRegistry.AttestationSchemaMismatch.selector);
        registry.recordAttestation(otherSchema, recipient, uid);

        // Recipient mismatch
        vm.prank(provider1);
        vm.expectRevert(ProviderRegistry.AttestationRecipientMismatch.selector);
        registry.recordAttestation(testSchema, address(0x888), uid);

        // Attester mismatch (uid created by provider1, provider2 tries to record)
        vm.prank(provider2);
        vm.expectRevert(ProviderRegistry.AttestationAttesterMismatch.selector);
        registry.recordAttestation(testSchema, recipient, uid);
    }

    function test_RecordAttestation_OverwritesPrevious() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);
        bytes32 uid1 = _createAttestation(testSchema, recipient, provider1);
        bytes32 uid2 = _createAttestation(testSchema, recipient, provider1);

        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid1);
        assertEq(registry.getAttestation(testSchema, recipient), uid1);

        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid2);
        assertEq(registry.getAttestation(testSchema, recipient), uid2);
    }

    function test_RecordAttestation_DeactivatedProviderCannotRecord() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);
        bytes32 uid = _createAttestation(testSchema, recipient, provider1);

        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid);

        vm.prank(owner);
        registry.deactivateProvider(provider1, "Suspended");

        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotActive.selector, provider1));
        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, keccak256("new"));
    }

    function test_RecordAttestation_RevertSchemaNotBound() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        bytes32 unboundSchema = schemaRegistry.register("string foo", ISchemaResolver(address(0)), true);
        address recipient = address(0x999);
        bytes32 uid = _createAttestation(unboundSchema, recipient, provider1);

        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.SchemaCapabilityNotSet.selector, unboundSchema));
        registry.recordAttestation(unboundSchema, recipient, uid);
    }

    // ==================
    // ClearAttestation Tests
    // ==================

    function test_ClearAttestation() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);
        bytes32 uid = _createAttestation(testSchema, recipient, provider1);

        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid);
        assertEq(registry.getAttestation(testSchema, recipient), uid);

        vm.expectEmit(true, true, true, true);
        emit AttestationCleared(testSchema, recipient, provider1);

        vm.prank(provider1);
        registry.clearAttestation(testSchema, recipient, uid);
        assertEq(registry.getAttestation(testSchema, recipient), bytes32(0));
    }

    function test_ClearAttestation_Validations() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);
        _addProviderWithCap(provider2, "Provider 2", ProviderRegistry.ProviderType.LEGAL);

        address recipient = address(0x999);

        // Not active (unregistered)
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.ProviderNotActive.selector, attacker));
        registry.clearAttestation(testSchema, recipient, bytes32(0));

        // Missing capability (provider2 has LEGAL, not KYC_AML)
        vm.prank(provider2);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProviderRegistry.ProviderMissingCapability.selector, provider2, ProviderRegistry.ProviderType.KYC_AML
            )
        );
        registry.clearAttestation(testSchema, recipient, bytes32(0));

        // Unbound schema
        bytes32 unboundSchema = schemaRegistry.register("bool flag", ISchemaResolver(address(0)), true);
        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.SchemaCapabilityNotSet.selector, unboundSchema));
        registry.clearAttestation(unboundSchema, recipient, bytes32(0));
    }

    /// @dev One provider cannot wipe another provider's attestation index entry. Without the
    ///      attester-ownership check, any active capability-bearing provider could force arbitrary
    ///      holders into fail-closed (NOT_VERIFIED) states across KYC, Accredited, RegS.
    function test_ClearAttestation_OnlyAttester() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);
        _addProviderWithCap(provider2, "Provider 2", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);

        // provider1 attests
        bytes32 uid = _createAttestation(testSchema, recipient, provider1);
        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid);

        // provider2 (same capability) tries to clear — must revert
        vm.prank(provider2);
        vm.expectRevert(ProviderRegistry.AttestationAttesterMismatch.selector);
        registry.clearAttestation(testSchema, recipient, uid);

        // Index is intact
        assertEq(registry.getAttestation(testSchema, recipient), uid);

        // Original attester can still clear
        vm.prank(provider1);
        registry.clearAttestation(testSchema, recipient, uid);
        assertEq(registry.getAttestation(testSchema, recipient), bytes32(0));
    }

    /// @dev Clearing a never-recorded (empty) slot is a no-op, no ownership check.
    function test_ClearAttestation_EmptySlot_NoOp() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);
        vm.prank(provider1);
        registry.clearAttestation(testSchema, recipient, bytes32(0));
        assertEq(registry.getAttestation(testSchema, recipient), bytes32(0));
    }

    /// @dev Revoking a stale (superseded) UID must NOT wipe the current live index entry.
    ///      Scenario: provider attests (uid1), re-attests (uid2 overrides in index), later
    ///      revokes uid1 to tidy up. The newer uid2 record must survive.
    function test_ClearAttestation_StaleUidNoOps() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);

        bytes32 uid1 = _createAttestation(testSchema, recipient, provider1);
        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid1);

        bytes32 uid2 = _createAttestation(testSchema, recipient, provider1);
        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid2);
        assertEq(registry.getAttestation(testSchema, recipient), uid2);

        // Provider revokes the OLD uid1 — must leave uid2 in place.
        vm.prank(provider1);
        registry.clearAttestation(testSchema, recipient, uid1);
        assertEq(registry.getAttestation(testSchema, recipient), uid2, "live uid2 must not be wiped");

        // Explicit uid2 clear still works.
        vm.prank(provider1);
        registry.clearAttestation(testSchema, recipient, uid2);
        assertEq(registry.getAttestation(testSchema, recipient), bytes32(0));
    }

    // ==================
    // Schema Capability Gating Tests
    // ==================

    function test_SchemaCapabilityGating() public {
        // Register two providers: one with KYC_AML, one with LEGAL only
        ProviderRegistry.ProviderType[] memory kycCaps = new ProviderRegistry.ProviderType[](1);
        kycCaps[0] = ProviderRegistry.ProviderType.KYC_AML;
        ProviderRegistry.ProviderType[] memory legalCaps = new ProviderRegistry.ProviderType[](1);
        legalCaps[0] = ProviderRegistry.ProviderType.LEGAL;

        vm.startPrank(owner);
        registry.addProvider(provider1, "KYC Provider", "ipfs://", kycCaps);
        registry.addProvider(provider2, "Legal Provider", "ipfs://", legalCaps);
        vm.stopPrank();

        assertEq(uint8(registry.schemaCapabilities(testSchema)), uint8(ProviderRegistry.ProviderType.KYC_AML));

        address recipient = address(0x999);

        // KYC provider can record
        bytes32 uid1 = _createAttestation(testSchema, recipient, provider1);
        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid1);
        assertEq(registry.getAttestation(testSchema, recipient), uid1);

        // Legal provider cannot record on KYC-gated schema
        bytes32 uid2 = _createAttestation(testSchema, recipient, provider2);
        vm.prank(provider2);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProviderRegistry.ProviderMissingCapability.selector, provider2, ProviderRegistry.ProviderType.KYC_AML
            )
        );
        registry.recordAttestation(testSchema, recipient, uid2);
    }

    function test_SchemaCapabilities_Batch() public {
        bytes32 schema2 = schemaRegistry.register("string name", ISchemaResolver(address(0)), true);

        bytes32[] memory schemas = new bytes32[](2);
        schemas[0] = testSchema;
        schemas[1] = schema2;
        ProviderRegistry.ProviderType[] memory types = new ProviderRegistry.ProviderType[](2);
        types[0] = ProviderRegistry.ProviderType.KYC_AML;
        types[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;

        vm.prank(owner);
        registry.setSchemaCapabilities(schemas, types);

        assertEq(uint8(registry.schemaCapabilities(testSchema)), uint8(ProviderRegistry.ProviderType.KYC_AML));
        assertEq(uint8(registry.schemaCapabilities(schema2)), uint8(ProviderRegistry.ProviderType.ACCREDITED_INVESTOR));

        // Length mismatch reverts
        bytes32[] memory oneSchema = new bytes32[](1);
        oneSchema[0] = testSchema;
        vm.prank(owner);
        vm.expectRevert(ProviderRegistry.ArrayLengthMismatch.selector);
        registry.setSchemaCapabilities(oneSchema, types);
    }

    function test_SchemaCapability_OnlyOwner() public {
        bytes32[] memory schemas = new bytes32[](1);
        schemas[0] = testSchema;
        ProviderRegistry.ProviderType[] memory types = new ProviderRegistry.ProviderType[](1);
        types[0] = ProviderRegistry.ProviderType.KYC_AML;

        vm.prank(attacker);
        vm.expectRevert();
        registry.setSchemaCapabilities(schemas, types);

        vm.prank(attacker);
        vm.expectRevert();
        registry.removeSchemaCapabilities(schemas);
    }

    function test_SchemaCapability_UnboundSchemaReverts() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        // Create a new schema that is NOT bound to any capability
        bytes32 unboundSchema = schemaRegistry.register("uint256 value", ISchemaResolver(address(0)), true);
        address recipient = address(0x999);
        bytes32 uid = _createAttestation(unboundSchema, recipient, provider1);

        // Should revert — strict mode requires capability binding
        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.SchemaCapabilityNotSet.selector, unboundSchema));
        registry.recordAttestation(unboundSchema, recipient, uid);
    }

    function test_SchemaCapability_RemoveAndRevert() public {
        _addProviderWithCap(provider1, "Provider 1", ProviderRegistry.ProviderType.KYC_AML);

        address recipient = address(0x999);
        bytes32 uid1 = _createAttestation(testSchema, recipient, provider1);

        // Can record when bound
        vm.prank(provider1);
        registry.recordAttestation(testSchema, recipient, uid1);

        // Owner removes capability → reverts
        bytes32[] memory schemas = new bytes32[](1);
        schemas[0] = testSchema;
        vm.prank(owner);
        registry.removeSchemaCapabilities(schemas);

        bytes32 uid2 = _createAttestation(testSchema, recipient, provider1);
        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.SchemaCapabilityNotSet.selector, testSchema));
        registry.recordAttestation(testSchema, recipient, uid2);
    }

    // ==================
    // EAS Update Tests
    // ==================

    function test_SetEAS() public {
        address newEAS = address(0xEA52);

        vm.expectEmit(true, false, false, false);
        emit EASUpdated(newEAS);

        vm.prank(owner);
        registry.setEAS(newEAS);

        assertEq(registry.eas(), newEAS);
    }

    function test_SetEAS_Validations() public {
        vm.prank(owner);
        vm.expectRevert(ProviderRegistry.ZeroAddress.selector);
        registry.setEAS(address(0));

        vm.prank(attacker);
        vm.expectRevert();
        registry.setEAS(address(0xEA52));
    }

    // ==================
    // Pagination Tests
    // ==================

    function test_GetProvidersPaginated() public {
        for (uint256 i = 1; i <= 5; i++) {
            address p = address(uint160(i * 100));
            ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](0);
            vm.prank(owner);
            registry.addProvider(p, string.concat("Provider ", vm.toString(i)), "ipfs://", caps);
        }

        // First page
        (address[] memory page1, uint256 total) = registry.getProvidersPaginated(0, 2);
        assertEq(total, 5);
        assertEq(page1.length, 2);
        assertEq(page1[0], address(100));
        assertEq(page1[1], address(200));

        // Second page
        (address[] memory page2,) = registry.getProvidersPaginated(2, 2);
        assertEq(page2.length, 2);
        assertEq(page2[0], address(300));
        assertEq(page2[1], address(400));

        // Last page (partial)
        (address[] memory page3,) = registry.getProvidersPaginated(4, 2);
        assertEq(page3.length, 1);
        assertEq(page3[0], address(500));

        // Offset beyond total
        (address[] memory empty,) = registry.getProvidersPaginated(10, 2);
        assertEq(empty.length, 0);

        // Zero limit
        (address[] memory zeroLimit, uint256 total2) = registry.getProvidersPaginated(0, 0);
        assertEq(zeroLimit.length, 0);
        assertEq(total2, 5);
    }

    function test_GetActiveProvidersPaginated() public {
        // Add 5 providers, deactivate 2
        for (uint256 i = 1; i <= 5; i++) {
            address p = address(uint160(i * 100));
            ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](0);
            vm.prank(owner);
            registry.addProvider(p, string.concat("Provider ", vm.toString(i)), "ipfs://", caps);
        }
        vm.startPrank(owner);
        registry.deactivateProvider(address(200), "reason");
        registry.deactivateProvider(address(400), "reason");
        vm.stopPrank();

        (address[] memory active, uint256 total) = registry.getActiveProvidersPaginated(0, 10);
        assertEq(total, 3);
        assertEq(active.length, 3);
        assertEq(active[0], address(100));
        assertEq(active[1], address(300));
        assertEq(active[2], address(500));

        (address[] memory page1,) = registry.getActiveProvidersPaginated(0, 2);
        assertEq(page1.length, 2);

        (address[] memory page2,) = registry.getActiveProvidersPaginated(2, 2);
        assertEq(page2.length, 1);
    }

    function test_GetActiveProvidersPaginated_EdgeCases() public {
        _addProvider(provider1, "P1");
        _addProvider(provider2, "P2");

        // Zero limit
        (address[] memory empty, uint256 total) = registry.getActiveProvidersPaginated(0, 0);
        assertEq(empty.length, 0);
        assertEq(total, 2);

        // Offset beyond total
        (address[] memory empty2, uint256 total2) = registry.getActiveProvidersPaginated(10, 5);
        assertEq(empty2.length, 0);
        assertEq(total2, 2);
    }

    function test_GetActiveProvidersByTypePaginated() public {
        ProviderRegistry.ProviderType[] memory kycCaps = new ProviderRegistry.ProviderType[](1);
        kycCaps[0] = ProviderRegistry.ProviderType.KYC_AML;

        ProviderRegistry.ProviderType[] memory legalCaps = new ProviderRegistry.ProviderType[](1);
        legalCaps[0] = ProviderRegistry.ProviderType.LEGAL;

        address provider3 = address(_newAttestationProvider());
        address provider4 = address(_newAttestationProvider());

        vm.startPrank(owner);
        registry.addProvider(provider1, "KYC Provider 1", "ipfs://", kycCaps);
        registry.addProvider(provider2, "Legal Provider", "ipfs://", legalCaps);

        registry.addProvider(provider3, "KYC Provider 2", "ipfs://", kycCaps);
        registry.deactivateProvider(provider3, "Suspended"); // KYC but deactivated

        registry.addProvider(provider4, "KYC Provider 3", "ipfs://", kycCaps);
        vm.stopPrank();

        // Active KYC providers: provider1, provider4 (not provider3)
        (address[] memory kycProviders, uint256 total) =
            registry.getActiveProvidersByTypePaginated(ProviderRegistry.ProviderType.KYC_AML, 0, 10);
        assertEq(total, 2);
        assertEq(kycProviders[0], provider1);
        assertEq(kycProviders[1], provider4);

        // Active Legal providers: provider2
        (address[] memory legalProviders,) =
            registry.getActiveProvidersByTypePaginated(ProviderRegistry.ProviderType.LEGAL, 0, 10);
        assertEq(legalProviders.length, 1);
        assertEq(legalProviders[0], provider2);
    }

    function test_GetActiveProvidersByTypePaginated_EdgeCases() public {
        ProviderRegistry.ProviderType[] memory kycCaps = new ProviderRegistry.ProviderType[](1);
        kycCaps[0] = ProviderRegistry.ProviderType.KYC_AML;

        address provider3 = address(_newAttestationProvider());

        vm.startPrank(owner);
        registry.addProvider(provider1, "P1", "ipfs://", kycCaps);
        registry.addProvider(provider2, "P2", "ipfs://", kycCaps);
        registry.addProvider(provider3, "P3", "ipfs://", kycCaps);
        vm.stopPrank();

        // Zero limit
        (address[] memory empty, uint256 total) =
            registry.getActiveProvidersByTypePaginated(ProviderRegistry.ProviderType.KYC_AML, 0, 0);
        assertEq(empty.length, 0);
        assertEq(total, 3);

        // Offset beyond total
        (address[] memory empty2,) =
            registry.getActiveProvidersByTypePaginated(ProviderRegistry.ProviderType.KYC_AML, 10, 5);
        assertEq(empty2.length, 0);

        // Non-zero offset pagination
        (address[] memory page2,) =
            registry.getActiveProvidersByTypePaginated(ProviderRegistry.ProviderType.KYC_AML, 1, 2);
        assertEq(page2.length, 2);
        assertEq(page2[0], provider2);
        assertEq(page2[1], provider3);

        // Partial last page
        (address[] memory page3,) =
            registry.getActiveProvidersByTypePaginated(ProviderRegistry.ProviderType.KYC_AML, 2, 5);
        assertEq(page3.length, 1);
        assertEq(page3[0], provider3);
    }

    // ==================
    // Query Tests
    // ==================

    function test_AddProvider_AttestationType_RevertsWhenEOA() public {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](1);
        caps[0] = ProviderRegistry.ProviderType.KYC_AML;

        address eoa = address(0xEEE);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.NotAContract.selector, eoa));
        registry.addProvider(eoa, "EOA", "ipfs://", caps);
    }

    function test_AddProvider_AttestationType_RevertsWhenNoERC165() public {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](1);
        caps[0] = ProviderRegistry.ProviderType.KYC_AML;

        address bad = address(new NotAnAttestationProvider());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.InvalidProviderInterface.selector, bad));
        registry.addProvider(bad, "Bad", "ipfs://", caps);
    }

    function test_AddProvider_AttestationType_RevertsWhenInterfaceReturnsFalse() public {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](1);
        caps[0] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;

        address wrong = address(new WrongInterfaceProvider());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.InvalidProviderInterface.selector, wrong));
        registry.addProvider(wrong, "Wrong Interface", "ipfs://", caps);
    }

    function test_AddProvider_ServiceTypeAllowsEOA() public {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](1);
        caps[0] = ProviderRegistry.ProviderType.LEGAL;

        // EOA provider is valid for service-only capabilities
        address eoa = address(0xEEE);
        vm.prank(owner);
        registry.addProvider(eoa, "Legal EOA", "ipfs://", caps);

        assertTrue(registry.hasCapability(eoa, ProviderRegistry.ProviderType.LEGAL));
    }

    function test_SetProviderCapability_AttestationType_ValidatesInterface() public {
        // Register an EOA with a service-only capability
        address eoa = address(0xEEE);
        _addProvider(eoa, "Service provider");

        // Upgrading an EOA to an attestation capability must revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ProviderRegistry.NotAContract.selector, eoa));
        registry.setProviderCapability(eoa, ProviderRegistry.ProviderType.KYC_AML, true);

        // A real attestation provider (provider1 = AttestationProvider) passes the check
        _addProvider(provider1, "Attestation provider registered without caps");
        vm.prank(owner);
        registry.setProviderCapability(provider1, ProviderRegistry.ProviderType.KYC_AML, true);
        assertTrue(registry.hasCapability(provider1, ProviderRegistry.ProviderType.KYC_AML));
    }

    function test_SetProviderCapability_DisableAttestationSkipsValidation() public {
        // Register provider1 (real contract) with KYC_AML
        _addProviderWithCap(provider1, "KYC Provider", ProviderRegistry.ProviderType.KYC_AML);

        // Disabling must succeed regardless of interface state (we only validate when enabling)
        vm.prank(owner);
        registry.setProviderCapability(provider1, ProviderRegistry.ProviderType.KYC_AML, false);
        assertFalse(registry.hasCapability(provider1, ProviderRegistry.ProviderType.KYC_AML));
    }

    function test_QueryFunctions() public {
        assertFalse(registry.isRegistered(provider1));
        assertEq(registry.getProviderCount(), 0);

        _addProvider(provider1, "Provider 1");
        _addProvider(provider2, "Provider 2");

        assertTrue(registry.isRegistered(provider1));
        assertTrue(registry.isActive(provider1));
        assertEq(registry.getProviderCount(), 2);
        assertEq(registry.getProviderAt(0), provider1);
        assertEq(registry.getProviderAt(1), provider2);
    }

    // ==================
    // Helper Functions
    // ==================

    function _addProvider(address provider, string memory name) internal {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](0);
        vm.prank(owner);
        registry.addProvider(provider, name, "ipfs://metadata", caps);
    }

    function _addProviderWithCap(address provider, string memory name, ProviderRegistry.ProviderType cap) internal {
        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](1);
        caps[0] = cap;
        vm.prank(owner);
        registry.addProvider(provider, name, "ipfs://metadata", caps);
    }

    /// @dev Deploy a real `AttestationProvider` that implements the interface the registry requires.
    function _newAttestationProvider() internal returns (AttestationProvider) {
        return new AttestationProvider(address(eas), address(registry), owner, bytes32(0), bytes32(0), bytes32(0));
    }

    function _bindSchema(bytes32 schemaUID, ProviderRegistry.ProviderType providerType) internal {
        bytes32[] memory schemas = new bytes32[](1);
        schemas[0] = schemaUID;
        ProviderRegistry.ProviderType[] memory types = new ProviderRegistry.ProviderType[](1);
        types[0] = providerType;
        vm.prank(owner);
        registry.setSchemaCapabilities(schemas, types);
    }

    function _createAttestation(bytes32 schema, address recipient, address attester) internal returns (bytes32) {
        vm.prank(attester);
        return eas.attest(
            AttestationRequest({
                schema: schema,
                data: AttestationRequestData({
                    recipient: recipient, expirationTime: 0, revocable: true, refUID: bytes32(0), data: "", value: 0
                })
            })
        );
    }
}
