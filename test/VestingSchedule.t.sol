// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";

/// @title VestingSchedule Test
contract VestingScheduleTest is BaseTest {
    VestingSchedule public vesting;
    ShareToken public token;

    address public vestingFounder = address(0x1);
    address public vestingEmployee = address(0x2);

    uint256 public constant FOUNDER_AMOUNT = 10_000_000_000; // 10,000 shares
    uint256 public constant EMPLOYEE_AMOUNT = 500_000_000; // 500 shares

    function setUp() public {
        _baseSetUp();

        // Deploy company with custom share class (20K authorized shares)
        ShareholderRegistry deployedRegistry;
        OptionPool deployedOptionPool;
        SAFE deployedSAFE;
        Fundraise deployedFundraise;
        (company, vault, vesting, deployedRegistry, deployedOptionPool, deployedSAFE, token, deployedFundraise) =
            _deployCompanyWithShareClass("Test Company", "TEST", "Common", "Common", "TEST", 20_000_000_000);

        // Board issues tokens to vesting contract via company
        vm.prank(board);
        issuance.issueGrant("Common", address(vesting), 12_000_000_000, "Initial vesting allocation", "");
    }

    // ===================
    // Initialization Tests
    // ===================

    function test_Constructor() public view {
        assertEq(address(vesting.company()), address(company));
        assertEq(vesting.scheduleCount(), 0);
    }

    function test_Constructor_RevertsZeroAddress() public {
        VestingSchedule newVesting = new VestingSchedule();
        vm.expectRevert(VestingSchedule.ZeroAddress.selector);
        newVesting.initialize(address(0));
    }

    // ===================
    // Create Schedule Tests
    // ===================

    function test_CreateSchedule() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        assertEq(scheduleId, 0);
        assertEq(vesting.scheduleCount(), 1);
        assertEq(vesting.totalAllocated(address(token)), FOUNDER_AMOUNT);

        VestingSchedule.Schedule memory schedule = vesting.getSchedule(scheduleId);
        assertEq(schedule.beneficiary, vestingFounder);
        assertEq(schedule.totalAmount, FOUNDER_AMOUNT);
    }

    function test_CreateSchedule_InputValidation() public {
        // ZeroAddress beneficiary
        vm.prank(board);
        vm.expectRevert(VestingSchedule.ZeroAddress.selector);
        vesting.createSchedule(
            address(0), address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // ZeroAddress token
        vm.prank(board);
        vm.expectRevert(VestingSchedule.ZeroAddress.selector);
        vesting.createSchedule(
            vestingFounder, address(0), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // ZeroAmount
        vm.prank(board);
        vm.expectRevert(VestingSchedule.ZeroAmount.selector);
        vesting.createSchedule(vestingFounder, address(token), 0, block.timestamp, 365 days, 1460 days, false, "");

        // InvalidDuration (vestingDuration == 0)
        vm.prank(board);
        vm.expectRevert(VestingSchedule.InvalidDuration.selector);
        vesting.createSchedule(vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 0, false, "");

        // CliffExceedsDuration
        vm.prank(board);
        vm.expectRevert(VestingSchedule.CliffExceedsDuration.selector);
        vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 1460 days, 365 days, false, ""
        ); // cliff > duration

        // OnlyBoardOrCompany access control
        vm.prank(vestingFounder);
        vm.expectRevert(VestingSchedule.OnlyBoardOrCompany.selector);
        vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );
    }

    function test_CreateSchedule_PreventDoubleAllocation() public {
        // Vesting contract has 12,000 shares
        // Create first schedule for 10,000 shares
        vm.prank(board);
        vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // Try to create second schedule for 3,000 shares (should fail, only 2,000 left)
        uint256 tooMuch = 3_000_000_000; // 3,000 shares
        vm.prank(board);
        vm.expectRevert(VestingSchedule.InsufficientBalance.selector);
        vesting.createSchedule(vestingEmployee, address(token), tooMuch, block.timestamp, 365 days, 1460 days, true, "");

        // But should succeed for EMPLOYEE_AMOUNT (500 shares)
        vm.prank(board);
        vesting.createSchedule(
            vestingEmployee, address(token), EMPLOYEE_AMOUNT, block.timestamp, 365 days, 1460 days, true, ""
        );

        assertEq(vesting.totalAllocated(address(token)), FOUNDER_AMOUNT + EMPLOYEE_AMOUNT);
    }

    function test_CreateSchedule_Backdated() public {
        // Set current time to a known value
        uint256 currentTime = 1000 days;
        vm.warp(currentTime);

        // Create a schedule that started 6 months ago
        uint256 sixMonthsAgo = currentTime - 180 days;

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingEmployee, address(token), EMPLOYEE_AMOUNT, sixMonthsAgo, 365 days, 1460 days, true, ""
        );

        // Verify schedule was created with past startTime
        VestingSchedule.Schedule memory schedule = vesting.getSchedule(scheduleId);
        assertEq(schedule.startTime, sixMonthsAgo);

        // Since we're 6 months past start but cliff is 12 months, nothing vested yet
        uint256 vested = vesting.calculateVested(scheduleId);
        assertEq(vested, 0);

        // Warp to exactly at cliff (365 days from start)
        vm.warp(sixMonthsAgo + 365 days);

        // At cliff (12 months from start), should have 365/1460 vested (25%)
        vested = vesting.calculateVested(scheduleId);
        uint256 expected = (EMPLOYEE_AMOUNT * 365 days) / 1460 days;
        assertEq(vested, expected);

        // Can release the vested amount
        vm.prank(vestingEmployee);
        vesting.release(scheduleId);
        assertEq(token.balanceOf(vestingEmployee), expected);
    }

    function test_CreateSchedule_BackdatedFullyVested() public {
        // Set current time to a known value
        uint256 currentTime = 2000 days;
        vm.warp(currentTime);

        // Create a schedule that started 5 years ago (fully vested)
        uint256 fiveYearsAgo = currentTime - (1460 days + 365 days);

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, fiveYearsAgo, 365 days, 1460 days, false, ""
        );

        // Should be fully vested
        uint256 vested = vesting.calculateVested(scheduleId);
        assertEq(vested, FOUNDER_AMOUNT);

        // Can release all tokens immediately
        vm.prank(vestingFounder);
        vesting.release(scheduleId);
        assertEq(token.balanceOf(vestingFounder), FOUNDER_AMOUNT);
    }

    // ===================
    // Vesting Calculation Tests
    // ===================

    function test_CalculateVested_BeforeCliff() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        assertEq(vesting.calculateVested(scheduleId), 0);

        vm.warp(block.timestamp + 364 days);
        assertEq(vesting.calculateVested(scheduleId), 0);
    }

    function test_CalculateVested_AtCliff() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        vm.warp(block.timestamp + 365 days);
        assertEq(vesting.calculateVested(scheduleId), FOUNDER_AMOUNT / 4);
    }

    function test_CalculateVested_LinearVesting() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // At 2 years = 50%
        vm.warp(block.timestamp + 730 days);
        assertEq(vesting.calculateVested(scheduleId), FOUNDER_AMOUNT / 2);

        // At 4 years = 100%
        vm.warp(block.timestamp + 1460 days);
        assertEq(vesting.calculateVested(scheduleId), FOUNDER_AMOUNT);
    }

    function test_CalculateVested_DiscreteDaily() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // After cliff, test discrete daily vesting
        vm.warp(block.timestamp + 365 days); // Pass cliff

        // At start of day 366 (exactly 365 days + 1 second)
        vm.warp(block.timestamp + 1 seconds);
        uint256 vestedAtDayStart = vesting.calculateVested(scheduleId);

        // 12 hours into day 366 (middle of the day)
        vm.warp(block.timestamp + 12 hours);
        uint256 vestedAtMidDay = vesting.calculateVested(scheduleId);

        // 23 hours into day 366 (almost end of day)
        vm.warp(block.timestamp + 11 hours); // 12 + 11 = 23 hours total
        uint256 vestedAtDayEnd = vesting.calculateVested(scheduleId);

        // All three should be EXACTLY the same (discrete daily vesting)
        assertEq(vestedAtDayStart, vestedAtMidDay, "Vesting should not change within same day (start vs mid)");
        assertEq(vestedAtMidDay, vestedAtDayEnd, "Vesting should not change within same day (mid vs end)");
        assertEq(vestedAtDayStart, vestedAtDayEnd, "Vesting should not change within same day (start vs end)");

        // Verify vested amount is a whole share
        assertEq(vestedAtDayStart % 1e6, 0, "Vested amount must be whole shares (no fractional shares)");

        // Now advance to the next complete day
        vm.warp(block.timestamp + 2 hours); // Cross midnight (23 + 2 = 25 hours from day start)
        uint256 vestedNextDay = vesting.calculateVested(scheduleId);
        console.log("Vested next day:", vestedNextDay);

        // Next day should have MORE vested shares
        assertGt(vestedNextDay, vestedAtDayEnd, "Vesting should increase on next complete day");

        // Verify next day vested amount is also a whole share
        assertEq(vestedNextDay % 1e6, 0, "Vested amount must be whole shares (no fractional shares)");
    }

    function test_CalculateVested_InvalidScheduleId() public {
        vm.expectRevert(VestingSchedule.InvalidScheduleId.selector);
        vesting.calculateVested(999);
    }

    // ===================
    // Release Tests
    // ===================

    function test_Release() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        vm.warp(block.timestamp + 365 days);

        uint256 balanceBefore = token.balanceOf(vestingFounder);
        vesting.release(scheduleId);
        uint256 balanceAfter = token.balanceOf(vestingFounder);

        assertEq(balanceAfter - balanceBefore, FOUNDER_AMOUNT / 4);
    }

    function test_Release_InputValidation() public {
        // InvalidScheduleId
        vm.expectRevert(VestingSchedule.InvalidScheduleId.selector);
        vesting.release(999);

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // NoTokensToRelease (before cliff)
        vm.expectRevert(VestingSchedule.NoTokensToRelease.selector);
        vesting.release(scheduleId);
    }

    // ===================
    // Revoke Tests
    // ===================

    function test_Revoke_BeforeCliff() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingEmployee, address(token), EMPLOYEE_AMOUNT, block.timestamp, 365 days, 1460 days, true, ""
        );

        uint256 initialSupply = token.totalSupply();
        assertEq(vesting.totalAllocated(address(token)), EMPLOYEE_AMOUNT);

        vm.prank(board);
        vesting.revoke(scheduleId, "");

        // Employee gets nothing
        assertEq(token.balanceOf(vestingEmployee), 0);

        // All burned (not returned to company)
        assertEq(token.totalSupply(), initialSupply - EMPLOYEE_AMOUNT);

        // Deallocated
        assertEq(vesting.totalAllocated(address(token)), 0);
    }

    function test_Revoke_AfterCliff() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingEmployee, address(token), EMPLOYEE_AMOUNT, block.timestamp, 365 days, 1460 days, true, ""
        );

        uint256 initialSupply = token.totalSupply();

        // Warp to 50% vested
        vm.warp(block.timestamp + 730 days);

        vm.prank(board);
        vesting.revoke(scheduleId, "");

        // Employee gets 50%
        assertEq(token.balanceOf(vestingEmployee), EMPLOYEE_AMOUNT / 2);

        // Unvested 50% is burned
        assertEq(token.totalSupply(), initialSupply - (EMPLOYEE_AMOUNT / 2));

        // Fully deallocated (both vested and unvested portions left the contract)
        assertEq(vesting.totalAllocated(address(token)), 0);
    }

    function test_Revoke_InputValidation() public {
        // InvalidScheduleId
        vm.prank(board);
        vm.expectRevert(VestingSchedule.InvalidScheduleId.selector);
        vesting.revoke(999, "");

        // Create non-revocable schedule
        vm.prank(board);
        uint256 nonRevocableId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // NotRevocable
        vm.prank(board);
        vm.expectRevert(VestingSchedule.NotRevocable.selector);
        vesting.revoke(nonRevocableId, "");

        // Create revocable schedule
        vm.prank(board);
        uint256 revocableId = vesting.createSchedule(
            vestingEmployee, address(token), EMPLOYEE_AMOUNT, block.timestamp, 365 days, 1460 days, true, ""
        );

        // Revoke it once
        vm.prank(board);
        vesting.revoke(revocableId, "");

        // AlreadyRevoked
        vm.prank(board);
        vm.expectRevert(VestingSchedule.AlreadyRevoked.selector);
        vesting.revoke(revocableId, "");

        // OnlyBoard access control
        vm.prank(board);
        uint256 anotherRevocableId = vesting.createSchedule(
            address(0x123), address(token), EMPLOYEE_AMOUNT, block.timestamp, 365 days, 1460 days, true, ""
        );

        vm.prank(vestingEmployee);
        vm.expectRevert(VestingSchedule.OnlyBoard.selector);
        vesting.revoke(anotherRevocableId, "");
    }

    // ===================
    // Withdrawal Tests
    // ===================

    function test_WithdrawExcess() public {
        // Vesting has 12,000 shares, allocate 10,000 shares
        vm.prank(board);
        vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // Board can withdraw the 2,000 share excess
        uint256 excess = 2_000_000_000; // 2,000 shares
        vm.prank(board);
        vesting.withdrawExcess(address(token), excess);

        assertEq(token.balanceOf(board), excess);
    }

    function test_WithdrawExcess_CannotWithdrawAllocated() public {
        // Allocate all 12,000 shares
        uint256 totalAvailable = 12_000_000_000; // 12,000 shares
        vm.prank(board);
        vesting.createSchedule(
            vestingFounder, address(token), totalAvailable, block.timestamp, 365 days, 1460 days, false, ""
        );

        // Cannot withdraw any
        vm.prank(board);
        vm.expectRevert(VestingSchedule.InsufficientBalance.selector);
        vesting.withdrawExcess(address(token), 1);
    }

    function test_WithdrawExcess_InputValidation() public {
        // OnlyBoard access control
        vm.prank(vestingEmployee);
        vm.expectRevert(VestingSchedule.OnlyBoard.selector);
        vesting.withdrawExcess(address(token), 1);
    }

    // ===================
    // View/Query Function Tests
    // ===================

    function test_GetSchedule_InvalidScheduleId() public {
        vm.expectRevert(VestingSchedule.InvalidScheduleId.selector);
        vesting.getSchedule(999);
    }

    function test_GetScheduleDetails() public {
        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );

        // At cliff (25% vested, none released yet)
        vm.warp(block.timestamp + 365 days);

        (VestingSchedule.Schedule memory schedule, uint256 vested, uint256 releasable, uint256 remaining) =
            vesting.getScheduleDetails(scheduleId);

        assertEq(schedule.beneficiary, vestingFounder);
        assertEq(schedule.totalAmount, FOUNDER_AMOUNT);
        assertEq(vested, FOUNDER_AMOUNT / 4);
        assertEq(releasable, FOUNDER_AMOUNT / 4);
        assertEq(remaining, (FOUNDER_AMOUNT * 3) / 4);
    }

    function test_GetScheduleDetails_InvalidScheduleId() public {
        vm.expectRevert(VestingSchedule.InvalidScheduleId.selector);
        vesting.getScheduleDetails(999);
    }

    function test_GetReleasableAmount_InvalidScheduleId() public {
        vm.expectRevert(VestingSchedule.InvalidScheduleId.selector);
        vesting.getReleasableAmount(999);
    }

    function test_GetAllScheduleIds() public {
        // Create 3 schedules
        vm.startPrank(board);
        vesting.createSchedule(vestingFounder, address(token), 100_000, block.timestamp, 365 days, 1460 days, false, "");
        vesting.createSchedule(vestingEmployee, address(token), 50_000, block.timestamp, 365 days, 1460 days, true, "");
        vesting.createSchedule(address(0x3), address(token), 25_000, block.timestamp, 180 days, 730 days, true, "");
        vm.stopPrank();

        uint256[] memory ids = vesting.getAllScheduleIds();
        assertEq(ids.length, 3);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
        assertEq(ids[2], 2);
    }

    function test_GetAllSchedulesWithDetails() public {
        // Create 2 schedules
        vm.startPrank(board);
        vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );
        vesting.createSchedule(
            vestingEmployee, address(token), EMPLOYEE_AMOUNT, block.timestamp, 365 days, 1460 days, true, ""
        );
        vm.stopPrank();

        // Warp to cliff
        vm.warp(block.timestamp + 365 days);

        (VestingSchedule.Schedule[] memory schedules, uint256[] memory vesteds, uint256[] memory releasables) =
            vesting.getAllSchedulesWithDetails();

        assertEq(schedules.length, 2);
        assertEq(vesteds.length, 2);
        assertEq(releasables.length, 2);

        // Check founder schedule
        assertEq(schedules[0].beneficiary, vestingFounder);
        assertEq(vesteds[0], FOUNDER_AMOUNT / 4);
        assertEq(releasables[0], FOUNDER_AMOUNT / 4);

        // Check employee schedule
        assertEq(schedules[1].beneficiary, vestingEmployee);
        assertEq(vesteds[1], EMPLOYEE_AMOUNT / 4);
        assertEq(releasables[1], EMPLOYEE_AMOUNT / 4);
    }

    function test_GetBeneficiarySchedules() public {
        // Initially no schedules
        uint256[] memory schedules = vesting.getBeneficiarySchedules(vestingFounder);
        assertEq(schedules.length, 0);

        // Create 2 schedules for vestingFounder
        vm.startPrank(board);
        vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 365 days, 1460 days, false, ""
        );
        vesting.createSchedule(
            vestingFounder, address(token), 1_000_000, block.timestamp, 365 days, 730 days, false, ""
        );
        vm.stopPrank();

        // Create 1 schedule for vestingEmployee
        vm.prank(board);
        vesting.createSchedule(
            vestingEmployee, address(token), EMPLOYEE_AMOUNT, block.timestamp, 365 days, 1460 days, true, ""
        );

        // vestingFounder has 2 schedules
        schedules = vesting.getBeneficiarySchedules(vestingFounder);
        assertEq(schedules.length, 2);
        assertEq(schedules[0], 0);
        assertEq(schedules[1], 1);

        // vestingEmployee has 1 schedule
        schedules = vesting.getBeneficiarySchedules(vestingEmployee);
        assertEq(schedules.length, 1);
        assertEq(schedules[0], 2);
    }

    function test_GetBeneficiarySummary() public {
        // Create 2 schedules for same beneficiary
        uint256 scheduleAmount = EMPLOYEE_AMOUNT; // Use EMPLOYEE_AMOUNT for this test
        vm.startPrank(board);
        vesting.createSchedule(
            vestingFounder, address(token), scheduleAmount, block.timestamp, 365 days, 1460 days, false, ""
        );
        vesting.createSchedule(
            vestingFounder, address(token), scheduleAmount, block.timestamp, 365 days, 1460 days, false, ""
        );
        vm.stopPrank();

        // Warp to 50% vested
        vm.warp(block.timestamp + 730 days);

        (uint256 totalVested, uint256 totalReleasable, uint256 totalRemaining) =
            vesting.getBeneficiarySummary(vestingFounder);

        uint256 totalAmount = scheduleAmount * 2;
        assertEq(totalVested, totalAmount / 2); // 50% of total
        assertEq(totalReleasable, totalAmount / 2); // None released yet
        assertEq(totalRemaining, totalAmount / 2); // 50% not yet vested
    }

    function test_GetBeneficiarySummary_AfterPartialRelease() public {
        uint256 start = block.timestamp;

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, start, 365 days, 1460 days, false, ""
        );

        // Warp to 25% vested (1 year) and release
        vm.warp(start + 365 days);
        vesting.release(scheduleId);
        uint256 firstRelease = FOUNDER_AMOUNT / 4;

        // Warp to 50% vested (2 years)
        vm.warp(start + 730 days);

        (uint256 totalVested, uint256 totalReleasable, uint256 totalRemaining) =
            vesting.getBeneficiarySummary(vestingFounder);

        // Check that some vesting has occurred
        assertGt(totalVested, firstRelease);
        assertGt(totalReleasable, 0); // Can release more
        assertLt(totalVested, FOUNDER_AMOUNT); // Not fully vested yet
    }

    // ===================
    // Integration Tests
    // ===================

    function test_TotalAllocated_MultipleReleases() public {
        uint256 start = 1000 days; // Use fixed timestamp
        vm.warp(start);

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, start, 365 days, 1460 days, false, ""
        );

        // Initially fully allocated
        assertEq(vesting.totalAllocated(address(token)), FOUNDER_AMOUNT);

        // Warp to 25% vested (at cliff)
        vm.warp(start + 365 days);
        vesting.release(scheduleId);

        // 25% released, 75% still allocated
        uint256 released1 = (FOUNDER_AMOUNT * 365 days) / 1460 days;
        assertEq(vesting.totalAllocated(address(token)), FOUNDER_AMOUNT - released1);

        // Warp to 50% vested
        vm.warp(start + 730 days);
        vesting.release(scheduleId);

        // 50% released total, 50% still allocated
        uint256 totalVestedAt50Percent = (FOUNDER_AMOUNT * 730 days) / 1460 days;
        assertEq(vesting.totalAllocated(address(token)), FOUNDER_AMOUNT - totalVestedAt50Percent);

        // Warp to 100% vested
        vm.warp(start + 1460 days);
        vesting.release(scheduleId);

        // Fully released, nothing allocated
        assertEq(vesting.totalAllocated(address(token)), 0);
        assertEq(token.balanceOf(vestingFounder), FOUNDER_AMOUNT);
    }

    function test_TotalAllocated_CanReuseAfterFullRelease() public {
        // Create and fully vest first schedule
        vm.prank(board);
        uint256 scheduleId1 = vesting.createSchedule(
            vestingFounder, address(token), FOUNDER_AMOUNT, block.timestamp, 0, 1 days, false, ""
        );

        vm.warp(block.timestamp + 1 days);
        vesting.release(scheduleId1);

        // totalAllocated should be 0
        assertEq(vesting.totalAllocated(address(token)), 0);

        // Refill contract (board issues via company)
        vm.prank(board);
        issuance.issueGrant("Common", address(vesting), 2_000_000, "Vesting allocation", "");

        // Should be able to create another schedule for full amount
        vm.prank(board);
        uint256 scheduleId2 =
            vesting.createSchedule(vestingEmployee, address(token), 2_000_000, block.timestamp, 0, 1 days, true, "");

        assertEq(vesting.totalAllocated(address(token)), 2_000_000);
    }

    function test_IssueSharesWithVesting() public {
        uint256 amount = 1_000_000_000; // 1,000 shares

        vm.prank(board);
        uint256 scheduleId = issuance.issueGrantWithVesting(
            token, vestingFounder, amount, block.timestamp, 365 days, 1460 days, false, ""
        );

        // Schedule was created
        assertEq(vesting.scheduleCount(), 1);
        assertEq(scheduleId, 0);

        // Schedule has correct parameters
        VestingSchedule.Schedule memory schedule = vesting.getSchedule(scheduleId);
        assertEq(schedule.beneficiary, vestingFounder);
        assertEq(schedule.token, address(token));
        assertEq(schedule.totalAmount, amount);
        assertEq(schedule.cliffDuration, 365 days);
        assertEq(schedule.vestingDuration, 1460 days);
        assertEq(schedule.revocable, false);

        // Tokens were allocated
        assertEq(vesting.totalAllocated(address(token)), amount);
    }

    function test_IssueSharesWithVesting_MultipleSchedules() public {
        uint256 founderAmount = 1_000_000_000; // 1,000 shares
        uint256 employeeAmount = 500_000_000; // 500 shares

        vm.startPrank(board);
        uint256 founderId = issuance.issueGrantWithVesting(
            token, vestingFounder, founderAmount, block.timestamp, 365 days, 1460 days, false, ""
        );
        uint256 employeeId = issuance.issueGrantWithVesting(
            token, vestingEmployee, employeeAmount, block.timestamp, 365 days, 1460 days, true, ""
        );
        vm.stopPrank();

        assertEq(founderId, 0);
        assertEq(employeeId, 1);
        assertEq(vesting.scheduleCount(), 2);
        assertEq(vesting.totalAllocated(address(token)), founderAmount + employeeAmount);
    }

    function test_IssueSharesWithVesting_VestingWorks() public {
        uint256 amount = 1_000_000_000; // 1,000 shares

        vm.prank(board);
        uint256 scheduleId = issuance.issueGrantWithVesting(
            token, vestingFounder, amount, block.timestamp, 365 days, 1460 days, false, ""
        );

        // Before cliff - nothing vested
        assertEq(vesting.calculateVested(scheduleId), 0);

        // At cliff - 25% vested
        vm.warp(block.timestamp + 365 days);
        assertEq(vesting.calculateVested(scheduleId), amount / 4);

        // Release works
        vm.prank(vestingFounder);
        vesting.release(scheduleId);
        assertEq(token.balanceOf(vestingFounder), amount / 4);
    }

    function test_IssueSharesWithVesting_RevokeWorks() public {
        uint256 amount = 1_000_000_000; // 1,000 shares

        vm.prank(board);
        uint256 scheduleId = issuance.issueGrantWithVesting(
            token, vestingEmployee, amount, block.timestamp, 365 days, 1460 days, true, ""
        );

        // At 50% vested
        vm.warp(block.timestamp + 730 days);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(board);
        vesting.revoke(scheduleId, "");

        // Employee got 50%
        assertEq(token.balanceOf(vestingEmployee), amount / 2);

        // Unvested 50% burned
        assertEq(token.totalSupply(), supplyBefore - (amount / 2));
    }

    function test_IssueSharesWithVesting_RevertsZeroAddress() public {
        vm.prank(board);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        issuance.issueGrantWithVesting(
            token, address(0), 1_000_000_000, block.timestamp, 365 days, 1460 days, false, ""
        );
    }

    function test_IssueSharesWithVesting_RevertsZeroAmount() public {
        vm.prank(board);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        issuance.issueGrantWithVesting(token, vestingFounder, 0, block.timestamp, 365 days, 1460 days, false, "");
    }

    function test_IssueSharesWithVesting_RevertsOnlyBoard() public {
        vm.prank(vestingFounder);
        vm.expectRevert(abi.encodeWithSignature("OnlyBoard()"));
        issuance.issueGrantWithVesting(
            token, vestingFounder, 1_000_000_000, block.timestamp, 365 days, 1460 days, false, ""
        );
    }

    // ===================
    // Fuzz Tests
    // ===================

    function test_Fuzz_VestingNeverExceedsTotalAmount(uint256 timeElapsed, uint256 totalAmount, uint256 duration)
        public
    {
        // Bound inputs to reasonable ranges (max 1M to stay under 10M authorized - 2M already minted)
        totalAmount = bound(totalAmount, 1, 1_000_000);
        duration = bound(duration, 1 days, 10 * 365 days);
        timeElapsed = bound(timeElapsed, 0, duration * 2); // Test beyond duration too

        // Issue more shares if needed (we already have 2M from setUp)
        uint256 vestingBalance = token.balanceOf(address(vesting));
        if (totalAmount > vestingBalance) {
            vm.prank(board);
            issuance.issueGrant("Common", address(vesting), totalAmount - vestingBalance, "Vesting allocation", "");
        }

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), totalAmount, block.timestamp, 0, duration, false, ""
        );

        // Warp to timeElapsed
        vm.warp(block.timestamp + timeElapsed);

        // Calculate vested
        uint256 vested = vesting.calculateVested(scheduleId);

        // Vested should never exceed totalAmount
        assertLe(vested, totalAmount);

        // If we're past the duration, should be fully vested
        if (timeElapsed >= duration) {
            assertEq(vested, totalAmount);
        }
    }

    function test_Fuzz_TotalAllocatedConsistency(uint256 amount1, uint256 amount2) public {
        // Bound to reasonable ranges (combined must fit within what we can issue)
        amount1 = bound(amount1, 1, 500_000);
        amount2 = bound(amount2, 1, 500_000);

        // Ensure we have enough tokens (we already have 2M from setUp)
        uint256 totalNeeded = amount1 + amount2;
        uint256 vestingBalance = token.balanceOf(address(vesting));
        if (totalNeeded > vestingBalance) {
            vm.prank(board);
            issuance.issueGrant("Common", address(vesting), totalNeeded - vestingBalance, "Vesting allocation", "");
        }

        // Create two schedules
        vm.startPrank(board);
        vesting.createSchedule(vestingFounder, address(token), amount1, block.timestamp, 0, 1 days, false, "");
        vesting.createSchedule(vestingEmployee, address(token), amount2, block.timestamp, 0, 1 days, false, "");
        vm.stopPrank();

        // Total allocated should be sum of both
        assertEq(vesting.totalAllocated(address(token)), amount1 + amount2);

        // Fast forward
        vm.warp(block.timestamp + 1 days);

        // Release both
        vesting.release(0);
        vesting.release(1);

        // Total allocated should be 0
        assertEq(vesting.totalAllocated(address(token)), 0);

        // Beneficiaries should have their amounts
        assertEq(token.balanceOf(vestingFounder), amount1);
        assertEq(token.balanceOf(vestingEmployee), amount2);
    }

    function test_Fuzz_CliffWorksCorrectly(uint256 cliffDuration, uint256 totalDuration, uint256 timeElapsed) public {
        // Bound inputs
        cliffDuration = bound(cliffDuration, 1 days, 365 days);
        totalDuration = bound(totalDuration, cliffDuration, 1460 days);
        timeElapsed = bound(timeElapsed, 0, totalDuration);

        // Use EMPLOYEE_AMOUNT (500 shares) to ensure we have whole shares even after division
        uint256 amount = EMPLOYEE_AMOUNT;
        vm.prank(board);
        issuance.issueGrant("Common", address(vesting), amount, "Vesting allocation", "");

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingFounder, address(token), amount, block.timestamp, cliffDuration, totalDuration, false, ""
        );

        vm.warp(block.timestamp + timeElapsed);
        uint256 vested = vesting.calculateVested(scheduleId);

        // Before cliff: vested should be 0
        if (timeElapsed < cliffDuration) {
            assertEq(vested, 0);
        }
        // After cliff: vested should be proportional
        // NOTE: With discrete daily whole-share vesting, may be 0 if not enough time has passed to vest 1 whole share
        else if (timeElapsed < totalDuration) {
            // Vested may be 0 due to whole-share rounding, but should never exceed totalAmount
            assertLe(vested, amount);
        }
        // After duration: fully vested
        else {
            assertEq(vested, amount);
        }
    }

    function test_Fuzz_RevokePreservesInvariants(uint256 amount, uint256 timeBeforeRevoke) public {
        // Bound inputs
        amount = bound(amount, 100, 1_000_000);
        timeBeforeRevoke = bound(timeBeforeRevoke, 0, 1460 days);

        vm.prank(board);
        issuance.issueGrant("Common", address(vesting), amount, "Vesting allocation", "");

        vm.prank(board);
        uint256 scheduleId = vesting.createSchedule(
            vestingEmployee, address(token), amount, block.timestamp, 365 days, 1460 days, true, ""
        );

        // Warp and revoke
        vm.warp(block.timestamp + timeBeforeRevoke);

        uint256 balanceBefore = token.balanceOf(address(vesting));
        uint256 totalSupplyBefore = token.totalSupply();
        uint256 vestedAtRevoke = vesting.calculateVested(scheduleId);

        vm.prank(board);
        vesting.revoke(scheduleId, "");

        // Check invariants
        // 1. Vested amount went to employee
        assertEq(token.balanceOf(vestingEmployee), vestedAtRevoke);

        // 2. Unvested amount was burned
        uint256 unvested = amount - vestedAtRevoke;
        assertEq(token.totalSupply(), totalSupplyBefore - unvested);

        // 3. Vesting contract has no tokens left from this schedule
        assertEq(token.balanceOf(address(vesting)), balanceBefore - amount);

        // 4. Total allocated should be 0
        assertEq(vesting.totalAllocated(address(token)), 0);
    }
}
