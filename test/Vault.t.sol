// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";
import "../src/Vault.sol";
import "../src/SAFE.sol";
import "../src/interfaces/ISAFE.sol";
import "../src/mixins/CompanyStorage.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract VaultTest is BaseTest {
    Vault vaultContract;
    ShareToken testToken;
    SnapshotEngine testTokenEngine;

    address recipient = address(0xDEAD);

    function setUp() public {
        _baseSetUp();
        _setupCompany();

        vaultContract = vault;

        // Deploy another token for testing token deposits/withdrawals
        // This simulates having a different share class token
        (testToken, testTokenEngine,) = _deployToken("Test Token", "TEST", 1000000 ether);

        // Mint test tokens to this contract
        bytes32 MINTER_ROLE_TEST = keccak256("MINTER_ROLE");
        testToken.grantRole(MINTER_ROLE_TEST, address(this));
        testToken.mint(address(this), 1000000 ether);

        // Fund test addresses with ETH
        vm.deal(address(this), 100 ether);
        vm.deal(board, 100 ether);
        vm.deal(investor, 100 ether);
    }

    // ============ Initialization Tests ============
    function test_Initialize() public view {
        // Test success case
        assertEq(address(vaultContract.company()), address(company));
    }

    function test_InitializeRevertsWithZeroAddress() public {
        Vault testVault = new Vault();
        vm.expectRevert(Vault.ZeroAddress.selector);
        testVault.initialize(ICompany(address(0)));
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        vaultContract.initialize(ICompany(address(company)));
    }

    // ============ ETH Deposit Tests ============
    function test_ReceiveETHSuccess() public {
        uint256 depositAmount = 10 ether;

        vm.expectEmit(true, false, false, true);
        emit Vault.ETHDeposited(address(this), depositAmount);
        (bool success,) = address(vaultContract).call{value: depositAmount}("");
        require(success, "ETH transfer failed");
        assertEq(address(vaultContract).balance, depositAmount);
    }

    function test_ReceiveETHMultipleDeposits() public {
        uint256 firstDeposit = 5 ether;
        uint256 secondDeposit = 3 ether;

        (bool success1,) = address(vaultContract).call{value: firstDeposit}("");
        require(success1, "First ETH transfer failed");

        (bool success2,) = address(vaultContract).call{value: secondDeposit}("");
        require(success2, "Second ETH transfer failed");

        assertEq(address(vaultContract).balance, firstDeposit + secondDeposit);
    }

    // ============ ETH Withdrawal Tests ============
    function test_WithdrawETHSuccess() public {
        uint256 fundAmount = 10 ether;
        (bool success,) = address(vaultContract).call{value: fundAmount}("");
        require(success, "ETH transfer failed");

        uint256 withdrawAmount = 5 ether;
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(board);
        vm.expectEmit(true, false, false, true);
        emit Vault.ETHWithdrawn(recipient, withdrawAmount);

        vaultContract.withdrawETH(recipient, withdrawAmount);

        assertEq(address(vaultContract).balance, fundAmount - withdrawAmount);
        assertEq(recipient.balance, recipientBalanceBefore + withdrawAmount);
    }

    function test_WithdrawETHFullBalance() public {
        uint256 fundAmount = 10 ether;
        (bool success,) = address(vaultContract).call{value: fundAmount}("");
        require(success, "ETH transfer failed");

        vm.prank(board);
        vaultContract.withdrawETH(recipient, fundAmount);

        assertEq(address(vaultContract).balance, 0);
        assertEq(recipient.balance, fundAmount);
    }

    function test_WithdrawETHRevertsWhenNotBoard() public {
        uint256 fundAmount = 10 ether;
        (bool success,) = address(vaultContract).call{value: fundAmount}("");
        require(success, "ETH transfer failed");

        vm.prank(nonBoard);
        vm.expectRevert(Vault.OnlyCompanyOrBoard.selector);
        vaultContract.withdrawETH(recipient, 1 ether);
    }

    function test_WithdrawETHRevertsWhenInsufficientBalance() public {
        uint256 fundAmount = 1 ether;
        (bool success,) = address(vaultContract).call{value: fundAmount}("");
        require(success, "ETH transfer failed");

        vm.prank(board);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vaultContract.withdrawETH(recipient, 2 ether);
    }

    // ============ Token Deposit Tests ============
    function test_DepositTokenSuccess() public {
        uint256 depositAmount = 100 ether;
        testToken.approve(address(vaultContract), depositAmount);
        vm.expectEmit(true, true, false, true);
        emit Vault.TokenDeposited(address(testToken), address(this), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);
        assertEq(testToken.balanceOf(address(vaultContract)), depositAmount);
    }

    function test_DepositTokenMultipleDeposits() public {
        uint256 firstDeposit = 50 ether;
        uint256 secondDeposit = 30 ether;

        testToken.approve(address(vaultContract), firstDeposit + secondDeposit);
        vaultContract.depositToken(address(testToken), firstDeposit);
        vaultContract.depositToken(address(testToken), secondDeposit);
        assertEq(testToken.balanceOf(address(vaultContract)), firstDeposit + secondDeposit);
    }

    function test_DepositTokenRevertsWithInsufficientAllowance() public {
        // Don't approve, should fail
        vm.expectRevert();
        vaultContract.depositToken(address(testToken), 100 ether);
    }

    // ============ Token Withdrawal Tests ============
    function test_WithdrawTokenSuccess() public {
        uint256 depositAmount = 100 ether;
        uint256 withdrawAmount = 60 ether;

        // Deposit tokens first
        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);
        uint256 recipientBalanceBefore = testToken.balanceOf(recipient);

        vm.prank(board);
        vm.expectEmit(true, true, false, true);
        emit Vault.TokenWithdrawn(address(testToken), recipient, withdrawAmount);

        vaultContract.withdrawToken(address(testToken), recipient, withdrawAmount);

        assertEq(testToken.balanceOf(address(vaultContract)), depositAmount - withdrawAmount);
        assertEq(testToken.balanceOf(recipient), recipientBalanceBefore + withdrawAmount);
    }

    function test_WithdrawTokenFullBalance() public {
        uint256 depositAmount = 100 ether;

        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);

        vm.prank(board);
        vaultContract.withdrawToken(address(testToken), recipient, depositAmount);

        assertEq(testToken.balanceOf(address(vaultContract)), 0);
        assertEq(testToken.balanceOf(recipient), depositAmount);
    }

    function test_WithdrawTokenRevertsWhenNotBoard() public {
        uint256 depositAmount = 100 ether;

        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);

        vm.prank(nonBoard);
        vm.expectRevert(Vault.OnlyCompanyOrBoard.selector);
        vaultContract.withdrawToken(address(testToken), recipient, 50 ether);
    }

    // Zero token/recipient/amount validations covered by testWithdrawTokenAllValidations

    function test_WithdrawTokenRevertsWhenInsufficientBalance() public {
        uint256 depositAmount = 50 ether;

        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);

        vm.prank(board);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vaultContract.withdrawToken(address(testToken), recipient, 100 ether);
    }

    // ============ Pay Dividend Tests ============

    function test_WithdrawFromCompanySuccess() public {
        // Fund the vault
        uint256 fundAmount = 10 ether;
        (bool success,) = address(vaultContract).call{value: fundAmount}("");
        require(success, "ETH transfer failed");

        uint256 withdrawAmount = 3 ether;
        uint256 recipientBalanceBefore = recipient.balance;

        // Company calls withdraw
        vm.prank(address(company));
        vm.expectEmit(true, false, false, true);
        emit Vault.ETHWithdrawn(recipient, withdrawAmount);

        vaultContract.withdrawETH(recipient, withdrawAmount);

        assertEq(address(vaultContract).balance, fundAmount - withdrawAmount);
        assertEq(recipient.balance, recipientBalanceBefore + withdrawAmount);
    }

    function test_WithdrawRevertsWhenNotBoardOrCompany() public {
        uint256 fundAmount = 10 ether;
        (bool success,) = address(vaultContract).call{value: fundAmount}("");
        require(success, "ETH transfer failed");

        address unauthorized = address(0x9999);
        vm.prank(unauthorized);
        vm.expectRevert(Vault.OnlyCompanyOrBoard.selector);
        vaultContract.withdrawETH(recipient, 1 ether);
    }

    function test_WithdrawFromCompanyRevertsWhenInsufficientBalance() public {
        uint256 fundAmount = 1 ether;
        (bool success,) = address(vaultContract).call{value: fundAmount}("");
        require(success, "ETH transfer failed");

        vm.prank(address(company));
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vaultContract.withdrawETH(recipient, 2 ether);
    }

    // ============ Integration Tests ============
    function test_IntegrationDepositAndWithdrawETH() public {
        // Multiple users deposit
        uint256 deposit1 = 5 ether;
        uint256 deposit2 = 3 ether;

        (bool success1,) = address(vaultContract).call{value: deposit1}("");
        require(success1, "First deposit failed");

        vm.prank(investor);
        (bool success2,) = address(vaultContract).call{value: deposit2}("");
        require(success2, "Second deposit failed");

        assertEq(address(vaultContract).balance, deposit1 + deposit2);

        // Board withdraws some
        vm.prank(board);
        vaultContract.withdrawETH(recipient, 4 ether);

        assertEq(address(vaultContract).balance, 4 ether);
    }

    function test_IntegrationDepositAndWithdrawTokens() public {
        // Deposit tokens
        uint256 depositAmount = 1000 ether;
        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);

        // Board withdraws portion
        vm.prank(board);
        vaultContract.withdrawToken(address(testToken), recipient, 300 ether);

        assertEq(testToken.balanceOf(address(vaultContract)), 700 ether);
        assertEq(testToken.balanceOf(recipient), 300 ether);

        // Board withdraws remaining
        vm.prank(board);
        vaultContract.withdrawToken(address(testToken), investor, 700 ether);

        assertEq(testToken.balanceOf(address(vaultContract)), 0);
        assertEq(testToken.balanceOf(investor), 700 ether);
    }

    function test_IntegrationMixedOperations() public {
        // Deposit ETH
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success, "ETH deposit failed");

        // Deposit tokens
        testToken.approve(address(vaultContract), 500 ether);
        vaultContract.depositToken(address(testToken), 500 ether);

        // Company withdraws ETH
        vm.prank(address(company));
        vaultContract.withdrawETH(investor, 2 ether);

        // Board withdraws tokens
        vm.prank(board);
        vaultContract.withdrawToken(address(testToken), recipient, 200 ether);

        // Board withdraws ETH
        vm.prank(board);
        vaultContract.withdrawETH(board, 3 ether);

        // Verify final balances
        assertEq(address(vaultContract).balance, 5 ether); // 10 - 2 - 3
        assertEq(testToken.balanceOf(address(vaultContract)), 300 ether); // 500 - 200
    }

    function test_IntegrationVaultRecognizesNewBoardAfterTransfer() public {
        // Fund vault
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success, "ETH deposit failed");

        // Old board can withdraw
        vm.prank(board);
        vaultContract.withdrawETH(recipient, 2 ether);
        assertEq(address(vaultContract).balance, 8 ether);

        // Transfer board control
        address newBoard = address(0x9999);
        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");

        skip(7 days);

        vm.prank(board);
        company.executeBoardTransfer();

        // Old board can no longer withdraw
        vm.prank(board);
        vm.expectRevert(Vault.OnlyCompanyOrBoard.selector);
        vaultContract.withdrawETH(recipient, 1 ether);

        // New board can withdraw
        vm.prank(newBoard);
        vaultContract.withdrawETH(recipient, 3 ether);
        assertEq(address(vaultContract).balance, 5 ether);
    }

    // ============ Fuzz Tests ============
    function test_FuzzDepositETH(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 100 ether);
        vm.deal(address(this), amount);

        (bool success,) = address(vaultContract).call{value: amount}("");
        require(success, "ETH transfer failed");

        assertEq(address(vaultContract).balance, amount);
    }

    function test_FuzzWithdrawETH(uint256 depositAmount, uint256 withdrawAmount) public {
        vm.assume(depositAmount > 0 && depositAmount <= 100 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);

        // Fund vault
        vm.deal(address(this), depositAmount);
        (bool success,) = address(vaultContract).call{value: depositAmount}("");
        require(success, "ETH transfer failed");

        // Withdraw
        vm.prank(board);
        vaultContract.withdrawETH(recipient, withdrawAmount);

        assertEq(address(vaultContract).balance, depositAmount - withdrawAmount);
    }

    function test_FuzzDepositToken(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000000 ether);

        testToken.approve(address(vaultContract), amount);
        vaultContract.depositToken(address(testToken), amount);

        assertEq(testToken.balanceOf(address(vaultContract)), amount);
    }

    function test_FuzzWithdrawToken(uint256 depositAmount, uint256 withdrawAmount) public {
        vm.assume(depositAmount > 0 && depositAmount <= 1000000 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);

        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);

        vm.prank(board);
        vaultContract.withdrawToken(address(testToken), recipient, withdrawAmount);

        assertEq(testToken.balanceOf(address(vaultContract)), depositAmount - withdrawAmount);
    }

    // ============ Reentrancy Attack Tests ============

    function test_WithdrawETHBlocksReentrancy() public {
        // Transfer board to the attacker so it passes onlyCompanyOrBoard
        ReentrantAttacker attacker = new ReentrantAttacker(vaultContract);
        vm.prank(board);
        company.proposeBoardTransfer(address(attacker), "");
        skip(7 days);
        vm.prank(board);
        company.executeBoardTransfer();

        // Fund vault with 10 ETH
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success);

        // Attempt reentrancy: attacker withdraws 1 ETH, receive() tries to withdraw again
        attacker.attack(1 ether);

        // Only one withdrawal should succeed; nonReentrant blocks re-entry
        assertEq(address(vaultContract).balance, 9 ether);
        assertEq(address(attacker).balance, 1 ether);
        assertTrue(attacker.reentryFailed());
    }

    // ===================
    // Failure tests
    // ===================

    function test_DepositTokenAllValidations() public {
        // 1. Invalid token address
        vm.expectRevert(Vault.ZeroAddress.selector);
        vaultContract.depositToken(address(0), 100);
        // 2. Zero amount
        vm.expectRevert(Vault.ZeroAmount.selector);
        vaultContract.depositToken(address(testToken), 0);
    }

    function test_WithdrawTokenAllValidations() public {
        testToken.approve(address(vaultContract), 100 ether);
        vaultContract.depositToken(address(testToken), 100 ether);

        vm.prank(board);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vaultContract.withdrawToken(address(0), recipient, 50 ether);
        vm.prank(board);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vaultContract.withdrawToken(address(testToken), address(0), 50 ether);

        vm.prank(board);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vaultContract.withdrawToken(address(testToken), recipient, 0);
    }

    function test_WithdrawETHAllValidations() public {
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success);

        // 1. Zero recipient
        vm.prank(board);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vaultContract.withdrawETH(address(0), 5 ether);

        // 2. Zero amount
        vm.prank(board);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vaultContract.withdrawETH(recipient, 0);
    }

    // ============ Emergency Pause/Unpause Tests ============
    function test_PauseSuccess() public {
        assertFalse(vaultContract.paused());

        vm.prank(board);
        vm.expectEmit(true, false, false, false);
        emit PausableUpgradeable.Paused(board);
        vaultContract.pause();

        assertTrue(vaultContract.paused());
    }

    function test_UnpauseSuccess() public {
        vm.prank(board);
        vaultContract.pause();
        assertTrue(vaultContract.paused());

        vm.prank(board);
        vm.expectEmit(true, false, false, false);
        emit PausableUpgradeable.Unpaused(board);
        vaultContract.unpause();

        assertFalse(vaultContract.paused());
    }

    function test_PauseUnpause_OnlyBoard() public {
        // pause requires board
        vm.prank(nonBoard);
        vm.expectRevert(Vault.OnlyBoard.selector);
        vaultContract.pause();

        // pause as board
        vm.prank(board);
        vaultContract.pause();

        // unpause requires board
        vm.prank(nonBoard);
        vm.expectRevert(Vault.OnlyBoard.selector);
        vaultContract.unpause();
    }

    function test_WithdrawETHRevertsWhenPaused() public {
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success, "ETH transfer failed");

        vm.prank(board);
        vaultContract.pause();

        vm.prank(board);
        vm.expectRevert();
        vaultContract.withdrawETH(recipient, 5 ether);
    }

    function test_WithdrawTokenRevertsWhenPaused() public {
        uint256 depositAmount = 100 ether;
        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);

        vm.prank(board);
        vaultContract.pause();

        vm.prank(board);
        vm.expectRevert();
        vaultContract.withdrawToken(address(testToken), recipient, 50 ether);
    }

    function test_WithdrawWorksAfterUnpause() public {
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success, "ETH transfer failed");

        vm.prank(board);
        vaultContract.pause();
        vm.prank(board);
        vaultContract.unpause();

        vm.prank(board);
        vaultContract.withdrawETH(recipient, 5 ether);
        assertEq(address(vaultContract).balance, 5 ether);
    }

    function test_CompanyCannotWithdrawWhenPaused() public {
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success, "ETH transfer failed");

        vm.prank(board);
        vaultContract.pause();

        vm.prank(address(company));
        vm.expectRevert();
        vaultContract.withdrawETH(recipient, 3 ether);
    }

    function test_DepositsWorkWhenPaused() public {
        vm.prank(board);
        vaultContract.pause();

        uint256 depositAmount = 5 ether;
        (bool success,) = address(vaultContract).call{value: depositAmount}("");
        require(success, "ETH deposit failed");
        assertEq(address(vaultContract).balance, depositAmount);

        testToken.approve(address(vaultContract), 100 ether);
        vaultContract.depositToken(address(testToken), 100 ether);
        assertEq(testToken.balanceOf(address(vaultContract)), 100 ether);
    }

    receive() external payable {}

    function test_WithdrawETHRevertsWhenTransferFails() public {
        (bool success,) = address(vaultContract).call{value: 10 ether}("");
        require(success, "ETH transfer failed");

        RejectEther rejecter = new RejectEther();

        vm.prank(board);
        vm.expectRevert(Vault.TransferFailed.selector);
        vaultContract.withdrawETH(address(rejecter), 1 ether);

        // Funds should still be in vault
        assertEq(address(vaultContract).balance, 10 ether);
    }

    function test_ReserveDividend_OnlyCompany() public {
        _fundMUSD(address(vaultContract), 10e6);

        vm.prank(board);
        vm.expectRevert(Vault.OnlyCompany.selector);
        vaultContract.reserveDividend(1e6);

        vm.prank(nonBoard);
        vm.expectRevert(Vault.OnlyCompany.selector);
        vaultContract.reserveDividend(1e6);
    }

    function test_ReserveDividend_RevertsZeroAmount() public {
        _fundMUSD(address(vaultContract), 10e6);

        vm.prank(address(company));
        vm.expectRevert(Vault.ZeroAmount.selector);
        vaultContract.reserveDividend(0);
    }

    function test_ReleaseDividend_OnlyCompany() public {
        vm.prank(board);
        vm.expectRevert(Vault.OnlyCompany.selector);
        vaultContract.releaseDividend(1e6);

        vm.prank(nonBoard);
        vm.expectRevert(Vault.OnlyCompany.selector);
        vaultContract.releaseDividend(1e6);
    }

    function test_ReleaseDividend_RevertsZeroAmount() public {
        vm.prank(address(company));
        vm.expectRevert(Vault.ZeroAmount.selector);
        vaultContract.releaseDividend(0);
    }

    function test_ReleaseDividend_RevertsWhenExceedsReserved() public {
        // First reserve some funds
        _fundMUSD(address(vaultContract), 10e6);

        vm.prank(address(company));
        vaultContract.reserveDividend(5e6);

        // Try to release more than reserved
        vm.prank(address(company));
        vm.expectRevert(Vault.NoOp.selector);
        vaultContract.releaseDividend(6e6);
    }

    function test_WithdrawToken_CompanyCanCall() public {
        uint256 depositAmount = 100 ether;
        testToken.approve(address(vaultContract), depositAmount);
        vaultContract.depositToken(address(testToken), depositAmount);

        vm.prank(address(company));
        vaultContract.withdrawToken(address(testToken), recipient, 50 ether);

        assertEq(testToken.balanceOf(recipient), 50 ether);
    }

    // ============ Dividend Reservation Tests ============

    function test_DeclareDividendReservesFunds() public {
        vm.prank(board);
        issuance.issueGrant("Common", investor, 100000, "test allocation", "");

        _fundMUSD(address(vaultContract), 100e6);

        // Declare dividend (10 MUSD) - should reserve funds
        vm.prank(board);
        company.declareDividend(10e6, block.timestamp + 1 days, "");

        assertEq(vaultContract.reserved(), 10e6);
        assertEq(vaultContract.availableBalance(), 90e6);
    }

    function test_BoardCannotWithdrawReservedFunds() public {
        vm.prank(board);
        issuance.issueGrant("Common", investor, 100000, "test allocation", "");

        _fundMUSD(address(vaultContract), 100e6);

        // Declare dividend (80 MUSD reserved)
        vm.prank(board);
        company.declareDividend(80e6, block.timestamp + 1 days, "");

        // Board should only be able to withdraw 20 MUSD (unreserved)
        vm.prank(board);
        vaultContract.withdrawToken(address(musd), recipient, 20e6);
        assertEq(musd.balanceOf(recipient), 20e6);

        vm.prank(board);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vaultContract.withdrawToken(address(musd), recipient, 1e6);
    }

    function test_CannotDeclareSecondDividendExceedingAvailableBalance() public {
        vm.prank(board);
        issuance.issueGrant("Common", investor, 100000, "test allocation", "");

        _fundMUSD(address(vaultContract), 100e6);

        // Declare first dividend (60 MUSD)
        vm.prank(board);
        company.declareDividend(60e6, block.timestamp + 1 days, "");

        // Available balance is now 40 MUSD
        assertEq(vaultContract.availableBalance(), 40e6);
        vm.warp(block.timestamp + 1); // next block — same-block declares are blocked

        vm.prank(board);
        vm.expectRevert(CompanyStorage.InsufficientCapacity.selector);
        company.declareDividend(50e6, block.timestamp + 2 days, "");

        // But 40 MUSD should work
        vm.prank(board);
        company.declareDividend(40e6, block.timestamp + 2 days, "");

        assertEq(vaultContract.reserved(), 100e6);
        assertEq(vaultContract.availableBalance(), 0);
    }

    function test_DistributeDividendReleasesReservation() public {
        vm.prank(board);
        issuance.issueGrant("Common", investor, 100000, "test allocation", "");

        // Fund vault with MUSD
        _fundMUSD(address(vaultContract), 100e6);

        // Declare dividend
        vm.prank(board);
        uint256 dividendId = company.declareDividend(10e6, block.timestamp + 1, "");

        assertEq(vaultContract.reserved(), 10e6);

        // Distribute dividend
        vm.warp(block.timestamp + 2);
        _distributeDividend(company, dividendId);

        // Reservation should be released
        assertEq(vaultContract.reserved(), 0);
        // Balance decreased by dividend amount
        assertEq(musd.balanceOf(address(vaultContract)), 90e6);
        assertEq(vaultContract.availableBalance(), 90e6);
    }

    function test_MultipleDividendsAccumulateReservations() public {
        vm.prank(board);
        issuance.issueGrant("Common", investor, 100000, "test allocation", "");

        // Fund vault with MUSD
        _fundMUSD(address(vaultContract), 100e6);

        // Declare first dividend
        vm.prank(board);
        uint256 div1 = company.declareDividend(20e6, block.timestamp + 1 days, "");
        assertEq(vaultContract.reserved(), 20e6);
        vm.warp(block.timestamp + 1); // next block

        // Declare second dividend
        vm.prank(board);
        uint256 div2 = company.declareDividend(30e6, block.timestamp + 2 days, "");
        assertEq(vaultContract.reserved(), 50e6);

        uint256 startTime = block.timestamp;

        // Distribute first dividend (after div1 payment date)
        vm.warp(startTime + 1 days + 1);
        _distributeDividend(company, div1);
        assertEq(vaultContract.reserved(), 30e6);

        // Distribute second dividend (after div2 payment date)
        vm.warp(startTime + 2 days + 1);
        _distributeDividend(company, div2);
        assertEq(vaultContract.reserved(), 0);
    }

    function test_BoardWithdrawalRespectsMultipleReservations() public {
        vm.prank(board);
        issuance.issueGrant("Common", investor, 100000, "test allocation", "");

        // Fund vault with 100 MUSD
        _fundMUSD(address(vaultContract), 100e6);

        // Declare two dividends totaling 70 MUSD reserved
        vm.prank(board);
        company.declareDividend(40e6, block.timestamp + 1 days, "");
        vm.warp(block.timestamp + 1); // next block — same-block declares are blocked
        vm.prank(board);
        company.declareDividend(30e6, block.timestamp + 2 days, "");

        // Board can withdraw 30 MUSD (100 - 70 reserved)
        vm.prank(board);
        vaultContract.withdrawToken(address(musd), recipient, 30e6);
        assertEq(musd.balanceOf(recipient), 30e6);

        // Cannot withdraw any more
        vm.prank(board);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vaultContract.withdrawToken(address(musd), recipient, 1);
    }
}

/// @dev Attacker contract that attempts reentrancy on Vault.withdrawETH
contract ReentrantAttacker {
    Vault public target;
    uint256 public attackAmount;
    bool public attacking;
    bool public reentryFailed;

    constructor(Vault _target) {
        target = _target;
    }

    function attack(uint256 amount) external {
        attackAmount = amount;
        attacking = true;
        reentryFailed = false;
        target.withdrawETH(address(this), amount);
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            // Attempt reentrancy — nonReentrant should block this
            try target.withdrawETH(address(this), attackAmount) {
            // If we get here, reentrancy guard failed
            }
            catch {
                reentryFailed = true;
            }
        }
    }
}
