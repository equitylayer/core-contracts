// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import {RuleRegistry} from "../../src/RuleRegistry.sol";
import {IRuleRegistry} from "../../src/interfaces/rules/IRuleRegistry.sol";
import {RuleOFAC} from "../../src/rules/RuleOFAC.sol";
import {RuleKYC} from "../../src/rules/RuleKYC.sol";
import {RuleCountryBlocklist} from "../../src/rules/RuleCountryBlocklist.sol";
import {RuleAccredited} from "../../src/rules/RuleAccredited.sol";
import {RuleRegS} from "../../src/rules/RuleRegS.sol";
import {RuleHoldingPeriod} from "../../src/rules/RuleHoldingPeriod.sol";
import {MockChainalysisOracle} from "../../src/mocks/MockChainalysisOracle.sol";
import {CompanyShareClasses} from "../../src/mixins/CompanyShareClasses.sol";

/// @title USDelawareIntegrationTest
/// @notice End-to-end lifecycle of a US Delaware C-Corp issuer under the full (840, 1) approved rule
///         set. Mirrors the seed shape in [script/DeployFactories.s.sol](script/DeployFactories.s.sol).
///         Board explicitly attaches OFAC + KYC baseline after share-class deploy, then walks through:
///         baseline KYC tighten -> founder/employee issuance -> Reg D 506(c) round (Accredited +
///         HoldingPeriod) -> Reg S offshore tranche -> optional CountryBlocklist -> OFAC enforcement ->
///         post-expiry free transfers -> bind-once invariant -> jurisdictional isolation (Swiss company
///         can't reach US-only rules). One long test, read top to bottom.
contract USDelawareIntegrationTest is BaseTest {
    uint16 constant US = 840;
    uint8 constant CCORP = 1;
    uint16 constant CH = 756;
    uint8 constant AG = 1;

    uint16 constant CUBA = 192;
    uint16 constant IRAN = 364;
    uint16 constant DPRK = 408;
    uint16 constant SYRIA = 760;
    uint16 constant UK = 826;

    uint32 constant HOLDING_PERIOD = 180 days;
    uint64 constant REGS_COMPLIANCE = 40 days;

    RuleRegistry registry;
    RuleOFAC ofacImpl;
    RuleKYC kycImpl;
    RuleCountryBlocklist countryImpl;
    RuleAccredited accreditedImpl;
    RuleRegS regSImpl;
    RuleHoldingPeriod holdingImpl;
    MockChainalysisOracle oracle;

    // Cast
    address founder1 = makeAddr("founder1"); // US, accredited (income)
    address employee1 = makeAddr("employee1"); // US, accredited (entity)
    address regDInvestor = makeAddr("regDInvestor"); // US, accredited (professional)
    address unaccreditedUS = makeAddr("unaccreditedUS"); // US, NOT accredited
    address regSInvestor = makeAddr("regSInvestor"); // UK, non-US
    address iranianInvestor = makeAddr("iranianInvestor"); // IR, embargoed
    address sanctionedAddr = makeAddr("sanctionedAddr"); // on Chainalysis list

    function setUp() public {
        _baseSetUp();
        _setupEAS();

        RuleRegistry impl = new RuleRegistry();
        registry = RuleRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RuleRegistry.initialize, (factoryOwner))))
        );
        vm.prank(factoryOwner);
        factory.setRuleRegistry(address(registry));

        ofacImpl = new RuleOFAC();
        kycImpl = new RuleKYC();
        countryImpl = new RuleCountryBlocklist();
        accreditedImpl = new RuleAccredited();
        regSImpl = new RuleRegS();
        holdingImpl = new RuleHoldingPeriod();

        oracle = new MockChainalysisOracle(address(this));

        _seedDelawareRules();
    }

    /// @dev Mirrors the US (840, 1) seed from script/DeployFactories.s.sol::_seedRules.
    function _seedDelawareRules() internal {
        uint16[] memory ofacBaseline = new uint16[](4);
        ofacBaseline[0] = CUBA;
        ofacBaseline[1] = IRAN;
        ofacBaseline[2] = DPRK;
        ofacBaseline[3] = SYRIA;

        uint8[] memory usAccreditedTypes = new uint8[](5);
        usAccreditedTypes[0] = ShareholderSchemas.ACCREDITED_US_INCOME;
        usAccreditedTypes[1] = ShareholderSchemas.ACCREDITED_US_NET_WORTH;
        usAccreditedTypes[2] = ShareholderSchemas.ACCREDITED_US_PROFESSIONAL;
        usAccreditedTypes[3] = ShareholderSchemas.ACCREDITED_US_ENTITY;
        usAccreditedTypes[4] = ShareholderSchemas.ACCREDITED_US_FAMILY_OFFICE;

        IRuleRegistry.RuleConfig[] memory rules = new IRuleRegistry.RuleConfig[](6);
        rules[0] = IRuleRegistry.RuleConfig({impl: address(ofacImpl), initData: abi.encode(address(oracle))});
        rules[1] = IRuleRegistry.RuleConfig({
            impl: address(kycImpl),
            initData: abi.encode(address(providerRegistry), identitySchema, ShareholderSchemas.KYC_NONE)
        });
        rules[2] = IRuleRegistry.RuleConfig({
            impl: address(countryImpl), initData: abi.encode(address(providerRegistry), identitySchema, ofacBaseline)
        });
        rules[3] = IRuleRegistry.RuleConfig({
            impl: address(accreditedImpl),
            initData: abi.encode(address(providerRegistry), accreditationSchema, usAccreditedTypes)
        });
        rules[4] = IRuleRegistry.RuleConfig({
            impl: address(regSImpl), initData: abi.encode(address(providerRegistry), identitySchema, uint64(0))
        });
        rules[5] = IRuleRegistry.RuleConfig({impl: address(holdingImpl), initData: abi.encode(address(0), uint32(0))});

        vm.prank(factoryOwner);
        registry.setRules(US, CCORP, rules);
    }

    function _attestIdentity(address who, bool isUSPerson, uint16 countryCode, uint8 kycLevel) internal {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: countryCode,
            isUSPerson: isUSPerson,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: kycLevel,
            sanctionsCleared: true,
            verifiedAt: 0
        });
        vm.prank(attestationOperator);
        attestationProvider.attestIdentity(who, data, 0);
    }

    function _attestAccredited(address who, uint8 accreditationType) internal {
        ShareholderSchemas.AccreditationData memory data = ShareholderSchemas.AccreditationData({
            providerId: "obolos:test",
            externalId: "",
            accreditationType: accreditationType,
            qpType: ShareholderSchemas.QP_NONE,
            verifiedAt: 0,
            expiresAt: 0
        });
        vm.prank(attestationOperator);
        attestationProvider.attestAccreditation(who, data);
    }

    // ============ The whole flow ============

    function test_FullLifecycle() public {
        // -----------------------------------------------------------------------
        // 1. Factory deploys a Delaware C-Corp. Engine starts empty; board
        //    explicitly attaches the OFAC + KYC (level=NONE) baseline.
        // -----------------------------------------------------------------------
        _setupCompany();
        RuleEngine re = RuleEngine(address(shareToken.ruleEngine()));
        assertEq(re.rulesCountValidation(), 0, "engine starts empty");

        vm.startPrank(board);
        address ofacClone = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));
        address kycClone = company.deployAndAttachRule(
            "Common",
            address(kycImpl),
            abi.encode(address(providerRegistry), identitySchema, ShareholderSchemas.KYC_NONE)
        );
        vm.stopPrank();

        RuleOFAC ofac = RuleOFAC(ofacClone);
        RuleKYC kyc = RuleKYC(kycClone);
        assertEq(re.rulesCountValidation(), 2, "OFAC + KYC attached");
        assertEq(address(ofac.oracle()), address(oracle));
        assertEq(kyc.requiredKycLevel(), ShareholderSchemas.KYC_NONE);

        // -----------------------------------------------------------------------
        // 2. Board tightens KYC to BASIC. Founder and employee get attested and
        //    receive their stakes. An unattested recipient is blocked.
        // -----------------------------------------------------------------------
        vm.prank(board);
        kyc.setRequiredKycLevel(ShareholderSchemas.KYC_BASIC);

        _attestIdentity(founder1, true, US, ShareholderSchemas.KYC_BASIC);
        _attestAccredited(founder1, ShareholderSchemas.ACCREDITED_US_INCOME);
        _attestIdentity(employee1, true, US, ShareholderSchemas.KYC_BASIC);
        _attestAccredited(employee1, ShareholderSchemas.ACCREDITED_US_ENTITY);

        vm.startPrank(address(issuance));
        shareToken.issueShares(founder1, 500_000);
        shareToken.issueShares(employee1, 50_000);
        vm.stopPrank();
        assertEq(shareToken.balanceOf(founder1), 500_000);
        assertEq(shareToken.balanceOf(employee1), 50_000);

        vm.prank(address(issuance));
        vm.expectRevert();
        shareToken.issueShares(unaccreditedUS, 1);

        // -----------------------------------------------------------------------
        // 3. Reg D 506(c) round. Attach RuleAccredited + RuleHoldingPeriod (180d).
        //    Board supplies the real per-share-class token address to HoldingPeriod.
        // -----------------------------------------------------------------------
        uint8[] memory usTypes = new uint8[](5);
        usTypes[0] = ShareholderSchemas.ACCREDITED_US_INCOME;
        usTypes[1] = ShareholderSchemas.ACCREDITED_US_NET_WORTH;
        usTypes[2] = ShareholderSchemas.ACCREDITED_US_PROFESSIONAL;
        usTypes[3] = ShareholderSchemas.ACCREDITED_US_ENTITY;
        usTypes[4] = ShareholderSchemas.ACCREDITED_US_FAMILY_OFFICE;

        vm.startPrank(board);
        company.deployAndAttachRule(
            "Common", address(accreditedImpl), abi.encode(address(providerRegistry), accreditationSchema, usTypes)
        );
        address holdingClone = company.deployAndAttachRule(
            "Common", address(holdingImpl), abi.encode(address(shareToken), HOLDING_PERIOD)
        );
        vm.stopPrank();
        RuleHoldingPeriod holding = RuleHoldingPeriod(holdingClone);

        assertEq(re.rulesCountValidation(), 4, "OFAC + KYC + Accredited + HoldingPeriod");

        // Unaccredited US recipient rejected.
        _attestIdentity(unaccreditedUS, true, US, ShareholderSchemas.KYC_BASIC);
        vm.prank(address(issuance));
        vm.expectRevert();
        shareToken.issueShares(unaccreditedUS, 1);

        // Accredited investor receives shares + Rule 144 lot recorded.
        _attestIdentity(regDInvestor, true, US, ShareholderSchemas.KYC_BASIC);
        _attestAccredited(regDInvestor, ShareholderSchemas.ACCREDITED_US_PROFESSIONAL);
        uint256 regDAmount = 1000;
        vm.prank(address(issuance));
        shareToken.issueShares(regDInvestor, regDAmount);
        vm.prank(address(company));
        holding.recordIssuance(regDInvestor, regDAmount);

        assertEq(shareToken.balanceOf(regDInvestor), regDAmount);
        assertEq(holding.lockedBalance(regDInvestor), regDAmount);
        assertEq(holding.unlockedBalance(regDInvestor), 0);

        // Transfer during lockup -> blocked.
        vm.prank(regDInvestor);
        vm.expectRevert();
        shareToken.transfer(founder1, 100);

        // -----------------------------------------------------------------------
        // 4. Reg S offshore tranche on a SEPARATE share class — "Preferred-S".
        //    The Reg D Common class has Accredited attached (US-only types). Reg S buyers
        //    are non-US and wouldn't pass US accreditation checks, so the Reg S tranche
        //    lives on its own share class with RuleRegS (no Accredited).
        // -----------------------------------------------------------------------
        vm.deal(board, 10 ether);
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred-S", "Test Reg S", "TEST-S", 1_000_000, 1e6, 1, 0, ""
        );
        ShareToken regSToken = company.getShareToken("Preferred-S");
        RuleEngine regSRE = RuleEngine(address(regSToken.ruleEngine()));
        assertEq(regSRE.rulesCountValidation(), 0, "new share class starts with an empty engine");

        // Board attaches the baseline + Reg S on the new class.
        uint64 complianceEnd = uint64(block.timestamp) + REGS_COMPLIANCE;
        vm.startPrank(board);
        company.deployAndAttachRule("Preferred-S", address(ofacImpl), abi.encode(address(oracle)));
        address regSKycClone = company.deployAndAttachRule(
            "Preferred-S",
            address(kycImpl),
            abi.encode(address(providerRegistry), identitySchema, ShareholderSchemas.KYC_NONE)
        );
        company.deployAndAttachRule(
            "Preferred-S", address(regSImpl), abi.encode(address(providerRegistry), identitySchema, complianceEnd)
        );
        vm.stopPrank();

        // KYC on Reg S class also needs tightening (each share class has its own clones).
        RuleKYC regSKyc = RuleKYC(regSKycClone);
        vm.prank(board);
        regSKyc.setRequiredKycLevel(ShareholderSchemas.KYC_BASIC);

        _attestIdentity(regSInvestor, false, UK, ShareholderSchemas.KYC_BASIC);
        vm.prank(address(issuance));
        regSToken.issueShares(regSInvestor, 500);

        address anotherUSBuyer = makeAddr("anotherUSBuyer");
        _attestIdentity(anotherUSBuyer, true, US, ShareholderSchemas.KYC_BASIC);
        vm.prank(address(issuance));
        vm.expectRevert();
        regSToken.issueShares(anotherUSBuyer, 100);

        // -----------------------------------------------------------------------
        // 5. Attach CountryBlocklist. An Iranian investor (embargoed country) is
        //    blocked even though attested and accredited.
        // -----------------------------------------------------------------------
        uint16[] memory blocked = new uint16[](4);
        blocked[0] = CUBA;
        blocked[1] = IRAN;
        blocked[2] = DPRK;
        blocked[3] = SYRIA;
        vm.prank(board);
        company.deployAndAttachRule(
            "Common", address(countryImpl), abi.encode(address(providerRegistry), identitySchema, blocked)
        );

        _attestIdentity(iranianInvestor, false, IRAN, ShareholderSchemas.KYC_BASIC);
        _attestAccredited(iranianInvestor, ShareholderSchemas.ACCREDITED_US_INCOME);
        vm.prank(address(issuance));
        vm.expectRevert();
        shareToken.issueShares(iranianInvestor, 100);

        // -----------------------------------------------------------------------
        // 6. OFAC enforces Chainalysis sanctions regardless of other rule passes.
        //    Sanction -> blocked; un-sanction -> passes.
        // -----------------------------------------------------------------------
        oracle.addToSanctionsList(sanctionedAddr);
        _attestIdentity(sanctionedAddr, true, US, ShareholderSchemas.KYC_BASIC);
        _attestAccredited(sanctionedAddr, ShareholderSchemas.ACCREDITED_US_INCOME);
        vm.prank(founder1);
        vm.expectRevert();
        shareToken.transfer(sanctionedAddr, 100);

        oracle.removeFromSanctionsList(sanctionedAddr);
        vm.prank(founder1);
        assertTrue(shareToken.transfer(sanctionedAddr, 100));

        // -----------------------------------------------------------------------
        // 7. Warp past 180d lockup + Reg S window. Reg S is now dormant; Rule 144
        //    lockup released; Reg D investor can transfer freely.
        // -----------------------------------------------------------------------
        vm.warp(block.timestamp + HOLDING_PERIOD + 1);

        assertEq(holding.lockedBalance(regDInvestor), 0, "Rule 144 lockup expired");
        assertEq(holding.unlockedBalance(regDInvestor), regDAmount);

        vm.prank(regDInvestor);
        assertTrue(shareToken.transfer(founder1, 500));
        // founder1 started at 500_000, sent 100 to sanctionedAddr after un-sanction, received 500 back
        assertEq(shareToken.balanceOf(founder1), 500_000 - 100 + 500);

        // -----------------------------------------------------------------------
        // 8. Bind-once: registry mutation doesn't re-bind this share class.
        // -----------------------------------------------------------------------
        uint256 preChangeCount = re.rulesCountValidation();
        vm.prank(factoryOwner);
        registry.setRules(US, CCORP, new IRuleRegistry.RuleConfig[](0));
        assertEq(re.rulesCountValidation(), preChangeCount, "existing share class unaffected by registry change");

        // -----------------------------------------------------------------------
        // 9. Jurisdictional isolation: a Swiss GmbH cannot reach US-only rules.
        // -----------------------------------------------------------------------
        _seedDelawareRules(); // re-seed US (wiped above)
        IRuleRegistry.RuleConfig[] memory chRules = new IRuleRegistry.RuleConfig[](1);
        chRules[0] = IRuleRegistry.RuleConfig({impl: address(ofacImpl), initData: abi.encode(address(oracle))});
        vm.prank(factoryOwner);
        registry.setRules(CH, AG, chRules);

        vm.deal(board, 10 ether);
        vm.prank(board);
        CompanyFactory.DeploymentResult memory r =
            factory.deployCompany{value: 0.1 ether}("Swiss AG", "SAG", "", CH, AG, IERC20(address(musd)));
        vm.prank(board);
        Company(r.companyAddress).createShareClassWithToken{value: 0.05 ether}(
            "Common", "Swiss Common", "SAG-C", 1_000_000, 1e6, 1, 0, ""
        );
        Company swissCo = Company(r.companyAddress);

        // Swiss board attempting to attach US RuleAccredited -> gate rejects.
        vm.prank(board);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompanyShareClasses.RuleNotApprovedForJurisdiction.selector, address(accreditedImpl), CH, AG
            )
        );
        swissCo.deployAndAttachRule(
            "Common", address(accreditedImpl), abi.encode(address(providerRegistry), accreditationSchema, usTypes)
        );
    }
}
