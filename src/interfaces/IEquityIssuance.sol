// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ShareToken} from "../ShareToken.sol";
import {ISAFE} from "./ISAFE.sol";
import {IConvertibleNote} from "./IConvertibleNote.sol";

/// @notice Single share-emission gate. All paths that mint shares -- board grants,
///         vesting grants, option exercises, priced-round investors, and joint
///         SAFE+CN conversions funnel through `EquityIssuance._mint`, which
///         runs compliance and capacity / system-recipient guards before minting.
///         Also owns the joint SAFE/CN conversion lifecycle.
interface IEquityIssuance {
    /// @notice Single batch covering both SAFE and CN conversions in one financing.
    struct Conversion {
        uint256 conversionId;
        uint256[] safeIds;
        uint256[] noteIds;
        uint256 pricePerShare;
        uint256 fullyDiluted;
        uint256 currentTime;
        uint256 requestedAt;
        uint256 expiresAt;
        bool applied;
        bool rolledBack;
        string documentRef;
    }

    /// @notice Board-direct grant -- replaces the legacy `Company.issueShares`.
    /// @param className The share class to issue (e.g. "Common", "Preferred Series A").
    /// @param to Recipient. Reverts on system addresses (Company, board, instruments, ...).
    /// @param amount Number of shares to issue.
    /// @param purpose Short human-readable label (e.g. "employee grant", "seed investor").
    /// @param documentRef Optional doc (obolos:// URI or hash) authorising the issuance.
    function issueGrant(
        string calldata className,
        address to,
        uint256 amount,
        string calldata purpose,
        string calldata documentRef
    ) external;

    /// @notice Board-direct vesting grant. Mint targets the VestingSchedule contract
    ///         (which escrows the shares); compliance for the beneficiary re-runs at
    ///         release time via the CMTAT transfer rules.
    /// @param token The share token to issue.
    /// @param beneficiary Who receives the vested tokens at release time.
    /// @param amount Total tokens in the schedule.
    /// @param startTime Unix timestamp when vesting starts.
    /// @param cliffDuration Duration before any tokens vest (e.g. 365 days).
    /// @param vestingDuration Total vesting duration (e.g. 1460 days = 4 years).
    /// @param revocable Whether the company can revoke (true: employees, false: founders).
    /// @param documentRef Optional doc authorising the issuance / vesting plan.
    /// @return scheduleId The ID of the created vesting schedule.
    function issueGrantWithVesting(
        ShareToken token,
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable,
        string calldata documentRef
    ) external returns (uint256 scheduleId);

    /// @notice OptionPool calls this on option exercise. Replaces the legacy
    ///         `Company.issueSharesFromOptionPool`.
    /// @param token The share token to issue.
    /// @param to The exercising employee.
    /// @param amount Number of shares to issue.
    function issueFromExercise(ShareToken token, address to, uint256 amount) external;

    /// @notice Fundraise calls this on priced-round finalize; iterates round
    ///         investments and mints shares per non-refunded investor.
    /// @param roundId The Fundraise round id.
    /// @param documentRef Optional doc authorising the round issuance.
    /// @return totalSharesIssued Sum of shares minted across non-refunded investors.
    function issueFromPricedRound(uint256 roundId, string calldata documentRef)
        external
        returns (uint256 totalSharesIssued);

    // ============ Joint conversion lifecycle ============

    /// @notice Open a conversion batch covering all currently-active SAFEs and CNs.
    /// @param pricePerShare The qualifying round's price-per-share.
    /// @param fullyDiluted Pre-conversion fully diluted share count.
    /// @param expiresAt Deadline by which `applyConversion` must succeed (0 = no expiry).
    /// @param documentRef Off-chain reference (IPFS, audit URL) describing the financing.
    /// @return conversionId New batch identifier; both halves share it.
    function triggerConversion(
        uint256 pricePerShare,
        uint256 fullyDiluted,
        uint256 expiresAt,
        string calldata documentRef
    ) external returns (uint256 conversionId);

    /// @notice Apply a pending conversion batch with the joint proof.
    /// @param conversionId The batch to apply.
    /// @param safeResults Per-SAFE share allotments + commitments attested by the proof.
    /// @param noteResults Per-CN share allotments + commitments attested by the proof.
    /// @param proof UltraHonk proof bytes.
    /// @param encryptedSharesMemo Optional opaque memo emitted per-instrument in events.
    /// @return totalSharesIssued Sum of shares minted across all instruments.
    function applyConversion(
        uint256 conversionId,
        ISAFE.ConversionResult[] calldata safeResults,
        IConvertibleNote.ConversionResult[] calldata noteResults,
        bytes calldata proof,
        bytes calldata encryptedSharesMemo
    ) external returns (uint256 totalSharesIssued);

    /// @notice Roll an expired batch back; instruments return to Active. Anyone can call after expiry.
    function rollbackConversion(uint256 conversionId) external;

    /// @notice Board cancels a stuck conversion immediately, without waiting for expiry.
    function cancelConversion(uint256 conversionId) external;

    /// @notice Number of conversion batches ever opened (including applied/rolled-back).
    function conversionCount() external view returns (uint256);

    /// @notice Get a conversion batch's snapshot.
    function getConversion(uint256 conversionId) external view returns (Conversion memory batch);

    /// @notice Build the joint conversion circuit's public-input array.
    /// @dev Order MUST match `circuits/conversion/src/main.nr`'s `pub` parameter order.
    function conversionPublicInputs(
        uint256 conversionId,
        ISAFE.ConversionResult[] memory safeResults,
        IConvertibleNote.ConversionResult[] memory noteResults
    ) external view returns (bytes32[] memory inputs);
}
