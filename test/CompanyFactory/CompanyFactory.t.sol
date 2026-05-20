// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import "../../src/CompanyFactory.sol";
import "../../src/Company.sol";
import "../../src/EquityIssuance.sol";
import {IEquityIssuance} from "../../src/interfaces/IEquityIssuance.sol";
import "../../src/ShareToken.sol";
import "../../src/Vault.sol";
import "../../src/SnapshotEngine.sol";
import "../../src/VestingSchedule.sol";
import "../../src/SAFE.sol";
import "../../src/Fundraise.sol";
import "../../src/ConvertibleNote.sol";
import "../../src/CompanyFactoryView.sol";
import "../../src/DataRoom.sol";
import "../../src/mocks/MockUSD.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CompanyFactoryTest is BaseTest {
    CompanyFactoryView public factoryView;

    address public user1 = address(0x4);

    event CompanyDeployed(
        uint256 indexed companyId,
        address indexed companyAddress,
        address indexed board,
        address vault,
        address vestingSchedule,
        address shareholderRegistry,
        address optionPool,
        address safe,
        address fundraise,
        address convertibleNote,
        address equityIssuance,
        address dataRoom
    );
    event ShareClassDeployed(
        address indexed company,
        address indexed token,
        address indexed ruleEngine,
        string tokenSymbol,
        uint256 authorizedShares
    );
    event DeploymentFeeUpdated(uint256 oldFee, uint256 newFee);
    event ShareClassFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeeCollected(address indexed payer, uint256 amount);
    event PaymentTokenAllowlistUpdated(address indexed token, bool allowed);

    function setUp() public {
        _baseSetUp();
        factoryView = new CompanyFactoryView(address(factory));
        vm.deal(board, 10 ether);
        vm.deal(user1, 10 ether);
    }

    // ===================
    // Initialization Tests
    // ===================

    function test_Initialize() public view {
        assertEq(factory.owner(), factoryOwner);
        assertEq(factory.treasury(), treasury);
        assertEq(factory.deploymentFee(), 0.1 ether);
        assertEq(factory.companyCount(), 0);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        factory.initialize(treasury, 0.1 ether, factoryOwner, 0.05 ether, obolosOperator);
    }

    function test_InitializeRevertsWithZeroTreasuryOrOwner() public {
        SAFE testSAFEImpl = new SAFE();
        Fundraise testFundraiseImpl = new Fundraise();
        ConvertibleNote testNoteImpl = new ConvertibleNote();
        EquityIssuance equityIssuanceImpl = new EquityIssuance();
        CompanyFactory newFactoryImpl = new CompanyFactory(
            address(new Company()),
            address(new ShareToken()),
            address(new Vault()),
            address(new VestingSchedule()),
            address(new ShareholderRegistry()),
            address(new OptionPool()),
            address(testSAFEImpl),
            address(testFundraiseImpl),
            address(testNoteImpl),
            address(equityIssuanceImpl),
            address(new SnapshotEngine()),
            address(new DataRoom()),
            address(0x1001),
            address(0x1003)
        );

        // Zero treasury
        vm.expectRevert();
        new ERC1967Proxy(
            address(newFactoryImpl),
            abi.encodeWithSelector(
                CompanyFactory.initialize.selector, address(0), 0.1 ether, factoryOwner, 0.05 ether, obolosOperator
            )
        );

        // Zero owner
        vm.expectRevert();
        new ERC1967Proxy(
            address(newFactoryImpl),
            abi.encodeWithSelector(
                CompanyFactory.initialize.selector, treasury, 0.1 ether, address(0), 0.05 ether, obolosOperator
            )
        );
    }

    function test_ConstructorRevertsWithZeroImplementations() public {
        SAFE testSAFEImpl = new SAFE();
        Fundraise testFundraiseImpl = new Fundraise();
        ConvertibleNote testNoteImpl = new ConvertibleNote();
        EquityIssuance equityIssuanceImpl = new EquityIssuance();
        Company companyImpl = new Company();
        ShareToken tokenImpl = new ShareToken();
        Vault vaultImpl = new Vault();
        VestingSchedule vestingImpl = new VestingSchedule();
        ShareholderRegistry registryImpl = new ShareholderRegistry();
        OptionPool optionPoolImpl = new OptionPool();
        SnapshotEngine snapshotEngineImpl = new SnapshotEngine();

        DataRoom dataRoomImpl = new DataRoom();

        // Zero company impl
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        new CompanyFactory(
            address(0),
            address(tokenImpl),
            address(vaultImpl),
            address(vestingImpl),
            address(registryImpl),
            address(optionPoolImpl),
            address(testSAFEImpl),
            address(testFundraiseImpl),
            address(testNoteImpl),
            address(equityIssuanceImpl),
            address(snapshotEngineImpl),
            address(dataRoomImpl),
            address(0x1001),
            address(0x1003)
        );

        // Zero token impl
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        new CompanyFactory(
            address(companyImpl),
            address(0),
            address(vaultImpl),
            address(vestingImpl),
            address(registryImpl),
            address(optionPoolImpl),
            address(testSAFEImpl),
            address(testFundraiseImpl),
            address(testNoteImpl),
            address(equityIssuanceImpl),
            address(snapshotEngineImpl),
            address(dataRoomImpl),
            address(0x1001),
            address(0x1003)
        );

        // Zero vault impl
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        new CompanyFactory(
            address(companyImpl),
            address(tokenImpl),
            address(0),
            address(vestingImpl),
            address(registryImpl),
            address(optionPoolImpl),
            address(testSAFEImpl),
            address(testFundraiseImpl),
            address(testNoteImpl),
            address(equityIssuanceImpl),
            address(snapshotEngineImpl),
            address(dataRoomImpl),
            address(0x1001),
            address(0x1003)
        );

        // Zero vesting impl
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        new CompanyFactory(
            address(companyImpl),
            address(tokenImpl),
            address(vaultImpl),
            address(0),
            address(registryImpl),
            address(optionPoolImpl),
            address(testSAFEImpl),
            address(testFundraiseImpl),
            address(testNoteImpl),
            address(equityIssuanceImpl),
            address(snapshotEngineImpl),
            address(dataRoomImpl),
            address(0x1001),
            address(0x1003)
        );

        // Zero registry impl
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        new CompanyFactory(
            address(companyImpl),
            address(tokenImpl),
            address(vaultImpl),
            address(vestingImpl),
            address(0),
            address(optionPoolImpl),
            address(testSAFEImpl),
            address(testFundraiseImpl),
            address(testNoteImpl),
            address(equityIssuanceImpl),
            address(snapshotEngineImpl),
            address(dataRoomImpl),
            address(0x1001),
            address(0x1003)
        );
    }

    // ===================
    // Deployment Tests
    // ===================

    function test_DeployCompanySuccess() public {
        vm.startPrank(board);

        vm.expectEmit(false, false, true, false);
        emit CompanyDeployed(
            0,
            address(0),
            board,
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0)
        );

        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd))
        );

        vm.stopPrank();

        assertEq(result.companyId, 1);
        assertTrue(result.companyAddress != address(0));
        assertTrue(result.vaultAddress != address(0));
        assertEq(factory.companyCount(), 1);
        assertTrue(factoryView.isCompany(result.companyAddress));
        assertEq(factoryView.getCompanyId(result.companyAddress), 1);

        Company company_ = Company(result.companyAddress);
        assertEq(company_.board(), board);
        assertEq(company_.name(), "Acme Corp");
        assertEq(company_.ticker(), "ACME");
        assertEq(address(company_.vault()), result.vaultAddress);
        assertEq(address(company_.factory()), address(factory));
        assertEq(
            address(EquityIssuance(result.equityIssuanceAddress).conversionVerifier()), factory.conversionVerifier()
        );
        assertEq(address(ConvertibleNote(result.convertibleNoteAddress).repayVerifier()), factory.cnRepayVerifier());

        Vault vault_ = Vault(payable(result.vaultAddress));
        assertEq(address(vault_.company()), result.companyAddress);

        assertEq(treasury.balance, 0.1 ether);
    }

    function test_DeployMultipleCompanies() public {
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result1 =
            factory.deployCompany{value: 0.1 ether}("Company 1", "C1", "ipfs://1", 840, 1, IERC20(address(musd)));

        vm.prank(user1);
        CompanyFactory.DeploymentResult memory result2 =
            factory.deployCompany{value: 0.1 ether}("Company 2", "C2", "ipfs://2", 840, 1, IERC20(address(musd)));

        assertEq(result1.companyId, 1);
        assertEq(result2.companyId, 2);
        assertEq(factory.companyCount(), 2);
        assertTrue(factoryView.isCompany(result1.companyAddress));
        assertTrue(factoryView.isCompany(result2.companyAddress));
        assertEq(Company(factoryView.getCompanyById(1)).board(), board);
        assertEq(Company(factoryView.getCompanyById(2)).board(), user1);
    }

    function test_DeployCompanyValidations() public {
        // Insufficient fee
        vm.prank(board);
        vm.expectRevert(CompanyFactory.InsufficientFee.selector);
        factory.deployCompany{value: 0.1 ether - 1}("Acme", "ACME", "ipfs://", 840, 1, IERC20(address(musd)));

        // Empty name
        vm.prank(board);
        vm.expectRevert(CompanyFactory.EmptyString.selector);
        factory.deployCompany{value: 0.1 ether}("", "ACME", "ipfs://", 840, 1, IERC20(address(musd)));

        // Empty ticker
        vm.prank(board);
        vm.expectRevert(CompanyFactory.EmptyString.selector);
        factory.deployCompany{value: 0.1 ether}("Acme", "", "ipfs://", 840, 1, IERC20(address(musd)));

        // When paused
        vm.prank(factoryOwner);
        factory.pause();
        vm.prank(board);
        vm.expectRevert();
        factory.deployCompany{value: 0.1 ether}("Acme", "ACME", "ipfs://", 840, 1, IERC20(address(musd)));
    }

    function test_DeployCompanyRevertsWhenPaymentTokenNotAllowlisted() public {
        MockUSD other = new MockUSD();

        vm.prank(board);
        vm.expectRevert(CompanyFactory.PaymentTokenNotAllowed.selector);
        factory.deployCompany{value: 0.1 ether}("Acme", "ACME", "ipfs://", 840, 1, IERC20(address(other)));
    }

    function test_DeployCompanyWithExcessFee() public {
        uint256 treasuryBalanceBefore = treasury.balance;
        uint256 excessFee = 0.1 ether + 1 ether;

        vm.prank(board);
        factory.deployCompany{value: excessFee}("Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd)));

        assertEq(treasury.balance, treasuryBalanceBefore + excessFee);
    }

    function test_DeployCompanyWithZeroFee() public {
        vm.prank(factoryOwner);
        factory.setDeploymentFee(0);

        vm.prank(board);
        CompanyFactory.DeploymentResult memory result =
            factory.deployCompany("Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd)));

        assertEq(result.companyId, 1);
        assertEq(factory.companyCount(), 1);
    }

    // ===================
    // Fee Collection Tests (consolidated from integration file)
    // ===================

    function test_FeeCollection() public {
        uint256 treasuryBalanceBefore = treasury.balance;
        uint256 boardBalanceBefore = board.balance;

        vm.expectEmit(true, false, false, true);
        emit FeeCollected(board, 0.1 ether);

        vm.prank(board);
        factory.deployCompany{value: 0.1 ether}("Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd)));

        assertEq(treasury.balance, treasuryBalanceBefore + 0.1 ether);
        assertEq(board.balance, boardBalanceBefore - 0.1 ether);
    }

    function test_MultipleDeploymentsCollectFees() public {
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(board);
        factory.deployCompany{value: 0.1 ether}("Company 1", "C1", "ipfs://1", 840, 1, IERC20(address(musd)));

        vm.prank(user1);
        factory.deployCompany{value: 0.1 ether}("Company 2", "C2", "ipfs://2", 840, 1, IERC20(address(musd)));

        assertEq(treasury.balance, treasuryBalanceBefore + (0.1 ether * 2));
    }

    function test_ChangeTreasuryAndDeployCollectsToNewTreasury() public {
        address newTreasury = address(0xF3);

        vm.prank(factoryOwner);
        factory.setTreasury(newTreasury);

        uint256 newTreasuryBalanceBefore = newTreasury.balance;

        vm.prank(board);
        factory.deployCompany{value: 0.1 ether}("Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd)));

        assertEq(newTreasury.balance, newTreasuryBalanceBefore + 0.1 ether);
    }

    // ===================
    // Share Class Deployment Tests
    // ===================

    function test_DeployShareClassSuccess() public {
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd))
        );

        vm.startPrank(board);
        Company company_ = Company(result.companyAddress);

        vm.expectEmit(true, false, false, false);
        emit ShareClassDeployed(result.companyAddress, address(1), address(0), "", 0);

        company_.createShareClassWithToken{value: 0.05 ether}(
            "Preferred", "Acme Preferred", "ACME-P", 500000, 1e6, 1, 0, ""
        );
        vm.stopPrank();

        assertEq(company_.getShareClassCount(), 1);
        ShareToken token = company_.getShareToken("Preferred");
        assertTrue(address(token) != address(0));
        assertEq(token.name(), "Acme Preferred");
        assertEq(token.symbol(), "ACME-P");
        assertEq(token.authorizedShares(), 500000);
        assertTrue(token.hasRole(keccak256("MINTER_ROLE"), result.companyAddress));
        assertTrue(token.hasRole(0x00, board));
        assertTrue(token.hasRole(0x00, result.companyAddress));
    }

    function test_DeployShareClassValidations() public {
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd))
        );

        // Not registered company
        vm.deal(address(this), 1 ether);
        vm.expectRevert(CompanyFactory.NotRegisteredCompany.selector);
        factory.deployShareClass{value: 0.05 ether}(1000000, "Test Token", "TEST", board);

        // Zero owner
        vm.deal(result.companyAddress, 1 ether);
        vm.prank(result.companyAddress);
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        factory.deployShareClass{value: 0.05 ether}(1000000, "Test Token", "TEST", address(0));

        // Zero shares
        vm.prank(result.companyAddress);
        vm.expectRevert(CompanyFactory.EmptyString.selector);
        factory.deployShareClass{value: 0.05 ether}(0, "Test Token", "TEST", board);
    }

    // ===================
    // Admin Function Tests
    // ===================

    function test_SetDeploymentFee() public {
        uint256 newFee = 0.5 ether;
        vm.prank(factoryOwner);
        vm.expectEmit(true, true, false, false);
        emit DeploymentFeeUpdated(0.1 ether, newFee);
        factory.setDeploymentFee(newFee);
        assertEq(factory.deploymentFee(), newFee);

        // Non-owner reverts
        vm.prank(board);
        vm.expectRevert();
        factory.setDeploymentFee(0.5 ether);
    }

    function test_SetShareClassFee() public {
        uint256 newFee = 0.1 ether;
        vm.prank(factoryOwner);
        vm.expectEmit(true, true, false, false);
        emit ShareClassFeeUpdated(0.05 ether, newFee);
        factory.setShareClassFee(newFee);
        assertEq(factory.shareClassFee(), newFee);

        // Non-owner reverts
        vm.prank(board);
        vm.expectRevert();
        factory.setShareClassFee(0.1 ether);
    }

    function test_SetTreasury() public {
        address newTreasury = address(0x999);
        vm.prank(factoryOwner);
        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(treasury, newTreasury);
        factory.setTreasury(newTreasury);
        assertEq(factory.treasury(), newTreasury);

        // Zero address reverts
        vm.prank(factoryOwner);
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        factory.setTreasury(address(0));

        // Non-owner reverts
        vm.prank(board);
        vm.expectRevert();
        factory.setTreasury(address(0x999));
    }

    function test_AddPaymentTokenToAllowlist() public {
        MockUSD other = new MockUSD();

        assertFalse(factoryView.isPaymentTokenAllowed(address(other)));

        vm.prank(factoryOwner);
        vm.expectEmit(true, false, false, true);
        emit PaymentTokenAllowlistUpdated(address(other), true);
        factory.addPaymentTokenToAllowlist(address(other));

        assertTrue(factoryView.isPaymentTokenAllowed(address(other)));
        assertEq(factory.paymentTokenAllowlist(1), address(other));
    }

    function test_RemovePaymentTokenFromAllowlist() public {
        MockUSD other = new MockUSD();

        vm.prank(factoryOwner);
        factory.addPaymentTokenToAllowlist(address(other));
        assertTrue(factoryView.isPaymentTokenAllowed(address(other)));

        vm.prank(factoryOwner);
        vm.expectEmit(true, false, false, true);
        emit PaymentTokenAllowlistUpdated(address(other), false);
        factory.removePaymentTokenFromAllowlist(address(other));

        assertFalse(factoryView.isPaymentTokenAllowed(address(other)));
    }

    function test_PaymentTokenAllowlistIsIdempotent() public {
        // Adding already-allowed token is a no-op
        vm.prank(factoryOwner);
        factory.addPaymentTokenToAllowlist(address(musd));
        assertEq(factory.paymentTokenAllowlist(0), address(musd));

        // Remove it
        vm.prank(factoryOwner);
        factory.removePaymentTokenFromAllowlist(address(musd));
        assertFalse(factoryView.isPaymentTokenAllowed(address(musd)));

        // Removing already-removed token is a no-op
        vm.prank(factoryOwner);
        factory.removePaymentTokenFromAllowlist(address(musd));
        assertFalse(factoryView.isPaymentTokenAllowed(address(musd)));
    }

    function test_PaymentTokenAllowlistValidations() public {
        vm.prank(factoryOwner);
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        factory.addPaymentTokenToAllowlist(address(0));

        vm.prank(factoryOwner);
        vm.expectRevert(CompanyFactory.ZeroAddress.selector);
        factory.removePaymentTokenFromAllowlist(address(0));

        vm.prank(board);
        vm.expectRevert();
        factory.removePaymentTokenFromAllowlist(address(musd));
    }

    function test_PauseUnpause() public {
        vm.prank(factoryOwner);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(factoryOwner);
        factory.unpause();
        assertFalse(factory.paused());

        // Non-owner reverts for both
        vm.prank(board);
        vm.expectRevert();
        factory.pause();

        vm.prank(factoryOwner);
        factory.pause();
        vm.prank(board);
        vm.expectRevert();
        factory.unpause();
    }

    // ===================
    // View Function Tests
    // ===================

    function test_GetCompanyByIdRevertsWithInvalidId() public {
        vm.expectRevert(CompanyFactoryView.InvalidCompanyId.selector);
        factoryView.getCompanyById(0);

        vm.expectRevert(CompanyFactoryView.InvalidCompanyId.selector);
        factoryView.getCompanyById(999);
    }

    function test_GetCompanyIdReturnsZeroForUnregistered() public view {
        assertEq(factoryView.getCompanyId(address(0x9999)), 0);
    }

    function test_IsCompanyReturnsFalseForUnregistered() public view {
        assertFalse(factoryView.isCompany(address(0x9999)));
    }

    function test_PaymentTokenAllowlistView() public view {
        assertEq(factory.paymentTokenAllowlist(0), address(musd));
    }

    // ===================
    // Integration Tests
    // ===================

    function test_IntegrationChangeFeeAndDeploy() public {
        uint256 newFee = 0.05 ether;
        vm.prank(factoryOwner);
        factory.setDeploymentFee(newFee);

        vm.prank(board);
        CompanyFactory.DeploymentResult memory result =
            factory.deployCompany{value: newFee}("Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd)));

        assertEq(result.companyId, 1);
        assertEq(treasury.balance, newFee);
    }

    function test_IntegrationMultipleShareClasses() public {
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd))
        );

        Company company_ = Company(result.companyAddress);

        vm.startPrank(board);
        company_.createShareClassWithToken{value: 0.05 ether}("Common", "Acme Common", "ACME-C", 1000000, 1e6, 1, 0, "");
        company_.createShareClassWithToken{value: 0.05 ether}(
            "Preferred", "Acme Preferred", "ACME-P", 500000, 2e6, 0, 0, ""
        );
        vm.stopPrank();

        assertEq(company_.getShareClassCount(), 2);

        address commonToken = address(company_.getShareToken("Common"));
        address preferredToken = address(company_.getShareToken("Preferred"));
        assertTrue(commonToken != address(0));
        assertTrue(preferredToken != address(0));
        assertTrue(commonToken != preferredToken);

        // Use this test's company's issuance, not the BaseTest one.
        IEquityIssuance issuance_ = company_.issuance();
        vm.startPrank(board);
        issuance_.issueGrant("Common", investor, 100000, "common", "");
        issuance_.issueGrant("Preferred", investor, 50000, "preferred", "");
        vm.stopPrank();

        assertEq(ShareToken(commonToken).balanceOf(investor), 100000);
        assertEq(ShareToken(preferredToken).balanceOf(investor), 50000);
    }

    function test_SnapshotEngineTokenIsImmutable() public {
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Test Company", "TEST", "ipfs://test", 840, 1, IERC20(address(musd))
        );

        Company company_ = Company(result.companyAddress);
        vm.prank(board);
        company_.createShareClassWithToken{value: 0.05 ether}("Common", "Test Shares", "TEST-C", 1000000, 1e6, 1, 0, "");

        ShareToken token = company_.getShareToken("Common");
        SnapshotEngine se = SnapshotEngine(address(token.snapshotEngine()));

        assertEq(address(se.token()), address(token));
    }

    // ===================
    // Fuzz Tests
    // ===================

    function test_FuzzDeploymentFee(uint256 fee) public {
        vm.assume(fee <= 10 ether);

        vm.prank(factoryOwner);
        factory.setDeploymentFee(fee);
        assertEq(factory.deploymentFee(), fee);

        vm.prank(board);
        factory.deployCompany{value: fee}("Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd)));
        assertEq(factory.companyCount(), 1);
    }

    function test_FuzzFeeCollection(uint256 fee) public {
        vm.assume(fee <= 10 ether);

        vm.prank(factoryOwner);
        factory.setDeploymentFee(fee);

        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(board);
        factory.deployCompany{value: fee}("Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd)));

        assertEq(treasury.balance, treasuryBalanceBefore + fee);
    }

    // ===================
    // Security: Role Management Tests
    // ===================

    function test_FactoryDoesNotRetainAdminRoles() public {
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");

        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Test Company", "TEST", "ipfs://test", 840, 1, IERC20(address(musd))
        );

        vm.deal(result.companyAddress, 1 ether);
        vm.prank(result.companyAddress);
        address newTokenAddr = factory.deployShareClass{value: 0.05 ether}(1000000, "Preferred", "TEST-PA", board);

        ShareToken newToken = ShareToken(newTokenAddr);
        SnapshotEngine newSnapshotEngine = SnapshotEngine(address(newToken.snapshotEngine()));
        address newRuleEngine = address(newToken.ruleEngine());

        assertFalse(newToken.hasRole(DEFAULT_ADMIN_ROLE, address(factory)));
        assertFalse(newSnapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, address(factory)));
        assertTrue(newToken.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertTrue(newToken.hasRole(DEFAULT_ADMIN_ROLE, result.companyAddress));
        assertTrue(newSnapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, board));
        assertTrue(newSnapshotEngine.hasRole(DEFAULT_ADMIN_ROLE, result.companyAddress));
        assertTrue(IAccessControl(newRuleEngine).hasRole(DEFAULT_ADMIN_ROLE, board));
        assertTrue(IAccessControl(newRuleEngine).hasRole(DEFAULT_ADMIN_ROLE, result.companyAddress));
        assertTrue(newSnapshotEngine.hasRole(SNAPSHOOTER_ROLE, board));
        assertTrue(newToken.hasRole(MINTER_ROLE, result.companyAddress));
    }

    // ===================
    // Vesting Deployment Tests
    // ===================

    function test_DeployVestingSchedule() public {
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: 0.1 ether}(
            "Test Company", "TEST", "ipfs://test", 840, 1, IERC20(address(musd))
        );

        assertTrue(result.vestingAddress != address(0));
        VestingSchedule vesting = VestingSchedule(result.vestingAddress);
        assertEq(address(vesting.company()), result.companyAddress);
        assertEq(address(Company(result.companyAddress).vestingSchedule()), result.vestingAddress);
    }

    // ============ Helper Method Tests ============

    function test_GetMyCompanies() public {
        vm.prank(board);
        factory.deployCompany{value: 0.1 ether}("Company 1", "C1", "ipfs://1", 840, 1, IERC20(address(musd)));

        vm.prank(user1);
        factory.deployCompany{value: 0.1 ether}("Company 2", "C2", "ipfs://2", 840, 1, IERC20(address(musd)));

        vm.prank(board);
        address[] memory boardCompanies = factoryView.getMyCompanies();
        assertEq(boardCompanies.length, 1);
        assertEq(Company(boardCompanies[0]).board(), board);

        vm.prank(user1);
        address[] memory user1Companies = factoryView.getMyCompanies();
        assertEq(user1Companies.length, 1);
        assertEq(Company(user1Companies[0]).board(), user1);

        vm.prank(address(0x9999));
        address[] memory noCompanies = factoryView.getMyCompanies();
        assertEq(noCompanies.length, 0);
    }

    function test_GetMyCompaniesReturnsMultiple() public {
        vm.startPrank(board);
        factory.deployCompany{value: 0.1 ether}("Company 1", "C1", "ipfs://1", 840, 1, IERC20(address(musd)));
        factory.deployCompany{value: 0.1 ether}("Company 2", "C2", "ipfs://2", 840, 1, IERC20(address(musd)));
        factory.deployCompany{value: 0.1 ether}("Company 3", "C3", "ipfs://3", 840, 1, IERC20(address(musd)));
        vm.stopPrank();

        vm.prank(board);
        address[] memory companies = factoryView.getMyCompanies();
        assertEq(companies.length, 3);
    }

    function test_GetCompaniesForBoard() public {
        vm.prank(board);
        factory.deployCompany{value: 0.1 ether}("Company 1", "C1", "ipfs://1", 840, 1, IERC20(address(musd)));

        vm.prank(user1);
        factory.deployCompany{value: 0.1 ether}("Company 2", "C2", "ipfs://2", 840, 1, IERC20(address(musd)));

        vm.prank(board);
        factory.deployCompany{value: 0.1 ether}("Company 3", "C3", "ipfs://3", 840, 1, IERC20(address(musd)));

        vm.prank(user1);
        factory.deployCompany{value: 0.1 ether}("Company 4", "C4", "ipfs://4", 840, 1, IERC20(address(musd)));

        address[] memory boardCompanies = factoryView.getCompaniesForBoard(board);
        assertEq(boardCompanies.length, 2);
        assertEq(Company(boardCompanies[0]).name(), "Company 1");
        assertEq(Company(boardCompanies[1]).name(), "Company 3");

        address[] memory user1Companies = factoryView.getCompaniesForBoard(user1);
        assertEq(user1Companies.length, 2);
        assertEq(Company(user1Companies[0]).name(), "Company 2");
        assertEq(Company(user1Companies[1]).name(), "Company 4");

        address[] memory empty = factoryView.getCompaniesForBoard(address(0x12345));
        assertEq(empty.length, 0);
    }

    function test_CompanyFactoryViewConstructor() public view {
        assertEq(address(factoryView.factory()), address(factory));
    }
}
