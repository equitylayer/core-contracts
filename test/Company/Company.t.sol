// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import "../../src/mixins/CompanyStorage.sol";
import "../../src/SAFE.sol";
import "../../src/interfaces/ISAFE.sol";
import "../../src/Fundraise.sol";
import "../../src/interfaces/IFundraise.sol";
import "../../src/ConvertibleNote.sol";
import "../../src/interfaces/IConvertibleNote.sol";
import {IDataRoom} from "../../src/interfaces/IDataRoom.sol";
import {EquityIssuance} from "../../src/EquityIssuance.sol";

/// @title CompanyTest
/// @notice Basic tests for Company contract
contract CompanyTest is BaseTest {
    function setUp() public {
        _baseSetUp();
        _setupCompany();
    }

    // ===== INITIALIZATION TESTS =====
    function test_InitialState() public view {
        assertEq(company.board(), board);
        assertEq(company.name(), "Test Company Inc");
        assertEq(company.ticker(), "TEST");
        assertEq(company.metadataURI(), "ipfs://test-metadata");

        assertEq(address(company.vault()), address(vault));
        assertEq(address(company.factory()), address(factory));

        assertEq(address(company.getShareClass("Common").token), address(shareToken));
        assertEq(shareToken.authorizedShares(), 1000000);
        assertEq(shareToken.totalSupply(), 0);
    }

    struct CompanyDeps {
        Company c;
        ShareholderRegistry registry;
        VestingSchedule vesting;
        OptionPool optionPool;
        SAFE safeContract;
        Fundraise fundraise;
        ConvertibleNote note;
        EquityIssuance issuanceContract;
    }

    function _deployCompanyDeps() internal returns (CompanyDeps memory d) {
        d.c = new Company();
        d.registry = new ShareholderRegistry();
        d.vesting = new VestingSchedule();
        d.optionPool = new OptionPool();
        d.safeContract = new SAFE();
        d.fundraise = new Fundraise();
        d.note = new ConvertibleNote();
        d.issuanceContract = new EquityIssuance();

        d.registry.initialize(address(d.c));
        d.vesting.initialize(address(d.c));
        d.optionPool.initialize(address(d.c));
        d.fundraise.initialize(address(d.c));
        d.issuanceContract.initialize(address(d.c), address(d.fundraise), address(conversionVerifier));
        d.safeContract.initialize(address(d.c), address(d.fundraise), address(d.issuanceContract));
        d.note.initialize(address(d.c), address(d.fundraise), address(d.issuanceContract), address(cnRepayVerifier));
    }

    function _baseInitParams(CompanyDeps memory d) internal view returns (Company.InitParams memory) {
        return Company.InitParams({
            board: board,
            vault: IVault(address(vault)),
            factory: ICompanyFactory(address(factory)),
            shareholderRegistry: d.registry,
            vestingSchedule: d.vesting,
            optionPool: d.optionPool,
            safe: ISAFE(address(d.safeContract)),
            fundraise: IFundraise(address(d.fundraise)),
            convertibleNote: IConvertibleNote(address(d.note)),
            issuance: IEquityIssuance(address(d.issuanceContract)),
            dataRoom: IDataRoom(address(1)),
            paymentToken: IERC20(address(musd)),
            name: "Test",
            ticker: "T",
            metadataUri: "",
            countryCode: 840,
            entityType: 1
        });
    }

    function test_InitializeRevertsWithZeroAddresses() public {
        // Zero board
        CompanyDeps memory d = _deployCompanyDeps();
        Company.InitParams memory p = _baseInitParams(d);
        p.board = address(0);
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero factory
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.factory = ICompanyFactory(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero shareholderRegistry
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.shareholderRegistry = ShareholderRegistry(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero vestingSchedule
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.vestingSchedule = VestingSchedule(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero optionPool
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.optionPool = OptionPool(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero SAFE
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.safe = ISAFE(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero fundraise
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.fundraise = IFundraise(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero convertibleNote
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.convertibleNote = IConvertibleNote(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);

        // Zero issuance
        d = _deployCompanyDeps();
        p = _baseInitParams(d);
        p.issuance = IEquityIssuance(address(0));
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        d.c.initialize(p);
    }

    // ===== ACCESS CONTROL TESTS =====
    function test_OnlyBoardCanCallBoardOnlyFunctions() public {
        vm.startPrank(nonBoard);

        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.setCompanyTicker("FAIL");

        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.proposeBoardTransfer(address(0x9999), "");

        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.increaseAuthorizedShares("Common", 1000, "");

        vm.stopPrank();
    }

    function test_OnlyBoardCanSetTicker() public {
        vm.prank(board);
        company.setCompanyTicker("NEWTEST");
        assertEq(company.ticker(), "NEWTEST");
    }

    function test_OnlyBoardCanProposeTransfer() public {
        vm.prank(board);
        company.proposeBoardTransfer(address(0x9999), "");
        assertEq(company.proposedBoard(), address(0x9999));
    }

    // ===== SHARE AUTHORIZATION TESTS =====
    function test_IncreaseAuthorizedShares() public {
        vm.prank(board);
        company.increaseAuthorizedShares("Common", 500000, "");
        assertEq(shareToken.authorizedShares(), 1000000 + 500000);
    }

    function test_IncreaseAuthorizedSharesRevertsWithZeroAmount() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAmount.selector);
        company.increaseAuthorizedShares("Common", 0, "");
    }

    function test_IncreaseAuthorizedSharesRevertsForNonExistentClass() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.NotFound.selector);
        company.increaseAuthorizedShares("Preferred", 1000, "");
    }

    // ===== SHARE CLASS TESTS =====
    function test_GetShareClassNames() public view {
        string[] memory names = company.getShareClassNames();
        assertEq(names.length, 1);
        assertEq(names[0], "Common");
    }

    function test_GetShareClassCount() public view {
        assertEq(company.getShareClassCount(), 1);
    }

    function test_GetShareToken() public view {
        ShareToken token = company.getShareToken("Common");
        assertEq(address(token), address(shareToken));
    }

    // ===== SHARE ISSUANCE TESTS =====
    function test_IssueShares() public {
        vm.prank(board);
        issuance.issueGrant("Common", investor, 100, "seed investment", "");
        assertEq(shareToken.balanceOf(investor), 100);
        assertEq(shareToken.totalSupply(), 100);
    }

    function test_IssueSharesAllValidations() public {
        // 1. Non-board cannot issue
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        issuance.issueGrant("Common", investor, 100, "investment", "");

        // 2. Zero address recipient
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        issuance.issueGrant("Common", address(0), 100, "investment", "");

        // 3. Zero amount
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAmount.selector);
        issuance.issueGrant("Common", investor, 0, "investment", "");

        // 4. Non-existent share class
        vm.prank(board);
        vm.expectRevert(CompanyStorage.NotFound.selector);
        issuance.issueGrant("Preferred", investor, 100, "investment", "");
    }

    function test_IssueSharesRevertsWhenExceedingAuthorizedShares() public {
        vm.prank(board);
        vm.expectRevert(ShareToken.ExceedsAuthorizedShares.selector);
        issuance.issueGrant("Common", investor, 1000001, "too many shares", "");
    }

    function test_IssueSharesRevertsForProtectedAddresses() public {
        OptionPool _optionPool = company.optionPool();
        SAFE _safe = SAFE(address(company.safe()));
        ShareholderRegistry _registry = company.shareholderRegistry();

        vm.startPrank(board);

        // Cannot issue to company itself
        vm.expectRevert(EquityIssuance.NoOp.selector);
        issuance.issueGrant("Common", address(company), 100, "investment", "");

        // Cannot issue to board
        vm.expectRevert(EquityIssuance.NoOp.selector);
        issuance.issueGrant("Common", board, 100, "investment", "");

        // Cannot issue to option pool
        vm.expectRevert(EquityIssuance.NoOp.selector);
        issuance.issueGrant("Common", address(_optionPool), 100, "investment", "");

        // Cannot issue to SAFE
        vm.expectRevert(EquityIssuance.NoOp.selector);
        issuance.issueGrant("Common", address(_safe), 100, "investment", "");

        // Cannot issue to shareholder registry
        vm.expectRevert(EquityIssuance.NoOp.selector);
        issuance.issueGrant("Common", address(_registry), 100, "investment", "");

        // Cannot issue to share token itself
        vm.expectRevert(EquityIssuance.NoOp.selector);
        issuance.issueGrant("Common", address(shareToken), 100, "investment", "");

        vm.stopPrank();
    }

    function test_IssueSharesRevertsWhenWouldConsumeOptionPoolCapacity() public {
        OptionPool _optionPool = company.optionPool();

        // Authorized: 1,000,000 shares
        // Create option pool of 200,000
        vm.prank(board);
        _optionPool.increasePoolSize(address(shareToken), 200000, "");

        // Try to issue 900,000 shares (would leave only 100,000 for options)
        // 900,000 + 200,000 pool = 1,100,000 > 1,000,000 authorized
        vm.prank(board);
        vm.expectRevert(EquityIssuance.WouldConsumeOptionPoolCapacity.selector);
        issuance.issueGrant("Common", investor, 900000, "too many with pool", "");
    }

    function test_IssueSharesSucceedsWithOptionPoolWhenEnoughCapacity() public {
        OptionPool _optionPool = company.optionPool();

        // Authorized: 1,000,000 shares
        // Create option pool of 200,000
        vm.prank(board);
        _optionPool.increasePoolSize(address(shareToken), 200000, "");

        // Issue 700,000 shares (leaves 300,000 available, 200,000 for pool = OK)
        // 700,000 + 200,000 pool = 900,000 <= 1,000,000 authorized
        vm.prank(board);
        issuance.issueGrant("Common", investor, 700000, "with pool capacity", "");

        assertEq(shareToken.balanceOf(investor), 700000);
    }

    // ===== CREATE SHARE CLASS TESTS =====
    function test_CreateShareClassWithToken() public {
        vm.deal(board, 1 ether);
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred Series A",
            "Test Company Preferred A",
            "TCS-PA",
            500000, // authorized shares
            2e6, // 2x liquidation preference
            0, // non-voting
            0, // no par value
            ""
        );

        assertEq(company.getShareClassCount(), 2);
        string[] memory names = company.getShareClassNames();
        assertEq(names[1], "Preferred Series A");

        CompanyStorage.ShareClass memory preferredClass = company.getShareClass("Preferred Series A");
        assertEq(preferredClass.liquidationPreference, 2e6);
        assertEq(preferredClass.votingWeight, 0);
        assertTrue(address(preferredClass.token) != address(0));
    }

    function test_CreateShareClassRevertsForNonBoard() public {
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.createShareClassWithToken("Preferred", "Preferred", "PREF", 100000, 1e6, 1, 0, "");
    }

    // TODO should we revert?
    function test_CreateShareClassRevertsWithZeroAuthorizedShares() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.InvalidInput.selector);
        company.createShareClassWithToken("Preferred", "Preferred", "PREF", 0, 1e6, 1, 0, "");
    }

    function test_CreateShareClassRevertsForDuplicateClassName() public {
        vm.deal(board, 1 ether);
        vm.prank(board);
        vm.expectRevert(CompanyStorage.AlreadyExists.selector);
        company.createShareClassWithToken{value: 0.05 ether}("Common", "Duplicate", "DUP", 100000, 1e6, 1, 0, "");
    }

    function test_MaxShareClassesLimit() public {
        uint256 maxClasses = company.MAX_SHARE_CLASSES();
        assertEq(maxClasses, 10, "MAX_SHARE_CLASSES should be 10");

        // We already have 1 class (Common), so we can add 9 more
        vm.deal(board, 10 ether);
        vm.startPrank(board);
        for (uint256 i = 2; i <= maxClasses; i++) {
            string memory className = string(abi.encodePacked("Class", vm.toString(i)));
            string memory tokenName = string(abi.encodePacked("Token", vm.toString(i)));
            string memory tokenSymbol = string(abi.encodePacked("TK", vm.toString(i)));
            company.createShareClassWithToken{value: 0.05 ether}(
                className, tokenName, tokenSymbol, 10000, 1e6, 1, 0, ""
            );
        }

        assertEq(company.getShareClassCount(), maxClasses, "Should have max classes");

        vm.expectRevert(CompanyStorage.InsufficientCapacity.selector);
        company.createShareClassWithToken{value: 0.05 ether}("Excess", "Excess Token", "EXC", 10000, 1e6, 1, 0, "");
        vm.stopPrank();
    }

    // ===== VAULT MANAGEMENT TESTS =====
    function test_SetVault() public {
        Vault newVault = new Vault();
        newVault.initialize(ICompany(address(company)));

        vm.prank(board);
        company.setVault(IVault(address(newVault)));

        assertEq(address(company.vault()), address(newVault));
    }

    function test_SetVaultRevertsWithZeroAddress() public {
        vm.prank(board);
        vm.expectRevert(CompanyStorage.ZeroAddress.selector);
        company.setVault(IVault(address(0)));
    }

    function test_SetVaultRevertsForNonBoard() public {
        Vault newVault = new Vault();
        newVault.initialize(ICompany(address(company)));

        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.setVault(IVault(address(newVault)));
    }

    function test_SetVaultRevertsWhenVaultBelongsToAnotherCompany() public {
        // Deploy a second company (new signature without share class)
        vm.deal(board, 1 ether);
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Other Company", "OTHER", "ipfs://other", 840, 1, IERC20(address(musd))
        );

        // Try to set the other company's vault on our company - should fail
        vm.prank(board);
        vm.expectRevert(CompanyStorage.VaultMismatch.selector);
        company.setVault(IVault(result.vaultAddress));
    }

    // ===== METADATA TESTS =====
    function test_CompanyMetadata() public view {
        assertEq(company.name(), "Test Company Inc");
        assertEq(company.ticker(), "TEST");
        assertEq(company.metadataURI(), "ipfs://test-metadata");
    }

    function test_SetCompanyTickerRevertsForNonBoard() public {
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.setCompanyTicker("HACK");
    }

    function test_SetMetadataURI() public {
        vm.prank(board);
        vm.expectEmit(false, false, false, true);
        emit CompanyGovernance.MetadataURIUpdated("ipfs://new-logo-metadata");
        company.setMetadataURI("ipfs://new-logo-metadata");
        assertEq(company.metadataURI(), "ipfs://new-logo-metadata");
    }

    function test_SetMetadataURIRevertsForNonBoard() public {
        vm.prank(nonBoard);
        vm.expectRevert(CompanyStorage.OnlyBoard.selector);
        company.setMetadataURI("ipfs://hacker-logo");
    }

    function test_CannotIssueSharesToSelf() public {
        vm.startPrank(board);
        vm.expectRevert(EquityIssuance.NoOp.selector);
        issuance.issueGrant("Common", address(company), 1000, "test", "");
        vm.stopPrank();
    }

    // ===== FULLY DILUTED SHARES TESTS =====

    function test_GetFullyDilutedShares_NoSharesIssued() public view {
        // No shares issued, no options → fully diluted = 0
        assertEq(company.getFullyDilutedShares(), 0);
        assertEq(company.getTotalSharesOutstanding(), 0);
    }

    function test_GetFullyDilutedShares_OnlyIssuedShares() public {
        // Issue 500K shares — no options, so fullyDiluted == outstanding
        vm.prank(board);
        issuance.issueGrant("Common", investor, 500_000, "seed", "");

        assertEq(company.getTotalSharesOutstanding(), 500_000);
        assertEq(company.getFullyDilutedShares(), 500_000);
    }

    function test_GetFullyDilutedShares_WithOptionPool() public {
        OptionPool _optionPool = company.optionPool();

        // Issue 500K shares
        vm.prank(board);
        issuance.issueGrant("Common", investor, 500_000, "seed", "");

        // Set 200K option pool (unallocated)
        vm.prank(board);
        _optionPool.increasePoolSize(address(shareToken), 200_000, "");

        // fullyDiluted = 500K issued + 200K pool + 0 outstanding = 700K
        assertEq(company.getTotalSharesOutstanding(), 500_000);
        assertEq(company.getFullyDilutedShares(), 700_000);
    }

    function test_GetFullyDilutedShares_WithGrantedOptions() public {
        OptionPool _optionPool = company.optionPool();

        // Increase authorized to 10M for this test (default is 1M = 1 share at 6 decimals)
        vm.prank(board);
        company.increaseAuthorizedShares("Common", 9_000_000e6, "");

        // Record valuation for grants
        vm.prank(board);
        _optionPool.recordValuation(1e6, "ipfs://valuation");

        // Issue 500K shares
        vm.prank(board);
        issuance.issueGrant("Common", investor, 500_000e6, "seed", "");

        // Set 200K pool and grant 100K to employee (pool auto-decreases)
        vm.prank(board);
        _optionPool.increasePoolSize(address(shareToken), 200_000e6, "");
        vm.prank(board);
        _optionPool.grantOptions(employee, shareToken, 100_000e6, 0, 0, 1460 days, 1 days, true, "");

        // fullyDiluted = 500K issued + 100K pool (200K - 100K) + 100K outstanding = 700K
        assertEq(company.getTotalSharesOutstanding(), 500_000e6);
        assertEq(company.getFullyDilutedShares(), 700_000e6);
    }

    function test_GetFullyDilutedShares_MultipleShareClasses() public {
        OptionPool _optionPool = company.optionPool();

        // Issue 300K Common
        vm.prank(board);
        issuance.issueGrant("Common", investor, 300_000, "seed", "");

        // Create Preferred class
        vm.deal(board, 1 ether);
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Preferred A", "Preferred A Token", "PREF-A", 500_000, 2e6, 0, 0, ""
        );
        ShareToken prefToken = company.getShareToken("Preferred A");

        // Issue 200K Preferred
        vm.prank(board);
        issuance.issueGrant("Preferred A", investor, 200_000, "series A", "");

        // Pool on Common: 100K
        vm.prank(board);
        _optionPool.increasePoolSize(address(shareToken), 100_000, "");

        // fullyDiluted = 300K common + 200K preferred + 100K pool = 600K
        assertEq(company.getTotalSharesOutstanding(), 500_000);
        assertEq(company.getFullyDilutedShares(), 600_000);
    }

    function test_GetFullyDilutedShares_AfterExercise_Decreases() public {
        OptionPool _optionPool = company.optionPool();

        // Increase authorized to 10M for this test
        vm.prank(board);
        company.increaseAuthorizedShares("Common", 9_000_000e6, "");

        vm.prank(board);
        _optionPool.recordValuation(1e6, "ipfs://valuation");

        // Set 200K pool, grant 200K
        vm.prank(board);
        _optionPool.increasePoolSize(address(shareToken), 200_000e6, "");
        vm.prank(board);
        uint256 grantId = _optionPool.grantOptions(employee, shareToken, 200_000e6, 0, 0, 1460 days, 1 days, true, "");

        // Before exercise: fullyDiluted = 0 issued + 0 pool + 200K outstanding = 200K
        assertEq(company.getFullyDilutedShares(), 200_000e6);

        // Vest and exercise 200K
        vm.warp(block.timestamp + 1460 days);
        uint256 payment = (200_000e6 * 1e6) / 1e6;
        _mintAndApprove(employee, payment, address(_optionPool));
        vm.prank(employee);
        _optionPool.exercise(grantId, 200_000e6);

        // After exercise: fullyDiluted = 200K issued + 0 pool + 0 outstanding = 200K
        // Same total, but outstanding moved to issued
        assertEq(company.getTotalSharesOutstanding(), 200_000e6);
        assertEq(company.getFullyDilutedShares(), 200_000e6);
        assertEq(_optionPool.getOutstandingOptions(address(shareToken)), 0);
    }
}
