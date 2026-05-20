// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RuleKYC} from "../../src/rules/RuleKYC.sol";
import {ShareholderSchemas} from "../../src/attestations/ShareholderSchemas.sol";
import {IRuleCloneable} from "../../src/interfaces/rules/IRuleCloneable.sol";
import {IRuleKYC} from "../../src/interfaces/rules/IRuleKYC.sol";
import {IRuleOFAC} from "../../src/interfaces/rules/IRuleOFAC.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract RuleKYCTest is BaseTest {
    uint8 constant TRANSFER_OK = 0;

    RuleKYC public ruleKYC;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _setupRuleTest();
    }

    function _deployAndAddRules() internal override {
        ruleKYC =
            _deployRuleKYC(address(company), address(providerRegistry), identitySchema, ShareholderSchemas.KYC_BASIC);
        ruleEngine.addRuleValidation(IRuleValidation(address(ruleKYC)));
    }

    function _issueInitialShares() internal override {}

    // ============ Initialize Tests ============

    function test_Initialize() public view {
        assertEq(address(ruleKYC.company()), address(company));
        assertEq(address(ruleKYC.registry()), address(providerRegistry));
        assertEq(ruleKYC.idSchema(), identitySchema);
        assertEq(ruleKYC.requiredKycLevel(), ShareholderSchemas.KYC_BASIC);
    }

    function test_Initialize_RevertOnBadParams() public {
        // Deploy impl + clones up front so the only call left to revert is `initialize`.
        RuleKYC impl = new RuleKYC();

        address c1 = Clones.clone(address(impl));
        vm.expectRevert(RuleKYC.ZeroAddress.selector);
        RuleKYC(c1)
            .initialize(abi.encode(address(providerRegistry), identitySchema, ShareholderSchemas.KYC_BASIC), address(0));

        address c2 = Clones.clone(address(impl));
        vm.expectRevert(RuleKYC.ZeroAddress.selector);
        RuleKYC(c2).initialize(abi.encode(address(0), identitySchema, ShareholderSchemas.KYC_BASIC), address(company));

        address c3 = Clones.clone(address(impl));
        vm.expectRevert(RuleKYC.ZeroSchema.selector);
        RuleKYC(c3)
            .initialize(
                abi.encode(address(providerRegistry), bytes32(0), ShareholderSchemas.KYC_BASIC), address(company)
            );

        address c4 = Clones.clone(address(impl));
        vm.expectRevert(RuleKYC.InvalidKycLevel.selector);
        RuleKYC(c4).initialize(abi.encode(address(providerRegistry), identitySchema, uint8(99)), address(company));
    }

    // ============ KYC Level Tests ============

    function test_DetectTransferRestriction_NoAttestation() public view {
        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, ruleKYC.CODE_RECIPIENT_NOT_VERIFIED());
    }

    function test_DetectTransferRestriction_InsufficientKycLevel() public {
        _attestIdentity(bob, ShareholderSchemas.KYC_NONE, 0);

        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, ruleKYC.CODE_INSUFFICIENT_KYC_LEVEL());
    }

    function test_DetectTransferRestriction_SufficientKycLevel() public {
        _attestIdentity(bob, ShareholderSchemas.KYC_BASIC, 0);

        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_DetectTransferRestriction_EnhancedKycLevel() public {
        _attestIdentity(bob, ShareholderSchemas.KYC_ENHANCED, 0);

        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    // ============ Expiration Tests ============

    function test_DetectTransferRestriction_ExpiredAttestation() public {
        vm.warp(1000);
        _attestIdentity(bob, ShareholderSchemas.KYC_BASIC, uint64(block.timestamp + 100));

        // Warp past expiration
        vm.warp(block.timestamp + 200);

        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, ruleKYC.CODE_ATTESTATION_EXPIRED());
    }

    function test_DetectTransferRestriction_NoExpiration() public {
        _attestIdentity(bob, ShareholderSchemas.KYC_BASIC, 0);

        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    // ============ Revocation Tests ============

    function test_DetectTransferRestriction_RevokedAttestation() public {
        bytes32 uid = _attestIdentity(bob, ShareholderSchemas.KYC_BASIC, 0);

        vm.prank(attestationOperator);
        attestationProvider.revokeAttestation(identitySchema, uid);

        // revokeAttestation also clears the registry index, so the UID is gone
        // and the check returns CODE_RECIPIENT_NOT_VERIFIED (not CODE_ATTESTATION_REVOKED)
        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, ruleKYC.CODE_RECIPIENT_NOT_VERIFIED());
    }

    // ============ Burn/Mint Tests ============

    function test_DetectTransferRestriction_BurnAllowed() public view {
        uint8 code = ruleKYC.detectTransferRestriction(alice, address(0), 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_DetectTransferRestriction_MintRequiresKYC() public view {
        uint8 code = ruleKYC.detectTransferRestriction(address(0), bob, 100);
        assertEq(code, ruleKYC.CODE_RECIPIENT_NOT_VERIFIED());
    }

    // ============ setRequiredKycLevel Tests ============

    function test_SetRequiredKycLevel() public {
        vm.prank(board);
        ruleKYC.setRequiredKycLevel(ShareholderSchemas.KYC_ENHANCED);

        assertEq(ruleKYC.requiredKycLevel(), ShareholderSchemas.KYC_ENHANCED);
    }

    function test_SetRequiredKycLevel_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit RuleKYC.RequiredKycLevelUpdated(ShareholderSchemas.KYC_BASIC, ShareholderSchemas.KYC_ENHANCED);

        vm.prank(board);
        ruleKYC.setRequiredKycLevel(ShareholderSchemas.KYC_ENHANCED);
    }

    function test_SetRequiredKycLevel_RevertNotBoard() public {
        vm.expectRevert(RuleKYC.OnlyBoard.selector);
        vm.prank(alice);
        ruleKYC.setRequiredKycLevel(ShareholderSchemas.KYC_ENHANCED);
    }

    function test_SetRequiredKycLevel_RevertInvalidLevel() public {
        vm.expectRevert(RuleKYC.InvalidKycLevel.selector);
        vm.prank(board);
        ruleKYC.setRequiredKycLevel(99);
    }

    function test_KycNone_IsFullOffSwitch_EvenForUnattestedMintRecipient() public {
        vm.prank(board);
        ruleKYC.setRequiredKycLevel(ShareholderSchemas.KYC_NONE);

        // from = address(0), to = bob (no attestation whatsoever)
        uint8 mintCode = ruleKYC.detectTransferRestriction(address(0), bob, 100);
        assertEq(mintCode, TRANSFER_OK, "mint to unattested address must pass when rule is off");

        // And getVerificationStatus agrees — no EAS probe, no revert
        (uint8 statusCode, uint8 level) = ruleKYC.getVerificationStatus(bob);
        assertEq(statusCode, TRANSFER_OK);
        assertEq(level, 0);

        // isVerified convenience also returns true for everyone
        assertTrue(ruleKYC.isVerified(bob));
        assertTrue(ruleKYC.isVerified(address(0xDEAD)));
    }

    function test_SetRequiredKycLevel_AffectsTransfers() public {
        // Setup: alice has shares, bob has BASIC KYC
        _attestIdentity(alice, ShareholderSchemas.KYC_BASIC, 0);
        _attestIdentity(bob, ShareholderSchemas.KYC_BASIC, 0);

        // Mint shares to alice (she needs KYC to receive)
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        // Transfer works with BASIC level requirement
        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 100));
        assertEq(shareToken.balanceOf(bob), 100);

        // Board raises requirement to ENHANCED
        vm.prank(board);
        ruleKYC.setRequiredKycLevel(ShareholderSchemas.KYC_ENHANCED);

        // Transfer now fails - bob only has BASIC
        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 100);

        // Upgrade bob to ENHANCED
        _attestIdentity(bob, ShareholderSchemas.KYC_ENHANCED, 0);

        // Transfer works again
        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 100));
        assertEq(shareToken.balanceOf(bob), 200);
    }

    function test_SetRequiredKycLevel_LoweringAllowsPreviouslyBlocked() public {
        // Setup: bob has BASIC KYC, requirement is ENHANCED
        vm.prank(board);
        ruleKYC.setRequiredKycLevel(ShareholderSchemas.KYC_ENHANCED);

        _attestIdentity(alice, ShareholderSchemas.KYC_ENHANCED, 0);
        _attestIdentity(bob, ShareholderSchemas.KYC_BASIC, 0);

        // Mint to alice
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        // Transfer fails - bob only has BASIC
        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 100);

        // Board lowers requirement to BASIC
        vm.prank(board);
        ruleKYC.setRequiredKycLevel(ShareholderSchemas.KYC_BASIC);

        // Transfer now works
        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 100));
        assertEq(shareToken.balanceOf(bob), 100);
    }

    // ============ Sanctions Cleared Tests ============

    function test_DetectTransferRestriction_SanctionsNotCleared() public {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: 840,
            isUSPerson: true,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: ShareholderSchemas.KYC_BASIC,
            sanctionsCleared: false,
            verifiedAt: 0
        });
        vm.prank(attestationOperator);
        attestationProvider.attestIdentity(bob, data, 0);

        uint8 code = ruleKYC.detectTransferRestriction(alice, bob, 100);
        assertEq(code, ruleKYC.CODE_SANCTIONS_NOT_CLEARED());
    }

    function test_GetVerificationStatus_SanctionsNotCleared() public {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: 840,
            isUSPerson: true,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: ShareholderSchemas.KYC_BASIC,
            sanctionsCleared: false,
            verifiedAt: 0
        });
        vm.prank(attestationOperator);
        attestationProvider.attestIdentity(bob, data, 0);

        (uint8 code, uint8 level) = ruleKYC.getVerificationStatus(bob);
        assertEq(code, ruleKYC.CODE_SANCTIONS_NOT_CLEARED());
        assertEq(level, ShareholderSchemas.KYC_BASIC);
    }

    // ============ View Functions ============

    function test_IsVerified() public {
        assertFalse(ruleKYC.isVerified(bob));

        _attestIdentity(bob, ShareholderSchemas.KYC_BASIC, 0);

        assertTrue(ruleKYC.isVerified(bob));
    }

    function test_GetVerificationStatus() public {
        _attestIdentity(bob, ShareholderSchemas.KYC_ENHANCED, 0);

        (uint8 code, uint8 level) = ruleKYC.getVerificationStatus(bob);
        assertEq(code, TRANSFER_OK);
        assertEq(level, ShareholderSchemas.KYC_ENHANCED);
    }

    function test_GetVerificationStatus_NotVerified() public view {
        (uint8 code, uint8 level) = ruleKYC.getVerificationStatus(bob);
        assertEq(code, ruleKYC.CODE_RECIPIENT_NOT_VERIFIED());
        assertEq(level, 0);
    }

    function test_CanReturnTransferRestrictionCode() public view {
        assertTrue(ruleKYC.canReturnTransferRestrictionCode(ruleKYC.CODE_RECIPIENT_NOT_VERIFIED()));
        assertTrue(ruleKYC.canReturnTransferRestrictionCode(ruleKYC.CODE_ATTESTATION_EXPIRED()));
        assertTrue(ruleKYC.canReturnTransferRestrictionCode(ruleKYC.CODE_ATTESTATION_REVOKED()));
        assertTrue(ruleKYC.canReturnTransferRestrictionCode(ruleKYC.CODE_INSUFFICIENT_KYC_LEVEL()));
        assertTrue(ruleKYC.canReturnTransferRestrictionCode(ruleKYC.CODE_SCHEMA_MISMATCH()));
        assertTrue(ruleKYC.canReturnTransferRestrictionCode(ruleKYC.CODE_SANCTIONS_NOT_CLEARED()));
        assertFalse(ruleKYC.canReturnTransferRestrictionCode(TRANSFER_OK));
    }

    function test_MessageForTransferRestriction() public view {
        assertEq(
            ruleKYC.messageForTransferRestriction(ruleKYC.CODE_RECIPIENT_NOT_VERIFIED()),
            "Recipient does not have KYC verification"
        );
        assertEq(
            ruleKYC.messageForTransferRestriction(ruleKYC.CODE_ATTESTATION_EXPIRED()), "KYC attestation has expired"
        );
        assertEq(
            ruleKYC.messageForTransferRestriction(ruleKYC.CODE_ATTESTATION_REVOKED()),
            "KYC attestation has been revoked"
        );
        assertEq(
            ruleKYC.messageForTransferRestriction(ruleKYC.CODE_INSUFFICIENT_KYC_LEVEL()),
            "Recipient KYC level is insufficient"
        );
        assertEq(ruleKYC.messageForTransferRestriction(ruleKYC.CODE_SCHEMA_MISMATCH()), "Attestation schema mismatch");
        assertEq(
            ruleKYC.messageForTransferRestriction(ruleKYC.CODE_SANCTIONS_NOT_CLEARED()),
            "Recipient sanctions not cleared"
        );
        assertEq(ruleKYC.messageForTransferRestriction(99), "Unknown restriction code");
    }

    // ============ ERC-165 ============

    function test_SupportsInterface() public view {
        // Cloneable surface so the registry's publish probe accepts this impl
        assertTrue(ruleKYC.supportsInterface(type(IRuleCloneable).interfaceId));
        // Rule-type identity — lets the dapp distinguish rule types without method-name probing
        assertTrue(ruleKYC.supportsInterface(type(IRuleKYC).interfaceId));
        // Must NOT advertise other rule types
        assertFalse(ruleKYC.supportsInterface(type(IRuleOFAC).interfaceId));
        assertFalse(ruleKYC.supportsInterface(0xdeadbeef));
    }
}
