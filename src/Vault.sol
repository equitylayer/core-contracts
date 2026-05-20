// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./interfaces/IVault.sol";
import "./interfaces/ICompany.sol";

/// @title Vault
/// @notice Holds company funds (ETH and ERC20 tokens) for treasury, dividends, and repayments
/// @dev Uses Initializable pattern for EIP-1167 cloning by CompanyFactory
/// @dev Dividend reservation tracks paymentToken balance. ETH balance is independent.
contract Vault is IVault, Initializable, ReentrancyGuard, PausableUpgradeable {
    using SafeERC20 for IERC20;

    string public constant VERSION = "0.9.0";

    error OnlyCompany();
    error OnlyBoard();
    error OnlyCompanyOrBoard();
    error OnlyConvertibleNote();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error NoOp();

    ICompany public company;
    uint256 public reserved; // Reserved paymentToken for dividends

    event ETHDeposited(address indexed sender, uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event TokenDeposited(address indexed token, address indexed sender, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event DividendReserved(uint256 amount);
    event DividendReleased(uint256 amount);

    // --------------------
    // Modifiers
    // --------------------

    modifier onlyCompany() {
        if (msg.sender != address(company)) revert OnlyCompany();
        _;
    }

    modifier onlyCompanyOrBoard() {
        if (msg.sender != address(company) && msg.sender != company.board()) revert OnlyCompanyOrBoard();
        _;
    }

    modifier onlyConvertibleNote() {
        if (msg.sender != address(company.convertibleNote())) revert OnlyConvertibleNote();
        _;
    }

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    // --------------------
    // Constructor & Initialization
    // --------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Constructor is empty - initialization happens via initialize()
    /// @dev We do NOT call _disableInitializers() here because this contract
    ///      is meant to be deployed as fresh instances (not just as implementation for clones)
    constructor() {}

    /// @notice Initialize the vault with the company address
    /// @param _company The address of the company contract
    function initialize(ICompany _company) external initializer {
        if (address(_company) == address(0)) revert ZeroAddress();
        __Pausable_init();

        company = _company;
    }

    // --------------------
    // ETH Management
    // --------------------

    /// @notice Withdraw ETH from the vault
    /// @param recipient The address to receive the ETH
    /// @param amount The amount of ETH to withdraw
    /// @return success Whether the transfer succeeded
    function withdrawETH(address recipient, uint256 amount)
        external
        onlyCompanyOrBoard
        nonReentrant
        whenNotPaused
        returns (bool success)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance();

        (success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ETHWithdrawn(recipient, amount);
    }

    /// @notice Receive ETH deposits
    receive() external payable {
        emit ETHDeposited(msg.sender, msg.value);
    }

    // --------------------
    // Token Management
    // --------------------

    /// @notice Deposit ERC20 tokens into the vault
    /// @param token The address of the token to deposit
    /// @param amount The amount of tokens to deposit
    function depositToken(address token, uint256 amount) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit TokenDeposited(token, msg.sender, amount);
    }

    /// @notice Withdraw ERC20 tokens from the vault
    /// @param token The address of the token to withdraw
    /// @param recipient The address to receive the tokens
    /// @param amount The amount of tokens to withdraw
    /// @dev For paymentToken: respects dividend reservation (available = balance - reserved)
    function withdrawToken(address token, address recipient, uint256 amount)
        external
        onlyCompanyOrBoard
        nonReentrant
        whenNotPaused
    {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20 erc20 = IERC20(token);

        if (token == address(company.paymentToken())) {
            uint256 available = erc20.balanceOf(address(this)) - reserved;
            if (available < amount) revert InsufficientBalance();
        } else {
            uint256 balance = erc20.balanceOf(address(this));
            if (balance < amount) revert InsufficientBalance();
        }

        erc20.safeTransfer(recipient, amount);
        emit TokenWithdrawn(token, recipient, amount);
    }

    /// @notice Repay a convertible note in paymentToken (ConvertibleNote contract only)
    /// @param recipient The investor to receive the repayment
    /// @param amount The amount to repay (principal + interest in paymentToken)
    /// @return success Whether the transfer succeeded
    function repay(address recipient, uint256 amount)
        external
        onlyConvertibleNote
        nonReentrant
        whenNotPaused
        returns (bool success)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20 token = company.paymentToken();
        uint256 available = token.balanceOf(address(this)) - reserved;
        if (available < amount) revert InsufficientBalance();

        token.safeTransfer(recipient, amount);
        success = true;

        emit TokenWithdrawn(address(token), recipient, amount);
    }

    // --------------------
    // Dividend Management
    // --------------------

    /// @notice Reserve paymentToken funds for a declared dividend
    /// @param amount The amount to reserve
    function reserveDividend(uint256 amount) external onlyCompany {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = company.paymentToken();
        if (token.balanceOf(address(this)) < reserved + amount) revert InsufficientBalance();

        reserved += amount;
        emit DividendReserved(amount);
    }

    /// @notice Release reserved funds for a dividend
    /// @param amount The amount to release
    function releaseDividend(uint256 amount) external onlyCompany {
        if (amount == 0) revert ZeroAmount();
        if (amount > reserved) revert NoOp();

        reserved -= amount;
        emit DividendReleased(amount);
    }

    /// @notice Get the available (unreserved) paymentToken balance
    /// @return The paymentToken balance minus reserved amounts
    function availableBalance() external view returns (uint256) {
        IERC20 token = company.paymentToken();
        uint256 bal = token.balanceOf(address(this));
        return bal > reserved ? bal - reserved : 0;
    }

    // --------------------
    // Emergency Controls
    // --------------------

    /// @notice Pause all withdrawals in case of emergency
    function pause() external onlyBoard {
        _pause();
    }

    /// @notice Unpause withdrawals after emergency is resolved
    function unpause() external onlyBoard {
        _unpause();
    }
}
