// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import {RuleRegistry} from "../../src/RuleRegistry.sol";
import {IRuleRegistry} from "../../src/interfaces/rules/IRuleRegistry.sol";
import {RuleOFAC} from "../../src/rules/RuleOFAC.sol";
import {RuleCountryBlocklist} from "../../src/rules/RuleCountryBlocklist.sol";
import {MockChainalysisOracle} from "../../src/mocks/MockChainalysisOracle.sol";
import {CompanyShareClasses} from "../../src/mixins/CompanyShareClasses.sol";
import {CompanyStorage} from "../../src/mixins/CompanyStorage.sol";

/// @title BoardRuleAttachmentTest
/// @notice Exercises `Company.deployAndAttachRule` across two regimes:
///         - without a registry wired (legacy / local-dev) -> no jurisdiction gate, board can attach any cloneable rule
///         - with a registry wired -> only impls approved for the company's (countryCode, entityType) can attach
contract BoardRuleAttachmentTest is BaseTest {
    uint16 constant US = 840;
    uint8 constant CCORP = 1;
    uint16 constant CH = 756;
    uint8 constant AG = 1;

    RuleRegistry registry;
    RuleOFAC ofacImpl;
    RuleKYC kycImpl;
    RuleCountryBlocklist countryImpl;
    MockChainalysisOracle oracle;

    event AddRule(address indexed rule);
    event RuleDeployed(address indexed token, address indexed clone, address indexed impl, string className);

    function setUp() public {
        _baseSetUp();
        _setupEAS();
        _setupCompany(); // Deploys a US (840, 1) company. Registry not yet wired.

        ofacImpl = new RuleOFAC();
        kycImpl = new RuleKYC();
        countryImpl = new RuleCountryBlocklist();
        oracle = new MockChainalysisOracle(address(this));
    }

    // ============ Helpers ============

    /// @dev Wire the registry with OFAC (approved) + CountryBlocklist (approved) for US C-Corp.
    ///      kycImpl is intentionally left UN-approved for the unapproved-impl tests.
    function _wireRegistryWithApprovals() internal {
        RuleRegistry impl = new RuleRegistry();
        registry = RuleRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RuleRegistry.initialize, (factoryOwner))))
        );
        vm.prank(factoryOwner);
        factory.setRuleRegistry(address(registry));

        uint16[] memory blocked = new uint16[](2);
        blocked[0] = 364; // Iran
        blocked[1] = 408; // North Korea

        IRuleRegistry.RuleConfig[] memory rules = new IRuleRegistry.RuleConfig[](2);
        rules[0] = IRuleRegistry.RuleConfig({impl: address(ofacImpl), initData: abi.encode(address(oracle))});
        rules[1] = IRuleRegistry.RuleConfig({
            impl: address(countryImpl), initData: abi.encode(address(providerRegistry), identitySchema, blocked)
        });

        vm.prank(factoryOwner);
        registry.setRules(US, CCORP, rules);
    }

    // ============ Without registry: open-attach behaviour ============

    function test_DeployAndAttach_AddsCloneToRuleEngine() public {
        RuleEngine re = RuleEngine(address(shareToken.ruleEngine()));
        assertEq(re.rulesCountValidation(), 0, "engine starts empty; board attaches explicitly");

        vm.prank(board);
        address clone = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));

        assertTrue(clone != address(ofacImpl));
        assertEq(re.rulesCountValidation(), 1);
        assertEq(re.ruleValidation(0), clone);

        RuleOFAC attached = RuleOFAC(clone);
        assertEq(address(attached.company()), address(company));
        assertEq(address(attached.oracle()), address(oracle));
    }

    function test_DeployAndAttach_EmitsBothEvents() public {
        // CMTAT's RuleEngine fires AddRule(address indexed rule) inside addRuleValidation.
        // We don't know the clone address pre-Clones.clone, so only the emitter is asserted.
        vm.expectEmit(false, false, false, false, address(shareToken.ruleEngine()));
        emit AddRule(address(0));

        vm.expectEmit(true, false, false, false, address(company));
        emit RuleDeployed(address(shareToken), address(0), address(0), "Common");

        vm.prank(board);
        company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));
    }

    function test_DeployAndAttach_SameImplTwice_Reverts() public {
        vm.prank(board);
        company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));

        vm.prank(board);
        vm.expectRevert(abi.encodeWithSelector(CompanyShareClasses.RuleAlreadyAttached.selector, address(ofacImpl)));
        company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));

        // Only one clone on the engine
        RuleEngine re = RuleEngine(address(shareToken.ruleEngine()));
        assertEq(re.rulesCountValidation(), 1);
    }

    // ============ Detach ============

    function test_Detach_RemovesRuleFromEngine() public {
        vm.prank(board);
        address clone = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));

        RuleEngine re = RuleEngine(address(shareToken.ruleEngine()));
        assertEq(re.rulesCountValidation(), 1);
        assertEq(company.attachedRules(address(shareToken), address(ofacImpl)), clone);

        vm.prank(board);
        company.detachRule("Common", address(ofacImpl));

        assertEq(re.rulesCountValidation(), 0);
        assertEq(company.attachedRules(address(shareToken), address(ofacImpl)), address(0));
    }

    function test_Detach_ThenReattach_WithDifferentInitData() public {
        MockChainalysisOracle oracle2 = new MockChainalysisOracle(address(this));

        vm.startPrank(board);
        address c1 = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));
        company.detachRule("Common", address(ofacImpl));
        address c2 = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle2)));
        vm.stopPrank();

        assertTrue(c1 != c2, "fresh clone on re-attach");
        assertEq(address(RuleOFAC(c2).oracle()), address(oracle2));
        RuleEngine re = RuleEngine(address(shareToken.ruleEngine()));
        assertEq(re.rulesCountValidation(), 1);
        assertEq(re.ruleValidation(0), c2);
    }

    function test_Detach_OnlyBoard() public {
        vm.prank(board);
        company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));

        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.detachRule("Common", address(ofacImpl));
    }

    function test_Detach_RevertsOnUnknownClassName() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.NotFound.selector);
        company.detachRule("Nonexistent", address(ofacImpl));
    }

    function test_Detach_RevertsIfNotAttached() public {
        vm.prank(board);
        vm.expectRevert(abi.encodeWithSelector(CompanyShareClasses.RuleNotAttached.selector, address(ofacImpl)));
        company.detachRule("Common", address(ofacImpl));
    }

    function test_DeployAndAttach_DifferentRuleTypes_Coexist() public {
        vm.startPrank(board);
        address ofacClone = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));
        address kycClone = company.deployAndAttachRule(
            "Common",
            address(kycImpl),
            abi.encode(address(providerRegistry), identitySchema, ShareholderSchemas.KYC_BASIC)
        );
        vm.stopPrank();

        RuleEngine re = RuleEngine(address(shareToken.ruleEngine()));
        assertEq(re.rulesCountValidation(), 2);
        assertEq(re.ruleValidation(0), ofacClone);
        assertEq(re.ruleValidation(1), kycClone);

        RuleKYC kyc = RuleKYC(kycClone);
        assertEq(kyc.requiredKycLevel(), ShareholderSchemas.KYC_BASIC);
        assertEq(address(kyc.company()), address(company));
    }

    function test_DeployAndAttach_AttachedRuleIsControlledByBoard() public {
        // Dynamic-board lookup flows through: a board-deployed clone is controlled by the current board.
        vm.prank(board);
        address clone = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));

        vm.prank(board);
        RuleOFAC(clone).setOracle(address(0));
        assertEq(address(RuleOFAC(clone).oracle()), address(0));
    }

    // ============ Input validation ============

    function test_DeployAndAttach_RevertsForNonBoard() public {
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));
    }

    function test_DeployAndAttach_RevertsOnUnknownClassName() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.NotFound.selector);
        company.deployAndAttachRule("Nonexistent", address(ofacImpl), abi.encode(address(oracle)));
    }

    function test_DeployAndAttach_RevertsOnZeroImpl() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        company.deployAndAttachRule("Common", address(0), "");
    }

    function test_DeployAndAttach_RevertsOnNotCloneableImpl() public {
        address notARule = address(musd); // real ERC-20 but doesn't advertise IRuleCloneable
        vm.prank(board);
        vm.expectRevert(abi.encodeWithSelector(CompanyShareClasses.RuleNotCloneable.selector, notARule));
        company.deployAndAttachRule("Common", notARule, "");
    }

    // ============ With registry wired: jurisdictional gate ============

    function test_Gate_ApprovedAutoApplyImpl_Attaches() public {
        _wireRegistryWithApprovals();
        vm.prank(board);
        address clone = company.deployAndAttachRule("Common", address(ofacImpl), abi.encode(address(oracle)));
        assertTrue(clone != address(ofacImpl));
    }

    function test_Gate_ApprovedOptInImpl_Attaches() public {
        _wireRegistryWithApprovals();
        uint16[] memory blocked = new uint16[](1);
        blocked[0] = 364;

        vm.prank(board);
        address clone = company.deployAndAttachRule(
            "Common", address(countryImpl), abi.encode(address(providerRegistry), identitySchema, blocked)
        );
        assertTrue(clone != address(countryImpl));
    }

    function test_Gate_UnapprovedImpl_Reverts() public {
        _wireRegistryWithApprovals();
        // kycImpl is a valid RuleCloneable but wasn't added to (840, 1) by _wireRegistryWithApprovals.
        vm.prank(board);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompanyShareClasses.RuleNotApprovedForJurisdiction.selector, address(kycImpl), US, CCORP
            )
        );
        company.deployAndAttachRule(
            "Common",
            address(kycImpl),
            abi.encode(address(providerRegistry), identitySchema, ShareholderSchemas.KYC_BASIC)
        );
    }

    function test_Gate_ImplApprovedElsewhere_Reverts() public {
        _wireRegistryWithApprovals();

        // Remove CountryBlocklist from US approvals; re-register only under CH.
        IRuleRegistry.RuleConfig[] memory usRules = new IRuleRegistry.RuleConfig[](1);
        usRules[0] = IRuleRegistry.RuleConfig({impl: address(ofacImpl), initData: abi.encode(address(oracle))});
        uint16[] memory blocked = new uint16[](1);
        blocked[0] = 364;
        IRuleRegistry.RuleConfig[] memory chRules = new IRuleRegistry.RuleConfig[](1);
        chRules[0] = IRuleRegistry.RuleConfig({
            impl: address(countryImpl), initData: abi.encode(address(providerRegistry), identitySchema, blocked)
        });

        vm.startPrank(factoryOwner);
        registry.setRules(US, CCORP, usRules);
        registry.setRules(CH, AG, chRules);
        vm.stopPrank();

        // Our US company cannot reach the CH-only registration.
        vm.prank(board);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompanyShareClasses.RuleNotApprovedForJurisdiction.selector, address(countryImpl), US, CCORP
            )
        );
        company.deployAndAttachRule(
            "Common", address(countryImpl), abi.encode(address(providerRegistry), identitySchema, blocked)
        );
    }

    function test_Gate_AfterRemoveRule_Reverts() public {
        _wireRegistryWithApprovals();
        uint16[] memory blocked = new uint16[](1);
        blocked[0] = 364;

        // Initially succeeds.
        vm.prank(board);
        company.deployAndAttachRule(
            "Common", address(countryImpl), abi.encode(address(providerRegistry), identitySchema, blocked)
        );

        // Admin revokes approval.
        vm.prank(factoryOwner);
        registry.removeRule(US, CCORP, address(countryImpl));

        // Attach now fails — an existing clone is still live but future attachments are gated.
        vm.prank(board);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompanyShareClasses.RuleNotApprovedForJurisdiction.selector, address(countryImpl), US, CCORP
            )
        );
        company.deployAndAttachRule(
            "Common", address(countryImpl), abi.encode(address(providerRegistry), identitySchema, blocked)
        );
    }
}
