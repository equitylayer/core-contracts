// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ICompany} from "./interfaces/ICompany.sol";
import {CompanyFactory} from "./CompanyFactory.sol";

/// @title CompanyFactoryView
/// @notice View helper for CompanyFactory (separated to reduce factory bytecode)
contract CompanyFactoryView {
    string public constant VERSION = "0.9.0";

    CompanyFactory public immutable factory;

    error InvalidCompanyId();

    constructor(address _factory) {
        factory = CompanyFactory(_factory);
    }

    /// @notice Get deployed company address by ID
    function getCompanyById(uint256 companyId) external view returns (address) {
        if (companyId == 0 || companyId > factory.companyCount()) revert InvalidCompanyId();
        return factory.companyRegistry(companyId);
    }

    /// @notice Get company ID by company address
    function getCompanyId(address company) external view returns (uint256) {
        return factory.companyToId(company);
    }

    /// @notice Check if an address is a deployed company
    function isCompany(address company) external view returns (bool) {
        return factory.companyToId(company) != 0;
    }

    /// @notice If token is in allowlist as company payment token
    function isPaymentTokenAllowed(address token) external view returns (bool) {
        return factory.paymentTokenAllowed(token);
    }

    /// @notice Get all companies where caller is the board
    /// @return companies Array of company addresses controlled by caller
    function getMyCompanies() external view returns (address[] memory companies) {
        uint256 total = factory.companyCount();
        uint256 matches;

        for (uint256 i = 1; i <= total; i++) {
            address c = factory.companyRegistry(i);
            if (ICompany(c).board() == msg.sender) matches++;
        }

        companies = new address[](matches);
        uint256 idx;

        for (uint256 i = 1; i <= total; i++) {
            address c = factory.companyRegistry(i);
            if (ICompany(c).board() == msg.sender) {
                companies[idx++] = c;
            }
        }
    }

    /// @notice Get all companies where a specific address is the board
    function getCompaniesForBoard(address board) external view returns (address[] memory companies) {
        uint256 total = factory.companyCount();
        uint256 matches;

        for (uint256 i = 1; i <= total; i++) {
            address c = factory.companyRegistry(i);
            if (ICompany(c).board() == board) matches++;
        }

        companies = new address[](matches);
        uint256 idx;

        for (uint256 i = 1; i <= total; i++) {
            address c = factory.companyRegistry(i);
            if (ICompany(c).board() == board) {
                companies[idx++] = c;
            }
        }
    }
}
