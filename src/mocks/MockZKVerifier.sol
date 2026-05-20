// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IZKVerifier} from "../interfaces/IZKVerifier.sol";

/// @notice Test-only verifier. Returns `valid` (default true) regardless of proof contents.
///         Optionally checks that `publicInputs` matches an expected array (length +
///         element-wise) so tests can assert callers are constructing the right inputs.
contract MockZKVerifier is IZKVerifier {
    bool public valid = true;
    bool public requireExpectedInputs;
    bytes32[] private _expectedPublicInputs;

    function setValid(bool newValid) external {
        valid = newValid;
    }

    function setExpectedPublicInputs(bytes32[] calldata expected) external {
        delete _expectedPublicInputs;
        for (uint256 i = 0; i < expected.length; i++) {
            _expectedPublicInputs.push(expected[i]);
        }
        requireExpectedInputs = true;
    }

    function clearExpectedPublicInputs() external {
        delete _expectedPublicInputs;
        requireExpectedInputs = false;
    }

    function expectedPublicInputs() external view returns (bytes32[] memory) {
        return _expectedPublicInputs;
    }

    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool) {
        proof;
        if (!valid) return false;
        if (requireExpectedInputs) {
            if (publicInputs.length != _expectedPublicInputs.length) return false;
            for (uint256 i = 0; i < publicInputs.length; i++) {
                if (publicInputs[i] != _expectedPublicInputs[i]) return false;
            }
        }
        return true;
    }
}
