// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RuleCountryBlocklist} from "../../src/rules/RuleCountryBlocklist.sol";
import {RuleKYC} from "../../src/rules/RuleKYC.sol";
import {ShareholderSchemas} from "../../src/attestations/ShareholderSchemas.sol";
import {IRuleCloneable} from "../../src/interfaces/rules/IRuleCloneable.sol";
import {IRuleCountryBlocklist} from "../../src/interfaces/rules/IRuleCountryBlocklist.sol";
import {IRuleKYC} from "../../src/interfaces/rules/IRuleKYC.sol";
import {IRuleOFAC} from "../../src/interfaces/rules/IRuleOFAC.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract RuleCountryBlocklistTest is BaseTest {
    uint8 constant TRANSFER_OK = 0;

    // ISO 3166-1 numeric codes used across tests
    uint16 constant US = 840;
    uint16 constant IRAN = 364;
    uint16 constant NORTH_KOREA = 408;
    uint16 constant SYRIA = 760;
    uint16 constant GB = 826;

    RuleCountryBlocklist public rule;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _setupRuleTest();
    }

    function _deployAndAddRules() internal override {
        rule = _deployRule(_defaultBlockedCountries());
        ruleEngine.addRuleValidation(IRuleValidation(address(rule)));
    }

    function _issueInitialShares() internal override {}

    function _defaultBlockedCountries() internal pure returns (uint16[] memory) {
        uint16[] memory list = new uint16[](3);
        list[0] = IRAN;
        list[1] = NORTH_KOREA;
        list[2] = SYRIA;
        return list;
    }

    function _deployRule(uint16[] memory blocked) internal returns (RuleCountryBlocklist r) {
        RuleCountryBlocklist impl = new RuleCountryBlocklist();
        address clone = Clones.clone(address(impl));
        RuleCountryBlocklist(clone)
            .initialize(abi.encode(address(providerRegistry), identitySchema, blocked), address(company));
        r = RuleCountryBlocklist(clone);
    }

    function _attestIdentityWithCountry(address recipient, uint16 countryCode) internal returns (bytes32) {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: countryCode,
            isUSPerson: countryCode == US,
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
        assertEq(rule.blockedCountryCount(), 3);
        assertTrue(rule.isCountryBlocked(IRAN));
        assertTrue(rule.isCountryBlocked(NORTH_KOREA));
        assertTrue(rule.isCountryBlocked(SYRIA));
        assertFalse(rule.isCountryBlocked(US));
    }

    function test_Initialize_AcceptsEmptyList() public {
        uint16[] memory empty = new uint16[](0);
        RuleCountryBlocklist r = _deployRule(empty);
        assertEq(r.blockedCountryCount(), 0);
    }

    function test_Initialize_RevertsOnBadParams() public {
        RuleCountryBlocklist impl = new RuleCountryBlocklist();
        uint16[] memory list = _defaultBlockedCountries();

        address c1 = Clones.clone(address(impl));
        vm.expectRevert(RuleCountryBlocklist.ZeroAddress.selector);
        RuleCountryBlocklist(c1).initialize(abi.encode(address(providerRegistry), identitySchema, list), address(0));

        address c2 = Clones.clone(address(impl));
        vm.expectRevert(RuleCountryBlocklist.ZeroAddress.selector);
        RuleCountryBlocklist(c2).initialize(abi.encode(address(0), identitySchema, list), address(company));

        address c3 = Clones.clone(address(impl));
        vm.expectRevert(RuleCountryBlocklist.ZeroSchema.selector);
        RuleCountryBlocklist(c3).initialize(abi.encode(address(providerRegistry), bytes32(0), list), address(company));
    }

    function test_Initialize_RevertsOnZeroCountry() public {
        RuleCountryBlocklist impl = new RuleCountryBlocklist();
        address clone = Clones.clone(address(impl));
        uint16[] memory list = new uint16[](1);
        list[0] = 0;
        vm.expectRevert(RuleCountryBlocklist.ZeroCountry.selector);
        RuleCountryBlocklist(clone)
            .initialize(abi.encode(address(providerRegistry), identitySchema, list), address(company));
    }

    function test_Initialize_RevertsOnDuplicateInInitialSet() public {
        RuleCountryBlocklist impl = new RuleCountryBlocklist();
        address clone = Clones.clone(address(impl));
        uint16[] memory list = new uint16[](2);
        list[0] = IRAN;
        list[1] = IRAN;
        vm.expectRevert(abi.encodeWithSelector(RuleCountryBlocklist.DuplicateCountry.selector, IRAN));
        RuleCountryBlocklist(clone)
            .initialize(abi.encode(address(providerRegistry), identitySchema, list), address(company));
    }

    function test_Initialize_RevertsWhenOverMaxCountries() public {
        RuleCountryBlocklist impl = new RuleCountryBlocklist();
        address clone = Clones.clone(address(impl));
        uint16[] memory list = new uint16[](rule.MAX_COUNTRIES() + 1);
        for (uint256 i = 0; i < list.length; i++) {
            list[i] = uint16(i + 1);
        }
        vm.expectRevert(RuleCountryBlocklist.TooManyCountries.selector);
        RuleCountryBlocklist(clone)
            .initialize(abi.encode(address(providerRegistry), identitySchema, list), address(company));
    }

    // ============ Transfer restriction (attestations present) ============

    function test_DetectTransferRestriction_RecipientBlockedCountry() public {
        _attestIdentityWithCountry(alice, US);
        _attestIdentityWithCountry(bob, IRAN);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_COUNTRY_BLOCKED());
    }

    function test_DetectTransferRestriction_SenderBlockedCountry() public {
        _attestIdentityWithCountry(alice, NORTH_KOREA);
        _attestIdentityWithCountry(bob, US);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_SENDER_COUNTRY_BLOCKED());
    }

    function test_DetectTransferRestriction_BothAllowed() public {
        _attestIdentityWithCountry(alice, US);
        _attestIdentityWithCountry(bob, GB);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_DetectTransferRestriction_SenderAndRecipientBoth_BlockSender() public {
        // Order is sender-first, so this surfaces the sender code.
        _attestIdentityWithCountry(alice, IRAN);
        _attestIdentityWithCountry(bob, SYRIA);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_SENDER_COUNTRY_BLOCKED());
    }

    // ============ Fail-open (no attestation = pass) ============

    function test_FailOpen_NoAttestationOnEither() public view {
        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK, "unattested addresses must pass (KYC rule's responsibility)");
    }

    function test_FailOpen_RecipientUnattested_SenderUS() public {
        _attestIdentityWithCountry(alice, US);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_FailOpen_ExpiredAttestation() public {
        vm.warp(1000);
        _attestIdentityWithCountryExpiring(bob, IRAN, uint64(block.timestamp + 100));

        vm.warp(block.timestamp + 200);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK, "expired attestation falls open -- KYC rule catches stale verification");
    }

    function test_FailOpen_RevokedAttestation() public {
        bytes32 uid = _attestIdentityWithCountry(bob, IRAN);

        vm.prank(attestationOperator);
        attestationProvider.revokeAttestation(identitySchema, uid);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK, "revoked attestation falls open -- KYC rule catches the gap");
    }

    function _attestIdentityWithCountryExpiring(address recipient, uint16 countryCode, uint64 expiration)
        internal
        returns (bytes32)
    {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: countryCode,
            isUSPerson: countryCode == US,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: ShareholderSchemas.KYC_BASIC,
            sanctionsCleared: true,
            verifiedAt: 0
        });
        vm.prank(attestationOperator);
        return attestationProvider.attestIdentity(recipient, data, expiration);
    }

    // ============ Mint/Burn edge cases ============

    function test_Burn_AlwaysAllowed_EvenFromBlockedCountryHolder() public {
        _attestIdentityWithCountry(alice, IRAN);

        uint8 code = rule.detectTransferRestriction(alice, address(0), 100);
        assertEq(code, TRANSFER_OK, "burns must not block -- risks stranding positions");
    }

    function test_Mint_ToUnattestedRecipient_FallsOpen() public view {
        uint8 code = rule.detectTransferRestriction(address(0), bob, 100);
        assertEq(code, TRANSFER_OK, "un-attested mint recipient must not be blocked by country rule");
    }

    function test_Mint_ToBlockedCountryAttested_IsBlocked() public {
        _attestIdentityWithCountry(bob, IRAN);

        uint8 code = rule.detectTransferRestriction(address(0), bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_COUNTRY_BLOCKED());
    }

    // ============ transferFrom (spender not checked) ============

    function test_DetectTransferRestrictionFrom_IgnoresSpender() public {
        address spender = makeAddr("spender");
        _attestIdentityWithCountry(spender, IRAN);
        _attestIdentityWithCountry(alice, US);
        _attestIdentityWithCountry(bob, US);

        uint8 code = rule.detectTransferRestrictionFrom(spender, alice, bob, 100);
        assertEq(code, TRANSFER_OK, "spender residency is OFAC's domain, not ours");
    }

    // ============ End-to-end through CMTAT transfer ============

    function test_Transfer_BlockedWhenRecipientInBlockedCountry() public {
        // Also attach KYC at BASIC so transfers require attested recipients.
        RuleKYC kyc =
            _deployRuleKYC(address(company), address(providerRegistry), identitySchema, ShareholderSchemas.KYC_BASIC);
        // Board holds admin after _transferAdminToBoard(); test contract already renounced.
        vm.prank(board);
        ruleEngine.addRuleValidation(IRuleValidation(address(kyc)));

        _attestIdentityWithCountry(alice, US);

        // Initial issuance to alice
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        // Attest bob as IRAN
        _attestIdentityWithCountry(bob, IRAN);

        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 100);
    }

    function test_Transfer_AllowedAfterCountryRemovedFromBlocklist() public {
        _attestIdentityWithCountry(alice, US);
        _attestIdentityWithCountry(bob, IRAN);

        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 100);

        vm.prank(board);
        rule.removeCountry(IRAN);

        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 100));
        assertEq(shareToken.balanceOf(bob), 100);
    }

    // ============ addCountry / removeCountry / setCountries ============

    function test_AddCountry_Succeeds() public {
        vm.expectEmit(true, true, true, true);
        emit RuleCountryBlocklist.CountryAdded(GB);

        vm.prank(board);
        rule.addCountry(GB);

        assertTrue(rule.isCountryBlocked(GB));
        assertEq(rule.blockedCountryCount(), 4);
    }

    function test_AddCountry_OnlyBoard() public {
        vm.expectRevert(RuleCountryBlocklist.OnlyBoard.selector);
        vm.prank(alice);
        rule.addCountry(GB);
    }

    function test_AddCountry_RevertsOnDuplicate() public {
        vm.expectRevert(abi.encodeWithSelector(RuleCountryBlocklist.DuplicateCountry.selector, IRAN));
        vm.prank(board);
        rule.addCountry(IRAN);
    }

    function test_AddCountry_RevertsOnZero() public {
        vm.expectRevert(RuleCountryBlocklist.ZeroCountry.selector);
        vm.prank(board);
        rule.addCountry(0);
    }

    function test_RemoveCountry_Succeeds_AndSwapPopPreservesLookup() public {
        // IRAN (index 0), NORTH_KOREA (1), SYRIA (2). Remove IRAN -- SYRIA should swap into index 0.
        vm.expectEmit(true, true, true, true);
        emit RuleCountryBlocklist.CountryRemoved(IRAN);

        vm.prank(board);
        rule.removeCountry(IRAN);

        assertFalse(rule.isCountryBlocked(IRAN));
        assertTrue(rule.isCountryBlocked(NORTH_KOREA));
        assertTrue(rule.isCountryBlocked(SYRIA));
        assertEq(rule.blockedCountryCount(), 2);

        // Verify swap-and-pop left the remaining pair still addressable (remove NORTH_KOREA)
        vm.prank(board);
        rule.removeCountry(NORTH_KOREA);
        assertFalse(rule.isCountryBlocked(NORTH_KOREA));
        assertTrue(rule.isCountryBlocked(SYRIA));
        assertEq(rule.blockedCountryCount(), 1);
    }

    function test_RemoveCountry_OnlyBoard() public {
        vm.expectRevert(RuleCountryBlocklist.OnlyBoard.selector);
        vm.prank(alice);
        rule.removeCountry(IRAN);
    }

    function test_RemoveCountry_RevertsWhenNotBlocked() public {
        vm.expectRevert(abi.encodeWithSelector(RuleCountryBlocklist.CountryNotBlocked.selector, GB));
        vm.prank(board);
        rule.removeCountry(GB);
    }

    function test_SetCountries_WholesaleReplacesList() public {
        uint16[] memory next = new uint16[](2);
        next[0] = GB;
        next[1] = US;

        vm.expectEmit(true, true, true, true);
        emit RuleCountryBlocklist.CountriesReplaced(next);

        vm.prank(board);
        rule.setCountries(next);

        assertEq(rule.blockedCountryCount(), 2);
        assertTrue(rule.isCountryBlocked(GB));
        assertTrue(rule.isCountryBlocked(US));
        // Previous entries gone
        assertFalse(rule.isCountryBlocked(IRAN));
        assertFalse(rule.isCountryBlocked(NORTH_KOREA));
        assertFalse(rule.isCountryBlocked(SYRIA));
    }

    function test_SetCountries_OnlyBoard() public {
        uint16[] memory next = new uint16[](1);
        next[0] = GB;
        vm.expectRevert(RuleCountryBlocklist.OnlyBoard.selector);
        vm.prank(alice);
        rule.setCountries(next);
    }

    function test_SetCountries_RevertsOnDuplicate() public {
        uint16[] memory next = new uint16[](2);
        next[0] = GB;
        next[1] = GB;
        vm.expectRevert(abi.encodeWithSelector(RuleCountryBlocklist.DuplicateCountry.selector, GB));
        vm.prank(board);
        rule.setCountries(next);
    }

    function test_SetCountries_EmptyClearsList() public {
        uint16[] memory next = new uint16[](0);
        vm.prank(board);
        rule.setCountries(next);
        assertEq(rule.blockedCountryCount(), 0);
    }

    function test_GetBlockedCountries_ReturnsFullList() public view {
        uint16[] memory list = rule.getBlockedCountries();
        assertEq(list.length, 3);
        assertEq(list[0], IRAN);
        assertEq(list[1], NORTH_KOREA);
        assertEq(list[2], SYRIA);
    }

    // ============ Misc / rule-engine surface ============

    function test_CanReturnTransferRestrictionCode() public view {
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_SENDER_COUNTRY_BLOCKED()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_RECIPIENT_COUNTRY_BLOCKED()));
        assertFalse(rule.canReturnTransferRestrictionCode(TRANSFER_OK));
        assertFalse(rule.canReturnTransferRestrictionCode(99));
    }

    function test_MessageForTransferRestriction() public view {
        assertEq(
            rule.messageForTransferRestriction(rule.CODE_SENDER_COUNTRY_BLOCKED()),
            "Sender resides in a blocked country"
        );
        assertEq(
            rule.messageForTransferRestriction(rule.CODE_RECIPIENT_COUNTRY_BLOCKED()),
            "Recipient resides in a blocked country"
        );
        assertEq(rule.messageForTransferRestriction(99), "Unknown restriction code");
    }

    function test_SupportsInterface() public view {
        assertTrue(rule.supportsInterface(type(IRuleCloneable).interfaceId));
        assertTrue(rule.supportsInterface(type(IRuleCountryBlocklist).interfaceId));
        // Must not pretend to be any other rule type
        assertFalse(rule.supportsInterface(type(IRuleKYC).interfaceId));
        assertFalse(rule.supportsInterface(type(IRuleOFAC).interfaceId));
        assertFalse(rule.supportsInterface(0xdeadbeef));
    }
}
