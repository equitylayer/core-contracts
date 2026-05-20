// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IShareToken
 * @notice Interface for ShareToken with burn functionality
 */
interface IShareToken is IERC20 {
    /**
     * @notice Burn tokens from an account
     * @param account The account to burn from
     * @param value The amount to burn
     * @dev Requires BURNER_ROLE
     */
    function burn(address account, uint256 value) external;
}
