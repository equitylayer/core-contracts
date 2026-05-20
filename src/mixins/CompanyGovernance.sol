// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./CompanyStorage.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title CompanyGovernance
/// @notice Handles board management, timelocks, and admin functions
abstract contract CompanyGovernance is CompanyStorage {
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");

    // --------------------
    // Events
    // --------------------
    event BoardChanged(address indexed oldBoard, address indexed newBoard, string documentRef);
    event BoardTransferProposed(address indexed proposedBoard, uint256 executeAtTime, string documentRef);
    event BoardTransferCancelled(address indexed cancelledBoard);
    event MetadataURIUpdated(string newMetadataURI);
    event DividendExclusionSet(address indexed account, bool excluded);

    // --------------------
    // Admin Functions
    // --------------------

    /// @notice Update the company ticker
    /// @param _ticker New ticker symbol
    function setCompanyTicker(string memory _ticker) external onlyBoard {
        ticker = _ticker;
    }

    /// @notice Update the company metadata URI
    /// @param _metadataURI New metadata URI (e.g., IPFS link to JSON with logo and other metadata)
    function setMetadataURI(string memory _metadataURI) external onlyBoard {
        metadataURI = _metadataURI;
        emit MetadataURIUpdated(_metadataURI);
    }

    /// @notice Update the company vault
    /// @param _vault New vault address
    function setVault(IVault _vault) external onlyBoard {
        if (address(_vault) == address(0)) revert ZeroAddress();
        if (_vault.company() != ICompany(address(this))) revert VaultMismatch();
        vault = _vault;
    }

    function setDividendExclusion(address account, bool excluded) external onlyBoard {
        if (account == address(0)) revert ZeroAddress();
        if (account == address(vault)) revert VaultAlwaysExcluded();
        if (account == address(vestingSchedule)) revert VestingScheduleAlwaysExcluded();
        excludedFromDividends[account] = excluded;
        emit DividendExclusionSet(account, excluded);
    }

    // --------------------
    // Board Transfer with Timelock
    // --------------------
    /// @notice Propose a new board address (step 1 of 2)
    /// @param newBoard The address of the proposed new board
    /// @param documentRef Optional doc (obolos:// URI or hash) authorizing the transfer
    /// @dev Initiates a 7-day timelock before the transfer can be executed
    function proposeBoardTransfer(address newBoard, string calldata documentRef) external onlyBoard {
        if (newBoard == address(0)) revert ZeroAddress();
        if (newBoard == board) revert InvalidState();

        proposedBoard = newBoard;
        boardTransferProposedAt = block.timestamp;
        proposedBoardDocumentRef = documentRef;

        uint256 executeAtTime = block.timestamp + BOARD_TRANSFER_TIMELOCK;
        emit BoardTransferProposed(newBoard, executeAtTime, documentRef);
    }

    /// @notice Execute a previously proposed board transfer (step 2 of 2)
    /// @dev Can be called by either current board or proposed board after timelock expires
    function executeBoardTransfer() external {
        if (proposedBoard == address(0)) revert InvalidState();
        if (msg.sender != board && msg.sender != proposedBoard) revert OnlyCurrentOrProposedBoard();
        if (block.timestamp < boardTransferProposedAt + BOARD_TRANSFER_TIMELOCK) revert InvalidState();

        address oldBoard = board;
        address newBoard = proposedBoard;
        string memory documentRef = proposedBoardDocumentRef;

        // Rotate admin/operator roles on all share-class modules before switching board.
        _rotateBoardRoles(oldBoard, newBoard);

        board = newBoard;
        proposedBoard = address(0);
        boardTransferProposedAt = 0;
        delete proposedBoardDocumentRef;

        emit BoardChanged(oldBoard, newBoard, documentRef);
    }

    /// @notice Cancel a proposed board transfer
    /// @dev Can only be called by current board
    function cancelBoardTransfer() external onlyBoard {
        if (proposedBoard == address(0)) revert InvalidState();

        address cancelled = proposedBoard;
        proposedBoard = address(0);
        boardTransferProposedAt = 0;
        delete proposedBoardDocumentRef;

        emit BoardTransferCancelled(cancelled);
    }

    function _rotateBoardRoles(address oldBoard, address newBoard) private {
        uint256 len = shareClassNames.length;
        for (uint256 i = 0; i < len; i++) {
            ShareToken token = shares[shareClassNames[i]].token;
            if (address(token) == address(0)) continue;

            _rotateRole(address(token), DEFAULT_ADMIN_ROLE, oldBoard, newBoard);
            _rotateRole(address(token), SNAPSHOOTER_ROLE, oldBoard, newBoard);

            address snapshotEngineAddress = address(token.snapshotEngine());
            if (snapshotEngineAddress != address(0)) {
                _rotateRole(snapshotEngineAddress, DEFAULT_ADMIN_ROLE, oldBoard, newBoard);
                _rotateRole(snapshotEngineAddress, SNAPSHOOTER_ROLE, oldBoard, newBoard);
            }

            address ruleEngineAddress = address(token.ruleEngine());
            if (ruleEngineAddress != address(0)) {
                _rotateRole(ruleEngineAddress, DEFAULT_ADMIN_ROLE, oldBoard, newBoard);
            }
        }
    }

    function _rotateRole(address target, bytes32 role, address oldBoard, address newBoard) private {
        IAccessControl(target).grantRole(role, newBoard);
        IAccessControl(target).revokeRole(role, oldBoard);
    }
}
