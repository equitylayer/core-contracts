// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICompany} from "./interfaces/ICompany.sol";
import {ShareToken} from "./ShareToken.sol";

/**
 * @title OptionPool
 * @notice Manages employee stock options with on-demand share minting
 * @dev Shares are NOT pre-minted. They are minted at exercise time, matching real-world cap table practices.
 *
 * Key Features:
 * - Grant options with strike prices based on FMV valuations
 * - Exercise options by paying strike price (shares minted on-demand)
 * - Vesting integration with VestingSchedule contract
 * - Tax-advantaged vs standard designation (ISO/EMI/BSPCE per jurisdiction)
 * - Option expiration and revocation support
 * - Pool capacity checks against authorized shares
 */
contract OptionPool is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "0.9.0";

    struct OptionGrant {
        address employee;
        ShareToken shareToken;
        uint256 amount; // Total options granted
        uint256 exercised; // How many exercised so far
        uint256 strikePrice; // Price per share (in payment token units, based on FMV)
        uint256 grantDate;
        uint256 cliffDuration; // Cliff period (e.g., 365 days)
        uint256 vestingDuration; // Total vesting period (e.g., 1460 days = 4 years)
        uint256 vestingInterval; // Vesting granularity in seconds (e.g., 1 days, 7 days, 30 days, 90 days)
        uint256 expirationDate; // Usually 10 years from grant
        uint256 revokedAt; // Timestamp when revoked (0 if not revoked)
        bool isTaxAdvantaged; // Tax-advantaged (e.g., ISO, EMI, BSPCE) vs standard
        bool revoked;
    }

    struct ValuationRecord {
        uint256 date;
        uint256 fairMarketValue;
        string documentRef;
    }

    ICompany public company;
    ValuationRecord[] public valuations;

    uint256 public nextGrantId;
    mapping(uint256 => OptionGrant) public optionGrants;
    mapping(address => uint256[]) public employeeGrants;
    mapping(address => uint256) public outstandingOptionsByToken;
    mapping(address => uint256) public poolSizeByToken;

    // ========== ERRORS ==========

    // Access control
    error OnlyBoard();
    error OnlyEmployee();

    // Input validation
    error ZeroAddress();
    error ZeroAmount();
    error InvalidAmount();
    error InvalidGrantId();

    // State errors
    error InvalidState();

    // Critical safety
    error InsufficientAuthorizedShares();
    error NoValuationOnRecord();
    error NoPoolConfigured();
    error InsufficientPoolCapacity();
    error PoolTooSmall();
    error InvalidShareToken();

    // ========== EVENTS ==========

    event ValuationRecorded(uint256 indexed valuationIndex, uint256 fmv, uint256 timestamp, string documentRef);
    event OptionsGranted(
        uint256 indexed grantId,
        address indexed employee,
        uint256 amount,
        uint256 strikePrice,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 vestingInterval,
        bool isTaxAdvantaged,
        string documentRef
    );
    event OptionsExercised(
        uint256 indexed grantId, address indexed employee, uint256 amount, uint256 payment, uint256 timestamp
    );
    event GrantRevoked(
        uint256 indexed grantId,
        address indexed employee,
        uint256 vestedAmount,
        uint256 unvestedAmount,
        string documentRef
    );
    event ExpiredGrantCleaned(uint256 indexed grantId, address indexed token, uint256 amountReleased);
    event PoolSizeIncreased(address indexed token, uint256 previousSize, uint256 newSize, string documentRef);
    event PoolSizeDecreased(address indexed token, uint256 previousSize, uint256 newSize, string documentRef);

    // ========== MODIFIERS ==========

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    // ========== INITIALIZATION ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {}

    /**
     * @notice Initialize the option pool contract
     * @param _company Company that owns this option pool
     */
    function initialize(address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();
        company = ICompany(_company);
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Record a fair market value (FMV) valuation
     * @param fmv Fair market value per share (in payment token units)
     * @param documentRef Optional doc (obolos:// URI or hash) for the valuation report (409A / HMRC / etc.)
     *
     * @dev Required before granting options (strike price = FMV)
     * @dev Typically updated annually or after financing rounds
     */
    function recordValuation(uint256 fmv, string calldata documentRef) external onlyBoard {
        if (fmv == 0) revert ZeroAmount();
        valuations.push(ValuationRecord({date: block.timestamp, fairMarketValue: fmv, documentRef: documentRef}));

        emit ValuationRecorded(valuations.length - 1, fmv, block.timestamp, documentRef);
    }

    /**
     * @notice Increase the option pool size (or establish initial pool)
     * @param token The share token address
     * @param increaseAmount Amount to increase the pool by
     *
     * @dev May require increasing authorized shares first
     */
    function increasePoolSize(address token, uint256 increaseAmount, string calldata documentRef) external onlyBoard {
        if (token == address(0)) revert ZeroAddress();
        if (increaseAmount == 0) revert ZeroAmount();

        ShareToken shareToken = ShareToken(token);

        if (shareToken.companyAddress() != address(company)) revert InvalidShareToken();

        uint256 currentPool = poolSizeByToken[token];
        uint256 newPool = currentPool + increaseAmount;

        uint256 issued = shareToken.totalSupply();
        uint256 authorized = shareToken.authorizedShares();
        uint256 outstanding = outstandingOptionsByToken[token];

        // Total allocation check: issued + pool + outstanding <= authorized
        if (issued + newPool + outstanding > authorized) {
            revert InsufficientAuthorizedShares();
        }

        poolSizeByToken[token] = newPool;
        emit PoolSizeIncreased(token, currentPool, newPool, documentRef);
    }

    /**
     * @notice Decrease the option pool size (release capacity for share issuance)
     * @param token The share token address
     * @param decreaseAmount Amount to decrease the pool by
     *
     * @dev With automatic pool decrease on grant, pool represents capacity for NEW grants
     * @dev Board can decrease to 0 even if outstanding > 0 (they're independent capacities)
     *
     * Example: Pool is 2M, outstanding is 5M. Board can shrink pool to 0 to free capacity for investor issuance.
     */
    function decreasePoolSize(address token, uint256 decreaseAmount, string calldata documentRef) external onlyBoard {
        if (token == address(0)) revert ZeroAddress();
        if (decreaseAmount == 0) revert ZeroAmount();

        ShareToken shareToken = ShareToken(token);

        if (shareToken.companyAddress() != address(company)) revert InvalidShareToken();

        uint256 currentPool = poolSizeByToken[token];
        if (currentPool == 0) revert NoPoolConfigured();
        if (decreaseAmount > currentPool) revert InvalidAmount();

        uint256 newPool = currentPool - decreaseAmount;

        poolSizeByToken[token] = newPool;
        emit PoolSizeDecreased(token, currentPool, newPool, documentRef);
    }

    /**
     * @notice Grant stock options to employee
     * @param employee Recipient address
     * @param shareToken Which share class token these options are for
     * @param amount Number of options (each = 1 share when exercised)
     * @param grantDate Grant date timestamp (0 = now, or past timestamp for backdating)
     * @param cliffDuration Cliff period in seconds (e.g., 365 days)
     * @param vestingDuration Total vesting period in seconds (e.g., 1460 days = 4 years)
     * @param vestingInterval Vesting granularity in seconds (e.g., 1 days, 7 days, 30 days, 90 days)
     * @param isTaxAdvantaged true for tax-advantaged options (e.g., ISO, EMI, BSPCE), false for standard
     *
     * @dev Strike price = current FMV
     * @dev Options expire 10 years from grant date
     */
    function grantOptions(
        address employee,
        ShareToken shareToken,
        uint256 amount,
        uint256 grantDate,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 vestingInterval,
        bool isTaxAdvantaged,
        string calldata documentRef
    ) external onlyBoard returns (uint256 grantId) {
        if (employee == address(0)) revert ZeroAddress();
        if (address(shareToken) == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount % 1e6 != 0) revert InvalidAmount();
        if (valuations.length == 0) revert NoValuationOnRecord();
        if (vestingDuration == 0) revert ZeroAmount();
        if (vestingInterval == 0) revert ZeroAmount();
        if (vestingInterval > vestingDuration) revert InvalidAmount();
        if (cliffDuration > vestingDuration) revert InvalidAmount();

        // Grant date must be now or in the past bc strike price is set to FMV at grant date.
        uint256 effectiveGrantDate = grantDate <= 0 ? block.timestamp : grantDate;
        if (effectiveGrantDate > block.timestamp) revert InvalidAmount();

        if (shareToken.companyAddress() != address(company)) revert InvalidShareToken();

        uint256 poolSize = poolSizeByToken[address(shareToken)];
        if (poolSize == 0) revert NoPoolConfigured();

        if (amount > poolSize) {
            revert InsufficientPoolCapacity();
        }

        uint256 currentSupply = shareToken.totalSupply();
        uint256 authorizedCapacity = shareToken.authorizedShares();
        if (currentSupply + poolSize > authorizedCapacity) {
            revert InsufficientAuthorizedShares();
        }

        uint256 strikePrice = valuations[valuations.length - 1].fairMarketValue;

        grantId = nextGrantId++;
        optionGrants[grantId] = OptionGrant({
            employee: employee,
            shareToken: shareToken,
            amount: amount,
            exercised: 0,
            strikePrice: strikePrice,
            grantDate: effectiveGrantDate,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            vestingInterval: vestingInterval,
            expirationDate: effectiveGrantDate + 10 * 365 days,
            revokedAt: 0,
            isTaxAdvantaged: isTaxAdvantaged,
            revoked: false
        });

        employeeGrants[employee].push(grantId);

        // Reserve capacity in authorized shares for this token
        outstandingOptionsByToken[address(shareToken)] += amount;
        poolSizeByToken[address(shareToken)] -= amount;

        emit OptionsGranted(
            grantId,
            employee,
            amount,
            strikePrice,
            cliffDuration,
            vestingDuration,
            vestingInterval,
            isTaxAdvantaged,
            documentRef
        );
    }

    /**
     * @notice Exercise vested options by buying shares at strike price.
     * @param grantId The option grant ID
     * @param amount Number of options to exercise
     *
     * @dev Employee must pay: amount * strikePrice (in fiat units)
     * @dev Shares are MINTED NOW (dilution happens here)
     * @dev Payment goes directly to company Vault (treasury)
     * @dev Can only exercise vested options (checked via VestingSchedule)
     */
    function exercise(uint256 grantId, uint256 amount) external nonReentrant {
        OptionGrant storage grant = optionGrants[grantId];

        if (grant.amount == 0) revert InvalidGrantId();
        if (msg.sender != grant.employee) revert OnlyEmployee();
        if (amount % 1e6 != 0) revert InvalidAmount();
        if (block.timestamp >= grant.expirationDate) revert InvalidState();
        if (grant.exercised + amount > grant.amount) revert InvalidAmount();

        uint256 vestedAmount = _calculateVested(grantId);
        if (grant.exercised + amount > vestedAmount) {
            revert InvalidState();
        }

        uint256 payment = (amount * grant.strikePrice) / 1e6;

        // Release reserved capacity BEFORE the mint so EquityIssuance's capacity  check sees the post-exercise pool/outstanding totals.
        outstandingOptionsByToken[address(grant.shareToken)] -= amount;

        company.issuance().issueFromExercise(grant.shareToken, msg.sender, amount);

        IERC20 token = company.paymentToken();
        address vaultAddr = address(company.vault());
        token.safeTransferFrom(msg.sender, vaultAddr, payment);

        grant.exercised += amount;

        emit OptionsExercised(grantId, msg.sender, amount, payment, block.timestamp);
    }

    /**
     * @notice Revoke unvested options (employee termination)
     * Vested options remain exercisable for 90 days post-termination. Unvested options are forfeited immediately
     * @param grantId The option grant ID
     *
     */
    function revokeGrant(uint256 grantId, string calldata documentRef) external onlyBoard nonReentrant {
        OptionGrant storage grant = optionGrants[grantId];

        if (grant.amount == 0) revert InvalidGrantId();
        if (grant.revoked) revert InvalidState();

        uint256 vestedAmount = _calculateVested(grantId);
        grant.revoked = true;
        grant.revokedAt = block.timestamp;

        // Unvested options are forfeited (reduce outstanding count)
        uint256 unvestedOptions = grant.amount - vestedAmount;

        outstandingOptionsByToken[address(grant.shareToken)] -= unvestedOptions;
        poolSizeByToken[address(grant.shareToken)] += unvestedOptions;

        grant.expirationDate = block.timestamp + 90 days; // Employee has 90 days to exercise

        emit GrantRevoked(grantId, grant.employee, vestedAmount, unvestedOptions, documentRef);
    }

    /**
     * @notice Clean up expired grant to release reserved capacity
     * @param grantId The option grant ID
     *
     * @dev Only works for grants that have expired (past expirationDate)
     * @dev Releases unexercised options from outstanding count
     * @dev For revoked grants, only releases vested-but-unexercised (unvested already released at revocation)
     */
    function cleanupExpiredGrant(uint256 grantId) external {
        OptionGrant storage grant = optionGrants[grantId];

        if (grant.amount == 0) revert InvalidGrantId();
        if (block.timestamp < grant.expirationDate) revert InvalidState();

        // Calculate how many options remain outstanding
        // For revoked grants, this is vestedAmount - exercised (unvested already released)
        // For normal grants, this is amount - exercised
        uint256 stillOutstanding;
        if (grant.revoked) {
            // For revoked grants, unvested options were already released at revocation
            // Only vested-but-unexercised options remain outstanding
            uint256 vestedAmount = _calculateVested(grantId);
            stillOutstanding = vestedAmount - grant.exercised;
        } else {
            // For normal expired grants, all unexercised options are outstanding
            stillOutstanding = grant.amount - grant.exercised;
        }

        if (stillOutstanding == 0) revert InvalidState();

        outstandingOptionsByToken[address(grant.shareToken)] -= stillOutstanding;
        poolSizeByToken[address(grant.shareToken)] += stillOutstanding;
        grant.exercised = grant.amount;

        emit ExpiredGrantCleaned(grantId, address(grant.shareToken), stillOutstanding);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get a grant by ID
     * @param grantId The grant ID
     * @return grant The grant data
     */
    function getGrant(uint256 grantId) external view returns (OptionGrant memory grant) {
        grant = optionGrants[grantId];
        if (grant.amount == 0) revert InvalidGrantId();
    }

    /**
     * @notice Get all grant IDs for an employee
     * @param employee The employee address
     * @return grantIds Array of grant IDs
     */
    function getEmployeeGrants(address employee) external view returns (uint256[] memory grantIds) {
        return employeeGrants[employee];
    }

    /**
     * @notice Get current fair market value (most recent valuation)
     * @return fmv Current FMV in payment token units per share
     */
    function getCurrentFMV() external view returns (uint256 fmv) {
        if (valuations.length == 0) revert NoValuationOnRecord();
        return valuations[valuations.length - 1].fairMarketValue;
    }

    /**
     * @notice Get a specific valuation record
     * @param index Valuation index
     * @return record The valuation record
     */
    function getValuation(uint256 index) external view returns (ValuationRecord memory record) {
        return valuations[index];
    }

    /**
     * @notice Get number of valuation records
     * @return count Number of valuations
     */
    function getValuationCount() external view returns (uint256 count) {
        return valuations.length;
    }

    /**
     * @notice Get exercisable amount for a grant (vested - exercised)
     * @param grantId The grant ID
     * @return exercisable Number of options that can be exercised now
     */
    function getExercisableAmount(uint256 grantId) external view returns (uint256 exercisable) {
        OptionGrant memory grant = optionGrants[grantId];
        if (grant.amount == 0) revert InvalidGrantId();
        if (block.timestamp >= grant.expirationDate) {
            return 0;
        }

        uint256 vestedAmount = _calculateVested(grantId);
        exercisable = vestedAmount > grant.exercised ? vestedAmount - grant.exercised : 0;
    }

    /**
     * @notice Get detailed grant info with computed values
     * @param grantId The grant ID
     * @return grant The grant data
     * @return vested Amount vested so far
     * @return exercisable Amount that can be exercised now
     * @return remaining Amount not yet vested
     */
    function getGrantDetails(uint256 grantId)
        external
        view
        returns (OptionGrant memory grant, uint256 vested, uint256 exercisable, uint256 remaining)
    {
        grant = optionGrants[grantId];
        if (grant.amount == 0) revert InvalidGrantId();

        vested = _calculateVested(grantId);
        exercisable = vested > grant.exercised ? vested - grant.exercised : 0;
        remaining = grant.amount - vested;

        if (grant.revoked || block.timestamp >= grant.expirationDate) {
            exercisable = 0;
        }
    }

    /**
     * @notice Get outstanding options for a specific share token
     * @param token The share token address
     * @return outstanding Number of options that reserve capacity in authorized shares
     */
    function getOutstandingOptions(address token) external view returns (uint256 outstanding) {
        return outstandingOptionsByToken[token];
    }

    /**
     * @notice Get available capacity for granting new options (from explicit pool)
     * @param token The share token address
     * @return available Number of options that can still be granted
     * @dev Calculates: poolSize - outstandingOptions
     */
    function getAvailableCapacity(address token) external view returns (uint256 available) {
        // With automatic pool decrease on grant, poolSize already represents available capacity
        // poolSize = capacity for NEW grants (not yet granted)
        // outstanding = capacity already granted (reserved in authorized shares)
        return poolSizeByToken[token];
    }

    /**
     * @notice Get the pool size for a share token
     * @param token The share token address
     * @return poolSize The total pool capacity (board-designated)
     */
    function getPoolSize(address token) external view returns (uint256) {
        return poolSizeByToken[token];
    }

    /**
     * @notice Get comprehensive pool status for board dashboard
     * @param token The share token address
     * @return authorizedShares Maximum shares that can exist
     * @return issuedShares Currently minted shares
     * @return poolSize Board-designated pool for employee options
     * @return optionsGranted Options currently granted (outstanding)
     * @return poolAvailable Remaining pool capacity for new grants
     * @return unallocatedShares Shares not allocated to issued or pool
     */
    function getPoolStatus(address token)
        external
        view
        returns (
            uint256 authorizedShares,
            uint256 issuedShares,
            uint256 poolSize,
            uint256 optionsGranted,
            uint256 poolAvailable,
            uint256 unallocatedShares
        )
    {
        ShareToken shareToken = ShareToken(token);
        authorizedShares = shareToken.authorizedShares();
        issuedShares = shareToken.totalSupply();
        poolSize = poolSizeByToken[token];
        optionsGranted = outstandingOptionsByToken[token];
        // With automatic pool decrease on grant, poolSize already represents available capacity
        poolAvailable = poolSize;

        uint256 allocated = issuedShares + poolSize + optionsGranted;
        unallocatedShares = allocated <= authorizedShares ? authorizedShares - allocated : 0;
    }

    // ========== INTERNAL HELPERS ==========

    /**
     * @notice Calculate vested amount for a grant
     * @param grantId The grant ID
     * @return vested The amount vested (uses configurable interval vesting with whole shares)
     * @dev Vesting intervals: Arbitrary intervals in seconds (e.g., 1 day, 7 days, 30 days, 90 days, etc.)
     */
    function _calculateVested(uint256 grantId) internal view returns (uint256 vested) {
        OptionGrant storage grant = optionGrants[grantId];
        if (grant.amount == 0) return 0;

        // Determine effective time (revoked grants stop vesting)
        uint256 effectiveTime = grant.revoked ? grant.revokedAt : block.timestamp;

        // Before cliff
        if (effectiveTime < grant.grantDate + grant.cliffDuration) {
            return 0;
        }

        // After full vesting
        if (effectiveTime >= grant.grantDate + grant.vestingDuration) {
            return grant.amount;
        }

        // During vesting - discrete interval vesting in whole shares
        // Floor to complete intervals (e.g., daily, weekly, monthly, 90-day periods, etc.)
        uint256 timeVested = effectiveTime - grant.grantDate;
        uint256 intervalsVested = timeVested / grant.vestingInterval;
        uint256 totalIntervals = grant.vestingDuration / grant.vestingInterval;

        // Defensive check: if totalIntervals is 0 (vestingInterval > vestingDuration), return full amount
        if (totalIntervals == 0) {
            return grant.amount;
        }

        // Calculate vested amount based on complete intervals (in raw units)
        vested = (grant.amount * intervalsVested) / totalIntervals;

        // Round down to whole shares
        uint256 decimalFactor = 1e6;
        vested = (vested / decimalFactor) * decimalFactor;

        // Cap at totalAmount to handle edge cases
        if (vested > grant.amount) {
            vested = grant.amount;
        }
    }
}
