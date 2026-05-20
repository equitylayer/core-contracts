// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IRuleCloneable} from "../interfaces/rules/IRuleCloneable.sol";

/// @title RuleCloning
/// @notice Shared helpers for safely producing IRuleCloneable clones.
library RuleCloning {
    /// @notice Returns true iff `impl` implements ERC-165 and advertises {IRuleCloneable}.
    function supportsRuleCloneable(address impl) internal view returns (bool) {
        bytes memory payload =
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IRuleCloneable).interfaceId);
        (bool ok, bytes memory ret) = impl.staticcall(payload);
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @notice Clone `impl` via EIP-1167 and invoke its `IRuleCloneable.initialize(initData, company)`.
    function cloneAndInitialize(address impl, bytes memory initData, address company) internal returns (address clone) {
        clone = Clones.clone(impl);
        IRuleCloneable(clone).initialize(initData, company);
    }
}
