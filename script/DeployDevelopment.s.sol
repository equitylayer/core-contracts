// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";

import {MockChainalysisOracle} from "../src/mocks/MockChainalysisOracle.sol";
import {MockUSD} from "../src/mocks/MockUSD.sol";
import {SchemaRegistry} from "@eas/contracts/SchemaRegistry.sol";
import {EAS} from "@eas/contracts/EAS.sol";
import {MockTaskManager} from "@cofhe/mock-contracts/MockTaskManager.sol";
import {MockThresholdNetwork} from "@cofhe/mock-contracts/MockThresholdNetwork.sol";
import {TASK_MANAGER_ADDRESS} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title DeployDevelopment - Mock external dependencies for localhost
/// @notice Deploys mock contracts that simulate external services (EAS, Chainalysis, CoFHE)
contract DeployDevelopment is Script {
    using stdJson for string;
    // CoFHE mock bytecodes must be etched at hardcoded addresses BEFORE running this script.
    address constant ACL_ADDR = 0xa6Ea4b5291d044D93b73b3CFf3109A1128663E8B;
    address constant THRESHOLD_NETWORK_ADDR = 0x0000000000000000000000000000000000005002;

    function run() external {
        // Safety check: never mainnet
        require(block.chainid != 1, "DeployDevelopment: Cannot deploy mocks to mainnet");

        vm.startBroadcast();
        console.log("=== Deploying Mock External Dependencies ===");
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);

        // 1) Deploy MockChainalysisOracle
        console.log("\n--- MockChainalysisOracle ---");
        MockChainalysisOracle mockOracle = new MockChainalysisOracle(msg.sender);
        console.log("Address:", address(mockOracle));

        // Add test addresses to sanctions list (accounts #7 and #6)
        address[] memory sanctionedAddresses = new address[](2);
        sanctionedAddresses[0] = 0x14Dc79964Da2C08Da15fd353D30d9CBa8C7c3f04; // Anvil account #7
        sanctionedAddresses[1] = 0x976EA74026E726554dB657fA54763abd0C3a0aa9; // Anvil account #6
        mockOracle.addToSanctionsListMultiple(sanctionedAddresses);
        console.log("  Added 2 test addresses to sanctions list");

        // 2) Deploy MockUSD (development stablecoin)
        console.log("\n--- MockUSD ---");
        MockUSD mockUSD = new MockUSD();
        console.log("Address:", address(mockUSD));

        // Mint 5M MUSD to all 10 standard Anvil accounts
        address[10] memory anvilAccounts = [
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // #0
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8, // #1
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, // #2
            0x90F79bf6EB2c4f870365E785982E1f101E93b906, // #3
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65, // #4
            0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc, // #5
            0x976EA74026E726554dB657fA54763abd0C3a0aa9, // #6 (sanctioned)
            0x14Dc79964Da2C08Da15fd353D30d9CBa8C7c3f04, // #7 (sanctioned)
            0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f, // #8 (operator)
            0xa0Ee7A142d267C1f36714E4a8F75612F20a79720 // #9 (deployer/owner)
        ];

        uint256 mintAmount = 5_000_000e6;
        for (uint256 i = 0; i < anvilAccounts.length; i++) {
            mockUSD.mint(anvilAccounts[i], mintAmount);
        }
        console.log("  Minted 5M MUSD to 10 Anvil accounts");

        // 3) Deploy EAS infrastructure (only on localhost - testnets have real EAS)
        address schemaRegistryAddr;
        address easAddr;
        if (block.chainid == 31337) {
            console.log("\n--- Mock EAS (localhost) ---");
            SchemaRegistry schemaRegistry = new SchemaRegistry();
            schemaRegistryAddr = address(schemaRegistry);
            console.log("SchemaRegistry:", schemaRegistryAddr);

            EAS eas = new EAS(schemaRegistry);
            easAddr = address(eas);
            console.log("EAS:", easAddr);
        } else {
            console.log("\n--- EAS: Using official testnet contracts ---");
        }

        // 4) Initialize CoFHE mocks (bytecodes MUST have been etched)
        if (block.chainid == 31337) {
            console.log("\n--- CoFHE Mocks (Anvil) ---");

            MockTaskManager tm = MockTaskManager(TASK_MANAGER_ADDRESS);
            tm.initialize(msg.sender);
            tm.setSecurityZoneMin(0);
            tm.setSecurityZoneMax(1);
            tm.setACLContract(ACL_ADDR);

            MockThresholdNetwork tn = MockThresholdNetwork(THRESHOLD_NETWORK_ADDR);
            tn.initialize(TASK_MANAGER_ADDRESS, ACL_ADDR);

            console.log("MockTaskManager:", TASK_MANAGER_ADDRESS);
            console.log("MockACL:", ACL_ADDR);
            console.log("MockThresholdNetwork:", THRESHOLD_NETWORK_ADDR);
        }

        // 5) Save to mocks config
        saveMocksToJson(address(mockOracle), address(mockUSD), schemaRegistryAddr, easAddr);

        console.log("\n=== MOCKS DEPLOYMENT COMPLETE ===");
        vm.stopBroadcast();
    }

    function saveMocksToJson(address mockOracle, address mockUSD, address schemaRegistry, address eas) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/mocks.", vm.toString(block.chainid), ".json");

        string memory label = "mocks";
        string memory json;

        json = vm.serializeUint(label, "chainId", block.chainid);
        json = vm.serializeAddress(label, "mockChainalysisOracle", mockOracle);
        json = vm.serializeAddress(label, "mockUSD", mockUSD);
        json = vm.serializeAddress(label, "schemaRegistry", schemaRegistry);
        json = vm.serializeAddress(label, "eas", eas);

        vm.writeJson(json, path);
        console.log("\nMocks written to:", path);
    }
}
