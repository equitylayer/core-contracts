// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";

/// @title SnapshotTest
/// @notice Tests for snapshot functionality using production-style deployment
/// @dev Uses production-style deployment (RuleEngine + SnapshotEngine)
contract SnapshotTest is BaseTest {
    ShareToken public token;

    address public admin = address(this);
    address public snapshooter = address(0x1);
    address public investor1 = address(0x2);
    address public investor2 = address(0x3);
    address public nonAdmin = address(0x9999);

    function setUp() public {
        _baseSetUp();

        // Deploy token with BOTH engines (production-style)
        (token, snapshotEngine, ruleEngine) = _deployToken("Test Token", "TEST", 1000000);

        // Grant SNAPSHOOTER_ROLE to snapshooter
        bytes32 SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");
        snapshotEngine.grantRole(SNAPSHOOTER_ROLE, snapshooter);

        // Grant MINTER_ROLE for testing
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        token.grantRole(MINTER_ROLE, address(this));
    }

    // ============ Basic Snapshot Tests ============

    function test_SnapshotEngineIsSet() public view {
        assertEq(address(token.snapshotEngine()), address(snapshotEngine));
    }

    function test_ScheduleSnapshot() public {
        uint256 snapshotTime = block.timestamp + 1 days;

        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        // Verify snapshot is scheduled
        uint256[] memory snapshots = snapshotEngine.getNextSnapshots();
        assertEq(snapshots.length, 1);
        assertEq(snapshots[0], snapshotTime);
    }

    function test_SnapshotRecordsBalance() public {
        // Mint tokens to investor1
        token.mint(investor1, 1000);

        // Schedule and take snapshot (must be in the future or exactly at next block)
        uint256 snapshotTime = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        // Move time forward to snapshot time
        vm.warp(snapshotTime);

        // Trigger the snapshot by doing a transfer
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100));

        // Check snapshot balance (before transfer)
        uint256 snapshotBalance = snapshotEngine.snapshotBalanceOf(snapshotTime, investor1);
        assertEq(snapshotBalance, 1000); // Should be 1000 (before transfer)

        // Check current balance (after transfer)
        assertEq(token.balanceOf(investor1), 900); // Now 900
    }

    function test_SnapshotTotalSupply() public {
        // Mint initial supply
        token.mint(investor1, 5000);

        // Schedule and take snapshot
        uint256 snapshotTime = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        // Move time forward to snapshot time
        vm.warp(snapshotTime);

        // Trigger snapshot
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100));

        // Mint more tokens (after snapshot)
        token.mint(investor2, 3000);

        // Check snapshot total supply (before new mint)
        uint256 snapshotSupply = snapshotEngine.snapshotTotalSupply(snapshotTime);
        assertEq(snapshotSupply, 5000);

        // Check current total supply (after new mint)
        assertEq(token.totalSupply(), 8000);
    }

    function test_MultipleSnapshots() public {
        // Initial balance
        token.mint(investor1, 1000);

        // Snapshot 1
        uint256 snapshot1 = 100; // Use explicit timestamps to avoid confusion
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshot1);
        vm.warp(snapshot1);
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100)); // Trigger snapshot

        // Transfer more
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 200));

        // Snapshot 2 - must be after snapshot1
        uint256 snapshot2 = 200; // Use explicit timestamp > snapshot1
        vm.warp(snapshot2 - 1); // Warp to just before snapshot2
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshot2);
        vm.warp(snapshot2);
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100)); // Trigger snapshot

        // Verify balances at different snapshots
        assertEq(snapshotEngine.snapshotBalanceOf(snapshot1, investor1), 1000); // Before any transfer
        assertEq(snapshotEngine.snapshotBalanceOf(snapshot2, investor1), 700); // After 300 transferred
        assertEq(token.balanceOf(investor1), 600); // Current balance
    }

    function test_SnapshotInfo() public {
        // Setup balances
        token.mint(investor1, 1000);
        token.mint(investor2, 2000);

        // Schedule snapshot
        uint256 snapshotTime = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        // Move time forward to snapshot time
        vm.warp(snapshotTime);

        // Trigger snapshot
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100));

        // Get snapshot info (balance + total supply in one call)
        (uint256 balance, uint256 totalSupply) = snapshotEngine.snapshotInfo(snapshotTime, investor1);

        assertEq(balance, 1000);
        assertEq(totalSupply, 3000);
    }

    function test_SnapshotInfoBatch() public {
        // Setup balances
        token.mint(investor1, 1000);
        token.mint(investor2, 2000);

        // Schedule snapshot
        uint256 snapshotTime = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        // Move time forward to snapshot time
        vm.warp(snapshotTime);

        // Trigger snapshot
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100));

        // Get batch snapshot info
        address[] memory addresses = new address[](2);
        addresses[0] = investor1;
        addresses[1] = investor2;

        (uint256[] memory balances, uint256 totalSupply) = snapshotEngine.snapshotInfoBatch(snapshotTime, addresses);

        assertEq(balances[0], 1000);
        assertEq(balances[1], 2000);
        assertEq(totalSupply, 3000);
    }

    function test_IntegrationDividendWithSnapshot() public {
        // Setup: Issue shares to investors
        token.mint(investor1, 100000); // 50%
        token.mint(investor2, 100000); // 50%

        // Record date: Take snapshot
        uint256 recordDate = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(recordDate);

        // Move time forward to snapshot time
        vm.warp(recordDate);

        // Trigger snapshot
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 1)); // Trigger

        // After record date: investor1 sells all shares
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 99999));

        // Current balances are now: investor1=0, investor2=200000
        assertEq(token.balanceOf(investor1), 0);
        assertEq(token.balanceOf(investor2), 200000);

        // But snapshot balances (for dividend) are: investor1=100000, investor2=100000
        assertEq(snapshotEngine.snapshotBalanceOf(recordDate, investor1), 100000);
        assertEq(snapshotEngine.snapshotBalanceOf(recordDate, investor2), 100000);

        // Dividend distribution should use snapshot balances, not current balances
        // This ensures investor1 gets 50% even though they sold their shares
    }

    // ============ Reschedule Snapshot Tests ============

    function test_RescheduleSnapshot() public {
        uint256 oldTime = block.timestamp + 1 days;
        uint256 newTime = block.timestamp + 2 days;

        // Schedule initial snapshot
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(oldTime);

        // Reschedule it
        vm.prank(snapshooter);
        snapshotEngine.rescheduleSnapshot(oldTime, newTime);

        // Verify new time is scheduled
        uint256[] memory snapshots = snapshotEngine.getNextSnapshots();
        assertEq(snapshots.length, 1);
        assertEq(snapshots[0], newTime);
    }

    function test_RescheduleSnapshotOnlySnapshooterRole() public {
        uint256 oldTime = block.timestamp + 1 days;
        uint256 newTime = block.timestamp + 2 days;

        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(oldTime);

        vm.prank(nonAdmin);
        vm.expectRevert();
        snapshotEngine.rescheduleSnapshot(oldTime, newTime);
    }

    // ============ Unschedule Last Snapshot Tests ============

    function test_UnscheduleLastSnapshot() public {
        uint256 time1 = block.timestamp + 1 days;
        uint256 time2 = block.timestamp + 2 days;

        // Schedule two snapshots
        vm.startPrank(snapshooter);
        snapshotEngine.scheduleSnapshot(time1);
        snapshotEngine.scheduleSnapshot(time2);
        vm.stopPrank();

        // Unschedule the last one
        vm.prank(snapshooter);
        snapshotEngine.unscheduleLastSnapshot(time2);

        // Verify only first snapshot remains
        uint256[] memory snapshots = snapshotEngine.getNextSnapshots();
        assertEq(snapshots.length, 1);
        assertEq(snapshots[0], time1);
    }

    function test_UnscheduleLastSnapshotOnlySnapshooterRole() public {
        uint256 time = block.timestamp + 1 days;

        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(time);

        vm.prank(nonAdmin);
        vm.expectRevert();
        snapshotEngine.unscheduleLastSnapshot(time);
    }

    // ============ hasRole Override Tests ============

    function test_DefaultAdminHasAllRoles() public view {
        bytes32 SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;

        // Admin should have DEFAULT_ADMIN_ROLE
        assertTrue(snapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, admin));

        // Admin should also have SNAPSHOOTER_ROLE (via hasRole override)
        assertTrue(snapshotEngine.hasRole(SNAPSHOOTER_ROLE, admin));
    }

    function test_NonAdminDoesNotHaveAllRoles() public view {
        bytes32 SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;

        // snapshooter should have SNAPSHOOTER_ROLE
        assertTrue(snapshotEngine.hasRole(SNAPSHOOTER_ROLE, snapshooter));

        // but not DEFAULT_ADMIN_ROLE
        assertFalse(snapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, snapshooter));
    }

    // ============ onlyToken Modifier Tests ============

    function test_OperateOnTransferOnlyToken() public {
        // Try to call operateOnTransfer from non-token address
        vm.prank(nonAdmin);
        vm.expectRevert("SnapshotEngine: caller must be token");
        snapshotEngine.operateOnTransfer(investor1, investor2, 100, 100, 200);
    }

    function test_OperateOnTransferFromToken() public {
        // Mint tokens to investor1
        token.mint(investor1, 1000);

        // Schedule snapshot
        uint256 snapshotTime = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        vm.warp(snapshotTime);

        // Transfer triggers operateOnTransfer internally
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100));

        // Verify snapshot was updated
        uint256 snapshotBalance = snapshotEngine.snapshotBalanceOf(snapshotTime, investor1);
        assertEq(snapshotBalance, 1000); // Balance before transfer
    }

    // ============ Burn Operation Tests ============

    function test_SnapshotOnBurn() public {
        // Mint tokens
        token.mint(investor1, 1000);

        // Schedule snapshot
        uint256 snapshotTime = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        vm.warp(snapshotTime);

        // Burn tokens (triggers operateOnTransfer with to = address(0))
        token.burn(investor1, 300);

        // Verify snapshot
        uint256 snapshotBalance = snapshotEngine.snapshotBalanceOf(snapshotTime, investor1);
        uint256 snapshotSupply = snapshotEngine.snapshotTotalSupply(snapshotTime);

        assertEq(snapshotBalance, 1000); // Balance before burn
        assertEq(snapshotSupply, 1000); // Supply before burn

        // Verify current state
        assertEq(token.balanceOf(investor1), 700); // After burn
        assertEq(token.totalSupply(), 700); // After burn
    }

    // ============ Mint Operation Tests ============

    function test_SnapshotOnMint() public {
        // Initial mint
        token.mint(investor1, 500);

        // Schedule snapshot
        uint256 snapshotTime = block.timestamp + 1;
        vm.prank(snapshooter);
        snapshotEngine.scheduleSnapshot(snapshotTime);

        vm.warp(snapshotTime);

        // Trigger snapshot with a transfer
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100));

        // Mint more after snapshot (triggers operateOnTransfer with from = address(0))
        token.mint(investor2, 1000);

        // Verify snapshot
        uint256 snapshotSupply = snapshotEngine.snapshotTotalSupply(snapshotTime);
        assertEq(snapshotSupply, 500); // Supply before new mint

        // Verify current state
        assertEq(token.totalSupply(), 1500); // After new mint
    }

    // ============ Constructor Tests ============

    function test_ConstructorSetsToken() public view {
        assertEq(address(snapshotEngine.token()), address(token));
    }

    function test_ConstructorSetsAdmin() public view {
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        assertTrue(snapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_InitializeRevertsWithZeroAddress() public {
        SnapshotEngine se = new SnapshotEngine();
        vm.expectRevert("SnapshotEngine: invalid token address");
        se.initialize(ERC20Upgradeable(address(0)), admin);
    }

    // ============ snapshotInfo Batch Tests ============

    function test_SnapshotInfoBatchMultipleTimes() public {
        // Mint tokens
        token.mint(investor1, 1000);
        token.mint(investor2, 500);

        // Schedule multiple snapshots
        uint256 time1 = block.timestamp + 1;
        uint256 time2 = block.timestamp + 2;

        vm.startPrank(snapshooter);
        snapshotEngine.scheduleSnapshot(time1);
        snapshotEngine.scheduleSnapshot(time2);
        vm.stopPrank();

        // Take snapshot 1
        vm.warp(time1);
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 100));

        // Take snapshot 2
        vm.warp(time2);
        vm.prank(investor1);
        assertTrue(token.transfer(investor2, 200));

        // Query multiple times and addresses
        uint256[] memory times = new uint256[](2);
        times[0] = time1;
        times[1] = time2;

        address[] memory addresses = new address[](2);
        addresses[0] = investor1;
        addresses[1] = investor2;

        (uint256[][] memory balances, uint256[] memory supplies) = snapshotEngine.snapshotInfoBatch(times, addresses);

        // Verify snapshot 1
        assertEq(balances[0][0], 1000); // investor1 at time1
        assertEq(balances[0][1], 500); // investor2 at time1
        assertEq(supplies[0], 1500);

        // Verify snapshot 2
        assertEq(balances[1][0], 900); // investor1 at time2 (after first transfer)
        assertEq(balances[1][1], 600); // investor2 at time2
        assertEq(supplies[1], 1500);
    }
}
