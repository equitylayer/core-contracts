// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";

/// @title ShareTokenTest
/// @notice Tests for ShareToken - CMTAT-based security token
/// @dev Uses production-style deployment (RuleEngine + SnapshotEngine)
contract ShareTokenTest is BaseTest {
    ShareToken token;

    // Events
    event AuthorizedSharesIncreased(uint256 indexed previousAmount, uint256 indexed newAmount);
    event SharesIssued(address indexed to, uint256 indexed amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        (token, snapshotEngine, ruleEngine) = _deployToken("APPLE CLASS A", "APPA", 1000);
        token.setIssuanceAddress(address(this));
        token.grantRole(token.MINTER_ROLE(), address(this));
    }

    function test_InitialState() public view {
        assertEq(token.totalSupply(), 0);
        assertEq(token.name(), "APPLE CLASS A");
        assertEq(token.symbol(), "APPA");
    }

    function test_MintWithinAuthorizedShares() public {
        token.issueShares(investor, 500);
        assertEq(token.totalSupply(), 500);
    }

    function test_CannotMintBeyondAuthorizedShares() public {
        vm.expectRevert("ExceedsAuthorizedShares()");
        token.issueShares(investor, 2000);
    }

    function test_IncreaseAuthorizedThenMint() public {
        // Initially cannot mint 1500
        vm.expectRevert("ExceedsAuthorizedShares()");
        token.issueShares(investor, 1500);

        token.increaseAuthorizedShares(501);
        token.issueShares(investor, 1500);
        assertEq(token.totalSupply(), 1500);
    }

    // ========== ACCESS CTRL ==========
    function test_SetCompanyAddress() public {
        token.setCompanyAddress(board);
        assertEq(token.companyAddress(), board);
    }

    function test_OnlyAdminCanSetCompanyAddress() public {
        vm.prank(investor);
        vm.expectRevert();
        token.setCompanyAddress(board);
    }

    // ========== CUSTOM ERROR TESTS ==========
    function test_CustomErrors() public {
        vm.prank(investor);
        vm.expectRevert();
        token.issueShares(employee, 100);

        vm.prank(investor);
        vm.expectRevert(ShareToken.OnlyCompany.selector);
        token.increaseAuthorizedShares(500);

        vm.expectRevert(ShareToken.ExceedsAuthorizedShares.selector);
        token.issueShares(investor, 2000);

        vm.expectRevert(ShareToken.ZeroAddress.selector);
        token.setCompanyAddress(address(0));
    }

    // ========== CMTAT FUNCTIONALITY ==========
    function test_TransferBetweenInvestors() public {
        token.issueShares(investor, 500);

        vm.prank(investor);
        assertTrue(token.transfer(employee, 200));

        assertEq(token.balanceOf(investor), 300);
        assertEq(token.balanceOf(employee), 200);
    }

    function test_BurnShares() public {
        token.issueShares(investor, 500);
        token.burn(investor, 200);

        assertEq(token.balanceOf(investor), 300);
        assertEq(token.totalSupply(), 300);
    }

    function test_ApproveAll() public {
        token.issueShares(investor, 1000);

        vm.prank(investor);
        token.approve(employee, 500);
        assertEq(token.allowance(investor, employee), 500);

        // Change approval
        vm.prank(investor);
        token.approve(employee, 1000);
        assertEq(token.allowance(investor, employee), 1000);

        // Zero approval
        vm.prank(investor);
        token.approve(employee, 0);
        assertEq(token.allowance(investor, employee), 0);
    }

    function test_TransferFromAllValidations() public {
        // Test transferFrom for branch coverage

        token.issueShares(investor, 1000);

        vm.prank(investor);
        token.approve(employee, 500);

        // Transfer using allowance
        vm.prank(employee);
        assertTrue(token.transferFrom(investor, founder, 200));

        assertEq(token.balanceOf(investor), 800);
        assertEq(token.balanceOf(founder), 200);
        assertEq(token.allowance(investor, employee), 300);

        // Verify cannot transfer more than allowance
        vm.prank(employee);
        vm.expectRevert();
        (bool success) = token.transferFrom(investor, founder, 400);
        assertFalse(success);
    }

    // ========== SHAREHOLDER REGISTRY INTEGRATION ==========
    function test_RegistryUpdatesOnMint() public {
        token.issueShares(investor, 500);

        ShareholderRegistry registry = token.shareholderRegistry();
        assertTrue(registry.isHolder(address(token), investor));
        assertEq(registry.getShareholderCount(address(token)), 1);
    }

    function test_RegistryUpdatesOnTransfer() public {
        token.issueShares(investor, 500);

        vm.prank(investor);
        assertTrue(token.transfer(employee, 200));

        ShareholderRegistry registry = token.shareholderRegistry();
        assertTrue(registry.isHolder(address(token), investor));
        assertTrue(registry.isHolder(address(token), employee));
        assertEq(registry.getShareholderCount(address(token)), 2);
    }

    function test_RegistryUpdatesOnBurn() public {
        token.issueShares(investor, 500);
        token.burn(investor, 500);

        ShareholderRegistry registry = token.shareholderRegistry();
        assertFalse(registry.isHolder(address(token), investor));
        assertEq(registry.getShareholderCount(address(token)), 0);
    }

    function test_RegistryTracksMultipleShareholders() public {
        token.issueShares(investor, 300);
        token.issueShares(employee, 200);
        token.issueShares(founder, 100);

        ShareholderRegistry registry = token.shareholderRegistry();
        assertEq(registry.getShareholderCount(address(token)), 3);

        address[] memory shareholders = registry.getShareholders(address(token));
        assertEq(shareholders.length, 3);
        assertEq(shareholders[0], investor);
        assertEq(shareholders[1], employee);
        assertEq(shareholders[2], founder);
    }

    // ========== AUTHORIZED SHARES EDGE CASES ==========
    function test_MintExactlyAtLimit() public {
        token.issueShares(investor, 1000); // Exactly at authorized limit
        assertEq(token.totalSupply(), 1000);
        assertEq(token.authorizedShares(), 1000);
    }

    function test_CanMintAfterBurn() public {
        token.issueShares(investor, 1000); // At limit

        vm.expectRevert(ShareToken.ExceedsAuthorizedShares.selector);
        token.issueShares(employee, 1); // Over limit

        token.burn(investor, 100); // Burn some
        token.issueShares(employee, 100); // Now can mint
        assertEq(token.totalSupply(), 1000);
    }

    function test_IncreaseAuthorizedSharesByZeroReverts() public {
        vm.expectRevert(ShareToken.InvalidParameter.selector);
        token.increaseAuthorizedShares(0);
    }

    // ========== EVENT EMISSION TESTS ==========
    function test_SharesIssuedEvent() public {
        vm.expectEmit(true, true, false, false);
        emit SharesIssued(investor, 500);
        token.issueShares(investor, 500);
    }

    function test_AuthorizedSharesIncreasedEvent() public {
        vm.expectEmit(true, true, false, false);
        emit AuthorizedSharesIncreased(1000, 1500);
        token.increaseAuthorizedShares(500);
    }

    // ========== COMPANY ADDRESS CHANGES ==========
    function test_SetCompanyAddressGatesAdminPaths() public {
        token.setCompanyAddress(board);
        assertEq(token.companyAddress(), board);

        // Old companyAddress can no longer increase authorized shares.
        vm.expectRevert(ShareToken.OnlyCompany.selector);
        token.increaseAuthorizedShares(500);

        // New companyAddress can.
        vm.prank(board);
        token.increaseAuthorizedShares(500);
        assertEq(token.authorizedShares(), 1500);
    }

    function test_SetCompanyAddressAffectsIncreaseAuthorized() public {
        token.setCompanyAddress(board);

        // Old address cannot increase authorized shares
        vm.expectRevert(ShareToken.OnlyCompany.selector);
        token.increaseAuthorizedShares(500);

        // New company address can
        vm.prank(board);
        token.increaseAuthorizedShares(500);
        assertEq(token.authorizedShares(), 1500);
    }

    function test_SetCompanyAddressCanOnlyBeCalledOnce() public {
        token.setCompanyAddress(board);

        vm.expectRevert(ShareToken.CompanyAddressLocked.selector);
        token.setCompanyAddress(founder);
    }

    // ========== MULTI-CLASS INDEPENDENCE ==========
    function test_MultipleShareClassesIndependent() public {
        // Deploy second token
        (ShareToken token2,,) = _deployToken("APPLE CLASS B", "APPB", 2000);
        token2.setIssuanceAddress(address(this));
        token2.grantRole(token2.MINTER_ROLE(), address(this));

        token.issueShares(investor, 500);
        token2.issueShares(investor, 1000);

        assertEq(token.balanceOf(investor), 500);
        assertEq(token2.balanceOf(investor), 1000);
        assertEq(token.totalSupply(), 500);
        assertEq(token2.totalSupply(), 1000);
    }

    function test_InitializeRevertsWithZeroAddresses() public {
        ShareToken freshToken = new ShareToken();
        SnapshotEngine validSnapshot = _newSnapshotEngine(address(freshToken));
        RuleEngine validRule = new RuleEngine(address(this), address(0), address(freshToken));
        ShareholderRegistry validRegistry = new ShareholderRegistry();
        validRegistry.initialize(address(this));

        // Test 1: Zero company address
        vm.expectRevert(ShareToken.ZeroAddress.selector);
        freshToken.initialize(
            address(0), // Zero company address
            "Test Token",
            "TEST",
            1000,
            ISnapshotEngine(address(validSnapshot)),
            IRuleEngine(address(validRule)),
            validRegistry
        );

        // Test 2: Zero snapshot engine - need fresh token since initialize was attempted
        freshToken = new ShareToken();
        validSnapshot = _newSnapshotEngine(address(freshToken));
        validRule = new RuleEngine(address(this), address(0), address(freshToken));

        vm.expectRevert(ShareToken.ZeroAddress.selector);
        freshToken.initialize(
            address(this),
            "Test Token",
            "TEST",
            1000,
            ISnapshotEngine(address(0)), // Zero snapshot engine
            IRuleEngine(address(validRule)),
            validRegistry
        );

        // Test 3: Zero rule engine
        freshToken = new ShareToken();
        validSnapshot = _newSnapshotEngine(address(freshToken));

        vm.expectRevert(ShareToken.ZeroAddress.selector);
        freshToken.initialize(
            address(this),
            "Test Token",
            "TEST",
            1000,
            ISnapshotEngine(address(validSnapshot)),
            IRuleEngine(address(0)), // Zero rule engine
            validRegistry
        );

        // Test 4: Zero shareholder registry
        freshToken = new ShareToken();
        validSnapshot = _newSnapshotEngine(address(freshToken));
        validRule = new RuleEngine(address(this), address(0), address(freshToken));

        vm.expectRevert(ShareToken.ZeroAddress.selector);
        freshToken.initialize(
            address(this),
            "Test Token",
            "TEST",
            1000,
            ISnapshotEngine(address(validSnapshot)),
            IRuleEngine(address(validRule)),
            ShareholderRegistry(address(0)) // Zero registry
        );

        // Test 5: Empty name
        freshToken = new ShareToken();
        validSnapshot = _newSnapshotEngine(address(freshToken));
        validRule = new RuleEngine(address(this), address(0), address(freshToken));

        vm.expectRevert(ShareToken.InvalidParameter.selector);
        freshToken.initialize(
            address(this),
            "", // Empty name
            "TEST",
            1000,
            ISnapshotEngine(address(validSnapshot)),
            IRuleEngine(address(validRule)),
            validRegistry
        );

        // Test 6: Empty symbol
        freshToken = new ShareToken();
        validSnapshot = _newSnapshotEngine(address(freshToken));
        validRule = new RuleEngine(address(this), address(0), address(freshToken));

        vm.expectRevert(ShareToken.InvalidParameter.selector);
        freshToken.initialize(
            address(this),
            "Test Token",
            "", // Empty symbol
            1000,
            ISnapshotEngine(address(validSnapshot)),
            IRuleEngine(address(validRule)),
            validRegistry
        );
    }
}
