// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import {RuleOFAC} from "../../src/rules/RuleOFAC.sol";
import {IRuleCloneable} from "../../src/interfaces/rules/IRuleCloneable.sol";
import {IRuleOFAC} from "../../src/interfaces/rules/IRuleOFAC.sol";
import {IRuleKYC} from "../../src/interfaces/rules/IRuleKYC.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockChainalysisOracle} from "../../src/mocks/MockChainalysisOracle.sol";

contract RuleOFACTest is BaseTest {
    RuleOFAC public ruleOFAC;
    MockChainalysisOracle public sanctionsOracle;

    address public cleanAddress = makeAddr("clean");

    function setUp() public {
        _setupRuleTest();
    }

    function _deployAndAddRules() internal override {
        sanctionsOracle = new MockChainalysisOracle(address(this));

        RuleOFAC impl = new RuleOFAC();
        address clone = Clones.clone(address(impl));
        RuleOFAC(clone).initialize(abi.encode(address(sanctionsOracle)), address(company));
        ruleOFAC = RuleOFAC(clone);

        ruleEngine.addRuleValidation(IRuleValidation(address(ruleOFAC)));
    }

    function _issueInitialShares() internal override {
        vm.startPrank(address(issuance));
        shareToken.issueShares(founder, 100_000);
        shareToken.issueShares(investor, 50_000);
        shareToken.issueShares(cleanAddress, 50_000);
        vm.stopPrank();
    }

    // ============ Initialize ============

    function test_Initialize() public view {
        assertEq(address(ruleOFAC.company()), address(company));
        assertEq(address(ruleOFAC.oracle()), address(sanctionsOracle));
    }

    function test_Initialize_RevertsOnBadParams() public {
        RuleOFAC impl = new RuleOFAC();

        address c1 = Clones.clone(address(impl));
        vm.expectRevert(RuleOFAC.ZeroAddress.selector);
        RuleOFAC(c1).initialize(abi.encode(address(sanctionsOracle)), address(0));
    }

    function test_Initialize_AcceptsZeroOracle() public {
        // Zero oracle is a valid starting state — sanctions effectively disabled until the board sets one.
        RuleOFAC impl = new RuleOFAC();
        address clone = Clones.clone(address(impl));
        RuleOFAC(clone).initialize(abi.encode(address(0)), address(company));
        assertEq(address(RuleOFAC(clone).oracle()), address(0));
    }

    // ============ Transfer restrictions ============

    function test_TransferAllowedAfterRemovingFromSanctionsList() public {
        sanctionsOracle.addToSanctionsList(founder);

        vm.prank(founder);
        vm.expectRevert();
        shareToken.transfer(investor, 1000);

        sanctionsOracle.removeFromSanctionsList(founder);

        vm.prank(founder);
        assertTrue(shareToken.transfer(investor, 1000));
    }

    function test_MintingBlockedToSanctionedAddress() public {
        sanctionsOracle.addToSanctionsList(cleanAddress);

        vm.prank(address(company));
        vm.expectRevert();
        shareToken.issueShares(cleanAddress, 10_000);
    }

    function test_BurningBlockedFromSanctionedAddress() public {
        sanctionsOracle.addToSanctionsList(founder);

        vm.prank(address(board));
        vm.expectRevert();
        shareToken.burn(founder, 10_000);
    }

    function test_DetectTransferRestriction_SenderSanctioned() public {
        sanctionsOracle.addToSanctionsList(founder);

        uint8 code = ruleOFAC.detectTransferRestriction(founder, investor, 1000);
        assertEq(code, ruleOFAC.CODE_ADDRESS_FROM_IS_SANCTIONED());
        assertEq(ruleOFAC.messageForTransferRestriction(code), "The sender is sanctioned");
    }

    function test_DetectTransferRestriction_RecipientSanctioned() public {
        sanctionsOracle.addToSanctionsList(investor);

        uint8 code = ruleOFAC.detectTransferRestriction(founder, investor, 1000);
        assertEq(code, ruleOFAC.CODE_ADDRESS_TO_IS_SANCTIONED());
        assertEq(ruleOFAC.messageForTransferRestriction(code), "The recipient is sanctioned");
    }

    function test_DetectTransferRestriction_NoSanctions() public view {
        uint8 code = ruleOFAC.detectTransferRestriction(founder, investor, 1000);
        assertEq(code, 0);
    }

    function test_DetectTransferRestrictionFrom_SpenderSanctioned() public {
        address spender = makeAddr("spender");
        sanctionsOracle.addToSanctionsList(spender);

        uint8 code = ruleOFAC.detectTransferRestrictionFrom(spender, founder, investor, 1000);
        assertEq(code, ruleOFAC.CODE_ADDRESS_SPENDER_IS_SANCTIONED());
    }

    // ============ setOracle ============

    function test_SetOracle_SwapsOracle() public {
        MockChainalysisOracle newOracle = new MockChainalysisOracle(address(this));
        newOracle.addToSanctionsList(investor);

        // Transfer works under the old oracle
        vm.prank(founder);
        assertTrue(shareToken.transfer(investor, 1000));

        vm.prank(board);
        ruleOFAC.setOracle(address(newOracle));
        assertEq(address(ruleOFAC.oracle()), address(newOracle));

        // Transfer now blocked under the new oracle
        vm.prank(founder);
        vm.expectRevert();
        shareToken.transfer(investor, 1000);
    }

    function test_SetOracle_ZeroDisablesSanctions() public {
        sanctionsOracle.addToSanctionsList(founder);

        vm.prank(founder);
        vm.expectRevert();
        shareToken.transfer(investor, 1000);

        vm.prank(board);
        ruleOFAC.setOracle(address(0));

        vm.prank(founder);
        assertTrue(shareToken.transfer(investor, 1000));
    }

    function test_SetOracle_OnlyBoard() public {
        MockChainalysisOracle newOracle = new MockChainalysisOracle(address(this));

        vm.prank(founder);
        vm.expectRevert(RuleOFAC.OnlyBoard.selector);
        ruleOFAC.setOracle(address(newOracle));

        vm.prank(board);
        ruleOFAC.setOracle(address(newOracle));
        assertEq(address(ruleOFAC.oracle()), address(newOracle));
    }

    // ============ Misc ============

    function test_CanReturnTransferRestrictionCode() public view {
        assertTrue(ruleOFAC.canReturnTransferRestrictionCode(ruleOFAC.CODE_ADDRESS_FROM_IS_SANCTIONED()));
        assertTrue(ruleOFAC.canReturnTransferRestrictionCode(ruleOFAC.CODE_ADDRESS_TO_IS_SANCTIONED()));
        assertTrue(ruleOFAC.canReturnTransferRestrictionCode(ruleOFAC.CODE_ADDRESS_SPENDER_IS_SANCTIONED()));
        assertFalse(ruleOFAC.canReturnTransferRestrictionCode(0));
    }

    function test_SupportsInterface_IRuleCloneable() public view {
        assertTrue(ruleOFAC.supportsInterface(type(IRuleCloneable).interfaceId));
        assertFalse(ruleOFAC.supportsInterface(0xdeadbeef));
    }

    function test_SupportsInterface_IRuleOFAC_AndOnlyThatRuleType() public view {
        // Per-rule interface ID lets dapp distinguish rule types without method-name probing.
        assertTrue(ruleOFAC.supportsInterface(type(IRuleOFAC).interfaceId));
        // OFAC must NOT pretend to be KYC or Lockup
        assertFalse(ruleOFAC.supportsInterface(type(IRuleKYC).interfaceId));
    }
}
