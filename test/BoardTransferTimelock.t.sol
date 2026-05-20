// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";
import "../src/mixins/CompanyStorage.sol";

contract BoardTransferTimelockTest is BaseTest {
    address newBoard = address(0x7777);
    address anotherBoard = address(0x8888);

    function setUp() public {
        _baseSetUp();
        _setupCompany();
    }

    // ═════════════════════════════════════════════════════════
    //  proposeBoardTransfer(, "")
    // ═════════════════════════════════════════════════════════

    function test_propose_revertsInvalidInputsAndOverwrites() public {
        // Zero address
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        company.proposeBoardTransfer(address(0), "");

        // Self-transfer
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.proposeBoardTransfer(board, "");

        // Non-board caller
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.proposeBoardTransfer(newBoard, "");

        // Valid proposal
        vm.expectEmit(true, false, false, true);
        emit BoardTransferProposed(newBoard, block.timestamp + 7 days, "");
        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");
        assertEq(company.proposedBoard(), newBoard);
        assertEq(company.boardTransferProposedAt(), block.timestamp);

        // Overwrite resets timelock
        skip(3 days);
        vm.prank(board);
        company.proposeBoardTransfer(anotherBoard, "");
        assertEq(company.proposedBoard(), anotherBoard);
        assertEq(company.boardTransferProposedAt(), block.timestamp);
    }

    // ═════════════════════════════════════════════════════════
    //  executeBoardTransfer()
    // ═════════════════════════════════════════════════════════

    function test_execute_byCurrentBoardAfterTimelock() public {
        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");

        skip(7 days);

        vm.expectEmit(true, true, false, false);
        emit BoardChanged(board, newBoard, "");
        vm.prank(board);
        company.executeBoardTransfer();

        assertEq(company.board(), newBoard);
        assertEq(company.proposedBoard(), address(0));
        assertEq(company.boardTransferProposedAt(), 0);
        assertEq(company.BOARD_TRANSFER_TIMELOCK(), 7 days);
    }

    function test_execute_byProposedBoard() public {
        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");

        skip(7 days);

        vm.prank(newBoard);
        company.executeBoardTransfer();

        assertEq(company.board(), newBoard);
    }

    function test_execute_revertsBeforeTimelockAndUnauthorized() public {
        // No pending transfer
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.executeBoardTransfer();

        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");

        // Immediately
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.executeBoardTransfer();

        // 1 second before expiry
        skip(7 days - 1);
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.executeBoardTransfer();

        // Unauthorized caller at expiry
        skip(1);
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyCurrentOrProposedBoard.selector);
        company.executeBoardTransfer();

        // Exactly at expiry succeeds
        vm.prank(board);
        company.executeBoardTransfer();
        assertEq(company.board(), newBoard);
    }

    // ═════════════════════════════════════════════════════════
    //  cancelBoardTransfer()
    // ═════════════════════════════════════════════════════════

    function test_cancel_revertsNoPendingAndOnlyCurrentBoard() public {
        // No pending transfer
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.cancelBoardTransfer();

        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");

        // Proposed board cannot cancel
        vm.prank(newBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.cancelBoardTransfer();
        assertEq(company.proposedBoard(), newBoard);

        // Current board cancels
        vm.expectEmit(true, false, false, false);
        emit BoardTransferCancelled(newBoard);
        vm.prank(board);
        company.cancelBoardTransfer();
        assertEq(company.proposedBoard(), address(0));
        assertEq(company.boardTransferProposedAt(), 0);

        // Cancelled transfer cannot be executed
        skip(7 days);
        vm.prank(newBoard);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.executeBoardTransfer();
    }

    // ═════════════════════════════════════════════════════════
    //  Role rotation
    // ═════════════════════════════════════════════════════════

    function test_execute_rotatesExternalAdminRoles() public {
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        bytes32 SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");

        // Pre-transfer: old board + company have roles
        assertTrue(shareToken.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertTrue(snapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertTrue(ruleEngine.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertTrue(snapshotEngine.hasRole(SNAPSHOOTER_ROLE, board));

        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");
        skip(7 days);
        vm.prank(newBoard);
        company.executeBoardTransfer();

        // Old board stripped
        assertFalse(shareToken.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertFalse(snapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertFalse(ruleEngine.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertFalse(snapshotEngine.hasRole(SNAPSHOOTER_ROLE, board));

        // New board granted
        assertTrue(shareToken.hasRole(DEFAULT_ADMIN_ROLE, newBoard));
        assertTrue(snapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, newBoard));
        assertTrue(ruleEngine.hasRole(DEFAULT_ADMIN_ROLE, newBoard));
        assertTrue(snapshotEngine.hasRole(SNAPSHOOTER_ROLE, newBoard));

        // Company retains admin across rotations
        assertTrue(shareToken.hasRole(DEFAULT_ADMIN_ROLE, address(company)));
        assertTrue(snapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, address(company)));
        assertTrue(ruleEngine.hasRole(DEFAULT_ADMIN_ROLE, address(company)));
    }

    // ═════════════════════════════════════════════════════════
    //  Integration: full lifecycle
    // ═════════════════════════════════════════════════════════

    function test_fullLifecycle_cancelReproposeSequentialTransfers() public {
        // ── Propose → cancel → repropose ──
        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");
        vm.prank(board);
        company.cancelBoardTransfer();

        vm.prank(board);
        company.proposeBoardTransfer(newBoard, "");

        // Old board still operates during timelock
        vm.prank(board);
        company.setCompanyTicker("PENDING");
        assertEq(company.ticker(), "PENDING");

        // ── Execute A → B ──
        skip(7 days);
        vm.prank(newBoard);
        company.executeBoardTransfer();
        assertEq(company.board(), newBoard);

        // Old board locked out, new board operates
        vm.prank(board);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.setCompanyTicker("OLDBOARD");

        vm.prank(newBoard);
        issuance.issueGrant("Common", investor, 1000, "test", "");
        assertEq(shareToken.balanceOf(investor), 1000);

        // ── Sequential: B → C ──
        vm.prank(newBoard);
        company.proposeBoardTransfer(anotherBoard, "");
        skip(7 days);
        vm.prank(newBoard);
        company.executeBoardTransfer();
        assertEq(company.board(), anotherBoard);

        vm.prank(anotherBoard);
        company.setCompanyTicker("FINAL");
        assertEq(company.ticker(), "FINAL");
    }

    function test_timelockPreventsImmediateMaliciousTransfer() public {
        vm.deal(address(vault), 10 ether);

        // Attacker (with compromised board key) proposes transfer
        address attacker = address(0x666);
        vm.prank(board);
        company.proposeBoardTransfer(attacker, "");

        // Cannot execute immediately
        vm.prank(attacker);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.executeBoardTransfer();
        assertEq(address(vault).balance, 10 ether);

        // Legitimate board cancels
        vm.prank(board);
        company.cancelBoardTransfer();

        // Attacker blocked even after timelock
        skip(7 days);
        vm.prank(attacker);
        vm.expectRevert(CompanyStorage.InvalidState.selector);
        company.executeBoardTransfer();

        assertEq(company.board(), board);
    }

    // Events (re-declared for vm.expectEmit)
    event BoardTransferProposed(address indexed proposedBoard, uint256 executeAtTime, string documentRef);
    event BoardTransferCancelled(address indexed cancelledBoard);
}
