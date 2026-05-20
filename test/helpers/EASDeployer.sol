// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SchemaRegistry} from "@eas/contracts/SchemaRegistry.sol";
import {ISchemaRegistry} from "@eas/contracts/ISchemaRegistry.sol";
import {EAS} from "@eas/contracts/EAS.sol";

/// @dev Deploys EAS infrastructure (SchemaRegistry + EAS) from tests.
/// Needed because EAS uses pragma 0.8.28 (exact) while tests use ^0.8.35.
/// BaseTest reads this artifact via vm.readFile since vm.getCode breaks with multi-solc.
contract EASDeployer {
    function deploy() external returns (address easAddr, address schemaRegistryAddr) {
        SchemaRegistry sr = new SchemaRegistry();
        EAS eas = new EAS(ISchemaRegistry(address(sr)));
        return (address(eas), address(sr));
    }
}
