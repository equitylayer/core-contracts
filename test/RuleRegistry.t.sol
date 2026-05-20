// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "forge-std/Test.sol";
import {RuleRegistry} from "../src/RuleRegistry.sol";
import {IRuleRegistry} from "../src/interfaces/rules/IRuleRegistry.sol";
import {RuleOFAC} from "../src/rules/RuleOFAC.sol";
import {RuleCountryBlocklist} from "../src/rules/RuleCountryBlocklist.sol";
import {RuleKYC} from "../src/rules/RuleKYC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RuleRegistryTest is Test {
    RuleRegistry public registry;

    address owner = address(0xABCD);
    address rando = address(0xBAD);

    // Real rule implementations — all advertise IRuleCloneable via ERC-165.
    address ruleA;
    address ruleB;
    address ruleC;

    uint16 constant US = 840;
    uint8 constant CCORP = 1;
    uint16 constant UK = 826;
    uint8 constant LTD = 1;

    event RulesSet(uint16 indexed countryCode, uint8 indexed entityType, IRuleRegistry.RuleConfig[] rules);
    event RuleAdded(uint16 indexed countryCode, uint8 indexed entityType, address indexed impl);
    event RuleRemoved(uint16 indexed countryCode, uint8 indexed entityType, address indexed impl);

    function setUp() public {
        RuleRegistry impl = new RuleRegistry();
        registry =
            RuleRegistry(address(new ERC1967Proxy(address(impl), abi.encodeCall(RuleRegistry.initialize, (owner)))));

        ruleA = address(new RuleOFAC());
        ruleB = address(new RuleCountryBlocklist());
        ruleC = address(new RuleKYC());
    }

    function _cfg(address impl) internal pure returns (IRuleRegistry.RuleConfig memory) {
        return IRuleRegistry.RuleConfig({impl: impl, initData: ""});
    }

    function _one(address impl) internal pure returns (IRuleRegistry.RuleConfig[] memory out) {
        out = new IRuleRegistry.RuleConfig[](1);
        out[0] = _cfg(impl);
    }

    function _empty() internal pure returns (IRuleRegistry.RuleConfig[] memory) {
        return new IRuleRegistry.RuleConfig[](0);
    }

    // ============ Initialize ============

    function test_Initialize() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.VERSION(), "0.9.0");
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        registry.initialize(rando);
    }

    function test_Initialize_RevertZeroOwner() public {
        RuleRegistry impl = new RuleRegistry();
        vm.expectRevert(RuleRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(RuleRegistry.initialize, (address(0))));
    }

    // ============ setRules ============

    function test_SetRules_StoresList() public {
        IRuleRegistry.RuleConfig[] memory rules = new IRuleRegistry.RuleConfig[](2);
        rules[0] = _cfg(ruleA);
        rules[1] = _cfg(ruleB);

        vm.prank(owner);
        registry.setRules(US, CCORP, rules);

        IRuleRegistry.RuleConfig[] memory got = registry.getRules(US, CCORP);
        assertEq(got.length, 2);
        assertEq(got[0].impl, ruleA);
        assertEq(got[1].impl, ruleB);
    }

    function test_SetRules_EmptyClears() public {
        vm.startPrank(owner);
        registry.setRules(US, CCORP, _one(ruleA));
        registry.setRules(US, CCORP, _empty());
        vm.stopPrank();
        assertEq(registry.getRules(US, CCORP).length, 0);
    }

    function test_SetRules_OverwritesWholesale() public {
        vm.startPrank(owner);
        registry.setRules(US, CCORP, _one(ruleA));
        registry.setRules(US, CCORP, _one(ruleB));
        vm.stopPrank();

        IRuleRegistry.RuleConfig[] memory got = registry.getRules(US, CCORP);
        assertEq(got.length, 1);
        assertEq(got[0].impl, ruleB);
    }

    function test_SetRules_JurisdictionsAreIndependent() public {
        vm.startPrank(owner);
        registry.setRules(US, CCORP, _one(ruleA));
        registry.setRules(UK, LTD, _one(ruleB));
        vm.stopPrank();

        assertEq(registry.getRules(US, CCORP)[0].impl, ruleA);
        assertEq(registry.getRules(UK, LTD)[0].impl, ruleB);
        assertEq(registry.getRules(US, 99).length, 0);
    }

    function test_SetRules_EmitsEvent() public {
        IRuleRegistry.RuleConfig[] memory rules = _one(ruleA);

        vm.expectEmit(true, true, false, true);
        emit RulesSet(US, CCORP, rules);

        vm.prank(owner);
        registry.setRules(US, CCORP, rules);
    }

    function test_SetRules_OnlyOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        registry.setRules(US, CCORP, _one(ruleA));
    }

    function test_SetRules_RevertsOnZeroJurisdiction() public {
        vm.prank(owner);
        vm.expectRevert(RuleRegistry.InvalidJurisdiction.selector);
        registry.setRules(0, CCORP, _one(ruleA));
    }

    function test_SetRules_RevertsOnZeroImpl() public {
        vm.prank(owner);
        vm.expectRevert(RuleRegistry.ZeroAddress.selector);
        registry.setRules(US, CCORP, _one(address(0)));
    }

    function test_SetRules_RevertsOnEOAImpl() public {
        vm.prank(owner);
        vm.expectRevert(RuleRegistry.NotAContract.selector);
        registry.setRules(US, CCORP, _one(address(0xE0A)));
    }

    function test_SetRules_RevertsOnTooMany() public {
        IRuleRegistry.RuleConfig[] memory tooMany = new IRuleRegistry.RuleConfig[](registry.MAX_RULES() + 1);
        for (uint256 i = 0; i < tooMany.length; i++) {
            tooMany[i] = _cfg(ruleA);
        }
        vm.prank(owner);
        vm.expectRevert(RuleRegistry.TooManyRules.selector);
        registry.setRules(US, CCORP, tooMany);
    }

    function test_SetRules_RevertsOnDuplicate() public {
        IRuleRegistry.RuleConfig[] memory dup = new IRuleRegistry.RuleConfig[](2);
        dup[0] = _cfg(ruleA);
        dup[1] = _cfg(ruleA);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RuleRegistry.DuplicateRule.selector, ruleA));
        registry.setRules(US, CCORP, dup);
    }

    function test_SetRules_RevertsWhenImplNotCloneable() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RuleRegistry.NotCloneable.selector, address(this)));
        registry.setRules(US, CCORP, _one(address(this)));
    }

    function test_SetRules_StoresInitData() public {
        IRuleRegistry.RuleConfig[] memory rules = new IRuleRegistry.RuleConfig[](1);
        rules[0] = IRuleRegistry.RuleConfig({impl: ruleA, initData: hex"deadbeef"});

        vm.prank(owner);
        registry.setRules(US, CCORP, rules);

        assertEq(registry.getRules(US, CCORP)[0].initData, hex"deadbeef");
    }

    // ============ getRules ============

    function test_GetRules_EmptyWhenUnset() public view {
        assertEq(registry.getRules(US, CCORP).length, 0);
    }

    // ============ isApprovedFor ============

    function test_IsApprovedFor_TrueWhenPresent() public {
        IRuleRegistry.RuleConfig[] memory rules = new IRuleRegistry.RuleConfig[](2);
        rules[0] = _cfg(ruleA);
        rules[1] = _cfg(ruleB);
        vm.prank(owner);
        registry.setRules(US, CCORP, rules);

        assertTrue(registry.isApprovedFor(US, CCORP, ruleA));
        assertTrue(registry.isApprovedFor(US, CCORP, ruleB));
        assertFalse(registry.isApprovedFor(US, CCORP, ruleC));
    }

    function test_IsApprovedFor_JurisdictionIsolated() public {
        vm.prank(owner);
        registry.setRules(US, CCORP, _one(ruleA));

        assertTrue(registry.isApprovedFor(US, CCORP, ruleA));
        assertFalse(registry.isApprovedFor(UK, LTD, ruleA), "Swiss-cant-apply-US-laws equivalent");
    }

    function test_IsApprovedFor_SameImplCanLiveInMultipleJurisdictions() public {
        vm.startPrank(owner);
        registry.setRules(US, CCORP, _one(ruleA));
        registry.setRules(UK, LTD, _one(ruleA));
        vm.stopPrank();

        assertTrue(registry.isApprovedFor(US, CCORP, ruleA));
        assertTrue(registry.isApprovedFor(UK, LTD, ruleA));
    }

    function test_IsApprovedFor_FalseOnEmptyRegistry() public view {
        assertFalse(registry.isApprovedFor(US, CCORP, ruleA));
        assertFalse(registry.isApprovedFor(US, CCORP, address(0)));
    }

    // ============ addRule ============

    function test_AddRule_Appends() public {
        vm.startPrank(owner);
        registry.setRules(US, CCORP, _one(ruleA));
        registry.addRule(US, CCORP, _cfg(ruleB));
        vm.stopPrank();

        IRuleRegistry.RuleConfig[] memory got = registry.getRules(US, CCORP);
        assertEq(got.length, 2);
        assertEq(got[0].impl, ruleA);
        assertEq(got[1].impl, ruleB);
    }

    function test_AddRule_WorksOnEmptyJurisdiction() public {
        vm.prank(owner);
        registry.addRule(US, CCORP, _cfg(ruleA));

        assertEq(registry.getRules(US, CCORP)[0].impl, ruleA);
        assertTrue(registry.isApprovedFor(US, CCORP, ruleA));
    }

    function test_AddRule_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit RuleAdded(US, CCORP, ruleA);

        vm.prank(owner);
        registry.addRule(US, CCORP, _cfg(ruleA));
    }

    function test_AddRule_OnlyOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        registry.addRule(US, CCORP, _cfg(ruleA));
    }

    function test_AddRule_RevertsOnZeroJurisdiction() public {
        vm.prank(owner);
        vm.expectRevert(RuleRegistry.InvalidJurisdiction.selector);
        registry.addRule(0, CCORP, _cfg(ruleA));
    }

    function test_AddRule_RevertsOnZeroImpl() public {
        vm.prank(owner);
        vm.expectRevert(RuleRegistry.ZeroAddress.selector);
        registry.addRule(US, CCORP, _cfg(address(0)));
    }

    function test_AddRule_RevertsOnEOAImpl() public {
        vm.prank(owner);
        vm.expectRevert(RuleRegistry.NotAContract.selector);
        registry.addRule(US, CCORP, _cfg(address(0xE0A)));
    }

    function test_AddRule_RevertsOnNotCloneable() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RuleRegistry.NotCloneable.selector, address(this)));
        registry.addRule(US, CCORP, _cfg(address(this)));
    }

    function test_AddRule_RevertsOnDuplicate() public {
        vm.startPrank(owner);
        registry.addRule(US, CCORP, _cfg(ruleA));
        vm.expectRevert(abi.encodeWithSelector(RuleRegistry.DuplicateRule.selector, ruleA));
        registry.addRule(US, CCORP, _cfg(ruleA));
        vm.stopPrank();
    }

    function test_AddRule_RevertsWhenListFull() public {
        address[] memory impls = new address[](registry.MAX_RULES());
        for (uint256 i = 0; i < impls.length; i++) {
            impls[i] = address(new RuleOFAC());
        }

        vm.startPrank(owner);
        for (uint256 i = 0; i < impls.length; i++) {
            registry.addRule(US, CCORP, _cfg(impls[i]));
        }

        address extra = address(new RuleOFAC());
        vm.expectRevert(RuleRegistry.TooManyRules.selector);
        registry.addRule(US, CCORP, _cfg(extra));
        vm.stopPrank();
    }

    // ============ removeRule ============

    function test_RemoveRule_RemovesEntry() public {
        vm.startPrank(owner);
        registry.addRule(US, CCORP, _cfg(ruleA));
        registry.addRule(US, CCORP, _cfg(ruleB));
        registry.removeRule(US, CCORP, ruleA);
        vm.stopPrank();

        IRuleRegistry.RuleConfig[] memory got = registry.getRules(US, CCORP);
        assertEq(got.length, 1);
        assertEq(got[0].impl, ruleB);
        assertFalse(registry.isApprovedFor(US, CCORP, ruleA));
        assertTrue(registry.isApprovedFor(US, CCORP, ruleB));
    }

    function test_RemoveRule_SwapAndPopPreservesOthers() public {
        vm.startPrank(owner);
        registry.addRule(US, CCORP, _cfg(ruleA));
        registry.addRule(US, CCORP, _cfg(ruleB));
        registry.addRule(US, CCORP, _cfg(ruleC));
        registry.removeRule(US, CCORP, ruleA);
        vm.stopPrank();

        assertEq(registry.getRules(US, CCORP).length, 2);
        assertFalse(registry.isApprovedFor(US, CCORP, ruleA));
        assertTrue(registry.isApprovedFor(US, CCORP, ruleB));
        assertTrue(registry.isApprovedFor(US, CCORP, ruleC));
    }

    function test_RemoveRule_EmitsEvent() public {
        vm.startPrank(owner);
        registry.addRule(US, CCORP, _cfg(ruleA));

        vm.expectEmit(true, true, true, true);
        emit RuleRemoved(US, CCORP, ruleA);
        registry.removeRule(US, CCORP, ruleA);
        vm.stopPrank();
    }

    function test_RemoveRule_OnlyOwner() public {
        vm.prank(owner);
        registry.addRule(US, CCORP, _cfg(ruleA));

        vm.prank(rando);
        vm.expectRevert();
        registry.removeRule(US, CCORP, ruleA);
    }

    function test_RemoveRule_RevertsOnMissing() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RuleRegistry.RuleNotFound.selector, ruleA));
        registry.removeRule(US, CCORP, ruleA);
    }
}
