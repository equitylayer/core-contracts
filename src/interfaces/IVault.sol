// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ICompany} from "./ICompany.sol";

interface IVault {
    /// @notice Deposit ERC-20 tokens into the vault
    /// @param token The address of the token to deposit
    /// @param amount The amount of tokens to deposit
    function depositToken(address token, uint256 amount) external;

    /// @notice Withdraw ERC20 tokens from the vault (board or company can call)
    /// @param token The address of the token to withdraw
    /// @param recipient The address to receive the tokens
    /// @param amount The amount of tokens to withdraw
    /// @dev For paymentToken: respects dividend reservation
    function withdrawToken(address token, address recipient, uint256 amount) external;

    /// @notice Withdraw ETH from the vault (board or company can call)
    /// @param recipient The address to receive the ETH
    /// @param amount The amount of ETH to withdraw
    /// @return success Whether the transfer succeeded
    function withdrawETH(address recipient, uint256 amount) external returns (bool success);

    /// @notice Repay a convertible note in paymentToken (ConvertibleNote contract only)
    /// @param recipient The investor to receive the repayment
    /// @param amount The amount to repay (principal + interest)
    /// @return success Whether the transfer succeeded
    function repay(address recipient, uint256 amount) external returns (bool success);

    /// @notice Reserve paymentToken funds for a declared dividend
    /// @param amount The amount to reserve
    function reserveDividend(uint256 amount) external;

    /// @notice Release reserved funds for a dividend
    /// @param amount The amount to release
    function releaseDividend(uint256 amount) external;

    /// @notice Get the available (unreserved) paymentToken balance
    /// @return The paymentToken balance minus reserved amounts
    function availableBalance() external view returns (uint256);

    /// @notice Get the amount reserved for dividends
    /// @return The reserved amount
    function reserved() external view returns (uint256);

    /// @notice Get the company contract
    /// @return The company contract interface
    function company() external view returns (ICompany);

    /// @notice Pause all withdrawals in case of emergency
    function pause() external;

    /// @notice Unpause withdrawals after emergency is resolved
    function unpause() external;
}
