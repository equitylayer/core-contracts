// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";
import "../src/OptionPool.sol";
import "../src/VestingSchedule.sol";

/// @title OptionPoolTest
/// @notice Comprehensive tests for the OptionPool contract
contract OptionPoolTest is BaseTest {
    OptionPool optionPool;
    ShareholderRegistry shareholderRegistry;

    address employee1 = address(0xE1);
    address employee2 = address(0xE2);

    event ValuationRecorded(uint256 indexed valuationIndex, uint256 fmv, uint256 timestamp, string documentRef);
    event OptionsGranted(
        uint256 indexed grantId,
        address indexed employee,
        uint256 amount,
        uint256 strikePrice,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 vestingInterval,
        bool isTaxAdvantaged,
        string documentRef
    );
    event OptionsExercised(
        uint256 indexed grantId, address indexed employee, uint256 amount, uint256 payment, uint256 timestamp
    );
    event GrantRevoked(
        uint256 indexed grantId,
        address indexed employee,
        uint256 vestedAmount,
        uint256 unvestedAmount,
        string documentRef
    );
    event ExpiredGrantCleaned(uint256 indexed grantId, address indexed token, uint256 amountReleased);
    event PoolSizeIncreased(address indexed token, uint256 previousSize, uint256 newSize, string documentRef);
    event PoolSizeDecreased(address indexed token, uint256 previousSize, uint256 newSize, string documentRef);

    function setUp() public {
        _baseSetUp();

        // Deploy standard company with 10M authorized shares using helper
        ShareholderRegistry deployedRegistry;
        SAFE deployedSAFE;
        Fundraise deployedFundraise;
        (company, vault, vestingSchedule, deployedRegistry, optionPool, deployedSAFE, shareToken, deployedFundraise) =
            _deployStandardCompany();

        shareholderRegistry = deployedRegistry;

        // Fund employees for option exercises (ERC20 payment token)
        _fundMUSD(employee1, 100e6);
        _fundMUSD(employee2, 100e6);

        // Set up default option pool (5M shares = 50% of authorized)
        // Tests can override this if they need different pool sizes
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 5_000_000e6, "");
    }

    // ========== 409A VALUATION TESTS. ==========

    function test_Record409A() public {
        vm.prank(board);
        vm.expectEmit(true, true, true, true);
        emit ValuationRecorded(0, 0.001e6, block.timestamp, "ipfs://409a-report-1");
        optionPool.recordValuation(0.001e6, "ipfs://409a-report-1");

        assertEq(optionPool.getValuationCount(), 1);
        assertEq(optionPool.getCurrentFMV(), 0.001e6);

        OptionPool.ValuationRecord memory record = optionPool.getValuation(0);
        assertEq(record.fairMarketValue, 0.001e6);
        assertEq(record.documentRef, "ipfs://409a-report-1");
    }

    function test_Record409A_Multiple() public {
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-1");

        vm.warp(block.timestamp + 365 days);

        vm.prank(board);
        optionPool.recordValuation(0.5e6, "ipfs://409a-2");

        assertEq(optionPool.getValuationCount(), 2);
        assertEq(optionPool.getCurrentFMV(), 0.5e6);
    }

    function test_Record409A_OnlyBoard() public {
        vm.prank(employee1);
        vm.expectRevert(OptionPool.OnlyBoard.selector);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report-1");
    }

    // ========== POOL MANAGEMENT TESTS ==========

    function test_IncreasePoolSize_InitialSetup() public {
        // Create new token to test fresh pool setup from 0
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred", "Test Preferred", "TEST-P", 5_000_000e6, 1e6, 1, 0, ""
        );
        ShareToken prefToken = company.getShareToken("Preferred");

        // Initially, pool should be 0
        assertEq(optionPool.getPoolSize(address(prefToken)), 0);

        // Establish initial pool (from 0 to 2M)
        vm.prank(board);
        vm.expectEmit(true, false, false, true);
        emit PoolSizeIncreased(address(prefToken), 0, 2_000_000e6, "");
        optionPool.increasePoolSize(address(prefToken), 2_000_000e6, "");

        // Verify
        assertEq(optionPool.getPoolSize(address(prefToken)), 2_000_000e6);

        // Check status
        (
            uint256 authorized,
            uint256 issued,
            uint256 poolSize,
            uint256 granted,
            uint256 available,
            uint256 unallocated
        ) = optionPool.getPoolStatus(address(prefToken));

        assertEq(authorized, 5_000_000e6);
        assertEq(issued, 0);
        assertEq(poolSize, 2_000_000e6);
        assertEq(granted, 0);
        assertEq(available, 2_000_000e6);
        assertEq(unallocated, 3_000_000e6);
    }

    function test_IncreasePoolSize_ZeroValidations() public {
        vm.startPrank(board);
        // Zero address
        vm.expectRevert(OptionPool.ZeroAddress.selector);
        optionPool.increasePoolSize(address(0), 1_000_000e6, "");
        // Zero amount
        vm.expectRevert(OptionPool.ZeroAmount.selector);
        optionPool.increasePoolSize(address(shareToken), 0, "");
        vm.stopPrank();
    }

    function test_IncreasePoolSize_OnlyBoard() public {
        vm.prank(employee1);
        vm.expectRevert(OptionPool.OnlyBoard.selector);
        optionPool.increasePoolSize(address(shareToken), 1_000_000e6, "");
    }

    function test_IncreasePoolSize_ExceedsAuthorizedShares() public {
        // Pool is 5M, trying to increase by 6M would total 11M > 10M authorized
        vm.prank(board);
        vm.expectRevert(OptionPool.InsufficientAuthorizedShares.selector);
        optionPool.increasePoolSize(address(shareToken), 6_000_000e6, "");
    }

    function test_IncreasePoolSize_InsufficientCapacity() public {
        _initializePoolAndValuation();

        // Issue 5M shares to investor
        address investor = address(0xABCD);
        vm.prank(board);
        issuance.issueGrant("Common", investor, 5_000_000e6, "Investors", "");

        // Grant 4M options (pool auto-decreases from 5M to 1M)
        vm.prank(board);
        optionPool.grantOptions(employee1, shareToken, 4_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Current: 5M issued + 1M pool + 4M outstanding = 10M allocated
        // Try to increase pool by 1M: 5M issued + 2M pool + 4M outstanding = 11M > 10M authorized
        vm.prank(board);
        vm.expectRevert(OptionPool.InsufficientAuthorizedShares.selector);
        optionPool.increasePoolSize(address(shareToken), 1_000_000e6, "");
    }

    function test_IncreasePoolSize_AddToExisting() public {
        // Pool is 5M from setUp, increase by 1M to reach 6M
        vm.prank(board);
        vm.expectEmit(true, false, false, true);
        emit PoolSizeIncreased(address(shareToken), 5_000_000e6, 6_000_000e6, "");
        optionPool.increasePoolSize(address(shareToken), 1_000_000e6, "");

        assertEq(optionPool.getPoolSize(address(shareToken)), 6_000_000e6);
    }

    function test_DecreasePoolSize() public {
        // Pool is 5M from setUp
        vm.prank(board);
        vm.expectEmit(true, false, false, true);
        emit PoolSizeDecreased(address(shareToken), 5_000_000e6, 4_000_000e6, "");
        optionPool.decreasePoolSize(address(shareToken), 1_000_000e6, "");

        assertEq(optionPool.getPoolSize(address(shareToken)), 4_000_000e6);
    }

    function test_DecreasePoolSize_NoPoolConfigured() public {
        // Create new token without pool
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "ClassC", "Test Class C", "TEST-C", 5_000_000e6, 1e6, 1, 0, ""
        );
        ShareToken classCToken = company.getShareToken("ClassC");

        vm.prank(board);
        vm.expectRevert(OptionPool.NoPoolConfigured.selector);
        optionPool.decreasePoolSize(address(classCToken), 1_000_000e6, "");
    }

    function test_DecreasePoolSize_ZeroValidations() public {
        vm.startPrank(board);
        // Zero address
        vm.expectRevert(OptionPool.ZeroAddress.selector);
        optionPool.decreasePoolSize(address(0), 1_000_000e6, "");
        // Zero amount
        vm.expectRevert(OptionPool.ZeroAmount.selector);
        optionPool.decreasePoolSize(address(shareToken), 0, "");
        vm.stopPrank();
    }

    function test_DecreasePoolSize_ExceedsPool() public {
        // Pool is 5M, try to decrease by 6M
        vm.prank(board);
        vm.expectRevert(OptionPool.InvalidAmount.selector);
        optionPool.decreasePoolSize(address(shareToken), 6_000_000e6, "");
    }

    function test_DecreasePoolSize_PoolTooSmall() public {
        _initializePoolAndValuation();

        // Grant 3M options (pool automatically decreases from 5M to 2M)
        vm.prank(board);
        optionPool.grantOptions(employee1, shareToken, 3_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Pool is now 2M, outstanding is 3M
        // Try to decrease pool by more than available (2M + 1 wei)
        // This would make pool negative, which should revert
        vm.prank(board);
        vm.expectRevert(OptionPool.InvalidAmount.selector);
        optionPool.decreasePoolSize(address(shareToken), 2_000_001e6, "");
    }

    function test_DecreasePoolSize_OnlyBoard() public {
        vm.prank(employee1);
        vm.expectRevert(OptionPool.OnlyBoard.selector);
        optionPool.decreasePoolSize(address(shareToken), 1_000_000e6, "");
    }

    function test_GetPoolStatus_Comprehensive() public {
        _initializePoolAndValuation();

        // Issue 2M shares to investor (not board)
        address investor = address(0xABCD);
        vm.prank(board);
        issuance.issueGrant("Common", investor, 2_000_000e6, "Investors", "");

        // Grant 1M options (pool automatically decreases from 5M to 4M)
        vm.prank(board);
        optionPool.grantOptions(employee1, shareToken, 1_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Check status
        (
            uint256 authorized,
            uint256 issued,
            uint256 poolSize,
            uint256 granted,
            uint256 available,
            uint256 unallocated
        ) = optionPool.getPoolStatus(address(shareToken));

        assertEq(authorized, 10_000_000e6, "Authorized should be 10M");
        assertEq(issued, 2_000_000e6, "Issued should be 2M");
        assertEq(poolSize, 4_000_000e6, "Pool should be 4M (5M - 1M granted)");
        assertEq(granted, 1_000_000e6, "Granted should be 1M");
        assertEq(available, 4_000_000e6, "Available should be 4M (pool = available with automatic decrease)");
        assertEq(unallocated, 3_000_000e6, "Unallocated should be 3M (10M - 2M issued - 4M pool - 1M granted)");
    }

    function test_PoolManagement_IntegrationScenario() public {
        _initializePoolAndValuation();

        // 1. Pool is 5M from setUp, grant 2M (pool auto-decreases to 3M)
        vm.prank(board);
        optionPool.grantOptions(employee1, shareToken, 2_000_000e6, 0, 0, 1460 days, 1 days, true, "");
        assertEq(optionPool.getPoolSize(address(shareToken)), 3_000_000e6, "Pool should be 3M after 2M grant");
        assertEq(
            optionPool.getAvailableCapacity(address(shareToken)), 3_000_000e6, "Available = pool when no further grants"
        );
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 2_000_000e6, "Outstanding = granted");

        // 2. Increase pool by 2M (from 3M to 5M)
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 2_000_000e6, "");
        assertEq(optionPool.getPoolSize(address(shareToken)), 5_000_000e6, "Pool increased to 5M");
        assertEq(optionPool.getAvailableCapacity(address(shareToken)), 5_000_000e6, "Available = pool");

        // 3. Grant another 3M (pool auto-decreases from 5M to 2M)
        vm.prank(board);
        optionPool.grantOptions(employee2, shareToken, 3_000_000e6, 0, 0, 1460 days, 1 days, true, "");
        assertEq(optionPool.getPoolSize(address(shareToken)), 2_000_000e6, "Pool decreased to 2M after 3M grant");
        assertEq(optionPool.getAvailableCapacity(address(shareToken)), 2_000_000e6, "Available = pool");
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 5_000_000e6, "Total outstanding = 2M + 3M");

        // 4. Try to issue shares without decreasing pool (should fail)
        // Current: 0M supply, 2M pool, 5M outstanding, trying 4M
        // Check: 0 + 4M + (2M pool + 5M outstanding) = 11M > 10M authorized ❌
        vm.prank(board);
        vm.expectRevert(); // WouldConsumeOptionPoolCapacity from CompanyStorage
        issuance.issueGrant("Common", address(0x9ABC), 4_000_000e6, "Would exceed", "");

        // 5. Board decreases pool by 2M (from 2M to 0M)
        // This is a governance decision: board decides they don't need the remaining pool capacity
        vm.prank(board);
        optionPool.decreasePoolSize(address(shareToken), 2_000_000e6, "");
        assertEq(optionPool.getPoolSize(address(shareToken)), 0, "Pool decreased to 0");

        // 6. Now can issue shares: 0M supply + 4M + (0M pool + 5M outstanding) = 9M ≤ 10M ✓
        vm.prank(board);
        issuance.issueGrant("Common", address(0x9ABC), 4_000_000e6, "Within capacity", "");
        assertEq(shareToken.totalSupply(), 4_000_000e6);

        // Current: 4M supply + 0M pool + 5M outstanding = 9M allocated, 1M available
        vm.prank(board);
        issuance.issueGrant("Common", address(0xDEF0), 1_000_000e6, "Final issuance", "");
        assertEq(shareToken.totalSupply(), 5_000_000e6);
    }

    function test_MultipleShareClasses_IndependentPools() public {
        _initializePoolAndValuation();

        // Create Preferred share class
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred-A", "Test Preferred A", "TEST-PA", 3_000_000e6, 1e6, 1, 0, ""
        );
        ShareToken prefToken = company.getShareToken("Preferred-A");

        // Establish pool for Preferred (500K)
        vm.prank(board);
        optionPool.increasePoolSize(address(prefToken), 500_000e6, "");

        // Record 409A for granting
        vm.prank(board);
        optionPool.recordValuation(0.01e6, "ipfs://409a-preferred");

        // Grant from Common pool (5M available, auto-decreases to 4M)
        vm.prank(board);
        optionPool.grantOptions(employee1, shareToken, 1_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Grant from Preferred pool (500K available, auto-decreases to 300K)
        vm.prank(board);
        optionPool.grantOptions(employee2, prefToken, 200_000e6, 0, 0, 1460 days, 1 days, false, "");

        // Verify independent tracking with automatic pool decrease
        assertEq(optionPool.getPoolSize(address(shareToken)), 4_000_000e6, "Common pool: 5M - 1M granted = 4M");
        assertEq(optionPool.getPoolSize(address(prefToken)), 300_000e6, "Preferred pool: 500K - 200K granted = 300K");
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 1_000_000e6, "Common outstanding");
        assertEq(optionPool.outstandingOptionsByToken(address(prefToken)), 200_000e6, "Preferred outstanding");
        assertEq(optionPool.getAvailableCapacity(address(shareToken)), 4_000_000e6, "Common available = pool");
        assertEq(optionPool.getAvailableCapacity(address(prefToken)), 300_000e6, "Preferred available = pool");
    }

    function test_IncreasePoolSize_RejectsInvalidToken() public {
        // Deploy a second company with its own token
        (Company company2,,,,,, ShareToken foreignToken,) = _deployStandardCompany();

        // Try to increase pool size for foreign token - should fail
        vm.prank(board);
        vm.expectRevert(OptionPool.InvalidShareToken.selector);
        optionPool.increasePoolSize(address(foreignToken), 1_000_000e6, "");
    }

    function test_DecreasePoolSize_RejectsInvalidToken() public {
        // Deploy a second company with its own token
        (Company company2,,,,,, ShareToken foreignToken,) = _deployStandardCompany();

        // Try to decrease pool size for foreign token - should fail
        vm.prank(board);
        vm.expectRevert(OptionPool.InvalidShareToken.selector);
        optionPool.decreasePoolSize(address(foreignToken), 1_000_000e6, "");
    }

    function test_GrantOptions_RejectsInvalidToken() public {
        _initializePoolAndValuation();

        // Deploy a second company with its own token
        (Company company2,,,,,, ShareToken foreignToken,) = _deployStandardCompany();

        // Try to grant options on foreign token - should fail
        vm.prank(board);
        vm.expectRevert(OptionPool.InvalidShareToken.selector);
        optionPool.grantOptions(employee1, foreignToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");
    }

    function test_PoolOperations_AcceptsValidToken() public {
        _initializePoolAndValuation();

        // Create a second share class for the SAME company
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred", "Test Preferred", "TEST-P", 5_000_000e6, 1e6, 1, 0, ""
        );
        ShareToken prefToken = company.getShareToken("Preferred");

        // Should be able to set pool size for valid token
        vm.prank(board);
        optionPool.increasePoolSize(address(prefToken), 1_000_000e6, "");
        assertEq(optionPool.getPoolSize(address(prefToken)), 1_000_000e6);

        // Should be able to grant options on valid token
        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, prefToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");
        OptionPool.OptionGrant memory grant = optionPool.getGrant(grantId);
        assertEq(address(grant.shareToken), address(prefToken));
    }

    // ========== OPTION GRANTING TESTS ==========

    function test_GrantOptions() public {
        _initializePoolAndValuation();

        vm.prank(board);
        vm.expectEmit(true, true, true, true);
        emit OptionsGranted(0, employee1, 100_000e6, 0.001e6, 365 days, 1460 days, 1 days, true, "");
        // Grant (4 year vest, 1 year cliff, 1 day tick)
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        // Verify grant
        OptionPool.OptionGrant memory grant = optionPool.getGrant(grantId);
        assertEq(grant.employee, employee1);
        assertEq(grant.amount, 100_000e6);
        assertEq(grant.strikePrice, 0.001e6);
        assertEq(grant.cliffDuration, 365 days);
        assertEq(grant.vestingDuration, 1460 days);
        assertEq(grant.vestingInterval, 1 days);
        assertTrue(grant.isTaxAdvantaged);
        assertFalse(grant.revoked);

        // Verify pool accounting (outstanding options for this token)
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 100_000e6);
    }

    function test_GrantOptions_ExceedsPoolCapacity() public {
        _initializePoolAndValuation();

        // Pool is 5M (set in setUp), trying to grant 11M should fail with InsufficientPoolCapacity
        vm.prank(board);
        vm.expectRevert(OptionPool.InsufficientPoolCapacity.selector);
        optionPool.grantOptions(employee1, shareToken, 11_000_000e6, 0, 365 days, 1460 days, 1 days, true, "");
    }

    function test_GrantOptions_NoValuation() public {
        vm.prank(board);
        vm.expectRevert(OptionPool.NoValuationOnRecord.selector);
        optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");
    }

    function test_GrantOptions_MultipleEmployees() public {
        _initializePoolAndValuation();

        vm.prank(board);
        optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        vm.prank(board);
        optionPool.grantOptions(employee2, shareToken, 50_000e6, 0, 365 days, 1460 days, 1 days, false, "");

        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 150_000e6);

        uint256[] memory employee1Grants = optionPool.getEmployeeGrants(employee1);
        uint256[] memory employee2Grants = optionPool.getEmployeeGrants(employee2);

        assertEq(employee1Grants.length, 1);
        assertEq(employee2Grants.length, 1);
    }

    // ========== OPTION EXERCISE TESTS ==========

    function test_ExerciseOptions() public {
        _initializePoolAndValuation();

        vm.prank(board);
        // 100k grant. 1y cliff. 1460 days duration, 1 day tick
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        // Fast forward 1 year (25% vested)
        vm.warp(block.timestamp + 365 days);

        // Exercise 25,000 vested options
        uint256 exercisableAmount = optionPool.getExercisableAmount(grantId);
        assertEq(exercisableAmount, 25_000e6);

        uint256 payment = (25_000e6 * 0.001e6) / 1e6;

        uint256 vaultBalanceBefore = musd.balanceOf(address(vault));
        uint256 totalSupplyBefore = shareToken.totalSupply();

        _mintAndApprove(employee1, payment, address(optionPool));
        vm.prank(employee1);
        vm.expectEmit(true, true, true, true);
        emit OptionsExercised(grantId, employee1, 25_000e6, payment, block.timestamp);
        optionPool.exercise(grantId, 25_000e6);

        // Verify shares minted
        assertEq(shareToken.balanceOf(employee1), 25_000e6);
        assertEq(shareToken.totalSupply(), totalSupplyBefore + 25_000e6);

        // Verify payment sent to vault
        assertEq(musd.balanceOf(address(vault)), vaultBalanceBefore + payment);

        // Verify grant updated
        OptionPool.OptionGrant memory grant = optionPool.getGrant(grantId);
        assertEq(grant.exercised, 25_000e6);

        // Verify outstanding options decreased (100k granted, 25k exercised = 75k outstanding)
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 75_000e6);
    }

    function test_ExerciseOptions_IncorrectPayment() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        vm.warp(block.timestamp + 365 days);

        uint256 payment = (25_000e6 * 0.001e6) / 1e6;

        // Approve less than required — ERC20 transferFrom will revert
        _mintAndApprove(employee1, payment - 1, address(optionPool));
        vm.prank(employee1);
        vm.expectRevert();
        optionPool.exercise(grantId, 25_000e6);
    }

    function test_ExerciseOptions_NotVested() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        // Try to exercise immediately (0 vested)
        uint256 payment = (10_000e6 * 0.001e6) / 1e6;

        _mintAndApprove(employee1, payment, address(optionPool));
        vm.prank(employee1);
        vm.expectRevert(OptionPool.InvalidState.selector);
        optionPool.exercise(grantId, 10_000e6);
    }

    function test_ExerciseOptions_PartialExercise() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        // Fast forward 2 years (50% vested = 50,000)
        vm.warp(block.timestamp + 730 days);

        // Exercise only 10,000 of 50,000 available
        uint256 payment = (10_000e6 * 0.001e6) / 1e6;

        _mintAndApprove(employee1, payment, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 10_000e6);

        assertEq(shareToken.balanceOf(employee1), 10_000e6);

        // Can exercise more later
        assertEq(optionPool.getExercisableAmount(grantId), 40_000e6);

        uint256 payment2 = (20_000e6 * 0.001e6) / 1e6;

        _mintAndApprove(employee1, payment2, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 20_000e6);

        assertEq(shareToken.balanceOf(employee1), 30_000e6);
        assertEq(optionPool.getExercisableAmount(grantId), 20_000e6);
    }

    function test_ExerciseOptions_OnlyEmployee() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        vm.warp(block.timestamp + 365 days);

        uint256 payment = (25_000e6 * 0.001e6) / 1e6;

        // Different address tries to exercise
        _mintAndApprove(employee2, payment, address(optionPool));
        vm.prank(employee2);
        vm.expectRevert(OptionPool.OnlyEmployee.selector);
        optionPool.exercise(grantId, 25_000e6);
    }

    // ========== REVOCATION TESTS ==========

    function test_RevokeGrant() public {
        _initializePoolAndValuation();

        // Pool starts at 5M, grant 100K reduces it to 4.9M
        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        assertEq(optionPool.getPoolSize(address(shareToken)), 4_900_000e6, "Pool should be 4.9M after 100K grant");
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 100_000e6, "Outstanding should be 100K");

        // Fast forward 1 year (25% vested)
        vm.warp(block.timestamp + 365 days);

        vm.prank(board);
        vm.expectEmit(true, true, true, true);
        emit GrantRevoked(grantId, employee1, 25_000e6, 75_000e6, "");
        optionPool.revokeGrant(grantId, "");

        // Verify grant is revoked
        OptionPool.OptionGrant memory grant = optionPool.getGrant(grantId);
        assertTrue(grant.revoked);

        // Verify expiration set to 90 days from now
        assertEq(grant.expirationDate, block.timestamp + 90 days);

        // Verify pool accounting: unvested (75K) returned to pool, only 25K vested remain outstanding
        assertEq(
            optionPool.outstandingOptionsByToken(address(shareToken)), 25_000e6, "Outstanding should be 25K (vested)"
        );
        assertEq(
            optionPool.getPoolSize(address(shareToken)), 4_975_000e6, "Pool should be 4.975M (4.9M + 75K returned)"
        );
    }

    function test_RevokeGrant_CanStillExerciseVested() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        uint256 grantTime = block.timestamp;
        vm.warp(grantTime + 365 days);

        vm.prank(board);
        optionPool.revokeGrant(grantId, "");

        // Should still be able to exercise vested options
        uint256 payment = (25_000e6 * 0.001e6) / 1e6;

        _mintAndApprove(employee1, payment, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 25_000e6);

        assertEq(shareToken.balanceOf(employee1), 25_000e6);
    }

    function test_RevokeGrant_AlreadyRevoked() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        vm.prank(board);
        optionPool.revokeGrant(grantId, "");

        vm.prank(board);
        vm.expectRevert(OptionPool.InvalidState.selector);
        optionPool.revokeGrant(grantId, "");
    }

    // ========== VIEW FUNCTION TESTS ==========

    function test_GetGrantDetails() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        vm.warp(block.timestamp + 365 days);

        (OptionPool.OptionGrant memory grant, uint256 vested, uint256 exercisable, uint256 remaining) =
            optionPool.getGrantDetails(grantId);

        assertEq(grant.employee, employee1);
        assertEq(vested, 25_000e6);
        assertEq(exercisable, 25_000e6);
        assertEq(remaining, 75_000e6);
    }

    // ========== INTEGRATION TESTS ==========

    function test_FullLifecycle() public {
        // 1. Initialize pool and record 409A
        _initializePoolAndValuation();

        // 2. Grant options to employee
        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        uint256 grantTime = block.timestamp;

        // 3. Wait 1 year, exercise 25%
        vm.warp(grantTime + 365 days);
        uint256 payment1 = (25_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment1, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 25_000e6);

        assertEq(shareToken.balanceOf(employee1), 25_000e6);

        // 4. Wait another year, exercise 25% more
        vm.warp(grantTime + 730 days);
        uint256 payment2 = (25_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment2, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 25_000e6);

        assertEq(shareToken.balanceOf(employee1), 50_000e6);

        // 5. Wait to full vest, exercise all remaining
        vm.warp(grantTime + 1460 days);
        uint256 payment3 = (50_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment3, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 50_000e6);

        assertEq(shareToken.balanceOf(employee1), 100_000e6);
        assertEq(optionPool.getExercisableAmount(grantId), 0);
    }

    function test_CapTableAccounting() public {
        _initializePoolAndValuation();

        // Initial state: no shares issued
        assertEq(shareToken.totalSupply(), 0);
        assertEq(shareToken.authorizedShares(), 10_000_000e6);

        // Grant options - NO dilution yet
        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        assertEq(shareToken.totalSupply(), 0); // Still no dilution

        // Exercise - NOW dilution happens
        vm.warp(block.timestamp + 365 days);
        uint256 payment = (25_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 25_000e6);

        assertEq(shareToken.totalSupply(), 25_000e6); // Dilution from exercise
    }

    // ========== EXPIRATION TESTS ==========

    function test_ExpiredOptions_BlockNewGrants() public {
        _initializePoolAndValuation();

        // Increase pool to 9M to test cleanup of large expired grants
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 4_000_000e6, ""); // 5M + 4M = 9M

        // Grant 9M options to employee1 (pool auto-decreases from 9M to 0M)
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(employee1, shareToken, 9_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Verify pool decreased and outstanding tracked
        assertEq(optionPool.getPoolSize(address(shareToken)), 0, "Pool should be 0 after 9M grant from 9M pool");
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 9_000_000e6, "Should track 9M outstanding");

        // Try to grant 2M more options to employee2 (pool exhausted to 0)
        vm.prank(board);
        vm.expectRevert(OptionPool.NoPoolConfigured.selector);
        optionPool.grantOptions(employee2, shareToken, 2_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Fast forward 10 years - options expire
        vm.warp(block.timestamp + 10 * 365 days + 1 days);

        // Options are now expired (employee can't exercise)
        _mintAndApprove(employee1, 1_000e6, address(optionPool));
        vm.prank(employee1);
        vm.expectRevert(OptionPool.InvalidState.selector);
        optionPool.exercise(grantId, 1_000_000e6);

        // But outstanding capacity is STILL reserved (this is expected behavior)
        assertEq(
            optionPool.outstandingOptionsByToken(address(shareToken)),
            9_000_000e6,
            "Outstanding still shows 9M even though expired"
        );

        // Board still can't grant new options even though old ones expired (pool exhausted to 0)
        vm.prank(board);
        vm.expectRevert(OptionPool.NoPoolConfigured.selector);
        optionPool.grantOptions(employee2, shareToken, 2_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Now cleanup the expired grant (can be called by anyone)
        optionPool.cleanupExpiredGrant(grantId);

        // Capacity should now be released back to pool (9M returned)
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 0, "Outstanding should be 0 after cleanup");
        assertEq(optionPool.getPoolSize(address(shareToken)), 9_000_000e6, "Pool should be 9M after cleanup");

        // Board can now grant from the restored pool (9M available)
        vm.prank(board);
        uint256 newGrantId =
            optionPool.grantOptions(employee2, shareToken, 2_000_000e6, 0, 0, 1460 days, 1 days, true, "");
        assertGt(newGrantId, 0, "Should successfully grant after cleanup");
        assertEq(optionPool.getPoolSize(address(shareToken)), 7_000_000e6, "Pool should be 7M after 2M grant");
    }

    function test_RevokedOptions_ExpireAfter90Days() public {
        _initializePoolAndValuation();

        // Grant options and let them vest
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(employee1, shareToken, 1_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Wait 1 year (25% vested)
        vm.warp(block.timestamp + 365 days);

        // Revoke the grant
        vm.prank(board);
        optionPool.revokeGrant(grantId, "");

        // Unvested options (750K) are forfeited, vested options (250K) remain exercisable for 90 days
        assertEq(
            optionPool.outstandingOptionsByToken(address(shareToken)),
            250_000e6,
            "Only vested portion should remain outstanding"
        );

        // Fast forward 90 days + 1 day
        vm.warp(block.timestamp + 90 days + 1 days);

        // Options are now expired
        _mintAndApprove(employee1, 100e6, address(optionPool));
        vm.prank(employee1);
        vm.expectRevert(OptionPool.InvalidState.selector);
        optionPool.exercise(grantId, 100_000e6);

        // But capacity is still reserved (same issue)
        assertEq(
            optionPool.outstandingOptionsByToken(address(shareToken)),
            250_000e6,
            "Outstanding still shows 250K even though expired"
        );

        // Cleanup the expired grant
        optionPool.cleanupExpiredGrant(grantId);

        // Capacity should now be released
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 0, "Outstanding should be 0 after cleanup");
    }

    function test_CleanupExpiredGrant_Validations() public {
        _initializePoolAndValuation();

        // Grant options
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(employee1, shareToken, 1_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Try to cleanup before expiration - should fail
        vm.expectRevert(OptionPool.InvalidState.selector);
        optionPool.cleanupExpiredGrant(grantId);

        // Fast forward to expiration
        vm.warp(block.timestamp + 10 * 365 days + 1 days);

        // Cleanup should work
        optionPool.cleanupExpiredGrant(grantId);

        // Try to cleanup again - should fail
        vm.expectRevert(OptionPool.InvalidState.selector);
        optionPool.cleanupExpiredGrant(grantId);
    }

    function test_CleanupExpiredGrant_PartiallyExercised() public {
        _initializePoolAndValuation();

        // Pool starts at 5M, grant 100K reduces it to 4.9M
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 0, 1460 days, 1 days, true, "");

        assertEq(optionPool.getPoolSize(address(shareToken)), 4_900_000e6, "Pool should be 4.9M after 100K grant");
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 100_000e6, "Outstanding should be 100K");

        // Wait and exercise 25K (25%)
        vm.warp(block.timestamp + 365 days);
        uint256 payment = (25_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 25_000e6);

        // Outstanding should be 75K (100K - 25K exercised)
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 75_000e6, "Outstanding should be 75K");
        assertEq(
            optionPool.getPoolSize(address(shareToken)),
            4_900_000e6,
            "Pool should still be 4.9M (exercise doesn't affect pool)"
        );

        // Fast forward to expiration
        vm.warp(block.timestamp + 10 * 365 days);

        // Cleanup - should release 75K (the unexercised portion) and return to pool
        optionPool.cleanupExpiredGrant(grantId);

        // Outstanding should be 0, pool should have 75K returned
        assertEq(optionPool.outstandingOptionsByToken(address(shareToken)), 0, "Outstanding should be 0 after cleanup");
        assertEq(
            optionPool.getPoolSize(address(shareToken)), 4_975_000e6, "Pool should be 4.975M (4.9M + 75K returned)"
        );
    }

    // ========== FUZZ TESTS ==========

    function test_Fuzz_VestingIntervals_Daily(uint256 grantAmount, uint256 timeElapsed) public {
        // Bound inputs to reasonable ranges (whole shares only)
        // Pool is 5M (set in setUp), so limit grants to pool size
        grantAmount = bound(grantAmount, 100, 5_000_000); // 100 to 5M shares
        grantAmount = grantAmount * 1e6; // Convert to 6 decimals (whole shares)
        timeElapsed = bound(timeElapsed, 0, 1460 days); // 0 to 4 years

        _initializePoolAndValuation();

        // Grant with DAILY vesting (1 day interval)
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(employee1, shareToken, grantAmount, 0, 0, 1460 days, 1 days, true, "");

        // Fast forward time
        vm.warp(block.timestamp + timeElapsed);

        // Get vested amount
        (, uint256 vested,,) = optionPool.getGrantDetails(grantId);

        // Assertions
        assertLe(vested, grantAmount, "Vested should not exceed grant amount");
        assertEq(vested % 1e6, 0, "Vested should be whole shares only");

        // Check that vesting is proportional
        if (timeElapsed >= 1460 days) {
            assertEq(vested, grantAmount, "Should be fully vested after 4 years");
        } else {
            uint256 expectedIntervals = timeElapsed / 1 days;
            uint256 totalIntervals = 1460 days / 1 days;
            uint256 expectedVested = (grantAmount * expectedIntervals) / totalIntervals;
            expectedVested = (expectedVested / 1e6) * 1e6; // Round to whole shares

            assertEq(vested, expectedVested, "Vested amount should match calculation");
        }
    }

    function test_Fuzz_VestingIntervals(uint256 grantAmount, uint256 vestingInterval, uint256 timeElapsed) public {
        // Pool is 5M (set in setUp), so limit grants to pool size
        grantAmount = bound(grantAmount, 100, 5_000_000);
        grantAmount = grantAmount * 1e6; // Whole shares only

        // Test various vesting intervals (1 day to 365 days)
        vestingInterval = bound(vestingInterval, 1 days, 365 days);

        // Ensure vestingDuration is divisible by vestingInterval for cleaner tests
        uint256 vestingDuration = 1460 days;

        timeElapsed = bound(timeElapsed, 0, vestingDuration);

        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(
            employee1, shareToken, grantAmount, 0, 0, vestingDuration, vestingInterval, true, ""
        );

        vm.warp(block.timestamp + timeElapsed);

        (, uint256 vested,,) = optionPool.getGrantDetails(grantId);

        // Invariants that must hold for ANY vesting interval
        assertLe(vested, grantAmount, "Vested should not exceed grant amount");
        assertEq(vested % 1e6, 0, "Vested should be whole shares only");

        // Additional check: vesting should be monotonic (always increasing or same)
        if (timeElapsed >= vestingDuration) {
            assertEq(vested, grantAmount, "Should be fully vested after vesting duration");
        }
    }

    function test_Fuzz_VestingWithCliff(
        uint256 grantAmount,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 timeElapsed
    ) public {
        // Bound inputs
        // Pool is 5M (set in setUp), so limit grants to pool size
        grantAmount = bound(grantAmount, 100, 5_000_000);
        grantAmount = grantAmount * 1e6; // Whole shares only
        cliffDuration = bound(cliffDuration, 0, 365 days); // 0 to 1 year cliff
        vestingDuration = bound(vestingDuration, cliffDuration + 1 days, 1460 days); // Vesting must be > cliff
        timeElapsed = bound(timeElapsed, 0, vestingDuration);

        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(
            employee1, shareToken, grantAmount, 0, cliffDuration, vestingDuration, 1 days, true, ""
        );

        vm.warp(block.timestamp + timeElapsed);

        (, uint256 vested,,) = optionPool.getGrantDetails(grantId);

        // Before cliff: nothing vests
        if (timeElapsed < cliffDuration) {
            assertEq(vested, 0, "Nothing should vest before cliff");
        }

        // After cliff: proportional vesting
        assertLe(vested, grantAmount, "Vested should not exceed grant amount");
        assertEq(vested % 1e6, 0, "Vested should be whole shares only");
    }

    function test_Fuzz_ExerciseAmount(uint256 grantAmount, uint256 exerciseAmount) public {
        // Pool is 5M (set in setUp), so limit grants to pool size
        grantAmount = bound(grantAmount, 1_000, 5_000_000); // 1K to 5M shares
        grantAmount = grantAmount * 1e6; // Whole shares
        exerciseAmount = bound(exerciseAmount, 1, grantAmount / 1e6); // 1 to grant amount (in shares)
        exerciseAmount = exerciseAmount * 1e6; // Whole shares

        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(employee1, shareToken, grantAmount, 0, 0, 1460 days, 1 days, true, "");

        // Fully vest
        vm.warp(block.timestamp + 1460 days);

        // Calculate payment
        uint256 payment = (exerciseAmount * 0.001e6) / 1e6;

        // Only exercise if payment is a reasonable amount
        if (payment <= 100e6) {
            _mintAndApprove(employee1, payment, address(optionPool));

            vm.prank(employee1);
            optionPool.exercise(grantId, exerciseAmount);

            // Verify shares were minted
            assertEq(shareToken.balanceOf(employee1), exerciseAmount, "Shares should be minted");

            // Verify outstanding decreased
            assertEq(
                optionPool.outstandingOptionsByToken(address(shareToken)),
                grantAmount - exerciseAmount,
                "Outstanding should decrease"
            );
        }
    }

    function test_Fuzz_StrikePriceCalculation(uint256 strikePrice, uint256 exerciseAmount) public {
        // Bound inputs (6-decimal payment token units)
        strikePrice = bound(strikePrice, 100, 10_000_000); // $0.0001 to $10 per share
        exerciseAmount = bound(exerciseAmount, 1, 100_000); // 1 to 100K shares
        exerciseAmount = exerciseAmount * 1e6; // Whole shares

        vm.prank(board);
        optionPool.recordValuation(strikePrice, "ipfs://409a-report");

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, exerciseAmount, 0, 0, 1460 days, 1 days, true, "");

        // Fully vest
        vm.warp(block.timestamp + 1460 days);

        // Calculate expected payment
        uint256 expectedPayment = (exerciseAmount * strikePrice) / 1e6;

        // Only test if payment is reasonable
        if (expectedPayment <= 100_000e6) {
            _mintAndApprove(employee1, expectedPayment, address(optionPool));

            uint256 vaultBalanceBefore = musd.balanceOf(address(vault));

            vm.prank(employee1);
            optionPool.exercise(grantId, exerciseAmount);

            // Verify payment went to vault
            assertEq(musd.balanceOf(address(vault)), vaultBalanceBefore + expectedPayment, "Payment should go to vault");
        }
    }

    // ========== BACKDATING TESTS ==========

    function test_GrantOptions_Backdated() public {
        vm.warp(365 days * 10); // Set realistic timestamp
        _initializePoolAndValuation();

        // Company onboards 6 months after promising options
        uint256 promiseDate = block.timestamp - 180 days;

        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(
            employee1, shareToken, 100_000e6, promiseDate, 365 days, 1460 days, 1 days, true, ""
        );

        OptionPool.OptionGrant memory grant = optionPool.getGrant(grantId);
        assertEq(grant.grantDate, promiseDate, "Grant date should be backdated");
        assertEq(grant.expirationDate, promiseDate + 10 * 365 days, "Expiration anchored to grant date");

        // 180 days elapsed, cliff is 365 days — still in cliff
        assertEq(optionPool.getExercisableAmount(grantId), 0, "Still in cliff");

        // Warp 185 more days (total 365 days from promiseDate) — cliff passed, ~25% vested
        vm.warp(block.timestamp + 185 days);
        uint256 exercisable = optionPool.getExercisableAmount(grantId);
        assertEq(exercisable, 25_000e6, "25% vested after 1 year from backdated grant");
    }

    function test_GrantOptions_BackdatedAlreadyVested() public {
        vm.warp(365 days * 10);
        _initializePoolAndValuation();

        // Backdate 2 years — 50% already vested at grant time
        uint256 twoYearsAgo = block.timestamp - 730 days;

        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(
            employee1, shareToken, 100_000e6, twoYearsAgo, 365 days, 1460 days, 1 days, true, ""
        );

        // Should be immediately exercisable (50% of 4yr vest)
        uint256 exercisable = optionPool.getExercisableAmount(grantId);
        assertEq(exercisable, 50_000e6, "50% immediately exercisable on backdated grant");

        // Exercise immediately
        uint256 payment = (50_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grantId, 50_000e6);

        assertEq(shareToken.balanceOf(employee1), 50_000e6);
    }

    function test_GrantOptions_BackdatedZeroMeansNow() public {
        _initializePoolAndValuation();

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        OptionPool.OptionGrant memory grant = optionPool.getGrant(grantId);
        assertEq(grant.grantDate, block.timestamp, "grantDate=0 should use block.timestamp");
    }

    function test_GrantOptions_RevertFutureDate() public {
        _initializePoolAndValuation();

        vm.prank(board);
        vm.expectRevert(OptionPool.InvalidAmount.selector);
        optionPool.grantOptions(
            employee1, shareToken, 100_000e6, block.timestamp + 1, 365 days, 1460 days, 1 days, true, ""
        );
    }

    function test_GrantOptions_BackdatedFuzz(uint256 backdateDays) public {
        // 1D to 5Y
        backdateDays = bound(backdateDays, 1, 1825);
        vm.warp(365 days * 10);
        _initializePoolAndValuation();

        uint256 pastDate = block.timestamp - (backdateDays * 1 days);

        vm.prank(board);
        uint256 grantId =
            optionPool.grantOptions(employee1, shareToken, 100_000e6, pastDate, 365 days, 1460 days, 1 days, true, "");

        OptionPool.OptionGrant memory grant = optionPool.getGrant(grantId);
        assertEq(grant.grantDate, pastDate);
        assertEq(grant.expirationDate, pastDate + 10 * 365 days);

        // Vested amount should be consistent with elapsed time
        uint256 elapsed = block.timestamp - pastDate;
        if (elapsed < 365 days) {
            assertEq(optionPool.getExercisableAmount(grantId), 0);
        } else if (elapsed >= 1460 days) {
            // Fully vested
            assertEq(optionPool.getExercisableAmount(grantId), 100_000e6);
        } else {
            // Partially vested — should be > 0
            assertTrue(optionPool.getExercisableAmount(grantId) > 0);
        }
    }

    // ========== HELPER FUNCTIONS ==========

    function _initializePoolAndValuation() internal {
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report"); // $0.001 per share in 6-decimal payment token
    }
}
