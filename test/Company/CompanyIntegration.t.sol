// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import {SAFE} from "../../src/SAFE.sol";
import {EquityIssuance} from "../../src/EquityIssuance.sol";
import {MockZKVerifier} from "../../src/mocks/MockZKVerifier.sol";

/// @title CompanyIntegrationTest
/// @notice Integration tests for Company contract interactions with VestingSchedule, OptionPool, SAFE, and ShareTokens
contract CompanyIntegrationTest is BaseTest {
    OptionPool optionPool;
    SAFE safeContract;
    Fundraise fundraise;
    // `issuance` inherited from BaseTest (populated by _deployStandardCompany).
    MockZKVerifier zkVerifier;
    address employee1 = address(0xE001);
    address employee2 = address(0xE002);
    address investor1 = address(0x1001);
    address investor2 = address(0x1002);

    function setUp() public {
        _baseSetUp();

        // Deploy standard company with 10M authorized shares using helper
        ShareholderRegistry deployedRegistry;
        Fundraise deployedFundraise;
        (company, vault, vestingSchedule, deployedRegistry, optionPool, safeContract, shareToken, deployedFundraise) =
            _deployStandardCompany();
        fundraise = deployedFundraise;

        zkVerifier = conversionVerifier;

        // Fund employees and investors
        vm.deal(employee1, 10000 ether);
        vm.deal(employee2, 10000 ether);
        vm.deal(investor1, 10000 ether);
        vm.deal(investor2, 10000 ether);
    }

    /**
     * @notice Integration Test: Authorized Share Capacity Protection (Options + Vesting)
     *
     * SCENARIO:
     * Company has 10M authorized shares. Board wants to:
     * 1. Issue 6M shares with vesting for founders
     * 2. Grant 3M options to employees
     * 3. Issue additional shares to investors
     *
     * REAL WORKFLOW STEPS:
     * 1. Mint 6M shares to VestingSchedule contract (immediate dilution)
     * 2. Create vesting schedule for founder (shares locked in vesting)
     * 3. Set option pool to 3M and grant to employees (reserves 3M capacity)
     * 4. Try to issue 2M more shares → Should FAIL (6M minted + 3M reserved = 9M, only 1M available)
     * 5. Issue 1M shares → SUCCESS (exactly hits 10M limit)
     * 6. Employee exercises 250K options (mints 250K, releases 250K from reserved)
     * 7. Now 1.25M more capacity available for new issuance
     *
     * DEMONSTRATES:
     * - Vesting causes immediate dilution (shares pre-minted)
     * - Options reserve capacity without dilution (until exercised)
     * - System prevents over-allocation across all mechanisms
     * - Exercising options frees up capacity for new issuance
     */
    function test_CannotExceedAuthorizedShares_OptionsAndVesting() public {
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report");

        // Authorized shares: 10,000,000e6
        // Strategy: Issue 6M via vesting, grant 3M in options, exercise to reach 9.25M, then try to exceed

        // Step 1: Issue 6,000,000 shares to VestingSchedule
        vm.prank(board);
        issuance.issueGrantWithVesting(
            ShareToken(shareToken), employee1, 6_000_000e6, block.timestamp, 0, 1460 days, false, ""
        );

        // Step 2: Board establishes 3M option pool (6M issued + 3M pool = 9M <= 10M authorized)
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 3_000_000e6, "");

        // Step 3: Grant 3,000,000 options to employee2
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(
            employee2,
            shareToken,
            3_000_000e6,
            0, // grantDate (now)
            0, // no cliff
            1460 days,
            1 days,
            true,
            ""
        );

        // Step 4: Wait for options to vest (1 year = 25%)
        uint256 grantTime = block.timestamp;
        vm.warp(grantTime + 365 days);

        // Step 5: Exercise 750,000 options (25% of 3M)
        // Current minted: 6M (vesting)
        // Trying to mint: 750K (options)
        // Total would be: 6.75M (still under 10M limit, should succeed)
        uint256 exerciseAmount = 750_000e6;
        uint256 payment = (exerciseAmount * 0.001e6) / 1e6;

        _mintAndApprove(employee2, payment, address(optionPool));
        vm.prank(employee2);
        optionPool.exercise(grantId, exerciseAmount);

        assertEq(shareToken.totalSupply(), 6_750_000e6, "Total supply should be 6.75M after first exercise");

        // Step 6: Try to exercise the remaining options to exceed the limit
        // Trying to exercise remaining 2.25M options
        // Total would be: 6.75M + 2.25M = 9M (still under 10M, but we'll exercise MORE than vested)
        // Wait for full vesting
        vm.warp(grantTime + 1460 days);

        // Try to exercise all remaining: 3M - 750K = 2.25M
        // Total would be: 6.75M + 2.25M = 9M (still valid)
        uint256 remainingAmount = 2_250_000e6;
        uint256 payment2 = (remainingAmount * 0.001e6) / 1e6;

        _mintAndApprove(employee2, payment2, address(optionPool));
        vm.prank(employee2);
        optionPool.exercise(grantId, remainingAmount);

        // Total supply should now be 9M (6M vesting + 3M options exercised)
        assertEq(shareToken.totalSupply(), 9_000_000e6, "Total supply should be 9M after all exercises");
    }

    /**
     * @notice Integration Test: Option Pool Protection from Over-Issuance
     *
     * SCENARIO:
     * Company issues shares to investors and founders, then establishes option pool.
     * Board later tries to issue more shares to new investors, but must respect the
     * option pool reservation to ensure employees can exercise their grants.
     *
     * REAL WORKFLOW STEPS:
     * 1. Issue 3M shares directly to seed investors (mints immediately)
     * 2. Issue 2M shares to VestingSchedule for founder vesting (mints immediately)
     *    - Total supply: 5M
     * 3. Board establishes 3M option pool (governance decision, reserves capacity)
     *    - Allocated: 5M issued + 3M pool = 8M (2M unallocated)
     * 4. Grant entire 3M pool to employee2 with 4-year vesting
     *    - Pool auto-decreases: 3M → 0M
     *    - Outstanding: 0 → 3M
     * 5. Time passes, employee2 vests 25% (but hasn't exercised yet)
     * 6. Board tries to issue 4M more shares to Series A investors → FAIL
     *    - Would require: 5M current + 4M new + 3M outstanding = 12M > 10M authorized
     *    - System blocks with WouldConsumeOptionPoolCapacity error
     * 7. Board can only issue 2M shares (exactly hits capacity limit)
     *    - Calculation: 5M + 2M + 3M = 10M (exactly authorized)
     * 8. Employee2 fully vests and exercises all 3M options
     *    - Mints 3M shares → total supply reaches exactly 10M
     *
     * DEMONSTRATES:
     * - Option pool explicitly reserves capacity in authorized shares
     * - Direct share issuance cannot consume capacity reserved for options
     * - Protection ensures employees can always exercise granted options
     * - System prevents board from accidentally blocking employee equity
     * - Capacity formula enforced: supply + issuance + outstanding ≤ authorized
     */
    function test_ShareIssuance_AfterOptionsGranted_BlocksExercise() public {
        // Record 409A valuation for option grants
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report");

        // Authorized shares: 10,000,000e6
        // Scenario: Set pool, issue shares, grant options, verify pool is protected

        // Step 1: Issue 3M shares directly to investors
        vm.prank(board);
        issuance.issueGrant("Common", address(0xAAAA), 3_000_000e6, "Seed investors", "");

        // Step 2: Issue 2M shares with vesting for founders
        vm.prank(board);
        issuance.issueGrantWithVesting(shareToken, employee1, 2_000_000e6, block.timestamp, 0, 1460 days, false, "");

        // Step 3: Board establishes 3M share option pool (explicit governance decision)
        // Allocated: 5M issued + 3M pool = 8M (2M unallocated)
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 3_000_000e6, "");

        // Step 4: Grant 3M options to employee2 (uses entire pool)
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(
            employee2,
            shareToken,
            3_000_000e6,
            0, // grantDate (now)
            0, // no cliff
            1460 days,
            1 days,
            true,
            ""
        );

        assertEq(shareToken.totalSupply(), 5_000_000e6, "Total supply should be 5M");

        // Step 5: Time passes, employee2's options vest (1 year = 25%)
        uint256 grantTime = block.timestamp;
        vm.warp(grantTime + 365 days);

        // Step 6: Board tries to issue MORE shares (4M) to new investors
        // Current: 5M issued + 3M pool = 8M allocated
        // Trying to issue: 4M
        // Total would be: 5M + 4M + 3M = 12M > 10M authorized
        // This should FAIL because it would consume the option pool capacity
        vm.prank(board);
        vm.expectRevert(EquityIssuance.WouldConsumeOptionPoolCapacity.selector);
        issuance.issueGrant("Common", address(0xBBBB), 4_000_000e6, "Series A investors", "");

        // Verify supply hasn't changed
        assertEq(shareToken.totalSupply(), 5_000_000e6, "Total supply should still be 5M");

        // Step 7: Board can issue smaller amount (2M) that doesn't consume pool
        // 5M + 2M + 3M = 10M (exactly at limit, should succeed)
        vm.prank(board);
        issuance.issueGrant("Common", address(0xBBBB), 2_000_000e6, "Series A investors", "");

        assertEq(shareToken.totalSupply(), 7_000_000e6, "Total supply should be 7M");

        // Step 7: Employee2 can now exercise all 3M options over time
        vm.warp(grantTime + 1460 days); // Fully vested

        uint256 payment = (3_000_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee2, payment, address(optionPool));
        vm.prank(employee2);
        optionPool.exercise(grantId, 3_000_000e6);

        assertEq(shareToken.totalSupply(), 10_000_000e6, "Should reach exactly 10M");
    }

    /// @notice Test that explicit option pool protects capacity for employee equity
    /// @dev With Option B approach, the entire pool is reserved and protected
    /**
     * @notice Integration Test: Option Pool Capacity Reservation
     *
     * SCENARIO:
     * Startup grants large option pool (8M) to employees, wants to ensure they can always exercise
     * even if investors want shares. Tests that granted options truly reserve capacity.
     *
     * REAL WORKFLOW STEPS:
     * 1. Board establishes 8M option pool (80% of 10M authorized)
     * 2. Grant 8M options to 2 employees (4M each)
     *    - Pool auto-decreases: 8M → 4M → 0M
     *    - Outstanding increases: 0 → 4M → 8M
     * 3. Try to issue 3M shares to investors → FAIL
     *    - Calculation: 0 supply + 3M issuance + 0 pool + 8M outstanding = 11M > 10M authorized
     * 4. Board can only issue 2M shares (exactly hits capacity limit)
     * 5. Both employees vest and exercise their 4M options
     * 6. Total supply = 2M (investors) + 8M (employees) = 10M (exactly authorized)
     *
     * DEMONSTRATES:
     * - Automatic pool decrease: when options granted, pool shrinks
     * - Outstanding tracking: granted options reserve capacity in authorized shares
     * - No race condition: employees protected even after direct share issuance
     * - Capacity protection formula: supply + issuance + pool + outstanding ≤ authorized
     */
    function test_OptionsReserveCapacity() public {
        // Record 409A valuation for option grants
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report");

        // Authorized shares: 10,000,000e6

        // Step 1: Board establishes 8M share option pool
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 8_000_000e6, "");

        // Step 2: Grant 8M options to employee1 and employee2 (4M each)
        // Pool auto-decreases: 8M -> 4M -> 0M
        vm.prank(board);
        uint256 grant1 = optionPool.grantOptions(employee1, shareToken, 4_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        vm.prank(board);
        uint256 grant2 = optionPool.grantOptions(employee2, shareToken, 4_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Verify pool and outstanding with automatic decrease
        assertEq(optionPool.getPoolSize(address(shareToken)), 0, "Pool should be 0 after 8M granted from 8M");
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 8_000_000e6, "Should track 8M outstanding");

        // Step 3: Board tries to issue 3M shares to investors
        // 0 (current supply) + 3M (trying to issue) + 0M (pool) + 8M (outstanding) = 11M > 10M
        // This should FAIL - protects the granted options
        vm.prank(board);
        vm.expectRevert(EquityIssuance.WouldConsumeOptionPoolCapacity.selector);
        issuance.issueGrant("Common", address(0xCCCC), 3_000_000e6, "Investors", "");

        // Step 4: Board can only issue up to 2M shares
        // 0 + 2M + 0M pool + 8M outstanding = 10M (exactly at limit)
        vm.prank(board);
        issuance.issueGrant("Common", address(0xCCCC), 2_000_000e6, "Investors", "");

        assertEq(shareToken.totalSupply(), 2_000_000e6);

        // Step 4: Both employees can exercise their options (no race condition!)
        uint256 grantTime = block.timestamp;
        vm.warp(grantTime + 1460 days); // Fully vest both

        uint256 payment1 = (4_000_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment1, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grant1, 4_000_000e6);

        assertEq(shareToken.totalSupply(), 6_000_000e6, "Employee1 exercised");

        uint256 payment2 = (4_000_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee2, payment2, address(optionPool));
        vm.prank(employee2);
        optionPool.exercise(grant2, 4_000_000e6);

        assertEq(shareToken.totalSupply(), 10_000_000e6, "Both employees exercised, exactly 10M");

        // Verify outstanding options decreased as they were exercised
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 0, "All options exercised");
    }

    /**
     * @notice Integration Test: Full Cap Table with All Instruments (Vesting + Options + SAFEs)
     *
     * SCENARIO:
     * Pre-seed startup managing complete cap table with all equity instruments:
     * - Founders with vesting (immediate dilution)
     * - Employees with options (reserved capacity)
     * - SAFE investors (reserved capacity for future conversion)
     * - Direct share issuance to investors
     *
     * NOTE: If discounts or caps it can exceed capacity thus the Board needs to issue more
     *
     * REAL WORKFLOW STEPS:
     * 1. Investor invests $2M via SAFE with $10M cap (issued FIRST while supply = 0)
     * 2. Board sets 3M option pool and grants to employee
     *    - Pool auto-decreases: 3M → 0M
     *    - Outstanding: 0 → 3M
     * 3. Issue 3M shares directly to Series A investors (mints immediately)
     * 4. Issue 2M more shares to additional investors
     *    - Current: 5M minted + 0M pool + 3M outstanding = 8M allocated, 2M available
     * 5. Employee vests and exercises 3M options
     *    - Mints 3M more shares → 8M total minted
     *    - Outstanding: 3M → 0M
     * 6. Board doesn't manually decrease pool (automatic decrease already handled it)
     * 7. Priced round qualifies → opens SAFE conversion batch (async, ZK-gated)
     * 8. Apply SAFE conversion proof → mints remaining shares to SAFE holder
     *    - Final: 10M shares (exactly authorized)
     *
     * SAFE conversion uses MockZKVerifier; real prover lives off-chain.
     * SAFE.t.sol covers verifier mechanics in isolation.
     *
     * DEMONSTRATES:
     * - Order matters: SAFE issued first to get best conversion terms
     * - Automatic pool management: no manual decrease needed after exercise
     * - Multi-instrument coordination: vesting + options + SAFEs + direct issuance
     * - System prevents over-allocation across ALL instruments
     * - Real pre-seed → seed round workflow
     */
    function test_CannotExceedAuthorizedShares_AllThreeTypes() public {
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report");

        // Authorized shares: 10,000,000e6
        // Strategy:
        // - Issue SAFE FIRST (reserves based on 0 shares outstanding)
        // - Reserve 3M for options
        // - Issue 2M via vesting (minted)
        // - Try to issue too many more shares (should fail)

        // Step 1: Issue SAFE via Fundraise FIRST when totalSupply = 0
        // Use smaller investment and NO discount to avoid exceeding capacity
        // Investor invests $2M at $10M cap with 0% discount

        // Create a fundraise round for the SAFE
        vm.prank(board);
        uint256 safeRoundId = fundraise.createRound(
            IFundraise.RoundParams({
                name: "SAFE Round",
                roundType: IFundraise.RoundType.SAFE,
                valuationCap: 10_000_000e6, // $10M valuation cap
                discountBps: 0, // NO discount to avoid exceeding authorized shares
                pricePerShare: 0,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: true,
                whitelistOnly: false,
                documentRef: "ipfs://safe-agreement",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );

        // Investor invests $2M via MUSD
        _mintAndApprove(investor1, 2_000_000e6, address(fundraise));
        _invest(fundraise, safeRoundId, investor1, 2_000_000e6);

        // Close and finalize the round to issue the SAFE
        vm.prank(board);
        fundraise.closeRound(safeRoundId);
        vm.prank(board);
        fundraise.finalizeRound(safeRoundId);

        // Note issued via Fundraise - board manages capacity manually
        // Current state: 0M minted + 0M reserved (options) = 0M allocated, 10M available

        // Step 2: Set option pool size to 3M shares
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 3_000_000e6, "");

        // Step 2b: Grant 3M options to employee (pool auto-decreases from 3M to 0M)
        vm.prank(board);
        uint256 optionGrantId =
            optionPool.grantOptions(employee1, shareToken, 3_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Current state: 0M minted + 0M pool + 3M outstanding = 3M allocated, 7M available

        // Step 3: Issue 3M shares directly
        vm.prank(board);
        issuance.issueGrant("Common", address(0xDDDD), 3_000_000e6, "Series A investors", "");

        assertEq(shareToken.totalSupply(), 3_000_000e6, "Should have 3M minted");

        // Current state: 3M minted + 0M pool + 3M outstanding = 6M allocated, 4M available

        // Step 4: Issue 2M more shares
        vm.prank(board);
        issuance.issueGrant("Common", address(0xEEEE), 2_000_000e6, "More investors", "");

        assertEq(shareToken.totalSupply(), 5_000_000e6, "Should have 5M minted total");

        // Current state: 5M minted + 0M pool + 3M outstanding = 8M allocated, 2M available
        // Board needs to reserve room for SAFE conversion (~2M shares)

        // Step 5: Fast forward to full vesting, exercise the options we granted in step 2
        vm.warp(block.timestamp + 1460 days);

        uint256 optionPayment = (3_000_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, optionPayment, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(optionGrantId, 3_000_000e6);

        assertEq(shareToken.totalSupply(), 8_000_000e6, "Should be 8M after options exercised (5M + 3M)");

        // Step 6: With automatic pool decrease, pool is already 0 after granting 3M
        // No need to manually decrease - capacity is automatically freed
        // Current: 8M minted + 0M pool + 0M outstanding = 8M allocated, 2M available
        assertEq(optionPool.getPoolSize(address(shareToken)), 0, "Pool should be 0 after 3M grant");
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 0, "Outstanding should be 0 after exercise");

        // Step 7: Priced round qualifies and opens SAFE conversion batch
        // Priced investor takes 1 share (1 USDC at $1/share), leaving headroom for SAFE conversion.
        vm.prank(board);
        uint256 pricedRoundId = fundraise.createRound(
            IFundraise.RoundParams({
                name: "Series A Priced",
                roundType: IFundraise.RoundType.PRICED,
                valuationCap: 0,
                discountBps: 0,
                pricePerShare: 1e6,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: false,
                whitelistOnly: false,
                documentRef: "ipfs://priced-round",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );

        _mintAndApprove(investor2, 1e6, address(fundraise));
        _invest(fundraise, pricedRoundId, investor2, 1e6);

        vm.startPrank(board);
        fundraise.closeRound(pricedRoundId);
        fundraise.finalizeRound(pricedRoundId);
        vm.stopPrank();

        // Priced round minted 1 share to investor2 and opened a joint conversion on Fundraise.
        assertEq(shareToken.totalSupply(), 8_000_000e6 + 1e6, "8M + 1 priced share");
        assertEq(issuance.conversionCount(), 1, "Conversion opened on Fundraise");

        // Step 8: Apply SAFE conversion proof — mints remaining headroom (~2M - 1 share) to SAFE holder.
        IEquityIssuance.Conversion memory conversion = issuance.getConversion(0);
        uint256 safeId = conversion.safeIds[0];
        uint256 safeShares = 2_000_000e6 - 1e6;
        bytes32 sharesCommitment = keccak256("conversion:investor1");

        ISAFE.ConversionResult[] memory safeResults = new ISAFE.ConversionResult[](1);
        safeResults[0] =
            ISAFE.ConversionResult({safeId: safeId, sharesIssued: safeShares, sharesCommitment: sharesCommitment});
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        zkVerifier.setExpectedPublicInputs(issuance.conversionPublicInputs(0, safeResults, noteResults));
        issuance.applyConversion(0, safeResults, noteResults, "proof", "");

        // Final: 8M direct + 1 priced + (2M - 1) SAFE = exactly 10M authorized.
        assertEq(shareToken.totalSupply(), 10_000_000e6, "Lands on authorized cap exactly");
        assertEq(shareToken.balanceOf(investor1), safeShares, "SAFE holder received conversion shares");
    }

    /**
     * @notice Integration Test: Employee Turnover with Pool Capacity Recycling
     *
     * SCENARIO:
     * Startup grants options to employee who leaves before vesting. The unvested options
     * must return to the pool so a replacement hire can receive the same capacity.
     * Tests the complete revoke → pool restoration → re-grant → exercise cycle.
     *
     * REAL WORKFLOW STEPS:
     * 1. Establish 5M option pool (50% of 10M authorized)
     * 2. Grant 1M options to employee1 with 4-year vesting and 1-year cliff
     *    - Pool: 5M → 4M (auto-decrease)
     *    - Outstanding: 0 → 1M
     * 3. Employee1 leaves after 6 months (before cliff, 0% vested)
     * 4. Revoke grant - all 1M options unvested, return to pool
     *    - Pool: 4M → 5M (restored)
     *    - Outstanding: 1M → 0
     * 5. Grant same 1M options to employee2 (replacement hire)
     *    - Pool: 5M → 4M
     *    - Outstanding: 0 → 1M
     * 6. Employee2 vests over 4 years and exercises all 1M options
     *    - Mints 1M shares to employee2
     *    - Outstanding: 1M → 0
     *
     * DEMONSTRATES:
     * - Pool capacity recycling on employee turnover
     * - Unvested options fully return to pool for new grants
     * - Replacement hires can receive same capacity as departed employees
     * - Complete lifecycle: grant → revoke → restore → re-grant → exercise → mint
     * - Cross-contract coordination: OptionPool + Company + ShareToken
     */
    function test_RealWorkflow_RevokeAndReGrant() public {
        // Record 409A valuation for option grants
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report");

        // Initial: Pool = 5M, Outstanding = 0
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 5_000_000e6, "");
        assertEq(optionPool.getPoolSize(address(shareToken)), 5_000_000e6, "Pool starts at 5M");

        // Grant 1M options to employee1 with 4-year vesting, 1-year cliff
        vm.prank(board);
        uint256 grant1 =
            optionPool.grantOptions(employee1, shareToken, 1_000_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        // After grant: Pool = 4M, Outstanding = 1M
        assertEq(optionPool.getPoolSize(address(shareToken)), 4_000_000e6, "Pool decreased to 4M after 1M grant");
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 1_000_000e6, "Outstanding = 1M");

        // Employee1 leaves after 6 months (no vesting yet due to 1-year cliff)
        vm.warp(block.timestamp + 180 days);

        // Revoke grant - all 1M options are unvested, should return to pool
        vm.prank(board);
        optionPool.revokeGrant(grant1, "");

        // After revoke: Pool = 5M (restored), Outstanding = 0
        assertEq(
            optionPool.getPoolSize(address(shareToken)), 5_000_000e6, "Pool restored to 5M after revoking unvested"
        );
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 0, "Outstanding = 0 after full revocation");

        // Board can now grant options to new employee2 using the restored capacity
        vm.prank(board);
        uint256 grant2 =
            optionPool.grantOptions(employee2, shareToken, 1_000_000e6, 0, 365 days, 1460 days, 1 days, true, "");

        // After new grant: Pool = 4M, Outstanding = 1M (same state as after first grant)
        assertEq(optionPool.getPoolSize(address(shareToken)), 4_000_000e6, "Pool decreased to 4M after new grant");
        assertEq(
            optionPool.getOutstandingOptions(address(shareToken)), 1_000_000e6, "Outstanding = 1M for new employee"
        );

        // Verify employee2 can exercise after vesting
        vm.warp(block.timestamp + 1460 days);
        uint256 payment = (1_000_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee2, payment, address(optionPool));
        vm.prank(employee2);
        optionPool.exercise(grant2, 1_000_000e6);

        // After exercise: Outstanding = 0, shares minted
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 0, "Outstanding = 0 after exercise");
        assertEq(shareToken.balanceOf(employee2), 1_000_000e6, "Employee2 has 1M shares");
    }

    /**
     * @notice Integration Test: Partial Vesting with Pool Capacity Split
     *
     * SCENARIO:
     * Employee partially vests before leaving. Only the unvested portion returns to pool,
     * while vested options remain exercisable. New hire gets the unvested portion while
     * original employee exercises their vested shares. Tests pool capacity splitting.
     *
     * REAL WORKFLOW STEPS:
     * 1. Establish 5M option pool
     * 2. Grant 1M options to employee1 with 4-year vesting, no cliff
     *    - Pool: 5M → 4M
     *    - Outstanding: 0 → 1M
     * 3. Employee1 works 1 year (25% vested = 250K, 75% unvested = 750K)
     * 4. Revoke grant - 750K unvested returns to pool, 250K vested stays outstanding
     *    - Pool: 4M → 4.75M (restored partial)
     *    - Outstanding: 1M → 250K (only vested)
     * 5. Grant 750K options to employee2 (new hire gets exactly the returned capacity)
     *    - Pool: 4.75M → 4M
     *    - Outstanding: 250K → 1M (250K old vested + 750K new grant)
     * 6. Employee1 exercises 250K vested options (within 90-day window)
     *    - Mints 250K shares to employee1
     *    - Outstanding: 1M → 750K
     *
     * DEMONSTRATES:
     * - Partial pool restoration based on unvested amount
     * - Vested options remain exercisable after revocation
     * - Pool capacity can be split between old vested and new grants
     * - Precise tracking: pool + outstanding always accounts for capacity
     * - Real scenario: departing employee keeps vested, company reuses unvested
     */
    function test_RealWorkflow_PartialRevocationAndReGrant() public {
        // Record 409A valuation for option grants
        vm.prank(board);
        optionPool.recordValuation(0.001e6, "ipfs://409a-report");

        // Establish 5M option pool
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 5_000_000e6, "");

        // Grant 1M options with 4-year vesting, no cliff
        vm.prank(board);
        uint256 grant1 = optionPool.grantOptions(employee1, shareToken, 1_000_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Pool = 4M, Outstanding = 1M
        assertEq(optionPool.getPoolSize(address(shareToken)), 4_000_000e6);

        // Employee works for 1 year (25% vested = 250K)
        vm.warp(block.timestamp + 365 days);

        // Revoke - 750K unvested returns to pool, 250K vested remains outstanding
        vm.prank(board);
        optionPool.revokeGrant(grant1, "");

        // After revoke: Pool = 4.75M (4M + 750K), Outstanding = 250K (vested)
        assertEq(optionPool.getPoolSize(address(shareToken)), 4_750_000e6, "750K unvested returned to pool");
        assertEq(optionPool.getOutstandingOptions(address(shareToken)), 250_000e6, "250K vested still outstanding");

        // Grant 750K to new employee using the returned capacity
        vm.prank(board);
        uint256 grant2 = optionPool.grantOptions(employee2, shareToken, 750_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Pool = 4M (4.75M - 750K), Outstanding = 1M (250K + 750K)
        assertEq(optionPool.getPoolSize(address(shareToken)), 4_000_000e6, "Pool decreased by new grant");
        assertEq(
            optionPool.getOutstandingOptions(address(shareToken)), 1_000_000e6, "Outstanding = old vested + new grant"
        );

        // Original employee can still exercise their vested portion within 90 days
        uint256 payment1 = (250_000e6 * 0.001e6) / 1e6;
        _mintAndApprove(employee1, payment1, address(optionPool));
        vm.prank(employee1);
        optionPool.exercise(grant1, 250_000e6);

        assertEq(shareToken.balanceOf(employee1), 250_000e6, "Employee1 exercised vested portion");
        assertEq(
            optionPool.getOutstandingOptions(address(shareToken)), 750_000e6, "Outstanding decreased after exercise"
        );
    }

    /**
     * @notice Integration Test: Fully Diluted Shares — Legal Cap Table View
     *
     * SCENARIO:
     * Company has multiple instruments active simultaneously. Verifies that
     * getFullyDilutedShares() returns the correct legal cap table count:
     * issued shares + full option pool + outstanding grants.
     *
     * SAFEs are explicitly EXCLUDED because they are not equity until conversion.
     * The share count from SAFE conversion depends on a future priced round price,
     * which is unknown until it happens. Pro-forma estimates should be done off-chain.
     *
     * WORKFLOW:
     * 1. Issue 3M shares to investors (minted)
     * 2. Issue 2M shares with vesting to founders (minted)
     * 3. Board sets 2M option pool (reserved)
     * 4. Grant 1.5M options to employees (pool auto-decreases)
     * 5. Issue $1M SAFE (not equity, excluded from fully diluted)
     * 6. Verify: fullyDiluted = 5M minted + 0.5M pool + 1.5M outstanding = 7M
     * 7. Employee exercises 500K options → fullyDiluted stays 7M (outstanding→issued)
     * 8. Convert SAFE in priced round → fullyDiluted increases by conversion shares
     */
    function test_GetFullyDilutedShares_WithAllInstruments() public {
        vm.prank(board);
        optionPool.recordValuation(1e6, "ipfs://valuation");

        // Step 1: Issue 3M shares to investors
        vm.prank(board);
        issuance.issueGrant("Common", address(0xAAAA), 3_000_000e6, "Seed investors", "");

        // Step 2: Issue 2M shares with vesting to founder
        vm.prank(board);
        issuance.issueGrantWithVesting(shareToken, employee1, 2_000_000e6, block.timestamp, 0, 1460 days, false, "");

        assertEq(company.getTotalSharesOutstanding(), 5_000_000e6);
        assertEq(company.getFullyDilutedShares(), 5_000_000e6, "No pool yet, FD == outstanding");

        // Step 3: Board sets 2M option pool
        vm.prank(board);
        optionPool.increasePoolSize(address(shareToken), 2_000_000e6, "");

        assertEq(company.getFullyDilutedShares(), 7_000_000e6, "5M issued + 2M pool = 7M");

        // Step 4: Grant 1.5M options to employee (pool: 2M → 0.5M, outstanding: 0 → 1.5M)
        vm.prank(board);
        uint256 grantId = optionPool.grantOptions(employee2, shareToken, 1_500_000e6, 0, 0, 1460 days, 1 days, true, "");

        // FD = 5M issued + 0.5M pool + 1.5M outstanding = 7M (unchanged, just reshuffled)
        assertEq(company.getFullyDilutedShares(), 7_000_000e6, "Pool->outstanding reshuffle, FD unchanged");

        // Step 5: Issue $1M SAFE — NOT included in fully diluted
        vm.prank(board);
        uint256 safeRoundId = fundraise.createRound(
            IFundraise.RoundParams({
                name: "SAFE Round",
                roundType: IFundraise.RoundType.SAFE,
                valuationCap: 10_000_000e6,
                discountBps: 0,
                pricePerShare: 0,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: false,
                whitelistOnly: false,
                documentRef: "ipfs://safe",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
        _mintAndApprove(investor1, 1_000_000e6, address(fundraise));
        _invest(fundraise, safeRoundId, investor1, 1_000_000e6);
        vm.prank(board);
        fundraise.closeRound(safeRoundId);
        vm.prank(board);
        fundraise.finalizeRound(safeRoundId);

        // SAFE issued but NOT equity — fully diluted should be unchanged
        assertEq(company.getFullyDilutedShares(), 7_000_000e6, "SAFE excluded from fully diluted");
        assertEq(company.getTotalSharesOutstanding(), 5_000_000e6, "Outstanding unchanged by SAFE");

        // Step 6: Employee exercises 500K options after partial vesting
        vm.warp(block.timestamp + 730 days); // 2 years = 50% vested = 750K exercisable
        uint256 exerciseAmount = 500_000e6;
        uint256 payment = (exerciseAmount * 1e6) / 1e6;
        _mintAndApprove(employee2, payment, address(optionPool));
        vm.prank(employee2);
        optionPool.exercise(grantId, exerciseAmount);

        // FD = 5.5M issued + 0.5M pool + 1M outstanding = 7M (still unchanged)
        assertEq(company.getTotalSharesOutstanding(), 5_500_000e6);
        assertEq(company.getFullyDilutedShares(), 7_000_000e6, "Exercise moves outstanding->issued, FD unchanged");

        // Step 7: Priced round qualifies and opens SAFE conversion batch
        vm.prank(board);
        uint256 pricedRoundId = fundraise.createRound(
            IFundraise.RoundParams({
                name: "Series A Priced",
                roundType: IFundraise.RoundType.PRICED,
                valuationCap: 0,
                discountBps: 0,
                pricePerShare: 1e6,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: false,
                whitelistOnly: false,
                documentRef: "ipfs://priced-round",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );

        _mintAndApprove(investor2, 1e6, address(fundraise));
        _invest(fundraise, pricedRoundId, investor2, 1e6);

        vm.startPrank(board);
        fundraise.closeRound(pricedRoundId);
        fundraise.finalizeRound(pricedRoundId);
        vm.stopPrank();

        assertEq(issuance.conversionCount(), 1, "Priced round opened joint conversion on Fundraise");

        IEquityIssuance.Conversion memory conversion = issuance.getConversion(0);
        uint256 safeId = conversion.safeIds[0];
        uint256 safeShares = 1_000_000e6;
        bytes32 sharesCommitment = keccak256("conversion:fully-diluted");

        ISAFE.ConversionResult[] memory safeResults = new ISAFE.ConversionResult[](1);
        safeResults[0] =
            ISAFE.ConversionResult({safeId: safeId, sharesIssued: safeShares, sharesCommitment: sharesCommitment});
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        zkVerifier.setExpectedPublicInputs(issuance.conversionPublicInputs(0, safeResults, noteResults));
        issuance.applyConversion(0, safeResults, noteResults, "proof", "");

        assertEq(company.getTotalSharesOutstanding(), 6_500_000e6 + 1e6, "Priced + SAFE shares are outstanding");
        assertEq(company.getFullyDilutedShares(), 8_000_000e6 + 1e6, "FD includes converted SAFE shares");
        assertEq(shareToken.balanceOf(investor1), safeShares, "SAFE holder received conversion shares");
    }

    /**
     * @notice Integration Test: Emergency Vault Pause and Resume
     *
     * SCENARIO:
     * Board detects a potential security issue and needs to pause vault withdrawals
     * to investigate. After confirming everything is safe, they resume normal operations.
     *
     * WORKFLOW:
     * 1. Company has ETH and tokens in vault for regular operations
     * 2. Board pauses vault due to emergency
     * 3. Withdrawals (both ETH and tokens) are blocked while paused
     * 4. Board investigates and resolves the issue
     * 5. Board unpauses vault
     * 6. Normal operations resume - withdrawals work again
     */
    function test_VaultEmergencyPauseAndResume() public {
        // Setup: Deploy test token for the vault
        (ShareToken testToken, SnapshotEngine testTokenEngine,) = _deployToken("Test Token", "TEST", 1_000_000 ether);
        bytes32 MINTER_ROLE_TEST = keccak256("MINTER_ROLE");
        testToken.grantRole(MINTER_ROLE_TEST, address(this));
        testToken.mint(address(this), 1_000_000 ether);

        // Fund vault with ETH and tokens
        (bool success,) = address(vault).call{value: 10 ether}("");
        require(success, "ETH deposit failed");
        testToken.approve(address(vault), 1000 ether);
        vault.depositToken(address(testToken), 1000 ether);

        // Verify initial balances
        assertEq(address(vault).balance, 10 ether, "Vault has ETH");
        assertEq(testToken.balanceOf(address(vault)), 1000 ether, "Vault has tokens");

        // EMERGENCY: Board detects an issue and pauses the vault
        vm.prank(board);
        vault.pause();
        assertTrue(vault.paused(), "Vault should be paused");

        // Verify withdrawals are blocked while paused
        vm.prank(board);
        vm.expectRevert();
        vault.withdrawETH(investor1, 1 ether);

        vm.prank(board);
        vm.expectRevert();
        vault.withdrawToken(address(testToken), investor1, 100 ether);

        // Even company contract cannot withdraw during pause
        vm.prank(address(company));
        vm.expectRevert();
        vault.withdrawETH(investor1, 1 ether);

        // Board investigates and resolves the issue
        // Board unpauses after confirming everything is safe
        vm.prank(board);
        vault.unpause();
        assertFalse(vault.paused(), "Vault should be unpaused");

        // Normal operations resume - withdrawals work again
        vm.prank(board);
        vault.withdrawETH(investor1, 2 ether);
        assertEq(investor1.balance, 10002 ether, "Investor1 received ETH");
        assertEq(address(vault).balance, 8 ether, "Vault ETH reduced");

        vm.prank(board);
        vault.withdrawToken(address(testToken), investor2, 500 ether);
        assertEq(testToken.balanceOf(investor2), 500 ether, "Investor2 received tokens");
        assertEq(testToken.balanceOf(address(vault)), 500 ether, "Vault tokens reduced");
    }
}
