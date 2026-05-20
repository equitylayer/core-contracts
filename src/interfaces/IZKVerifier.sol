// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IZKVerifier
/// @notice Shared interface for all ZK verifier contracts in the obolos ZK SAFE / CN flows.
/// the array in the order the corresponding circuit expects.
interface IZKVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
