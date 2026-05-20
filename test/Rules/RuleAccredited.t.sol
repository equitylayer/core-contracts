// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {BaseTest} from "../helpers/BaseTest.sol";
import {RuleAccredited} from "../../src/rules/RuleAccredited.sol";
import {ShareholderSchemas} from "../../src/attestations/ShareholderSchemas.sol";
import {IRuleCloneable} from "../../src/interfaces/rules/IRuleCloneable.sol";
import {IRuleAccredited} from "../../src/interfaces/rules/IRuleAccredited.sol";
import {IRuleKYC} from "../../src/interfaces/rules/IRuleKYC.sol";
import {IRuleOFAC} from "../../src/interfaces/rules/IRuleOFAC.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract RuleAccreditedTest is BaseTest {
    uint8 constant TRANSFER_OK = 0;

    RuleAccredited public rule;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _setupRuleTest();
    }

    function _deployAndAddRules() internal override {
        rule = _deployRule(_defaultAcceptedTypes());
        ruleEngine.addRuleValidation(IRuleValidation(address(rule)));
    }

    function _issueInitialShares() internal override {}

    function _defaultAcceptedTypes() internal pure returns (uint8[] memory) {
        // Any US Reg 501(a) accredited type.
        uint8[] memory t = new uint8[](5);
        t[0] = ShareholderSchemas.ACCREDITED_US_INCOME;
        t[1] = ShareholderSchemas.ACCREDITED_US_NET_WORTH;
        t[2] = ShareholderSchemas.ACCREDITED_US_PROFESSIONAL;
        t[3] = ShareholderSchemas.ACCREDITED_US_ENTITY;
        t[4] = ShareholderSchemas.ACCREDITED_US_FAMILY_OFFICE;
        return t;
    }

    function _deployRule(uint8[] memory types) internal returns (RuleAccredited r) {
        RuleAccredited impl = new RuleAccredited();
        address clone = Clones.clone(address(impl));
        RuleAccredited(clone)
            .initialize(abi.encode(address(providerRegistry), accreditationSchema, types), address(company));
        r = RuleAccredited(clone);
    }

    function _attestAccreditation(address recipient, uint8 accreditationType, uint64 expiration)
        internal
        returns (bytes32)
    {
        ShareholderSchemas.AccreditationData memory data = ShareholderSchemas.AccreditationData({
            providerId: "obolos:test",
            externalId: "",
            accreditationType: accreditationType,
            qpType: ShareholderSchemas.QP_NONE,
            verifiedAt: 0,
            expiresAt: expiration
        });
        vm.prank(attestationOperator);
        return attestationProvider.attestAccreditation(recipient, data);
    }

    // ============ Initialize ============

    function test_Initialize() public view {
        assertEq(address(rule.company()), address(company));
        assertEq(address(rule.registry()), address(providerRegistry));
        assertEq(rule.accreditationSchema(), accreditationSchema);
        uint8[] memory types = rule.getAcceptedTypes();
        assertEq(types.length, 5);
        assertTrue(rule.isTypeAccepted(ShareholderSchemas.ACCREDITED_US_INCOME));
        assertFalse(rule.isTypeAccepted(ShareholderSchemas.ACCREDITED_UK_CERTIFIED_HNW));
    }

    function test_Initialize_RevertsOnBadParams() public {
        RuleAccredited impl = new RuleAccredited();
        uint8[] memory types = _defaultAcceptedTypes();

        address c1 = Clones.clone(address(impl));
        vm.expectRevert(RuleAccredited.ZeroAddress.selector);
        RuleAccredited(c1).initialize(abi.encode(address(providerRegistry), accreditationSchema, types), address(0));

        address c2 = Clones.clone(address(impl));
        vm.expectRevert(RuleAccredited.ZeroAddress.selector);
        RuleAccredited(c2).initialize(abi.encode(address(0), accreditationSchema, types), address(company));

        address c3 = Clones.clone(address(impl));
        vm.expectRevert(RuleAccredited.ZeroSchema.selector);
        RuleAccredited(c3).initialize(abi.encode(address(providerRegistry), bytes32(0), types), address(company));

        address c4 = Clones.clone(address(impl));
        vm.expectRevert(RuleAccredited.EmptyAcceptedTypes.selector);
        RuleAccredited(c4)
            .initialize(abi.encode(address(providerRegistry), accreditationSchema, new uint8[](0)), address(company));
    }

    function test_Initialize_RevertsOnDuplicateType() public {
        RuleAccredited impl = new RuleAccredited();
        address clone = Clones.clone(address(impl));
        uint8[] memory types = new uint8[](2);
        types[0] = ShareholderSchemas.ACCREDITED_US_INCOME;
        types[1] = ShareholderSchemas.ACCREDITED_US_INCOME;
        vm.expectRevert(
            abi.encodeWithSelector(
                RuleAccredited.DuplicateAcceptedType.selector, ShareholderSchemas.ACCREDITED_US_INCOME
            )
        );
        RuleAccredited(clone)
            .initialize(abi.encode(address(providerRegistry), accreditationSchema, types), address(company));
    }

    // ============ Transfer restriction ============

    function test_DetectTransferRestriction_RecipientAccredited() public {
        _attestAccreditation(bob, ShareholderSchemas.ACCREDITED_US_INCOME, 0);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_DetectTransferRestriction_NoAttestation_Rejects() public view {
        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_NOT_ACCREDITED(), "fail-closed: no attestation = rejected");
    }

    function test_DetectTransferRestriction_AccreditationExpired() public {
        vm.warp(1000);
        _attestAccreditation(bob, ShareholderSchemas.ACCREDITED_US_INCOME, uint64(block.timestamp + 100));

        vm.warp(block.timestamp + 200);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_ATTESTATION_EXPIRED());
    }

    function test_DetectTransferRestriction_AccreditationRevoked() public {
        bytes32 uid = _attestAccreditation(bob, ShareholderSchemas.ACCREDITED_US_INCOME, 0);

        vm.prank(attestationOperator);
        attestationProvider.revokeAttestation(accreditationSchema, uid);

        // revocation clears the registry index, so the lookup returns empty → NOT_ACCREDITED code
        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_NOT_ACCREDITED());
    }

    function test_DetectTransferRestriction_TypeNotAccepted() public {
        // UK HNW type — not in the default US-only acceptedTypes list.
        _attestAccreditation(bob, ShareholderSchemas.ACCREDITED_UK_CERTIFIED_HNW, 0);

        uint8 code = rule.detectTransferRestriction(alice, bob, 100);
        assertEq(code, rule.CODE_ACCREDITATION_TYPE_NOT_ACCEPTED());
    }

    function test_DetectTransferRestriction_Burn_Allowed() public view {
        uint8 code = rule.detectTransferRestriction(alice, address(0), 100);
        assertEq(code, TRANSFER_OK);
    }

    function test_DetectTransferRestriction_Mint_RequiresAccreditation() public view {
        uint8 code = rule.detectTransferRestriction(address(0), bob, 100);
        assertEq(code, rule.CODE_RECIPIENT_NOT_ACCREDITED(), "mint to unattested recipient rejected");
    }

    function test_DetectTransferRestrictionFrom_IgnoresSpender() public {
        address spender = makeAddr("spender");
        _attestAccreditation(bob, ShareholderSchemas.ACCREDITED_US_INCOME, 0);

        uint8 code = rule.detectTransferRestrictionFrom(spender, alice, bob, 100);
        assertEq(code, TRANSFER_OK);
    }

    // ============ setAcceptedTypes ============

    function test_SetAcceptedTypes_UpdatesSet() public {
        uint8[] memory newTypes = new uint8[](1);
        newTypes[0] = ShareholderSchemas.ACCREDITED_UK_CERTIFIED_HNW;

        vm.prank(board);
        rule.setAcceptedTypes(newTypes);

        assertTrue(rule.isTypeAccepted(ShareholderSchemas.ACCREDITED_UK_CERTIFIED_HNW));
        assertFalse(rule.isTypeAccepted(ShareholderSchemas.ACCREDITED_US_INCOME));
        assertEq(rule.getAcceptedTypes().length, 1);
    }

    function test_SetAcceptedTypes_EmitsEvent() public {
        uint8[] memory newTypes = new uint8[](1);
        newTypes[0] = ShareholderSchemas.ACCREDITED_EU_PROFESSIONAL;

        vm.expectEmit(false, false, false, false);
        emit RuleAccredited.AcceptedTypesUpdated(_defaultAcceptedTypes(), newTypes);

        vm.prank(board);
        rule.setAcceptedTypes(newTypes);
    }

    function test_SetAcceptedTypes_OnlyBoard() public {
        uint8[] memory newTypes = new uint8[](1);
        newTypes[0] = ShareholderSchemas.ACCREDITED_US_INCOME;
        vm.expectRevert(RuleAccredited.OnlyBoard.selector);
        vm.prank(alice);
        rule.setAcceptedTypes(newTypes);
    }

    function test_SetAcceptedTypes_RevertsOnEmpty() public {
        vm.expectRevert(RuleAccredited.EmptyAcceptedTypes.selector);
        vm.prank(board);
        rule.setAcceptedTypes(new uint8[](0));
    }

    function test_SetAcceptedTypes_RevertsOnDuplicate() public {
        uint8[] memory dup = new uint8[](2);
        dup[0] = ShareholderSchemas.ACCREDITED_EU_PROFESSIONAL;
        dup[1] = ShareholderSchemas.ACCREDITED_EU_PROFESSIONAL;
        vm.expectRevert(
            abi.encodeWithSelector(
                RuleAccredited.DuplicateAcceptedType.selector, ShareholderSchemas.ACCREDITED_EU_PROFESSIONAL
            )
        );
        vm.prank(board);
        rule.setAcceptedTypes(dup);
    }

    function test_SetAcceptedTypes_RevertsOnTooMany() public {
        uint8[] memory tooMany = new uint8[](rule.MAX_ACCEPTED_TYPES() + 1);
        for (uint256 i = 0; i < tooMany.length; i++) {
            tooMany[i] = uint8(i + 1);
        }
        vm.expectRevert(RuleAccredited.TooManyAcceptedTypes.selector);
        vm.prank(board);
        rule.setAcceptedTypes(tooMany);
    }

    function test_SetAcceptedTypes_NarrowingBlocksPreviouslyPassing() public {
        // Setup: bob accredited as professional; rule accepts it initially.
        _attestAccreditation(bob, ShareholderSchemas.ACCREDITED_US_PROFESSIONAL, 0);
        assertEq(rule.detectTransferRestriction(alice, bob, 100), TRANSFER_OK);

        // Board narrows to income-only → bob's professional attestation no longer accepted.
        uint8[] memory income = new uint8[](1);
        income[0] = ShareholderSchemas.ACCREDITED_US_INCOME;
        vm.prank(board);
        rule.setAcceptedTypes(income);

        assertEq(rule.detectTransferRestriction(alice, bob, 100), rule.CODE_ACCREDITATION_TYPE_NOT_ACCEPTED());
    }

    // ============ End-to-end through CMTAT ============

    function test_Transfer_BlockedWithoutAccreditation() public {
        _attestAccreditation(alice, ShareholderSchemas.ACCREDITED_US_INCOME, 0);

        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        // bob has no accreditation — transfer must fail
        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 100);
    }

    function test_Transfer_AllowedAfterAccreditation() public {
        _attestAccreditation(alice, ShareholderSchemas.ACCREDITED_US_INCOME, 0);

        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);

        _attestAccreditation(bob, ShareholderSchemas.ACCREDITED_US_ENTITY, 0);

        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 100));
        assertEq(shareToken.balanceOf(bob), 100);
    }

    // ============ Misc ============

    function test_CanReturnTransferRestrictionCode() public view {
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_RECIPIENT_NOT_ACCREDITED()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_ATTESTATION_EXPIRED()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_ATTESTATION_REVOKED()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_ACCREDITATION_TYPE_NOT_ACCEPTED()));
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_SCHEMA_MISMATCH()));
        assertFalse(rule.canReturnTransferRestrictionCode(TRANSFER_OK));
    }

    function test_MessageForTransferRestriction() public view {
        assertEq(
            rule.messageForTransferRestriction(rule.CODE_RECIPIENT_NOT_ACCREDITED()),
            "Recipient is not attested as accredited"
        );
        assertEq(
            rule.messageForTransferRestriction(rule.CODE_ATTESTATION_EXPIRED()), "Accreditation attestation has expired"
        );
        assertEq(rule.messageForTransferRestriction(99), "Unknown restriction code");
    }

    function test_SupportsInterface() public view {
        assertTrue(rule.supportsInterface(type(IRuleCloneable).interfaceId));
        assertTrue(rule.supportsInterface(type(IRuleAccredited).interfaceId));
        assertFalse(rule.supportsInterface(type(IRuleKYC).interfaceId));
        assertFalse(rule.supportsInterface(type(IRuleOFAC).interfaceId));
    }
}
