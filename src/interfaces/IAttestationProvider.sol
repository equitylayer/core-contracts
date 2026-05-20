// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ShareholderSchemas} from "../attestations/ShareholderSchemas.sol";

/// @title IAttestationProvider
/// @notice Minimal interface implemented by attestation providers registered with `ProviderRegistry`.
/// @dev The registry validates this interface via ERC-165 before granting attestation capabilities.
interface IAttestationProvider {
    function attestIdentity(address recipient, ShareholderSchemas.IdentityData calldata data, uint64 expirationTime)
        external
        returns (bytes32);

    function revokeAttestation(bytes32 schemaUID, bytes32 uid) external;

    function getSchemas() external view returns (bytes32 identity, bytes32 accreditation, bytes32 tax);
}
