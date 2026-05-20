// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ICompany} from "./interfaces/ICompany.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {ShareToken} from "./ShareToken.sol";

/**
 * @title VestingSchedule
 * @notice Manages token vesting schedules with cliff and linear vesting
 * @dev Tokens are held by this contract until vested and released to beneficiaries
 *
 * Features:
 * - Flexible vesting parameters (duration, cliff, revocability)
 * - Linear vesting after cliff period
 * - Revocable schedules (e.g., for termination scenarios)
 * - Multiple schedules per beneficiary
 * - Support for backdated schedules
 * - Query vested/releasable amounts
 * - Emergency withdrawal of excess tokens
 */
contract VestingSchedule is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "0.9.0";

    struct Schedule {
        address beneficiary;
        address token;
        uint256 totalAmount;
        uint256 startTime;
        uint256 cliffDuration;
        uint256 vestingDuration;
        uint256 released;
        bool revocable;
        bool revoked;
        uint256 revokedAt;
    }

    ICompany public company;
    mapping(uint256 => Schedule) public schedules;
    mapping(address => uint256[]) public beneficiarySchedules;
    uint256 public scheduleCount;
    mapping(address => uint256) public totalAllocated;

    // Custom errors
    error OnlyBoard();
    error OnlyBoardOrCompany();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidDuration();
    error CliffExceedsDuration();
    error InvalidScheduleId();
    error NotRevocable();
    error AlreadyRevoked();
    error NoTokensToRelease();
    error InsufficientBalance();
    error InvalidShareClass();

    // Events
    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 totalAmount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable,
        string documentRef
    );
    event TokensReleased(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );
    event ScheduleRevoked(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 vestedAmount,
        uint256 returnedAmount,
        uint256 timestamp,
        string documentRef
    );
    event ExcessWithdrawn(address indexed token, uint256 amount);
    event VestedTransferFailed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    modifier onlyBoardOrCompany() {
        if (
            msg.sender != company.board() && msg.sender != address(company) && msg.sender != address(company.issuance())
        ) revert OnlyBoardOrCompany();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {}

    /**
     * @notice Initialize the vesting contract (replaces constructor for clones)
     * @param _company Company that owns this vesting contract
     */
    function initialize(address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();
        company = ICompany(_company);
    }

    /**
     * @notice Create a new vesting schedule
     * @param beneficiary Who receives the vested tokens
     * @param token Which share class token
     * @param totalAmount Total tokens in schedule
     * @param startTime Unix timestamp when vesting starts
     * @param cliffDuration Duration before any tokens vest (e.g., 365 days)
     * @param vestingDuration Total duration (e.g., 1460 days = 4 years)
     * @param revocable Can company revoke (true for employees, false for founders)
     * @return scheduleId The ID of the created schedule
     *
     */
    function createSchedule(
        address beneficiary,
        address token,
        uint256 totalAmount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable,
        string calldata documentRef
    ) public onlyBoardOrCompany returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (vestingDuration == 0) revert InvalidDuration();
        if (cliffDuration > vestingDuration) revert CliffExceedsDuration();
        if (startTime > block.timestamp + 365 days) revert InvalidDuration();

        try ShareToken(token).companyAddress() returns (address tokenCompany) {
            if (tokenCompany != address(company)) revert InvalidShareClass();
        } catch {
            revert InvalidShareClass();
        }

        // Check this contract has enough unallocated tokens
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 available = balance - totalAllocated[token];
        if (available < totalAmount) revert InsufficientBalance();

        totalAllocated[token] += totalAmount;

        scheduleId = scheduleCount++;
        schedules[scheduleId] = Schedule({
            beneficiary: beneficiary,
            token: token,
            totalAmount: totalAmount,
            startTime: startTime,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            released: 0,
            revocable: revocable,
            revoked: false,
            revokedAt: 0
        });

        beneficiarySchedules[beneficiary].push(scheduleId);

        emit ScheduleCreated(
            scheduleId,
            beneficiary,
            token,
            totalAmount,
            startTime,
            cliffDuration,
            vestingDuration,
            revocable,
            documentRef
        );
    }

    /**
     * @notice Calculate vested amount for a schedule
     * @param scheduleId The schedule ID
     * @return vested The amount of tokens that have vested
     *
     * @dev Discrete daily vesting - shares vest in WHOLE SHARES per complete day
     * @dev Uses floor division on days AND rounds down to whole shares (using 6 decimals)
     * @dev Ensures no fractional shares vest (e.g., 454.000000 not 454.931506)
     * @dev If revoked, vesting stops at revocation time
     */
    function calculateVested(uint256 scheduleId) public view returns (uint256 vested) {
        Schedule memory schedule = schedules[scheduleId];
        if (schedule.totalAmount == 0) revert InvalidScheduleId();

        // Determine effective time (revoked schedules stop vesting)
        uint256 effectiveTime = schedule.revoked ? schedule.revokedAt : block.timestamp;

        // Before cliff
        if (effectiveTime < schedule.startTime + schedule.cliffDuration) {
            return 0;
        }

        // After full vesting
        if (effectiveTime >= schedule.startTime + schedule.vestingDuration) {
            return schedule.totalAmount;
        }

        // Floor to complete days to ensure shares vest in discrete daily chunks
        uint256 timeVested = effectiveTime - schedule.startTime;
        uint256 daysVested = timeVested / 1 days;
        uint256 totalDays = schedule.vestingDuration / 1 days;

        // Defensive check: if totalDays is 0 (vestingDuration < 1 day), return full amount
        if (totalDays == 0) {
            return schedule.totalAmount;
        }

        // Calculate vested amount based on complete days
        vested = (schedule.totalAmount * daysVested) / totalDays;
        uint256 decimalFactor = 1e6;
        vested = (vested / decimalFactor) * decimalFactor;
        // Cap at totalAmount to handle edge cases
        if (vested > schedule.totalAmount) {
            vested = schedule.totalAmount;
        }
    }

    /**
     * @notice Get releasable amount (vested but not yet released)
     * @param scheduleId The schedule ID
     * @return releasable The amount of tokens that can be released now
     */
    function getReleasableAmount(uint256 scheduleId) public view returns (uint256 releasable) {
        Schedule memory schedule = schedules[scheduleId];
        if (schedule.totalAmount == 0) revert InvalidScheduleId();

        uint256 vested = calculateVested(scheduleId);
        releasable = vested > schedule.released ? vested - schedule.released : 0;
    }

    /**
     * @notice Release vested tokens to beneficiary
     * @param scheduleId The schedule ID
     *
     * @dev Anyone can call (typically beneficiary)
     * @dev Transfers tokens from this contract to beneficiary
     * @dev Updates schedule.released
     */
    function release(uint256 scheduleId) external nonReentrant {
        Schedule storage schedule = schedules[scheduleId];
        if (schedule.totalAmount == 0) revert InvalidScheduleId();

        uint256 releasable = getReleasableAmount(scheduleId);
        if (releasable == 0) revert NoTokensToRelease();

        // Update released amount and deallocate
        schedule.released += releasable;
        totalAllocated[schedule.token] -= releasable;

        // Transfer tokens to beneficiary
        IERC20(schedule.token).safeTransfer(schedule.beneficiary, releasable);

        emit TokensReleased(scheduleId, schedule.beneficiary, schedule.token, releasable, block.timestamp);
    }

    // --------- VIEWS --------------

    /**
     * @notice Revoke a vesting schedule (employee termination)
     * @param scheduleId The schedule ID
     *
     * @dev Only works if revocable == true
     * @dev Calculates vested amount up to revocation
     * @dev Releases vested portion to beneficiary
     * @dev Returns unvested portion to company
     */
    function revoke(uint256 scheduleId, string calldata documentRef) external onlyBoard nonReentrant {
        Schedule storage schedule = schedules[scheduleId];
        if (schedule.totalAmount == 0) revert InvalidScheduleId();
        if (!schedule.revocable) revert NotRevocable();
        if (schedule.revoked) revert AlreadyRevoked();

        schedule.revoked = true;
        schedule.revokedAt = block.timestamp;

        uint256 vested = calculateVested(scheduleId);
        uint256 unvested = schedule.totalAmount - vested;

        // Releases vested portion to beneficiary
        // If sanctioned: tokens stay in contract for beneficiary to claim via release()
        if (vested > schedule.released) {
            uint256 toRelease = vested - schedule.released;
            schedule.released += toRelease;
            totalAllocated[schedule.token] -= toRelease;
            try IERC20(schedule.token).transfer(schedule.beneficiary, toRelease) returns (bool success) {
                if (!success) {
                    schedule.released -= toRelease;
                    totalAllocated[schedule.token] += toRelease;
                    emit VestedTransferFailed(scheduleId, schedule.beneficiary, toRelease);
                }
            } catch {
                schedule.released -= toRelease;
                totalAllocated[schedule.token] += toRelease;
                emit VestedTransferFailed(scheduleId, schedule.beneficiary, toRelease);
            }
        }

        // Burn unvested portion and deallocate
        // Note: VestingSchedule needs BURNER_ROLE on the token
        if (unvested > 0) {
            totalAllocated[schedule.token] -= unvested;
            IShareToken(schedule.token).burn(address(this), unvested);
        }

        emit ScheduleRevoked(
            scheduleId, schedule.beneficiary, schedule.token, vested, unvested, block.timestamp, documentRef
        );
    }

    /**
     * @notice Get a schedule by ID
     * @param scheduleId The schedule ID
     * @return schedule The schedule data
     */
    function getSchedule(uint256 scheduleId) external view returns (Schedule memory schedule) {
        schedule = schedules[scheduleId];
        if (schedule.totalAmount == 0) revert InvalidScheduleId();
    }

    /**
     * @notice Get all schedule IDs for a beneficiary
     * @param beneficiary The beneficiary address
     * @return scheduleIds Array of schedule IDs
     */
    function getBeneficiarySchedules(address beneficiary) external view returns (uint256[] memory scheduleIds) {
        return beneficiarySchedules[beneficiary];
    }

    /**
     * @notice Get all schedule IDs
     * @return scheduleIds Array of all schedule IDs (0 to scheduleCount-1)
     * @dev UI can iterate through these to display all schedules
     */
    function getAllScheduleIds() external view returns (uint256[] memory scheduleIds) {
        scheduleIds = new uint256[](scheduleCount);
        for (uint256 i = 0; i < scheduleCount; i++) {
            scheduleIds[i] = i;
        }
    }

    /**
     * @notice Get detailed schedule info with computed values
     * @param scheduleId The schedule ID
     * @return schedule The schedule data
     * @return vested Amount vested so far
     * @return releasable Amount that can be released now
     * @return remaining Amount not yet vested
     */
    function getScheduleDetails(uint256 scheduleId)
        external
        view
        returns (Schedule memory schedule, uint256 vested, uint256 releasable, uint256 remaining)
    {
        schedule = schedules[scheduleId];
        if (schedule.totalAmount == 0) revert InvalidScheduleId();

        vested = calculateVested(scheduleId);
        releasable = getReleasableAmount(scheduleId);
        remaining = schedule.totalAmount - vested;
    }

    /**
     * @notice Get all schedules with details
     * @return allSchedules Array of all schedules
     * @return vesteds Array of vested amounts (parallel to allSchedules)
     * @return releasables Array of releasable amounts (parallel to allSchedules)
     * @dev Warning: Gas-intensive for many schedules. Use pagination for large datasets.
     */
    function getAllSchedulesWithDetails()
        external
        view
        returns (Schedule[] memory allSchedules, uint256[] memory vesteds, uint256[] memory releasables)
    {
        allSchedules = new Schedule[](scheduleCount);
        vesteds = new uint256[](scheduleCount);
        releasables = new uint256[](scheduleCount);

        for (uint256 i = 0; i < scheduleCount; i++) {
            allSchedules[i] = schedules[i];
            vesteds[i] = calculateVested(i);
            releasables[i] = getReleasableAmount(i);
        }
    }

    /**
     * @notice Get summary for a beneficiary across all their schedules
     * @param beneficiary The beneficiary address
     * @return totalVested Total amount vested across all schedules
     * @return totalReleasable Total amount that can be released now
     * @return totalRemaining Total amount not yet vested
     */
    function getBeneficiarySummary(address beneficiary)
        external
        view
        returns (uint256 totalVested, uint256 totalReleasable, uint256 totalRemaining)
    {
        uint256[] memory scheduleIds = beneficiarySchedules[beneficiary];

        for (uint256 i = 0; i < scheduleIds.length; i++) {
            uint256 scheduleId = scheduleIds[i];
            Schedule memory schedule = schedules[scheduleId];

            if (schedule.totalAmount > 0) {
                uint256 vested = calculateVested(scheduleId);
                totalVested += vested;
                totalReleasable += getReleasableAmount(scheduleId);
                totalRemaining += schedule.totalAmount - vested;
            }
        }
    }

    /**
     * @notice Withdraw excess tokens not allocated to vesting schedules
     * @param token Token address
     * @param amount Amount to withdraw
     * @dev Cannot withdraw tokens allocated to active schedules.
     */
    function withdrawExcess(address token, uint256 amount) external onlyBoard nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 available = balance - totalAllocated[token];

        if (amount > available) revert InsufficientBalance();

        IERC20(token).safeTransfer(msg.sender, amount);
        emit ExcessWithdrawn(token, amount);
    }
}
