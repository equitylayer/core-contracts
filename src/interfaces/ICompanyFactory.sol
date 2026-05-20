// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IRuleRegistry} from "./rules/IRuleRegistry.sol";

/// @title ICompanyFactory
/// @notice Factory interface for deploying ShareToken contracts (CMTAT version)
interface ICompanyFactory {
    /// @notice Deploy a new share class (ShareToken via EIP-1167 clone)
    /// @param authorizedShares Initial authorized shares
    /// @param tokenName Token name
    /// @param tokenSymbol Token symbol
    /// @param tokenOwner Owner/admin address (Company contract)
    /// @return tokenAddress The deployed token address
    function deployShareClass(
        uint256 authorizedShares,
        string memory tokenName,
        string memory tokenSymbol,
        address tokenOwner
    ) external payable returns (address tokenAddress);

    function ruleRegistry() external view returns (IRuleRegistry);

    /// @notice Platform operator address
    function operator() external view returns (address);
}
