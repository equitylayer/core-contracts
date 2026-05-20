// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import "../../src/CompanyFactory.sol";
import "../../src/Company.sol";
import {IEquityIssuance} from "../../src/interfaces/IEquityIssuance.sol";
import "../../src/ShareToken.sol";
import "../../src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CompanyFactoryIntegrationTest
/// @notice End-to-end lifecycle integration tests for factory-deployed companies.
///         Fee collection and admin tests live in CompanyFactory.t.sol.
contract CompanyFactoryIntegrationTest is BaseTest {
    address public board2 = address(0xB2);

    function setUp() public {
        _baseSetUp();
        vm.deal(board, 10 ether);
        vm.deal(board2, 10 ether);
        vm.deal(investor, 10 ether);
    }

    function test_FullCompanyLifecycleWithFees() public {
        uint256 deploymentFee = factory.deploymentFee();

        // 1. Deploy company with fee
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result = factory.deployCompany{value: deploymentFee}(
            "Acme Corp", "ACME", "ipfs://metadata", 840, 1, IERC20(address(musd))
        );

        // Verify deployment
        assertEq(result.companyId, 1);
        assertTrue(factory.companyToId(result.companyAddress) != 0);

        Company company = Company(result.companyAddress);
        Vault vault = Vault(payable(result.vaultAddress));

        // 2. Verify initialization
        assertEq(company.board(), board);
        assertEq(address(company.vault()), result.vaultAddress);
        assertEq(address(vault.company()), result.companyAddress);

        // 3. Create share class
        uint256 shareClassFee = factory.shareClassFee();
        vm.prank(board);
        company.createShareClassWithToken{value: shareClassFee}(
            "Common", "Acme Common", "ACME-C", 1000000, 1e6, 1, 0, ""
        );

        address tokenAddr = address(company.getShareToken("Common"));
        ShareToken token = ShareToken(tokenAddr);

        // 4. Issue shares. Use THIS company's issuance, not the BaseTest one.
        IEquityIssuance issuance_ = company.issuance();
        vm.prank(board);
        issuance_.issueGrant("Common", investor, 50000, "initial allocation", "");
        assertEq(token.balanceOf(investor), 50000);

        // 5. Fund vault
        vm.deal(result.companyAddress, 10 ether);
        (bool success,) = result.vaultAddress.call{value: 5 ether}("");
        require(success, "vault funding failed");
        assertEq(result.vaultAddress.balance, 5 ether);

        // 6. Withdraw ETH from vault
        vm.prank(result.companyAddress);
        vault.withdrawETH(investor, 1 ether);
        assertEq(investor.balance, 10 ether + 1 ether);
    }

    function test_TwoCompaniesIndependentOperations() public {
        uint256 deploymentFee = factory.deploymentFee();
        uint256 shareClassFee = factory.shareClassFee();

        // Deploy two companies with fees
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result1 =
            factory.deployCompany{value: deploymentFee}("Company 1", "C1", "ipfs://1", 840, 1, IERC20(address(musd)));

        vm.prank(board2);
        CompanyFactory.DeploymentResult memory result2 =
            factory.deployCompany{value: deploymentFee}("Company 2", "C2", "ipfs://2", 840, 1, IERC20(address(musd)));

        // Create Common share class for company 1
        vm.prank(board);
        Company(result1.companyAddress).createShareClassWithToken{value: shareClassFee}(
            "Common", "Company 1 Common", "C1-C", 1000000, 1e6, 1, 0, ""
        );

        // Create Common share class for company 2
        vm.prank(board2);
        Company(result2.companyAddress).createShareClassWithToken{value: shareClassFee}(
            "Common", "Company 2 Common", "C2-C", 1000000, 1e6, 1, 0, ""
        );

        // Issue shares from both companies. Cache issuance refs before pranking; the
        // chained `Company(...).issuance().issueGrant(...)` form would burn the prank
        // on the getter call.
        IEquityIssuance issuance1 = Company(result1.companyAddress).issuance();
        IEquityIssuance issuance2 = Company(result2.companyAddress).issuance();

        vm.prank(board);
        issuance1.issueGrant("Common", investor, 10000, "c1 allocation", "");

        vm.prank(board2);
        issuance2.issueGrant("Common", investor, 20000, "c2 allocation", "");

        // Get token addresses from companies
        address token1Addr = address(Company(result1.companyAddress).getShareToken("Common"));
        address token2Addr = address(Company(result2.companyAddress).getShareToken("Common"));

        // Verify balances are independent
        assertEq(ShareToken(token1Addr).balanceOf(investor), 10000);
        assertEq(ShareToken(token2Addr).balanceOf(investor), 20000);

        // Verify companies are independent
        assertTrue(result1.companyAddress != result2.companyAddress);
        assertTrue(token1Addr != token2Addr);
    }
}
