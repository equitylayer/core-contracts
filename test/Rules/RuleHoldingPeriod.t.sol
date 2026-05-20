// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {BaseTest} from "../helpers/BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {RuleHoldingPeriod} from "../../src/rules/RuleHoldingPeriod.sol";
import {IRuleCloneable} from "../../src/interfaces/rules/IRuleCloneable.sol";
import {IRuleHoldingPeriod} from "../../src/interfaces/rules/IRuleHoldingPeriod.sol";
import {IRuleKYC} from "../../src/interfaces/rules/IRuleKYC.sol";
import {IRuleOFAC} from "../../src/interfaces/rules/IRuleOFAC.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract RuleHoldingPeriodTest is BaseTest {
    uint8 constant TRANSFER_OK = 0;
    uint32 constant SIX_MONTHS = 180 days;

    RuleHoldingPeriod public rule;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _setupRuleTest();
    }

    function _deployAndAddRules() internal override {
        rule = _deployRule(SIX_MONTHS);
        ruleEngine.addRuleValidation(IRuleValidation(address(rule)));
    }

    function _issueInitialShares() internal override {}

    function _deployRule(uint32 period) internal returns (RuleHoldingPeriod r) {
        RuleHoldingPeriod impl = new RuleHoldingPeriod();
        address clone = Clones.clone(address(impl));
        RuleHoldingPeriod(clone).initialize(abi.encode(address(shareToken), period), address(company));
        r = RuleHoldingPeriod(clone);
    }

    // ============ Initialize ============

    function test_Initialize() public view {
        assertEq(address(rule.company()), address(company));
        assertEq(address(rule.token()), address(shareToken));
        assertEq(rule.holdingPeriodSeconds(), SIX_MONTHS);
    }

    function test_Initialize_RevertsOnBadParams() public {
        RuleHoldingPeriod impl = new RuleHoldingPeriod();

        address c1 = Clones.clone(address(impl));
        vm.expectRevert(RuleHoldingPeriod.ZeroAddress.selector);
        RuleHoldingPeriod(c1).initialize(abi.encode(address(shareToken), SIX_MONTHS), address(0));

        address c2 = Clones.clone(address(impl));
        vm.expectRevert(RuleHoldingPeriod.ZeroAddress.selector);
        RuleHoldingPeriod(c2).initialize(abi.encode(address(0), SIX_MONTHS), address(company));
    }

    // ============ recordIssuance ============

    function test_RecordIssuance_AppendsLot() public {
        vm.prank(address(company));
        rule.recordIssuance(alice, 1000);

        RuleHoldingPeriod.Lot[] memory lots = rule.getLots(alice);
        assertEq(lots.length, 1);
        assertEq(lots[0].amount, 1000);
        assertEq(uint256(lots[0].unlockTime), block.timestamp + SIX_MONTHS);
    }

    function test_RecordIssuance_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit RuleHoldingPeriod.IssuanceRecorded(alice, 1000, uint64(block.timestamp + SIX_MONTHS));

        vm.prank(address(company));
        rule.recordIssuance(alice, 1000);
    }

    function test_RecordIssuance_OnlyCompany() public {
        vm.expectRevert(RuleHoldingPeriod.OnlyCompany.selector);
        vm.prank(board);
        rule.recordIssuance(alice, 1000);

        vm.expectRevert(RuleHoldingPeriod.OnlyCompany.selector);
        vm.prank(alice);
        rule.recordIssuance(alice, 1000);
    }

    function test_RecordIssuance_RevertsOnZeroAccount() public {
        vm.expectRevert(RuleHoldingPeriod.ZeroAddress.selector);
        vm.prank(address(company));
        rule.recordIssuance(address(0), 1000);
    }

    function test_RecordIssuance_RevertsOnZeroAmount() public {
        vm.expectRevert(RuleHoldingPeriod.ZeroAmount.selector);
        vm.prank(address(company));
        rule.recordIssuance(alice, 0);
    }

    function test_RecordIssuance_RevertsOnOverflowAmount() public {
        vm.expectRevert(RuleHoldingPeriod.AmountOverflow.selector);
        vm.prank(address(company));
        rule.recordIssuance(alice, uint256(type(uint128).max) + 1);
    }

    function test_RecordIssuance_MultipleLots() public {
        vm.startPrank(address(company));
        rule.recordIssuance(alice, 1000);
        vm.warp(block.timestamp + 30 days);
        rule.recordIssuance(alice, 500);
        vm.stopPrank();

        RuleHoldingPeriod.Lot[] memory lots = rule.getLots(alice);
        assertEq(lots.length, 2);
        assertEq(lots[0].amount, 1000);
        assertEq(lots[1].amount, 500);
        // Second lot unlocks later
        assertGt(uint256(lots[1].unlockTime), uint256(lots[0].unlockTime));
    }

    function test_RecordIssuance_RevertsOnTooManyLots() public {
        vm.startPrank(address(company));
        for (uint256 i = 0; i < rule.MAX_LOTS_PER_HOLDER(); i++) {
            rule.recordIssuance(alice, 1);
        }
        vm.expectRevert(RuleHoldingPeriod.TooManyLots.selector);
        rule.recordIssuance(alice, 1);
        vm.stopPrank();
    }

    // ============ lockedBalance / unlockedBalance ============

    function test_LockedBalance_SumsUnexpiredLots() public {
        vm.startPrank(address(company));
        rule.recordIssuance(alice, 1000);
        vm.warp(block.timestamp + 30 days);
        rule.recordIssuance(alice, 500);
        vm.stopPrank();

        assertEq(rule.lockedBalance(alice), 1500);
    }

    function test_LockedBalance_ExcludesExpiredLots() public {
        vm.prank(address(company));
        rule.recordIssuance(alice, 1000);

        // Before unlock
        assertEq(rule.lockedBalance(alice), 1000);

        // After unlock
        vm.warp(block.timestamp + SIX_MONTHS + 1);
        assertEq(rule.lockedBalance(alice), 0);
    }

    function test_UnlockedBalance_TrackBalanceMinusLocked() public {
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);
        vm.prank(address(company));
        rule.recordIssuance(alice, 300);

        assertEq(rule.unlockedBalance(alice), 700);
    }

    function test_UnlockedBalance_ZeroWhenLockedExceedsBalance() public {
        // Edge case: lot recorded but holder transferred shares out before unlock
        vm.prank(address(company));
        rule.recordIssuance(alice, 1000); // locked 1000
        // balance is still 0 (no actual mint)
        assertEq(rule.unlockedBalance(alice), 0);
    }

    // ============ Transfer validation ============

    function test_DetectTransferRestriction_BlocksLockedShares() public {
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);
        vm.prank(address(company));
        rule.recordIssuance(alice, 1000);

        uint8 code = rule.detectTransferRestriction(alice, bob, 500);
        assertEq(code, rule.CODE_INSUFFICIENT_UNLOCKED_BALANCE());
    }

    function test_DetectTransferRestriction_AllowsUnlockedPortion() public {
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);
        vm.prank(address(company));
        rule.recordIssuance(alice, 300); // only 300 locked, 700 free

        assertEq(rule.detectTransferRestriction(alice, bob, 700), TRANSFER_OK);
        assertEq(rule.detectTransferRestriction(alice, bob, 701), rule.CODE_INSUFFICIENT_UNLOCKED_BALANCE());
    }

    function test_DetectTransferRestriction_AllowsAfterUnlock() public {
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);
        vm.prank(address(company));
        rule.recordIssuance(alice, 1000);

        assertEq(rule.detectTransferRestriction(alice, bob, 500), rule.CODE_INSUFFICIENT_UNLOCKED_BALANCE());

        vm.warp(block.timestamp + SIX_MONTHS + 1);

        assertEq(rule.detectTransferRestriction(alice, bob, 500), TRANSFER_OK);
    }

    function test_DetectTransferRestriction_MintAlwaysAllowed() public view {
        uint8 code = rule.detectTransferRestriction(address(0), alice, 1000);
        assertEq(code, TRANSFER_OK);
    }

    function test_DetectTransferRestrictionFrom_IgnoresSpender() public {
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);
        vm.prank(address(company));
        rule.recordIssuance(alice, 300);

        address spender = makeAddr("spender");
        assertEq(rule.detectTransferRestrictionFrom(spender, alice, bob, 700), TRANSFER_OK);
    }

    // ============ End-to-end through CMTAT ============

    function test_Transfer_RestrictedPortionBlocked_UnrestrictedPortionAllowed() public {
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);
        vm.prank(address(company));
        rule.recordIssuance(alice, 600); // 400 unlocked

        // Transfer of 400 works
        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 400));
        assertEq(shareToken.balanceOf(bob), 400);

        // Further transfer blocked (balance now 600, all locked)
        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 1);
    }

    function test_Transfer_WorksAfterHoldingPeriodExpires() public {
        vm.prank(address(issuance));
        shareToken.issueShares(alice, 1000);
        vm.prank(address(company));
        rule.recordIssuance(alice, 1000);

        vm.prank(alice);
        vm.expectRevert();
        shareToken.transfer(bob, 500);

        vm.warp(block.timestamp + SIX_MONTHS + 1);

        vm.prank(alice);
        assertTrue(shareToken.transfer(bob, 500));
    }

    // ============ reconcile ============

    function test_Reconcile_PrunesExpiredLots() public {
        vm.startPrank(address(company));
        rule.recordIssuance(alice, 100);
        vm.warp(block.timestamp + 30 days);
        rule.recordIssuance(alice, 200);
        vm.warp(block.timestamp + 30 days);
        rule.recordIssuance(alice, 300);
        vm.stopPrank();

        assertEq(rule.lotCount(alice), 3);

        // Warp past first lot's unlock (lot 1 was created at t=0, unlocks at t=SIX_MONTHS).
        // At t=60days+SIX_MONTHS+1, lot 1 expired, lots 2 & 3 not yet.
        vm.warp(SIX_MONTHS + 1);

        rule.reconcile(alice);
        assertEq(rule.lotCount(alice), 2, "expired lot pruned");
    }

    function test_Reconcile_EmitsEventOnlyWhenPruning() public {
        vm.prank(address(company));
        rule.recordIssuance(alice, 100);

        // No expired lots → no event
        vm.recordLogs();
        rule.reconcile(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no prune = no event");

        // Warp past unlock, reconcile, expect event
        vm.warp(block.timestamp + SIX_MONTHS + 1);

        vm.expectEmit(true, true, true, true);
        emit RuleHoldingPeriod.LotsReconciled(alice, 1);
        rule.reconcile(alice);
    }

    function test_Reconcile_CallableByAnyone() public {
        vm.prank(address(company));
        rule.recordIssuance(alice, 100);
        vm.warp(block.timestamp + SIX_MONTHS + 1);

        vm.prank(makeAddr("random"));
        rule.reconcile(alice);
        assertEq(rule.lotCount(alice), 0);
    }

    // ============ setHoldingPeriod ============

    function test_SetHoldingPeriod_AppliesToFutureLotsOnly() public {
        // First lot uses 180-day period
        vm.prank(address(company));
        rule.recordIssuance(alice, 100);
        uint64 firstUnlock = rule.getLots(alice)[0].unlockTime;

        // Board shortens to 30 days
        vm.prank(board);
        rule.setHoldingPeriod(30 days);

        vm.prank(address(company));
        rule.recordIssuance(alice, 200);
        uint64 secondUnlock = rule.getLots(alice)[1].unlockTime;

        // First lot unchanged; second has shorter period
        assertEq(uint256(firstUnlock), block.timestamp + SIX_MONTHS);
        assertEq(uint256(secondUnlock), block.timestamp + 30 days);
    }

    function test_SetHoldingPeriod_OnlyBoard() public {
        vm.expectRevert(RuleHoldingPeriod.OnlyBoard.selector);
        vm.prank(alice);
        rule.setHoldingPeriod(1 days);
    }

    function test_SetHoldingPeriod_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit RuleHoldingPeriod.HoldingPeriodUpdated(SIX_MONTHS, 365 days);

        vm.prank(board);
        rule.setHoldingPeriod(365 days);
    }

    // ============ Misc ============

    function test_CanReturnTransferRestrictionCode() public view {
        assertTrue(rule.canReturnTransferRestrictionCode(rule.CODE_INSUFFICIENT_UNLOCKED_BALANCE()));
        assertFalse(rule.canReturnTransferRestrictionCode(TRANSFER_OK));
    }

    function test_MessageForTransferRestriction() public view {
        assertEq(
            rule.messageForTransferRestriction(rule.CODE_INSUFFICIENT_UNLOCKED_BALANCE()),
            "Sender has insufficient unlocked balance (holding period active)"
        );
        assertEq(rule.messageForTransferRestriction(99), "Unknown restriction code");
    }

    function test_SupportsInterface() public view {
        assertTrue(rule.supportsInterface(type(IRuleCloneable).interfaceId));
        assertTrue(rule.supportsInterface(type(IRuleHoldingPeriod).interfaceId));
        assertFalse(rule.supportsInterface(type(IRuleKYC).interfaceId));
        assertFalse(rule.supportsInterface(type(IRuleOFAC).interfaceId));
    }
}
