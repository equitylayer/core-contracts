// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {euint128, ebool, InEuint128, InEbool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IFundraise {
    enum RoundStatus {
        OPEN,
        CLOSED,
        FINALIZED,
        CANCELLED
    }

    enum RoundType {
        SAFE,
        PRICED,
        CONVERTIBLE_NOTE
    }

    struct Round {
        string name;
        RoundType roundType;
        uint256 valuationCap;
        uint256 discountBps;
        uint256 pricePerShare;
        uint256 interestRateBps;
        uint256 maturityDuration;
        bool allowEarlyRepayment;
        bool mfn;
        bool proRata;
        bool whitelistOnly;
        string documentRef;
        uint256 minInvestment;
        uint256 maxInvestment;
        uint256 targetRaise;
        uint256 hardCap;
        uint256 deadline;
        uint256 totalRaised;
        uint256 investorCount;
        RoundStatus status;
        address targetShareClass;
        euint128 eTotalRaised;
    }

    struct Investment {
        address investor;
        uint256 amount;
        uint256 timestamp;
        bool refunded;
        euint128 eAmount;
        euint128 valuationCap;
        euint128 discountBps;
        ebool mfn;
        ebool proRata;
        bytes32 termsCommitment;
        euint128 salt;
    }

    /// @notice Parameters for creating a new fundraising round.
    struct RoundParams {
        string name; // e.g., "Seed Round Q1 2025" or "Series A"
        RoundType roundType; // SAFE, PRICED, or CONVERTIBLE_NOTE
        uint256 valuationCap; // (0 = no cap) - SAFE/NOTE only
        uint256 discountBps; // (0 = no discount, max 9900) - SAFE/NOTE only
        uint256 pricePerShare; // PRICED only
        uint256 interestRateBps; // (bps, 600 = 6%) - NOTE only
        uint256 maturityDuration; // NOTE only
        bool allowEarlyRepayment; // NOTE only
        bool mfn; // SAFE only
        bool proRata; // SAFE/NOTE only
        bool whitelistOnly;
        string documentRef;
        uint256 minInvestment;
        uint256 maxInvestment;
        uint256 targetRaise;
        uint256 hardCap;
        uint256 deadline;
        address targetShareClass;
    }

    // ============ State views ============

    /// @notice Minimum raise that promotes a priced round into a qualified financing
    ///         (which auto-triggers a joint SAFE/CN conversion on finalize).
    function qualifiedFinancingThreshold() external view returns (uint256);

    /// @notice Whether a qualified financing has happened (one-shot latch).
    function qualifiedFinancingOccurred() external view returns (bool);

    /// @notice The priced-round id that met the threshold; `type(uint256).max` = none.
    function qualifyingRoundId() external view returns (uint256);

    /// @notice Number of rounds ever created.
    function roundCount() external view returns (uint256);

    /// @notice Pull-pattern refund balance owed to `investor` after a cancelled round.
    function pendingRefunds(address investor) external view returns (uint256);

    /// @notice Whether `investor` is on `roundId`'s whitelist.
    function roundWhitelist(uint256 roundId, address investor) external view returns (bool);

    // ============ Round lifecycle ============

    /// @notice Create a new fundraising round.
    /// @param params Round parameters struct.
    /// @return roundId The ID of the created round.
    function createRound(RoundParams calldata params) external returns (uint256 roundId);

    /// @notice Close a round (stop accepting new investments).
    function closeRound(uint256 roundId) external;

    /// @notice Set the qualified financing threshold (minimum raise to trigger SAFE/Note conversion).
    /// @param threshold Minimum amount a priced round must raise.
    /// @dev Before any SAFEs/Notes exist: can be set to any value. After SAFEs/Notes
    ///      exist: can only decrease (protects investors from indefinite conversion delay).
    ///      A threshold of 0 means any priced round can trigger conversion.
    function setQFT(uint256 threshold) external;

    /// @notice Update the document reference for a round.
    /// @param ref The new document hash or `obolos://` dataroom URI.
    function setDocumentRef(uint256 roundId, string calldata ref) external;

    /// @notice Finalize a round and issue SAFEs / Notes / Shares according to `RoundType`.
    /// @dev Round must be CLOSED first.
    function finalizeRound(uint256 roundId) external;

    /// @notice Board-triggered manual conversion of all active SAFEs and CNs.
    /// @dev Delegates to `EquityIssuance.triggerConversion`; the `onlyFundraise` gate
    ///      on issuance stays tight because Fundraise is the caller.
    function triggerConversions(
        uint256 pricePerShare,
        uint256 fullyDiluted,
        uint256 expiresAt,
        string calldata documentRef
    ) external returns (uint256 conversionId);

    /// @notice Cancel a round and refund all investments.
    /// @dev Uses pull pattern: failed refunds are tracked in `pendingRefunds` for later claim.
    function cancelRound(uint256 roundId) external;

    /// @notice Reserve a spot for a special investor with optional custom terms.
    /// @param amount Reserved investment amount.
    /// @param valuationCap Custom valuation cap (only used if `useCustomTerms = true`).
    /// @param discountBps Custom discount (only used if `useCustomTerms = true`).
    /// @param mfn Custom MFN (only used if `useCustomTerms = true`).
    /// @param proRata Custom pro-rata (only used if `useCustomTerms = true`).
    /// @param useCustomTerms Whether to use custom terms or round defaults.
    function reserveSpot(
        uint256 roundId,
        address investor,
        uint256 amount,
        InEuint128 calldata valuationCap,
        InEuint128 calldata discountBps,
        InEbool calldata mfn,
        InEbool calldata proRata,
        bool useCustomTerms
    ) external;

    /// @notice Invest in a round.
    /// @param roundId The round ID.
    /// @param amount Amount to invest (plaintext -- leaks via token transfer anyway).
    /// @param termsCommitment Poseidon2 commitment over the SAFE/Note plaintext openings.
    /// @param termsSalt Blinding factor encrypted client-side.
    /// @dev If the investor has a reservation they must pay the exact reserved amount once.
    ///      Validates the investor against the rule engine before accepting payment.
    function invest(uint256 roundId, uint256 amount, bytes32 termsCommitment, InEuint128 calldata termsSalt) external;

    /// @notice Board refunds a specific investment, before finalizing.
    function refundInvestment(uint256 roundId, uint256 idx) external;

    /// @notice Claim pending refunds (pull pattern for failed automatic refunds).
    function claimRefund() external;

    /// @notice Add investors to a round's whitelist.
    /// @dev Only allowed on OPEN rounds.
    function addToWhitelist(uint256 roundId, address[] calldata investors) external;

    /// @notice Remove investors from a round's whitelist.
    /// @dev Only allowed on OPEN rounds.
    function removeFromWhitelist(uint256 roundId, address[] calldata investors) external;

    // ============ Per-round views ============

    /// @notice SAFE ids issued from a SAFE round. Populated after finalize.
    function getRoundSAFEIds(uint256 roundId) external view returns (uint256[] memory);

    /// @notice Note ids issued from a CONVERTIBLE_NOTE round. Populated after finalize.
    function getRoundNoteIds(uint256 roundId) external view returns (uint256[] memory);

    /// @notice Total shares issued from a PRICED round. Populated after finalize.
    function getRoundSharesIssued(uint256 roundId) external view returns (uint256);

    /// @notice One investment row for a round (reverts on out-of-range index).
    function getInvestment(uint256 roundId, uint256 investmentIndex) external view returns (Investment memory);

    /// @notice Investments for a round.
    function getInvestments(uint256 roundId) external view returns (Investment[] memory);

    /// @notice Get a round's full record.
    function getRound(uint256 roundId) external view returns (Round memory);

    /// @notice Sum of non-refunded `invest` amounts from `investor` in `roundId`.
    function getInvestorTotal(uint256 roundId, address investor) external view returns (uint256);

    /// @notice Number of investment rows for a round (incl. refunded).
    function getInvestmentCount(uint256 roundId) external view returns (uint256);

    /// @notice Whether `investor` is on the round's whitelist.
    function isWhitelisted(uint256 roundId, address investor) external view returns (bool);

    /// @notice Whether `investor` is currently eligible to invest in `roundId`.
    function canInvest(uint256 roundId, address investor) external view returns (bool);
}
