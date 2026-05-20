// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {euint128, ebool, InEuint128, InEbool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @notice Canonical types + external surface of `SAFE`.
interface ISAFE {
    enum Status {
        Active,
        Converted,
        Cancelled,
        PendingConversion
    }

    struct SAFEInstrument {
        uint256 safeId;
        address investor;
        Status status;
        bytes32 termsCommitment;
        address targetShareClass;
        uint256 issuedAt;
        uint256 convertedAt;
        uint256 sharesIssued;
        bytes32 sharesCommitment;
        uint256 conversionId;
        string documentRef;
        euint128 inv;
        euint128 cap;
        euint128 disc;
        ebool mfn;
        ebool proRata;
        euint128 salt;
    }

    /// @notice Ciphertext SAFE terms.
    struct TermsCiphertext {
        InEuint128 investmentAmount;
        InEuint128 valuationCap;
        InEuint128 discountBps;
        InEbool mfn;
        InEbool proRata;
    }

    struct ConversionResult {
        uint256 safeId;
        uint256 sharesIssued;
        bytes32 sharesCommitment;
    }

    struct IssueSAFEParams {
        address investor;
        bytes32 termsCommitment;
        euint128 inv;
        euint128 cap;
        euint128 disc;
        ebool mfn;
        ebool proRata;
        euint128 salt;
        address targetShareClass;
        uint256 issuedAt;
        string documentRef;
        bytes encryptedMemo;
    }

    /// @notice Whether SAFE conversion is allowed (Fundraise threshold satisfied).
    function canConvertSAFEs() external view returns (bool);

    /// @notice Issue a SAFE directly (board-initiated, off-chain agreement).
    function issueSAFE(
        address investor,
        bytes32 termsCommitment,
        TermsCiphertext calldata terms,
        InEuint128 calldata salt,
        address targetShareClass,
        string calldata documentRef,
        uint256 issuedAt,
        bytes calldata encryptedMemo
    ) external returns (uint256 safeId);

    /// @notice Issue a SAFE on behalf of a Fundraise round.
    function issueSAFEFromFundraise(
        address investor,
        bytes32 termsCommitment,
        euint128 inv,
        euint128 cap,
        euint128 disc,
        ebool mfn,
        ebool proRata,
        euint128 salt,
        address targetShareClass,
        string calldata documentRef,
        bytes calldata encryptedMemo
    ) external returns (uint256 safeId);

    /// @notice Cancel an active SAFE. Board-only.
    function cancelSAFE(uint256 safeId, string calldata documentRef) external;

    /// @notice Privileged: transition the listed SAFEs from Active to PendingConversion.
    function _markPendingConversion(uint256 conversionId, uint256[] calldata safeIds) external;

    /// @notice Privileged: apply per-SAFE conversion results AFTER Equity verified the
    ///         joint proof. State flip only -- EquityIssuance handles the per-recipient
    ///         mint (with compliance) itself.
    function _applyConversion(
        uint256 conversionId,
        ConversionResult[] calldata results,
        bytes calldata encryptedSharesMemo
    ) external returns (uint256 totalSharesIssued);

    /// @notice Privileged: roll PendingConversion SAFEs back to Active.
    function _rollbackConversion(uint256 conversionId, uint256[] calldata safeIds) external;

    /// @notice Get a SAFE's full record (incl. encrypted terms).
    function getSAFE(uint256 safeId) external view returns (SAFEInstrument memory safe_);

    /// @notice All SAFE ids ever issued to `investor` (any status).
    function getInvestorSAFEs(address investor) external view returns (uint256[] memory safeIds);

    /// @notice Number of SAFEs in `Active` status.
    function getActiveSAFECount() external view returns (uint256 count);

    /// @notice Ids of SAFEs in `Active` status.
    function getActiveSAFEs() external view returns (uint256[] memory safeIds);

    /// @notice SAFEs that are not terminal yet: Active or PendingConversion.
    function getOutstandingSAFECount() external view returns (uint256 count);
}
