// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import "../../src/mixins/CompanyStorage.sol";
import "../../src/mixins/CompanyDividends.sol";
import "../../src/Vault.sol";

/// @title CompanyDividendsTest
/// @notice Comprehensive tests for dividend declaration and distribution
contract CompanyDividendsTest is BaseTest {
    address shareholder1 = address(0xA1);
    address shareholder2 = address(0xA2);
    address shareholder3 = address(0xA3);

    function setUp() public {
        _baseSetUp();
        _setupCompany();

        vm.startPrank(board);
        issuance.issueGrant("Common", shareholder1, 100000, "allocation 1", "");
        issuance.issueGrant("Common", shareholder2, 50000, "allocation 2", "");
        issuance.issueGrant("Common", shareholder3, 50000, "allocation 3", "");
        vm.stopPrank();

        _fundMUSD(address(vault), 100e6);
    }

    // ===================
    // Declaration Tests
    // ===================

    function test_DeclareDividendSuccess() public {
        uint256 totalAmount = 10e6;
        uint256 paymentDate = block.timestamp + 7 days;

        vm.expectEmit(true, false, false, false);
        emit CompanyDividends.DividendDeclared(1, totalAmount, 200000, block.timestamp, paymentDate, "");

        vm.prank(board);
        uint256 dividendId = company.declareDividend(totalAmount, paymentDate, "");

        assertEq(dividendId, 1);
        assertEq(company.dividendCount(), 1);

        // Check dividend details
        (uint256 amount, uint256 recDate, uint256 payDate, bool distributed) = company.dividends(dividendId);
        assertEq(amount, totalAmount);
        assertEq(recDate, block.timestamp);
        assertEq(payDate, paymentDate);
        assertFalse(distributed);
    }

    function test_DeclareDividendRevertsWhenNotBoard() public {
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.declareDividend(10e6, block.timestamp + 7 days, "");
    }

    function test_DeclareDividendRevertsWithZeroAmount() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAmount.selector);
        company.declareDividend(0, block.timestamp + 7 days, "");
    }

    function test_DeclareDividendRevertsWhenPaymentDateInPast() public {
        vm.warp(block.timestamp + 10 days);

        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidInput.selector);
        company.declareDividend(10e6, block.timestamp - 1 days, "");
    }

    function test_DeclareDividendRevertsWhenPaymentDateEqualsNow() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidInput.selector);
        company.declareDividend(10e6, block.timestamp, "");
    }

    function test_DeclareMultipleDividends() public {
        vm.prank(board);
        uint256 div1 = company.declareDividend(5e6, vm.getBlockTimestamp() + 7 days, "");
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(board);
        uint256 div2 = company.declareDividend(10e6, vm.getBlockTimestamp() + 14 days, "");
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(board);
        uint256 div3 = company.declareDividend(15e6, vm.getBlockTimestamp() + 21 days, "");

        assertEq(div1, 1);
        assertEq(div2, 2);
        assertEq(div3, 3);
        assertEq(company.dividendCount(), 3);
    }

    function test_DeclareDividendRevertsInSameBlockAsPrevious() public {
        vm.prank(board);
        company.declareDividend(5e6, block.timestamp + 7 days, "");

        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.declareDividend(5e6, block.timestamp + 14 days, "");

        vm.warp(block.timestamp + 1);
        vm.prank(board);
        company.declareDividend(5e6, block.timestamp + 14 days, "");
    }

    // ===================
    // Distribution Tests
    // ===================

    function test_DistributeDividendsSuccess() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        vm.warp(block.timestamp + 2);

        uint256 sh1BalanceBefore = musd.balanceOf(shareholder1);
        uint256 sh2BalanceBefore = musd.balanceOf(shareholder2);
        uint256 sh3BalanceBefore = musd.balanceOf(shareholder3);
        uint256 vaultBalanceBefore = musd.balanceOf(address(vault));

        _distributeDividend(company, dividendId);

        // shareholder1 has 100k/200k shares = 50% = 5 MUSD
        // shareholder2 has 50k/200k shares = 25% = 2.5 MUSD
        // shareholder3 has 50k/200k shares = 25% = 2.5 MUSD
        assertEq(musd.balanceOf(shareholder1), sh1BalanceBefore + 5e6);
        assertEq(musd.balanceOf(shareholder2), sh2BalanceBefore + 2.5e6);
        assertEq(musd.balanceOf(shareholder3), sh3BalanceBefore + 2.5e6);
        assertEq(musd.balanceOf(address(vault)), vaultBalanceBefore - 10e6);

        (,,, bool distributed) = company.dividends(dividendId);
        assertTrue(distributed);
    }

    function test_DistributeBatch_Validations() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 7 days, "");

        // Not board
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.distributeDividendBatch(dividendId, 10);

        // Unknown id
        vm.prank(board);
        vm.expectRevert(CompanyStorage.NotFound.selector);
        company.distributeDividendBatch(999, 10);

        // Count = 0
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidInput.selector);
        company.distributeDividendBatch(dividendId, 0);

        // Count > MAX
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidInput.selector);
        company.distributeDividendBatch(dividendId, 101);

        // Before payment date
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.distributeDividendBatch(dividendId, 10);

        // Already distributed
        vm.warp(block.timestamp + 8 days);
        _distributeDividend(company, dividendId);
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.distributeDividendBatch(dividendId, 10);
    }

    function test_DeclareDividendRevertsWithInsufficientVaultBalance() public {
        // Drain MUSD from vault so declaration fails
        vm.prank(board);
        vault.withdrawToken(address(musd), board, 100e6);

        // Declaration should now fail (vault balance check happens upfront in declareDividend)
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InsufficientCapacity.selector);
        company.declareDividend(10e6, block.timestamp + 1, "");
    }

    /// @dev Vault has enough gross balance but not enough UNRESERVED balance (another dividend
    ///      already holds the rest). The early check must reject before doing snapshot + queue
    ///      work, matching Vault.reserveDividend's rule.
    function test_DeclareDividendRevertsWhenBalanceIsReservedByAnother() public {
        // Vault has 100 MUSD. First dividend reserves 95 MUSD, leaving 5 available.
        vm.prank(board);
        company.declareDividend(95e6, block.timestamp + 1 days, "");
        assertEq(vault.availableBalance(), 5e6);
        vm.warp(block.timestamp + 1); // next block for second declare

        // Attempt to declare another 10 MUSD dividend — gross balance >=10, but unreserved is 5.
        // Early check must revert before snapshot/queue work.
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InsufficientCapacity.selector);
        company.declareDividend(10e6, block.timestamp + 1 days, "");
    }

    // ===================
    // Calculation Tests
    // ===================

    function test_CalculateDividendAmountForNonShareholder() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        uint256 amount = company.calculateDividendAmount(dividendId, address(0xDEAD));
        assertEq(amount, 0);
    }

    function test_CalculateDividendAmount_ReflectsManualExclusion() public {
        vm.prank(board);
        company.setDividendExclusion(shareholder1, true);

        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");
        vm.warp(block.timestamp + 2);

        assertEq(company.calculateDividendAmount(dividendId, shareholder1), 0);
        assertEq(company.calculateDividendAmount(dividendId, shareholder2), 5e6);
        assertEq(company.calculateDividendAmount(dividendId, shareholder3), 5e6);

        // Quote must match the actual payout
        uint256 q2 = company.calculateDividendAmount(dividendId, shareholder2);
        uint256 q3 = company.calculateDividendAmount(dividendId, shareholder3);
        vm.prank(board);
        company.distributeDividendBatch(dividendId, 100);
        assertEq(musd.balanceOf(shareholder2), q2);
        assertEq(musd.balanceOf(shareholder3), q3);
    }

    // ===================
    // Multi-Class Dividend Tests
    // ===================

    function test_DividendsWithMultipleShareClasses() public {
        vm.deal(board, 1 ether);
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred", "Test Preferred", "TCS-P", 100000, 1e6, 1, 0, ""
        );

        // Issue preferred shares
        vm.prank(board);
        issuance.issueGrant("Preferred", shareholder1, 100000, "preferred allocation", "");

        // Now shareholder1 has 100k common + 100k preferred = 200k total shares
        // shareholder2 has 50k common
        // shareholder3 has 50k common
        // Total: 300k shares

        vm.prank(board);
        uint256 dividendId = company.declareDividend(30e6, block.timestamp + 1, "");

        // Verify total shares calculation includes both classes
        uint256 totalShares = company.dividendTotalShares(dividendId);
        assertEq(totalShares, 300000);

        // shareholder1 should get 200k/300k = 66.67% = 20 MUSD
        uint256 amount1 = company.calculateDividendAmount(dividendId, shareholder1);
        assertApproxEqAbs(amount1, 20e6, 0.01e6);

        // shareholder2 should get 50k/300k = 16.67% = 5 MUSD
        uint256 amount2 = company.calculateDividendAmount(dividendId, shareholder2);
        assertApproxEqAbs(amount2, 5e6, 0.01e6);
    }

    function test_DividendWithZeroSupplyShareClass() public {
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}("Empty", "Empty Class", "EMP", 100000, 1e6, 1, 0, "");

        // Declare dividend - should succeed despite Empty class having 0 supply
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        assertEq(dividendId, 1);

        vm.warp(block.timestamp + 2);

        uint256 sh1BalanceBefore = musd.balanceOf(shareholder1);
        _distributeDividend(company, dividendId);

        // shareholder1 has 100k/200k = 50% = 5 MUSD
        assertEq(musd.balanceOf(shareholder1), sh1BalanceBefore + 5e6);
    }

    function test_DividendRevertsWhenAllClassesHaveZeroSupply() public {
        // Create a fresh company with NO shares issued to anyone
        _baseSetUp();
        (Company emptyCompany,,,,,,,) = _deployCompany("Empty Company", "EMPTY", "ipfs://metadata");

        // Create multiple share classes but don't issue any shares
        vm.deal(board, 1 ether);
        vm.startPrank(board);
        emptyCompany.createShareClassWithToken{value: 0.05 ether}(
            "Common", "Common Shares", "COM", 1000000, 1e6, 1, 0, ""
        );
        emptyCompany.createShareClassWithToken{value: 0.05 ether}(
            "Preferred", "Preferred Shares", "PREF", 500000, 1e6, 1, 0, ""
        );
        vm.stopPrank();

        // Attempt to declare dividend when all classes have 0 supply
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InsufficientCapacity.selector);
        emptyCompany.declareDividend(10e6, block.timestamp + 1, "");
    }

    // ===================
    // Integration Tests
    // ===================

    function test_MultipleSequentialDividends() public {
        // Start at a reasonable timestamp to avoid edge cases
        vm.warp(1000 days);

        // Declare and distribute first dividend
        vm.prank(board);
        uint256 div1 = company.declareDividend(10e6, block.timestamp + 1 days, "");

        vm.warp(block.timestamp + 2 days);

        _distributeDividend(company, div1);

        // Issue more shares to shareholder1
        vm.prank(board);
        issuance.issueGrant("Common", shareholder1, 100000, "additional allocation", "");

        // Now shareholder1 has 200k, shareholder2 has 50k, shareholder3 has 50k (300k total)

        // Declare second dividend
        vm.prank(board);
        uint256 div2 = company.declareDividend(15e6, block.timestamp + 1, "");

        vm.warp(block.timestamp + 2);

        uint256 sh1BalanceBefore = musd.balanceOf(shareholder1);

        _distributeDividend(company, div2);

        // shareholder1 should now get 200k/300k = 66.67% of 15 MUSD = 10 MUSD
        assertEq(musd.balanceOf(shareholder1), sh1BalanceBefore + 10e6);
    }

    // ===================
    // Edge Cases
    // ===================

    // ===================
    // Dividend Exclusion Tests
    // ===================

    function test_SetDividendExclusion() public {
        address testAddress = address(0x999);

        // Set exclusion
        vm.prank(board);
        company.setDividendExclusion(testAddress, true);

        assertTrue(company.excludedFromDividends(testAddress));

        // Unset exclusion
        vm.prank(board);
        company.setDividendExclusion(testAddress, false);

        assertFalse(company.excludedFromDividends(testAddress));
    }

    function test_SetDividendExclusionOnlyBoard() public {
        address testAddress = address(0x999);

        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.setDividendExclusion(testAddress, true);
    }

    function test_SetDividendExclusionRevertsZeroAddress() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        company.setDividendExclusion(address(0), true);
    }

    function test_DividendAutoExcludesExcludedAddresses() public {
        vm.prank(board);
        company.setDividendExclusion(shareholder1, true);

        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        vm.warp(block.timestamp + 2);

        uint256 sh2Before = musd.balanceOf(shareholder2);
        uint256 sh3Before = musd.balanceOf(shareholder3);

        _distributeDividend(company, dividendId);

        assertEq(musd.balanceOf(shareholder1), 0);
        assertEq(musd.balanceOf(shareholder2), sh2Before + 5e6);
        assertEq(musd.balanceOf(shareholder3), sh3Before + 5e6);
    }

    function test_CannotManuallySetVaultExclusion() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.VaultAlwaysExcluded.selector);
        company.setDividendExclusion(address(vault), true);

        // Also can't try to "include" it
        vm.prank(board);
        vm.expectRevert(CompanyStorage.VaultAlwaysExcluded.selector);
        company.setDividendExclusion(address(vault), false);
    }

    function test_CalculateAndDistributeMatchWithExcludedShares() public {
        // Issue 100k shares to vault (treasury) - total: 200k shareholders + 100k vault = 300k
        vm.prank(board);
        issuance.issueGrant("Common", address(vault), 100000, "treasury stock", "");

        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        // calculateDividendAmount should exclude vault shares (use 200k, not 300k)
        uint256 calculated1 = company.calculateDividendAmount(dividendId, shareholder1);
        uint256 calculated2 = company.calculateDividendAmount(dividendId, shareholder2);
        uint256 calculated3 = company.calculateDividendAmount(dividendId, shareholder3);

        // sh1: 100k/200k = 50% = 5 MUSD
        // sh2: 50k/200k = 25% = 2.5 MUSD
        // sh3: 50k/200k = 25% = 2.5 MUSD
        assertEq(calculated1, 5e6, "calculateDividendAmount should exclude vault for sh1");
        assertEq(calculated2, 2.5e6, "calculateDividendAmount should exclude vault for sh2");
        assertEq(calculated3, 2.5e6, "calculateDividendAmount should exclude vault for sh3");

        // Now distribute and verify amounts match
        vm.warp(block.timestamp + 2);

        uint256 sh1Before = musd.balanceOf(shareholder1);
        uint256 sh2Before = musd.balanceOf(shareholder2);
        uint256 sh3Before = musd.balanceOf(shareholder3);

        _distributeDividend(company, dividendId);

        // Distributed amounts should match calculated amounts
        assertEq(musd.balanceOf(shareholder1) - sh1Before, calculated1, "distribute should match calculate for sh1");
        assertEq(musd.balanceOf(shareholder2) - sh2Before, calculated2, "distribute should match calculate for sh2");
        assertEq(musd.balanceOf(shareholder3) - sh3Before, calculated3, "distribute should match calculate for sh3");
    }

    function test_DividendExcludesBothVaultAndVesting() public {
        vm.startPrank(board);
        issuance.issueGrant("Common", address(vault), 100000, "treasury", "");
        issuance.issueGrant("Common", address(vestingSchedule), 150000, "vesting", "");
        vm.stopPrank();

        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        vm.warp(block.timestamp + 2);

        uint256 sh1Before = musd.balanceOf(shareholder1);

        _distributeDividend(company, dividendId);

        assertEq(musd.balanceOf(shareholder1), sh1Before + 5e6);
    }

    function test_DividendIgnoresShareClassCreatedAfterDeclaration() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        vm.deal(board, 1 ether);
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred", "Preferred Shares", "PREF", 100000, 1e6, 1, 0, ""
        );

        address shareholder4 = address(0xA4);
        vm.prank(board);
        issuance.issueGrant("Preferred", shareholder4, 100000, "new class", "");

        vm.warp(block.timestamp + 2);

        uint256 sh1Before = musd.balanceOf(shareholder1);
        uint256 sh4Before = musd.balanceOf(shareholder4);

        _distributeDividend(company, dividendId);

        assertEq(musd.balanceOf(shareholder1), sh1Before + 5e6);
        assertEq(musd.balanceOf(shareholder4), sh4Before);
    }

    function test_DividendUsesRecordDateNotCurrentHoldings() public {
        // Holdings: sh1=100k, sh2=50k, sh3=50k (200k total)
        // 1. Declare dividend NOW — createInstantSnapshot freezes balances
        uint256 paymentDate = block.timestamp + 7 days;
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, paymentDate, "");

        // 2. Transfer shares AFTER record date — sh4 gets 50k from sh1
        address shareholder4 = address(0xA4);
        vm.prank(shareholder1);
        assertTrue(shareToken.transfer(shareholder4, 50000));

        // 3. Distribute at payment date
        vm.warp(paymentDate + 1);
        uint256 sh1Before = musd.balanceOf(shareholder1);
        uint256 sh2Before = musd.balanceOf(shareholder2);
        uint256 sh3Before = musd.balanceOf(shareholder3);
        uint256 sh4Before = musd.balanceOf(shareholder4);

        _distributeDividend(company, dividendId);

        // 4. Payouts use record-date balances, not current
        assertEq(musd.balanceOf(shareholder1), sh1Before + 5e6, "sh1 had 100k at record date = 50%");
        assertEq(musd.balanceOf(shareholder2), sh2Before + 2.5e6, "sh2 had 50k at record date = 25%");
        assertEq(musd.balanceOf(shareholder3), sh3Before + 2.5e6, "sh3 had 50k at record date = 25%");
        assertEq(musd.balanceOf(shareholder4), sh4Before, "sh4 had 0 shares at record date");
    }

    // ===================
    // Pull Pattern Tests
    // Note: With standard ERC20, transfers to contracts always succeed (unlike ETH).
    // The pull pattern is relevant for tokens with blacklists (e.g. USDC/USDT).
    // These tests verify correct behavior when all ERC20 transfers succeed,
    // including transfers to contract addresses.
    // ===================

    function test_DividendPaysContractShareholdersSuccessfully() public {
        // Deploy a contract that holds shares — ERC20 transfers to it always succeed
        DummyShareHolder contractHolder = new DummyShareHolder();

        vm.prank(board);
        issuance.issueGrant("Common", address(contractHolder), 100000, "contract holder", "");

        // Now we have: sh1=100k, sh2=50k, sh3=50k, contractHolder=100k (total 300k)
        uint256 paymentDate = block.timestamp + 1;

        vm.prank(board);
        uint256 dividendId = company.declareDividend(9e6, paymentDate, "");

        vm.warp(paymentDate + 1);

        uint256 sh1Before = musd.balanceOf(shareholder1);

        // Distribute — all payments should succeed including to contract
        _distributeDividend(company, dividendId);

        // sh1: 100k/300k = 33.33% = 3 MUSD
        assertEq(musd.balanceOf(shareholder1), sh1Before + 3e6, "sh1 should receive dividend");
        // contractHolder: 100k/300k = 33.33% = 3 MUSD
        assertEq(musd.balanceOf(address(contractHolder)), 3e6, "contract should receive ERC20 dividend");
        // No pending dividends since ERC20 transfers succeed
        assertEq(company.pendingDividends(address(contractHolder)), 0, "no pending for successful ERC20 transfer");
    }

    function test_ClaimDividend_RevertsWhenNoPending() public {
        vm.prank(shareholder1);
        vm.expectRevert(); // NoPendingDividend
        company.claimDividend();
    }

    function test_DividendDistributesToMultipleContractHolders() public {
        // Deploy two contract holders
        DummyShareHolder holder1 = new DummyShareHolder();
        DummyShareHolder holder2 = new DummyShareHolder();

        vm.startPrank(board);
        issuance.issueGrant("Common", address(holder1), 50000, "holder1", "");
        issuance.issueGrant("Common", address(holder2), 50000, "holder2", "");
        vm.stopPrank();

        // Total: sh1=100k, sh2=50k, sh3=50k, h1=50k, h2=50k = 300k
        uint256 paymentDate = block.timestamp + 1;

        vm.prank(board);
        uint256 dividendId = company.declareDividend(6e6, paymentDate, "");

        vm.warp(paymentDate + 1);

        uint256 sh1Before = musd.balanceOf(shareholder1);

        _distributeDividend(company, dividendId);

        // All shareholders received their dividends
        assertEq(musd.balanceOf(shareholder1), sh1Before + 2e6, "sh1 should receive 100k/300k * 6 = 2 MUSD");
        assertEq(musd.balanceOf(address(holder1)), 1e6, "holder1 should receive 50k/300k * 6 = 1 MUSD");
        assertEq(musd.balanceOf(address(holder2)), 1e6, "holder2 should receive 50k/300k * 6 = 1 MUSD");
    }

    /// @dev Known limitation of the current design: the registry compacts on zero-balance
    function test_DividendPaysHolderWhoSoldAfterDeclare() public {
        uint256 paymentDate = block.timestamp + 7 days;
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, paymentDate, "");

        // After declare, sh1 sells all shares. Registry compacts them out, but the queue
        // already holds sh1 from the declare-time enumeration.
        vm.prank(shareholder1);
        assertTrue(shareToken.transfer(shareholder2, 100000));

        vm.warp(paymentDate + 1);
        _distributeDividend(company, dividendId);

        // Record-date balances: sh1=100k, sh2=50k, sh3=50k (total 200k)
        assertEq(musd.balanceOf(shareholder1), 5e6, "sh1 still paid from record-date snapshot");
        assertEq(musd.balanceOf(shareholder2), 2.5e6);
        assertEq(musd.balanceOf(shareholder3), 2.5e6);
        assertEq(vault.reserved(), 0);
    }

    // ===================
    // Queue-based Distribution (Prepare + Batch)
    // ===================

    function test_PrepareAndBatch_SingleCallDrainsQueue() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");
        vm.warp(block.timestamp + 2);

        // Queue is populated by declareDividend; denominator already cached
        assertGt(company.dividendDistributionShares(dividendId), 0);

        vm.prank(board);
        company.distributeDividendBatch(dividendId, 100);

        // All three holders paid (100k/200k, 50k/200k, 50k/200k)
        assertEq(musd.balanceOf(shareholder1), 5e6);
        assertEq(musd.balanceOf(shareholder2), 2.5e6);
        assertEq(musd.balanceOf(shareholder3), 2.5e6);
        assertEq(company.dividendRemainingAmt(dividendId), 0);

        (,,, bool distributed) = company.dividends(dividendId);
        assertTrue(distributed, "queue drained should auto-finalize");
    }

    function test_PrepareAndBatch_SmallCountAcrossMultipleCalls() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");
        vm.warp(block.timestamp + 2);

        // Batch 1: pop 1 holder
        vm.prank(board);
        company.distributeDividendBatch(dividendId, 1);
        (,,, bool distributed) = company.dividends(dividendId);
        assertFalse(distributed);

        // Batch 2: pop 1 holder
        vm.prank(board);
        company.distributeDividendBatch(dividendId, 1);
        (,,, distributed) = company.dividends(dividendId);
        assertFalse(distributed);

        // Batch 3: pop last holder — auto-finalize
        vm.prank(board);
        company.distributeDividendBatch(dividendId, 1);
        (,,, distributed) = company.dividends(dividendId);
        assertTrue(distributed);

        // All paid, nothing remaining
        assertEq(musd.balanceOf(shareholder1), 5e6);
        assertEq(musd.balanceOf(shareholder2), 2.5e6);
        assertEq(musd.balanceOf(shareholder3), 2.5e6);
        assertEq(company.dividendRemainingAmt(dividendId), 0);
    }

    function test_PrepareAndBatch_CountLargerThanQueueProcessesAll() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");
        vm.warp(block.timestamp + 2);

        // Queue has 3 holders, ask for 50 — should process 3 and auto-finalize
        vm.prank(board);
        company.distributeDividendBatch(dividendId, 50);
        (,,, bool distributed) = company.dividends(dividendId);
        assertTrue(distributed);
    }

    function test_PrepareAndBatch_ExcludedAfterPrepareIsSkipped() public {
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");
        vm.warp(block.timestamp + 2);

        // After declare, vault holds the full 10e6 reservation
        assertEq(vault.reserved(), 10e6);

        // Exclude sh1 after prepare; their slot stays in queue but batch skips at payout time.
        vm.prank(board);
        company.setDividendExclusion(shareholder1, true);

        vm.prank(board);
        company.distributeDividendBatch(dividendId, 100);

        // sh1 was popped but not paid; sh2 and sh3 got paid per original denominator (200k)
        assertEq(musd.balanceOf(shareholder1), 0);
        assertEq(musd.balanceOf(shareholder2), 2.5e6);
        assertEq(musd.balanceOf(shareholder3), 2.5e6);
        // sh1's 5e6 slice was released to vault on finalize, remaining zeroed
        assertEq(company.dividendRemainingAmt(dividendId), 0);
        assertEq(vault.reserved(), 0, "dust slice released back to vault on finalize");

        (,,, bool distributed) = company.dividends(dividendId);
        assertTrue(distributed, "queue drained");
    }

    function test_PrepareAndBatch_RoundingDustReleased() public {
        uint256 amount = 10e6 + 1;
        vm.prank(board);
        uint256 dividendId = company.declareDividend(amount, block.timestamp + 1, "");
        vm.warp(block.timestamp + 2);

        assertEq(vault.reserved(), amount, "full amount reserved at declare");

        vm.prank(board);
        company.distributeDividendBatch(dividendId, 100);

        // Integer division: sh1=5_000_000, sh2=2_500_000, sh3=2_500_000 → 10_000_000 paid, 1 wei dust
        assertEq(musd.balanceOf(shareholder1), 5_000_000);
        assertEq(musd.balanceOf(shareholder2), 2_500_000);
        assertEq(musd.balanceOf(shareholder3), 2_500_000);

        // Dust released on finalize; nothing stranded in reservation
        assertEq(company.dividendRemainingAmt(dividendId), 0);
        assertEq(vault.reserved(), 0, "rounding dust released to vault on finalize");
    }

    function test_PrepareAndBatch_DustReleaseIsolatedFromOtherDividends() public {
        vm.prank(board);
        uint256 div1 = company.declareDividend(10e6 + 1, vm.getBlockTimestamp() + 2, "");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(board);
        uint256 div2 = company.declareDividend(5e6, vm.getBlockTimestamp() + 2, "");

        // Both reserved simultaneously
        assertEq(vault.reserved(), 10e6 + 1 + 5e6);

        vm.warp(vm.getBlockTimestamp() + 2);

        // Distribute div1 fully (rounding dust path)
        vm.prank(board);
        company.distributeDividendBatch(div1, 100);

        // Only div1's full reservation removed (paid + dust released). div2 untouched.
        assertEq(vault.reserved(), 5e6, "div2 reservation intact after div1 finalize");
        assertEq(company.dividendRemainingAmt(div1), 0);
        assertEq(company.dividendRemainingAmt(div2), 5e6, "div2 tracking untouched");
    }
}

/// @dev Dummy contract that holds shares — demonstrates ERC20 dividends work to contract recipients
contract DummyShareHolder {}
