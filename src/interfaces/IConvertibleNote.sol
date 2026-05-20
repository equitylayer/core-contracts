// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IConvertibleNote {
    enum Status {
        Active,
        Converted,
        Repaid,
        Cancelled,
        PendingConversion
    }

    struct NoteInstrument {
        uint256 noteId;
        address investor;
        Status status;
        bytes32 termsCommitment;
        address targetShareClass;
        uint256 issuedAt;
        uint256 maturityDate;
        uint256 convertedAt;
        uint256 sharesIssued;
        bytes32 sharesCommitment;
        uint256 conversionId;
        bool allowEarlyRepayment;
        string documentRef;
        euint128 principal;
        euint128 rateBps;
        euint128 cap;
        euint128 disc;
        euint128 salt;
    }

    struct TermsCiphertext {
        InEuint128 principal;
        InEuint128 interestRateBps;
        InEuint128 valuationCap;
        InEuint128 discountBps;
    }

    struct ConversionResult {
        uint256 noteId;
        uint256 sharesIssued;
        bytes32 sharesCommitment;
    }

    struct IssueNoteParams {
        address investor;
        bytes32 termsCommitment;
        euint128 principal;
        euint128 rateBps;
        euint128 cap;
        euint128 disc;
        euint128 salt;
        address targetShareClass;
        uint256 issuedAt;
        uint256 maturityDate;
        bool allowEarlyRepayment;
        string documentRef;
        bytes encryptedMemo;
    }

    /// @notice Whether Notes can convert (Fundraise threshold satisfied).
    function canConvertNotes() external view returns (bool);

    /// @notice Issue a Note directly (board-initiated, off-chain agreement).
    function issueNote(
        address investor,
        bytes32 termsCommitment,
        TermsCiphertext calldata terms,
        InEuint128 calldata salt,
        address targetShareClass,
        uint256 issuedAt,
        uint256 maturityDate,
        bool allowEarlyRepayment,
        string calldata documentRef,
        bytes calldata encryptedMemo
    ) external returns (uint256 noteId);

    /// @notice Issue a Note on behalf of a Fundraise round.
    /// @dev Fundraise stores per-investor terms as ciphertexts; it passes them
    ///      directly here. No plaintext crosses the contract boundary.
    function issueNoteFromFundraise(
        address investor,
        bytes32 termsCommitment,
        euint128 principal,
        euint128 rateBps,
        euint128 cap,
        euint128 disc,
        euint128 salt,
        address targetShareClass,
        uint256 issuedAt,
        uint256 maturityDate,
        bool allowEarlyRepayment,
        string calldata documentRef,
        bytes calldata encryptedMemo
    ) external returns (uint256 noteId);

    /// @notice Cancel an active Note. Board-only.
    function cancelNote(uint256 noteId, string calldata documentRef) external;

    /// @notice Investor toggles whether company can repay note before maturity.
    function toggleEarlyRepayment(uint256 noteId, bool allowed) external;

    /// @notice Privileged: transition the listed notes from Active to PendingConversion.
    function _markPendingConversion(uint256 conversionId, uint256[] calldata noteIds) external;

    /// @notice Privileged: apply per-note conversion results AFTER EquityIssuance
    ///         verified the joint proof. State flip only -- EquityIssuance handles
    ///         the per-recipient mint (with compliance) itself.
    function _applyConversion(
        uint256 conversionId,
        ConversionResult[] calldata results,
        bytes calldata encryptedSharesMemo
    ) external returns (uint256 totalSharesIssued);

    /// @notice Privileged: roll PendingConversion notes back to Active.
    function _rollbackConversion(uint256 conversionId, uint256[] calldata noteIds) external;

    /// @notice Repay a note. ZK proof attests that `totalRepayment ==
    ///         principal + accrued_interest(currentTime)` against committed terms.
    /// @param noteId The note to repay.
    /// @param totalRepayment Principal + accrued interest, in payment-token units.
    /// @param currentTime Timestamp the off-chain prover used for the accrual proof.
    ///        Recency-bounded so prover/mempool drift is safe.
    /// @param proof Proof from `cn_repayment` circuit. The circuit clamps to
    ///        `maturityDate` internally.
    function repayNote(uint256 noteId, uint256 totalRepayment, uint256 currentTime, bytes calldata proof) external;

    /// @notice Build the public-input array for the `cn_repayment` circuit.
    function noteRepaymentPublicInputs(uint256 noteId, uint256 totalRepayment, uint256 currentTime)
        external
        view
        returns (bytes32[] memory inputs);

    /// @notice Get a Note's full record (incl. encrypted terms).
    function getNote(uint256 noteId) external view returns (NoteInstrument memory note);

    /// @notice All note ids ever issued to `investor` (any status).
    function getInvestorNotes(address investor) external view returns (uint256[] memory);

    /// @notice Number of Notes in `Active` status.
    function getActiveNoteCount() external view returns (uint256 count);

    /// @notice Ids of Notes in `Active` status.
    function getActiveNotes() external view returns (uint256[] memory noteIds);

    /// @notice Notes that are not terminal yet: Active or PendingConversion.
    function getOutstandingNoteCount() external view returns (uint256 count);
}
