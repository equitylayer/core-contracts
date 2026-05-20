// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AttestationProvider} from "../../src/attestations/AttestationProvider.sol";
import {ProviderRegistry} from "../../src/attestations/ProviderRegistry.sol";
import {ShareholderSchemas} from "../../src/attestations/ShareholderSchemas.sol";
import {SchemaRegistry} from "@eas/contracts/SchemaRegistry.sol";
import {EAS} from "@eas/contracts/EAS.sol";
import {Attestation} from "@eas/contracts/IEAS.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAttestationProvider} from "../../src/interfaces/IAttestationProvider.sol";

contract AttestationProviderTest is Test {
    AttestationProvider provider;
    ProviderRegistry registry;
    EAS eas;
    SchemaRegistry schemaRegistry;

    address owner = address(0x1);
    address operator = address(0x2);
    address recipient1 = address(0x100);
    address recipient2 = address(0x200);
    address attacker = address(0xBAD);

    bytes32 identitySchema;
    bytes32 accreditationSchema;
    bytes32 taxSchema;

    function setUp() public {
        schemaRegistry = new SchemaRegistry();
        eas = new EAS(schemaRegistry);

        ProviderRegistry registryImpl = new ProviderRegistry();
        registry = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImpl), abi.encodeCall(ProviderRegistry.initialize, (owner, address(eas)))
                )
            )
        );

        provider = new AttestationProvider(address(eas), address(registry), owner, bytes32(0), bytes32(0), bytes32(0));

        ProviderRegistry.ProviderType[] memory capabilities = new ProviderRegistry.ProviderType[](4);
        capabilities[0] = ProviderRegistry.ProviderType.KYC_AML;
        capabilities[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;
        capabilities[2] = ProviderRegistry.ProviderType.QUALIFIED_PURCHASER;
        capabilities[3] = ProviderRegistry.ProviderType.JURISDICTION;

        vm.prank(owner);
        registry.addProvider(address(provider), "D01 Provider", "ipfs://d01", capabilities);

        vm.prank(owner);
        provider.registerSchemas();

        (identitySchema, accreditationSchema, taxSchema) = provider.getSchemas();

        // Bind schemas to capability types (registry owner responsibility)
        bytes32[] memory schemas = new bytes32[](3);
        schemas[0] = identitySchema;
        schemas[1] = accreditationSchema;
        schemas[2] = taxSchema;
        ProviderRegistry.ProviderType[] memory types = new ProviderRegistry.ProviderType[](3);
        types[0] = ProviderRegistry.ProviderType.KYC_AML;
        types[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;
        types[2] = ProviderRegistry.ProviderType.KYC_AML;
        vm.prank(owner);
        registry.setSchemaCapabilities(schemas, types);

        vm.prank(owner);
        provider.addOperator(operator);
    }

    // ==================
    // Constructor Tests
    // ==================

    function test_Constructor() public view {
        assertEq(address(provider.eas()), address(eas));
        assertEq(address(provider.registry()), address(registry));
        assertEq(provider.owner(), owner);
    }

    function test_SupportsInterface() public view {
        assertTrue(provider.supportsInterface(type(IAttestationProvider).interfaceId));
        assertTrue(provider.supportsInterface(type(IERC165).interfaceId));
        assertFalse(provider.supportsInterface(0xdeadbeef));
    }

    function test_Constructor_RevertZeroEAS() public {
        vm.expectRevert(AttestationProvider.ZeroAddress.selector);
        new AttestationProvider(address(0), address(registry), owner, bytes32(0), bytes32(0), bytes32(0));
    }

    function test_Constructor_RevertZeroRegistry() public {
        vm.expectRevert(AttestationProvider.ZeroAddress.selector);
        new AttestationProvider(address(eas), address(0), owner, bytes32(0), bytes32(0), bytes32(0));
    }

    // ==================
    // Schema Tests
    // ==================

    function test_RegisterSchemas() public view {
        assertTrue(identitySchema != bytes32(0));
        assertTrue(accreditationSchema != bytes32(0));
        assertTrue(taxSchema != bytes32(0));
        assertTrue(identitySchema != accreditationSchema);
        assertTrue(identitySchema != taxSchema);
        assertTrue(accreditationSchema != taxSchema);
    }

    function test_RegisterSchemas_RevertNotOwner() public {
        AttestationProvider newProvider = new AttestationProvider(
            address(eas), address(registry), address(0x999), bytes32(0), bytes32(0), bytes32(0)
        );
        vm.expectRevert();
        vm.prank(attacker);
        newProvider.registerSchemas();
    }

    function test_Constructor_WithSchemaUIDs() public {
        bytes32 id = keccak256("identity");
        bytes32 accr = keccak256("accreditation");
        bytes32 tax = keccak256("tax");

        AttestationProvider p = new AttestationProvider(address(eas), address(registry), owner, id, accr, tax);

        (bytes32 i, bytes32 a, bytes32 t) = p.getSchemas();
        assertEq(i, id);
        assertEq(a, accr);
        assertEq(t, tax);
    }

    // ==================
    // Operator Tests
    // ==================

    function test_AddOperator() public {
        address newOperator = address(0x999);
        vm.prank(owner);
        provider.addOperator(newOperator);
        assertTrue(provider.operators(newOperator));
    }

    function test_AddOperator_RevertZeroAddress() public {
        vm.expectRevert(AttestationProvider.ZeroAddress.selector);
        vm.prank(owner);
        provider.addOperator(address(0));
    }

    function test_RemoveOperator() public {
        assertTrue(provider.operators(operator));
        vm.prank(owner);
        provider.removeOperator(operator);
        assertFalse(provider.operators(operator));
    }

    function test_RemoveOperator_RevertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        provider.removeOperator(operator);
    }

    function test_OwnerCanActAsOperator() public {
        ShareholderSchemas.IdentityData memory data = _createIdentityData();
        vm.prank(owner);
        bytes32 uid = provider.attestIdentity(recipient1, data, 0);
        assertTrue(uid != bytes32(0));
    }

    // ==================
    // Identity Attestation Tests
    // ==================

    function test_AttestIdentity() public {
        ShareholderSchemas.IdentityData memory data = _createIdentityData();

        vm.prank(operator);
        bytes32 uid = provider.attestIdentity(recipient1, data, 0);

        assertTrue(uid != bytes32(0));
        Attestation memory att = eas.getAttestation(uid);
        assertEq(att.recipient, recipient1);
        assertEq(att.schema, identitySchema);
        assertEq(registry.getAttestation(identitySchema, recipient1), uid);
    }

    function test_AttestIdentity_WithExpiration() public {
        ShareholderSchemas.IdentityData memory data = _createIdentityData();
        uint64 expiration = uint64(block.timestamp + 365 days);

        vm.prank(operator);
        bytes32 uid = provider.attestIdentity(recipient1, data, expiration);

        Attestation memory att = eas.getAttestation(uid);
        assertEq(att.expirationTime, expiration);
    }

    function test_AttestIdentity_RevertNotOperator() public {
        ShareholderSchemas.IdentityData memory data = _createIdentityData();
        vm.expectRevert(AttestationProvider.NotAuthorized.selector);
        vm.prank(attacker);
        provider.attestIdentity(recipient1, data, 0);
    }

    function test_AttestIdentity_RevertZeroRecipient() public {
        ShareholderSchemas.IdentityData memory data = _createIdentityData();
        vm.expectRevert(AttestationProvider.ZeroAddress.selector);
        vm.prank(operator);
        provider.attestIdentity(address(0), data, 0);
    }

    function test_AttestIdentity_RevertSchemaNotSet() public {
        AttestationProvider newProvider =
            new AttestationProvider(address(eas), address(registry), owner, bytes32(0), bytes32(0), bytes32(0));
        vm.prank(owner);
        newProvider.addOperator(operator);

        ShareholderSchemas.IdentityData memory data = _createIdentityData();
        vm.expectRevert(AttestationProvider.SchemaNotSet.selector);
        vm.prank(operator);
        newProvider.attestIdentity(recipient1, data, 0);
    }

    // ==================
    // Accreditation Attestation Tests
    // ==================

    function test_AttestAccreditation() public {
        ShareholderSchemas.AccreditationData memory data = _createAccreditationData();

        vm.prank(operator);
        bytes32 uid = provider.attestAccreditation(recipient1, data);

        assertTrue(uid != bytes32(0));
        Attestation memory att = eas.getAttestation(uid);
        assertEq(att.recipient, recipient1);
        assertEq(att.schema, accreditationSchema);
        assertEq(att.expirationTime, data.expiresAt, "EAS expirationTime tracks payload expiresAt");
        assertEq(registry.getAttestation(accreditationSchema, recipient1), uid);
    }

    function test_AttestAccreditation_Reverts() public {
        ShareholderSchemas.AccreditationData memory data = _createAccreditationData();

        // NotAuthorized
        vm.prank(attacker);
        vm.expectRevert(AttestationProvider.NotAuthorized.selector);
        provider.attestAccreditation(recipient1, data);

        // ZeroAddress
        vm.prank(operator);
        vm.expectRevert(AttestationProvider.ZeroAddress.selector);
        provider.attestAccreditation(address(0), data);

        // SchemaNotSet
        AttestationProvider noSchemas =
            new AttestationProvider(address(eas), address(registry), owner, bytes32(0), bytes32(0), bytes32(0));
        vm.prank(owner);
        noSchemas.addOperator(operator);
        vm.prank(operator);
        vm.expectRevert(AttestationProvider.SchemaNotSet.selector);
        noSchemas.attestAccreditation(recipient1, data);
    }

    // ==================
    // Tax Attestation Tests
    // ==================

    function test_AttestTax() public {
        ShareholderSchemas.TaxData memory data = _createTaxData();

        vm.prank(operator);
        bytes32 uid = provider.attestTax(recipient1, data, uint64(block.timestamp + 365 days));

        assertTrue(uid != bytes32(0));
        Attestation memory att = eas.getAttestation(uid);
        assertEq(att.recipient, recipient1);
        assertEq(att.schema, taxSchema);
        assertEq(registry.getAttestation(taxSchema, recipient1), uid);
    }

    function test_AttestTax_Reverts() public {
        ShareholderSchemas.TaxData memory data = _createTaxData();

        // NotAuthorized
        vm.prank(attacker);
        vm.expectRevert(AttestationProvider.NotAuthorized.selector);
        provider.attestTax(recipient1, data, 0);

        // ZeroAddress
        vm.prank(operator);
        vm.expectRevert(AttestationProvider.ZeroAddress.selector);
        provider.attestTax(address(0), data, 0);

        // SchemaNotSet
        AttestationProvider noSchemas =
            new AttestationProvider(address(eas), address(registry), owner, bytes32(0), bytes32(0), bytes32(0));
        vm.prank(owner);
        noSchemas.addOperator(operator);
        vm.prank(operator);
        vm.expectRevert(AttestationProvider.SchemaNotSet.selector);
        noSchemas.attestTax(recipient1, data, 0);
    }

    // ==================
    // AttestFull Tests
    // ==================

    function test_AttestFull() public {
        vm.prank(operator);
        (bytes32 identityUid, bytes32 accreditationUid, bytes32 taxUid) = provider.attestFull(
            recipient1,
            _createIdentityData(),
            _createAccreditationData(),
            _createTaxData(),
            0,
            uint64(block.timestamp + 365 days)
        );

        assertTrue(identityUid != bytes32(0));
        assertTrue(accreditationUid != bytes32(0));
        assertTrue(taxUid != bytes32(0));
        assertEq(registry.getAttestation(identitySchema, recipient1), identityUid);
        assertEq(registry.getAttestation(accreditationSchema, recipient1), accreditationUid);
        assertEq(registry.getAttestation(taxSchema, recipient1), taxUid);
    }

    function test_AttestFull_Reverts() public {
        // NotAuthorized
        vm.prank(attacker);
        vm.expectRevert(AttestationProvider.NotAuthorized.selector);
        provider.attestFull(recipient1, _createIdentityData(), _createAccreditationData(), _createTaxData(), 0, 0);

        // ZeroAddress
        vm.prank(operator);
        vm.expectRevert(AttestationProvider.ZeroAddress.selector);
        provider.attestFull(address(0), _createIdentityData(), _createAccreditationData(), _createTaxData(), 0, 0);
    }

    // ==================
    // Revocation Tests
    // ==================

    function test_RevokeAttestation() public {
        vm.startPrank(operator);
        bytes32 uid = provider.attestIdentity(recipient1, _createIdentityData(), 0);

        Attestation memory att = eas.getAttestation(uid);
        assertEq(att.revocationTime, 0);
        assertEq(registry.getAttestation(identitySchema, recipient1), uid);

        provider.revokeAttestation(identitySchema, uid);
        vm.stopPrank();

        att = eas.getAttestation(uid);
        assertTrue(att.revocationTime > 0);
        // Registry index cleared
        assertEq(registry.getAttestation(identitySchema, recipient1), bytes32(0));
    }

    function test_RevokeAttestation_RevertInvalidSchema() public {
        vm.prank(operator);
        bytes32 uid = provider.attestIdentity(recipient1, _createIdentityData(), 0);

        vm.expectRevert(AttestationProvider.InvalidSchema.selector);
        vm.prank(operator);
        provider.revokeAttestation(keccak256("invalid"), uid);
    }

    function test_RevokeAttestation_AccreditationAndTaxSchemas() public {
        vm.startPrank(operator);

        // Revoke accreditation attestation
        bytes32 accrUid = provider.attestAccreditation(recipient1, _createAccreditationData(0));
        provider.revokeAttestation(accreditationSchema, accrUid);
        assertTrue(eas.getAttestation(accrUid).revocationTime > 0);
        assertEq(registry.getAttestation(accreditationSchema, recipient1), bytes32(0));

        // Revoke tax attestation
        bytes32 taxUid = provider.attestTax(recipient1, _createTaxData(), 0);
        provider.revokeAttestation(taxSchema, taxUid);
        assertTrue(eas.getAttestation(taxUid).revocationTime > 0);
        assertEq(registry.getAttestation(taxSchema, recipient1), bytes32(0));

        vm.stopPrank();
    }

    function test_RevokeAttestation_RevertNotAuthorized() public {
        vm.prank(operator);
        bytes32 uid = provider.attestIdentity(recipient1, _createIdentityData(), 0);

        vm.prank(attacker);
        vm.expectRevert(AttestationProvider.NotAuthorized.selector);
        provider.revokeAttestation(identitySchema, uid);
    }

    // ==================
    // Multi-Attestation Tests
    // ==================

    function test_MultipleRecipients() public {
        ShareholderSchemas.IdentityData memory data = _createIdentityData();

        vm.startPrank(operator);
        bytes32 uid1 = provider.attestIdentity(recipient1, data, 0);
        bytes32 uid2 = provider.attestIdentity(recipient2, data, 0);
        vm.stopPrank();

        assertTrue(uid1 != uid2);
        assertEq(registry.getAttestation(identitySchema, recipient1), uid1);
        assertEq(registry.getAttestation(identitySchema, recipient2), uid2);
    }

    function test_NewAttestationOverwritesOldInRegistry() public {
        ShareholderSchemas.IdentityData memory data = _createIdentityData();

        vm.startPrank(operator);
        bytes32 uid1 = provider.attestIdentity(recipient1, data, 0);
        data.kycLevel = ShareholderSchemas.KYC_ENHANCED;
        bytes32 uid2 = provider.attestIdentity(recipient1, data, 0);
        vm.stopPrank();

        assertTrue(uid1 != uid2);
        assertEq(registry.getAttestation(identitySchema, recipient1), uid2);
    }

    // ==================
    // Data Encoding Tests
    // ==================

    function test_IdentityDataEncodedCorrectly() public {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:sumsub",
            externalId: "ext-123",
            countryCode: 840,
            isUSPerson: true,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: ShareholderSchemas.KYC_ENHANCED,
            sanctionsCleared: true,
            verifiedAt: 0
        });

        vm.prank(operator);
        bytes32 uid = provider.attestIdentity(recipient1, data, 0);

        Attestation memory att = eas.getAttestation(uid);
        ShareholderSchemas.IdentityData memory decoded = ShareholderSchemas.decodeIdentity(att.data);

        assertEq(decoded.providerId, "obolos:sumsub");
        assertEq(decoded.countryCode, 840);
        assertTrue(decoded.isUSPerson);
        assertEq(decoded.kycLevel, ShareholderSchemas.KYC_ENHANCED);
    }

    // ==================
    // Helpers
    // ==================

    function _createIdentityData() internal pure returns (ShareholderSchemas.IdentityData memory) {
        return ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: 840,
            isUSPerson: true,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: ShareholderSchemas.KYC_BASIC,
            sanctionsCleared: true,
            verifiedAt: 0
        });
    }

    function _createAccreditationData() internal view returns (ShareholderSchemas.AccreditationData memory) {
        return _createAccreditationData(uint64(block.timestamp + 90 days));
    }

    function _createAccreditationData(uint64 expiresAt)
        internal
        pure
        returns (ShareholderSchemas.AccreditationData memory)
    {
        return ShareholderSchemas.AccreditationData({
            providerId: "obolos:test",
            externalId: "",
            accreditationType: ShareholderSchemas.ACCREDITED_US_INCOME,
            qpType: ShareholderSchemas.QP_NONE,
            verifiedAt: 0,
            expiresAt: expiresAt
        });
    }

    function _createTaxData() internal pure returns (ShareholderSchemas.TaxData memory) {
        return ShareholderSchemas.TaxData({
            providerId: "obolos:selfAttest",
            externalId: "",
            taxCountry: 840,
            taxFormType: ShareholderSchemas.TAX_FORM_W9,
            verifiedAt: 0
        });
    }
}
