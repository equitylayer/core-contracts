// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../ShareToken.sol";
import "../interfaces/ICompany.sol";
import "../interfaces/IVault.sol";
import "../interfaces/ICompanyFactory.sol";
import "../interfaces/ISAFE.sol";
import "../interfaces/IFundraise.sol";
import "../interfaces/IConvertibleNote.sol";
import "../interfaces/IDataRoom.sol";
import "../interfaces/IEquityIssuance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../ShareholderRegistry.sol";
import "../VestingSchedule.sol";
import "../OptionPool.sol";

/// @title CompanyStorage
/// @notice Shared storage contract for Company mixins
abstract contract CompanyStorage is ICompany {
    // Access control
    error OnlyBoard();
    error OnlyOptionPool();
    error OnlySAFE();
    error OnlyFundraise();
    error OnlyConvertibleNote();
    error OnlyCurrentOrProposedBoard();
    // Input validation
    error ZeroAddress();
    error ZeroAmount();
    error InvalidInput();
    // Lookup errors
    error NotFound();
    error AlreadyExists();
    // State errors
    error InvalidState();
    // Capacity/resource errors
    error InsufficientCapacity();
    // Business logic (safety-critical)
    error VaultMismatch();
    error VaultAlwaysExcluded();
    error VestingScheduleAlwaysExcluded();
    error SnapshotEngineNotConfigured();

    address public override board;
    IVault public override vault;
    ICompanyFactory public factory;
    ShareholderRegistry public override shareholderRegistry;
    VestingSchedule public override vestingSchedule;
    OptionPool public override optionPool;
    ISAFE public override safe;
    IFundraise public override fundraise;
    IConvertibleNote public override convertibleNote;
    IDataRoom public override dataRoom;
    IERC20 public override paymentToken;
    IEquityIssuance public override issuance;

    // --------------------
    // Board Transfer Timelock State
    // --------------------
    address public proposedBoard;
    uint256 public boardTransferProposedAt;
    string internal proposedBoardDocumentRef;
    uint256 public constant BOARD_TRANSFER_TIMELOCK = 7 days;

    // --------------------
    // Company Public Data
    // --------------------
    string public name;
    string public ticker;
    string public metadataURI;

    // --------------------
    // Jurisdiction
    // --------------------
    /// @notice ISO 3166-1 numeric country code. https://en.wikipedia.org/wiki/ISO_3166-1_numeric
    uint16 public override countryCode;
    /// @notice Entity type - interpretation depends on jurisdiction
    /// @dev US: 1=C-Corp, 2=S-Corp | UK: 1=Ltd, 2=PLC | CH: 1=AG, 2=GmbH, 3=SA
    uint8 public override entityType;

    // --------------------
    // Share Classes
    // --------------------
    struct ShareClass {
        string className; // e.g., "Common", "Preferred Series A"
        ShareToken token;
        uint32 liquidationPreference; // Liquidation preference multiplier (1e6 = 1x, 1.5e6 = 1.5x)
        uint8 votingWeight; // Voting multiplier (1 = 1x, 10 = 10x, 0 = non-voting)
        uint256 parValue; // Par/nominal value per share in fiat units (0 = no-par, required in UK/CH/DE)
    }

    string[] public shareClassNames;
    mapping(string => ShareClass) public shares;

    /// @notice Tracks which rule impls are attached to which share class: token => impl => clone.
    mapping(address => mapping(address => address)) public attachedRules;

    // --------------------
    // Dividends
    // --------------------
    struct Dividend {
        uint256 totalAmount;
        uint256 recordDate;
        uint256 paymentDate;
        bool distributed;
    }

    struct DividendClassSnapshot {
        uint256 snapshotId;
    }

    mapping(uint256 => Dividend) public dividends;
    uint256 public dividendCount;
    mapping(uint256 => mapping(bytes32 => DividendClassSnapshot)) internal dividendSnapshots;

    mapping(uint256 => mapping(address => bool)) public dividendClaimed;
    mapping(address => bool) public excludedFromDividends;
    mapping(address => uint256) public pendingDividends;
    mapping(uint256 => uint256) public dividendRemainingAmt;
    /// @notice 0 = not yet prepared.
    mapping(uint256 => uint256) public dividendDistributionShares;
    mapping(uint256 => address[]) internal _unpaidHolders;

    modifier onlyBoard() {
        if (msg.sender != board) revert OnlyBoard();
        _;
    }

    function _classKey(string memory className) internal pure returns (bytes32) {
        return keccak256(bytes(className));
    }
}
