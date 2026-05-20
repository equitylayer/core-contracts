// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RuleRegS} from "../../src/rules/RuleRegS.sol";
import {ShareholderSchemas} from "../../src/attestations/ShareholderSchemas.sol";
import {IRuleCloneable} from "../../src/interfaces/rules/IRuleCloneable.sol";
import {IRuleRegS} from "../../src/interfaces/rules/IRuleRegS.sol";
import {IRuleKYC} from "../../src/interfaces/rules/IRuleKYC.sol";
import {IRuleOFAC} from "../../src/interfaces/rules/IRuleOFAC.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract RuleRegSTest is BaseTest {
    uint8 constant TRANSFER_OK = 0;

    RuleRegS public rule;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint64 constant COMPLIANCE_END = 1_800_000_000; // far future

    function setUp() public {
        _setupRuleTest();
    }

    function _deployAndAddRules() internal override {
        rule = _deployRule(COMPLIANCE_END);
        ruleEngine.addRuleValidation(IRuleValidation(address(rule)));
    }

    function _issueInitialShares() internal override {}

    function _deployRule(uint64 complianceEnd) internal returns (RuleRegS r) {
        RuleRegS impl = new RuleRegS();
        address clone = Clones.clone(address(impl));
        RuleRegS(clone)
            .initialize(abi.encode(address(providerRegistry), identitySchema, complianceEnd), address(company));
        r = RuleRegS(clone);
    }

    function _attestAsNonUS(address recipient) internal returns (bytes32) {
        return _attestIdentityFull(recipient, false);
    }

    function _attestAsUS(address recipient) internal returns (bytes32) {
        return _attestIdentityFull(recipient, true);
    }

    function _attestIdentityFull(address recipient, bool isUSPerson) internal returns (bytes32) {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: isUSPerson ? uint16(840) : uint16(826),
            isUSPerson: isUSPerson,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: ShareholderSchemas.KYC_BASIC,
            sanctionsCleared: true,
            verifiedAt: 0
        });
        vm.prank(attestationOperator);
        return attestationProvider.attestIdentity(recipient, data, 0);
    }

    // ============ Initialize ============

    function test_Initialize() public view {
        assertEq(address(rule.company()), address(company));
        assertEq(address(rule.registry()), address(providerRegistry));
        assertEq(rule.idSchema(), identitySchema);
        assertEq(rule.complianceEnd(), COMPLIANCE_END);
    }

    function test_Initialize_RevertsOnBadParams() public {
        RuleRegS impl = new RuleRegS();

        address c1 = Clones.clone(address(impl));
        vm.expectRevert(RuleRegS.ZeroAddress.selector);
        RuleRegS(c1).initialize(abi.encode(address(providerRegistry), identitySchema, COMPLIANCE_END), address(0));

        address c2 = Clones.clone(address(impl));
        vm.expectRevert(RuleRegS.ZeroAddress.selector);
        RuleRegS(c2).initialize(abi.encode(address(0), identitySchema, COMPLIANCE_END), address(company));

        address c3 = Clones.clone(address(impl));
        vm.expectRevert(RuleRegS.ZeroSchema.selector);
        RuleRegS(c3).initialize(abi.encode(address(providerRegistry), bytes32(0), COMPLIANCE_END), address(company));

        address c4 = Clones.clone(address(impl));
        vm.expectRevert(RuleRegS.InvalidComplianceEnd.selector);
        RuleRegS(c4).initialize(abi.encode(address(providerRegistry), identitySchema, uint64(0)), address(company));
    }

    // ============ During compliance period (active) ============

    function test_DetectTransferRestriction_RecipientNonUS_Passes() public {
        _attestAsNonUS(bob);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_DetectTransferRestriction_RecipientUSPerson_Rejected() public {
        _attestAsUS(bob);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_IS_US_PERSON());
    }

    function test_DetectTransferRestriction_NoAttestation_Rejected() public view {
        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_NOT_VERIFIED(), "fail-closed during compliance period");
    }

    /// @dev Identity attestations can carry an EAS expirationTime. During the compliance window,
    ///      an expired attestation must be rejected — mirrors RuleKYC + RuleCountryBlocklist.
    function test_DetectTransferRestriction_ExpiredAttestation_Rejected() public {
        vm.warp(1000);
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: uint16(826),
            isUSPerson: false,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: ShareholderSchemas.KYC_BASIC,
            sanctionsCleared: true,
            verifiedAt: 0
        });
        vm.prank(attestationOperator);
        attestationProvider.attestIdentity(bob, data, uint64(block.timestamp + 100));

        vm.warp(block.timestamp + 200);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_ATTESTATION_EXPIRED());
    }

    function test_DetectTransferRestriction_Revoked_Rejected() public {
        bytes32 uid = _attestAsNonUS(bob);

        vm.prank(attestationOperator);
        attestationProvider.revokeAttestation(identitySchema, uid);

        // Revocation clears the registry index -> NOT_VERIFIED
        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_NOT_VERIFIED());
    }

    // ============ After compliance period (inactive = no-op) ============

    function test_DetectTransferRestriction_PostCompliance_AllowsUSPerson() public {
        _attestAsUS(bob);

        vm.warp(uint256(COMPLIANCE_END) + 1);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK, "Reg S expires -> shares are seasoned, rule is no-op");
    }

    function test_DetectTransferRestriction_PostCompliance_AllowsUnattested() public {
        vm.warp(uint256(COMPLIANCE_END) + 1);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_IsActive_TogglesOnComplianceEnd() public {
        assertTrue(rule.isActive());

        vm.warp(uint256(COMPLIANCE_END) - 1);
        assertTrue(rule.isActive());

        vm.warp(uint256(COMPLIANCE_END));
        assertFalse(rule.isActive(), "inclusive boundary: at complianceEnd the rule goes dormant");
    }

    // ============ Burn / mint ============

    function test_Burn_Allowed() public view {
        uint8 code = rule.detectTransferRestriction(alice, address(0), 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_Mint_ToUSPerson_BlockedDuringCompliance() public {
        _attestAsUS(bob);

        uint8 code = rule.detectTransferRestriction(address(0), bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_IS_US_PERSON());
    }

    function test_Mint_ToNonUSPerson_AllowedDuringCompliance() public {
        _attestAsNonUS(bob);

        uint8 code = rule.detectTransferRestriction(address(0), bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    // ============ setComplianceEnd ============

    function test_SetComplianceEnd_UpdatesAndGoesInactive() public {
        _attestAsUS(bob);
        assertEq(rule.detectTransferRestriction(alice, bob, 100), rule.CODE_RECIPIENT_IS_US_PERSON());

        // Board shortens the window to "now" -> rule immediately dormant.
        vm.prank(board);
        rule.setComplianceEnd(uint64(block.timestamp));

        assertEq(rule.detectTransferRestriction(alice, bob, 100), TRANSFER_OK);
    }

    function test_SetComplianceEnd_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit RuleRegS.ComplianceEndUpdated(COMPLIANCE_END, COMPLIANCE_END + 100);

        vm.prank(board);
        rule.setComplianceEnd(COMPLIANCE_END + 100);
    }

    function test_SetComplianceEnd_OnlyBoard() public {
        vm.expectRevert(RuleRegS.OnlyBoard.selector);
        vm.prank(alice);
        rule.setComplianceEnd(COMPLIANCE_END + 100);
    }

    function test_SetComplianceEnd_RevertsOnZero() public {
        vm.expectRevert(RuleRegS.InvalidComplianceEnd.selector);
        vm.prank(board);
        rule.setComplianceEnd(0);
    }

    // ============ End-to-end through CMTAT ============

    function test_Transfer_BlockedToUSPersonDuringCompliance() public {
        _attestAsNonUS(alice);
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        _attestAsUS(bob);

        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 100);
    }

    function test_Transfer_AllowedPostCompliance() public {
        _attestAsNonUS(alice);
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        _attestAsUS(bob);

        vm.warp(uint256(COMPLIANCE_END) + 1);

        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 100));
    }

    // ============ Misc ============

    function test_CanReturnTransferRestrictionCode() public view {
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_RECIPIENT_IS_US_PERSON()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_RECIPIENT_NOT_VERIFIED()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_ATTESTATION_REVOKED()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_SCHEMA_MISMATCH()));
        assertFalse(rule.canReturnTransferRestrictionCode(TRANSFER_OK));
    }

    function test_MessageForTransferRestriction() public view {
        assertEq(
            rule.messageForTransferRestriction(rule.CODE_RECIPIENT_IS_US_PERSON()), "Reg S: recipient is a US person"
        );
        assertEq(rule.messageForTransferRestriction(99), "Unknown restriction code");
    }

    function test_SupportsInterface() public view {
        assertTrue(rule.supportsInterface(type(IRuleCloneable).interfaceId));
        assertTrue(rule.supportsInterface(type(IRuleRegS).interfaceId));
        assertFalse(rule.supportsInterface(type(IRuleKYC).interfaceId));
        assertFalse(rule.supportsInterface(type(IRuleOFAC).interfaceId));
    }
}
