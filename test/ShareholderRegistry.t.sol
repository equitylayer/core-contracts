// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";

contract ShareholderRegistryTest is BaseTest {
    address investor1 = address(0x1111);
    address investor2 = address(0x2222);
    address investor3 = address(0x3333);

    function setUp() public {
        _baseSetUp();
        _setupCompany();

        // Issue shares to some investors
        vm.startPrank(address(issuance));
        shareToken.issueShares(investor1, 1000);
        shareToken.issueShares(investor2, 500);
        shareToken.issueShares(investor3, 250);
        vm.stopPrank();
    }

    // ===================
    // Initialization Tests
    // ===================

    function test_Initialize() public {
        ShareholderRegistry newRegistry = new ShareholderRegistry();
        address testCompany = address(0xC0FFEE);

        newRegistry.initialize(testCompany);

        assertEq(newRegistry.company(), testCompany, "Company should be set");
    }

    function test_Initialize_CannotInitializeTwice() public {
        ShareholderRegistry registry = shareToken.shareholderRegistry();

        vm.expectRevert(ShareholderRegistry.AlreadyInitialized.selector);
        registry.initialize(address(company));
    }

    function test_Initialize_RevertsZeroCompany() public {
        ShareholderRegistry newRegistry = new ShareholderRegistry();

        vm.expectRevert(ShareholderRegistry.ZeroAddress.selector);
        newRegistry.initialize(address(0));
    }

    // ===================
    // View Function Tests
    // ===================

    function test_GetShareholders() public view {
        address[] memory shareholders = shareToken.shareholderRegistry().getShareholders(address(shareToken));

        assertEq(shareholders.length, 3, "Should have 3 shareholders");
        assertEq(shareholders[0], investor1);
        assertEq(shareholders[1], investor2);
        assertEq(shareholders[2], investor3);
    }

    function test_GetShareholderCount() public view {
        uint256 count = shareToken.shareholderRegistry().getShareholderCount(address(shareToken));
        assertEq(count, 3, "Should have 3 shareholders");
    }

    function test_IsHolder() public view {
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor1));
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor2));
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor3));
        assertFalse(shareToken.shareholderRegistry().isHolder(address(shareToken), address(0x9999)));
    }

    function test_RemoveShareholderOnTransferAll() public {
        // investor1 transfers all their shares to investor2
        vm.prank(investor1);
        assertTrue(shareToken.transfer(investor2, 1000));

        address[] memory shareholders = shareToken.shareholderRegistry().getShareholders(address(shareToken));

        assertEq(shareholders.length, 2, "deactivated holder is popped from array");
        assertFalse(shareToken.shareholderRegistry().isHolder(address(shareToken), investor1));
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor2));
    }

    function test_AddShareholderOnFirstPurchase() public {
        address newInvestor = address(0x4444);

        // New investor receives shares
        vm.prank(address(issuance));
        shareToken.issueShares(newInvestor, 100);

        address[] memory shareholders = shareToken.shareholderRegistry().getShareholders(address(shareToken));

        assertEq(shareholders.length, 4, "Should have 4 shareholders");
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), newInvestor));
    }

    function test_ShareholderPagination() public view {
        (address[] memory page1, uint256 total) =
            shareToken.shareholderRegistry().getShareholdersPaginated(address(shareToken), 0, 2);

        assertEq(total, 3, "Total should be 3");
        assertEq(page1.length, 2, "Page 1 should have 2 results");
        assertEq(page1[0], investor1);
        assertEq(page1[1], investor2);

        (address[] memory page2,) = shareToken.shareholderRegistry().getShareholdersPaginated(address(shareToken), 2, 2);

        assertEq(page2.length, 1, "Page 2 should have 1 result");
        assertEq(page2[0], investor3);
    }

    function test_MultipleTransfersPreservesList() public {
        // Multiple transfers but everyone keeps a balance
        vm.prank(investor1);
        assertTrue(shareToken.transfer(investor2, 100));

        vm.prank(investor2);
        assertTrue(shareToken.transfer(investor3, 50));

        address[] memory shareholders = shareToken.shareholderRegistry().getShareholders(address(shareToken));

        // All 3 should still be in the list
        assertEq(shareholders.length, 3, "Should still have 3 shareholders");
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor1));
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor2));
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor3));
    }

    function test_BurnRemovesShareholder() public {
        // investor3 transfers all their shares away
        vm.prank(investor3);
        assertTrue(shareToken.transfer(investor1, 250));

        address[] memory shareholders = shareToken.shareholderRegistry().getShareholders(address(shareToken));

        assertEq(shareholders.length, 2, "deactivated holder is popped from array");
        assertFalse(shareToken.shareholderRegistry().isHolder(address(shareToken), investor3));

        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor1));
        assertTrue(shareToken.shareholderRegistry().isHolder(address(shareToken), investor2));
    }

    function test_GetTotalUniqueShareholders() public view {
        uint256 uniqueCount = shareToken.shareholderRegistry().getTotalUniqueShareholders();
        assertEq(uniqueCount, 3, "Should have 3 unique shareholders");
    }

    // ========== ACCESS CONTROL TESTS ==========

    function test_OnlyShareTokenCanUpdateRegistry() public {
        ShareholderRegistry registry = shareToken.shareholderRegistry();
        address attacker = address(0xBAD);

        // Verify investor1 is currently a shareholder
        assertTrue(registry.isHolder(address(shareToken), investor1), "investor1 should be holder");

        // Attacker tries to remove investor1 from registry directly
        vm.prank(attacker);
        vm.expectRevert(ShareholderRegistry.OnlyShareToken.selector);
        registry.updateOnTransfer(
            address(shareToken), // target token
            investor1, // "from" - victim to remove
            attacker, // "to" - doesn't matter
            0, // fromBalance=0 would trigger removal
            1 // toBalance > 0
        );

        // Verify investor1 is still a shareholder (attack failed)
        assertTrue(registry.isHolder(address(shareToken), investor1), "investor1 should still be holder");
        assertEq(registry.getShareholderCount(address(shareToken)), 3, "Should still have 3 shareholders");
    }

    function test_OnlyShareTokenCanAddToRegistry() public {
        ShareholderRegistry registry = shareToken.shareholderRegistry();
        address attacker = address(0xBAD);
        address fakeHolder = address(0xFA1E);

        // Verify fakeHolder is not currently a shareholder
        assertFalse(registry.isHolder(address(shareToken), fakeHolder), "fakeHolder should not be holder");

        // Attacker tries to add fakeHolder to registry directly
        vm.prank(attacker);
        vm.expectRevert(ShareholderRegistry.OnlyShareToken.selector);
        registry.updateOnTransfer(
            address(shareToken), // target token
            address(0), // "from" - mint scenario
            fakeHolder, // "to" - fake holder to add
            0, // fromBalance doesn't matter for mint
            1000 // toBalance > 0 would trigger add
        );

        // Verify fakeHolder is still not a shareholder (attack failed)
        assertFalse(registry.isHolder(address(shareToken), fakeHolder), "fakeHolder should still not be holder");
        assertEq(registry.getShareholderCount(address(shareToken)), 3, "Should still have 3 shareholders");
    }

    function test_ShareTokenCanUpdateRegistry() public {
        ShareholderRegistry registry = shareToken.shareholderRegistry();
        address newHolder = address(0x5555);

        // Normal flow: share token issues shares, which calls updateOnTransfer internally
        vm.prank(address(issuance));
        shareToken.issueShares(newHolder, 100);

        // Verify newHolder was added via proper channel
        assertTrue(registry.isHolder(address(shareToken), newHolder), "newHolder should be holder");
        assertEq(registry.getShareholderCount(address(shareToken)), 4, "Should have 4 shareholders");
    }
}
