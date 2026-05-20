// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";

import {Company} from "../src/Company.sol";
import {CompanyFactory} from "../src/CompanyFactory.sol";
import {ShareToken} from "../src/ShareToken.sol";
import {Vault} from "../src/Vault.sol";
import {VestingSchedule} from "../src/VestingSchedule.sol";
import {OptionPool} from "../src/OptionPool.sol";
import {SAFE} from "../src/SAFE.sol";
import {EquityIssuance} from "../src/EquityIssuance.sol";
import {Fundraise} from "../src/Fundraise.sol";
import {ConvertibleNote} from "../src/ConvertibleNote.sol";
import {ShareholderRegistry} from "../src/ShareholderRegistry.sol";
import {SnapshotEngine} from "../src/SnapshotEngine.sol";
import {DataRoom} from "../src/DataRoom.sol";
import {CompanyFactoryView} from "../src/CompanyFactoryView.sol";
import {RuleOFAC} from "../src/rules/RuleOFAC.sol";
import {RuleKYC} from "../src/rules/RuleKYC.sol";
import {RuleCountryBlocklist} from "../src/rules/RuleCountryBlocklist.sol";
import {RuleAccredited} from "../src/rules/RuleAccredited.sol";
import {RuleRegS} from "../src/rules/RuleRegS.sol";
import {RuleHoldingPeriod} from "../src/rules/RuleHoldingPeriod.sol";
import {RuleRegistry} from "../src/RuleRegistry.sol";
import {IRuleRegistry} from "../src/interfaces/rules/IRuleRegistry.sol";
import {ShareholderSchemas} from "../src/attestations/ShareholderSchemas.sol";
import {ProviderRegistry} from "../src/attestations/ProviderRegistry.sol";
import {AttestationProvider} from "../src/attestations/AttestationProvider.sol";
import {ConversionVerifier} from "../src/zk-verifiers/ConversionVerifier.sol";
import {CnRepayVerifier} from "../src/zk-verifiers/CnRepayVerifier.sol";
import {SharedHonkVerifier} from "../src/zk-verifiers/SharedHonkVerifier.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployFactories - CMTAT-based deployment script
/// @notice Deploys Company, Token, and Vault implementations with CompanyFactory
contract DeployFactories is Script {
    using stdJson for string;

    // Static addresses
    address constant EAS_MAINNET = 0xA1207F3BBa224E2c9c3c6D5aF63D0eb1582Ce587;
    address constant EAS_SEPOLIA = 0xC2679fBD37d54388Ce493F1DB75320D236e1815e;
    address constant EAS_BASE_SEPOLIA = 0x4200000000000000000000000000000000000021;
    address constant EAS_ARB_SEPOLIA = 0x2521021fc8BF070473E1e1801D3c7B4aB701E1dE;
    address constant EAS_ARB_ONE = 0xbD75f629A22Dc1ceD33dDA0b68c546A1c035c458;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant ARB_SEPOLIA_CHAIN_ID = 421614;
    uint256 constant ARB_ONE_CHAIN_ID = 42161;
    // AUSD (Agora USD) — Ethereum mainnet at this vanity address.
    address constant AUSD_ETHEREUM = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    // AUSD testnet — same address on Base Sepolia and Arbitrum Sepolia.
    // Faucet: 0xd236c18D274E54FAccC3dd9DDA4b27965a73ee6C.
    address constant AUSD_TESTNET = 0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC;

    struct Deployments {
        // Attestation
        address providerRegistry;
        address providerRegistryImpl;
        address attestationProvider;
        bytes32 idSchema;
        bytes32 accSchema;
        bytes32 taxSchema;
        // Factory
        address companyImpl;
        address tokenImpl;
        address vaultImpl;
        address vestingImpl;
        address optionPoolImpl;
        address safeImpl;
        address fundraiseImpl;
        address convertibleNoteImpl;
        address equityIssuanceImpl;
        address registryImpl;
        address snapshotEngineImpl;
        address dataRoomImpl;
        address companyFactoryImplementation;
        address companyFactory;
        address companyFactoryView;
        address ruleRegistry;
        address ruleRegistryImpl;
        // Cloneable rule impls
        address ruleOFACImpl;
        address ruleKYCImpl;
        address ruleCountryBlocklistImpl;
        address ruleAccreditedImpl;
        address ruleRegSImpl;
        address ruleHoldingPeriodImpl;
        // ZK verifiers (singleton per chain. stateless; all companies share).
        address sharedHonkVerifier;
        address conversionVerifier;
        address cnRepayVerifier;
    }

    function run() external {
        vm.startBroadcast();
        console.log("Deployer:", msg.sender);

        Deployments memory d;
        FactoryConfig memory factoryConfig = loadCompanyFactoryConfig(msg.sender);

        _deployAttestations(d, factoryConfig);
        _deployImplementations(d);
        _deployZKVerifiers(d);
        _deployFactory(d, factoryConfig);
        _seedRules(d);
        _finalizeOwnership(d, factoryConfig);
        _saveAndLog(d);

        vm.stopBroadcast();
    }

    function _saveAndLog(Deployments memory d) internal {
        saveDeploymentToJson(d);

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("\nFactory:");
        console.log("  Company Factory:", d.companyFactory);
        console.log("\nImplementations:");
        console.log("  Company:", d.companyImpl);
        console.log("  Share Token:", d.tokenImpl);
        console.log("  Vault:", d.vaultImpl);
        console.log("  Vesting:", d.vestingImpl);
        console.log("  Shareholder Registry:", d.registryImpl);
        console.log("\nZK Verifiers:");
        console.log("  Shared Honk verifier: ", d.sharedHonkVerifier);
        console.log("  Conversion:           ", d.conversionVerifier);
        console.log("  CN repay:             ", d.cnRepayVerifier);
        console.log("\nChain ID:", block.chainid);
    }

    function _deployAttestations(Deployments memory d, FactoryConfig memory factoryConfig) internal {
        console.log("\n=== Deploying Attestation Infrastructure ===");
        address eas = loadEASAddress();
        console.log("EAS:", eas);

        ProviderRegistry registryImpl = new ProviderRegistry();
        d.providerRegistryImpl = address(registryImpl);
        d.providerRegistry = address(
            new ERC1967Proxy(d.providerRegistryImpl, abi.encodeCall(ProviderRegistry.initialize, (msg.sender, eas)))
        );
        console.log("ProviderRegistry:", d.providerRegistry);

        // Load any existing schema UIDs from prior deploy (EAS schemas persist per chain).
        (bytes32 existingId, bytes32 existingAcc, bytes32 existingTax) = _loadExistingSchemas();

        AttestationProvider provider =
            new AttestationProvider(eas, d.providerRegistry, msg.sender, existingId, existingAcc, existingTax);
        d.attestationProvider = address(provider);
        console.log("AttestationProvider:", d.attestationProvider);

        provider.addOperator(factoryConfig.operator);
        console.log("  Operator added:", factoryConfig.operator);

        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](4);
        caps[0] = ProviderRegistry.ProviderType.KYC_AML;
        caps[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;
        caps[2] = ProviderRegistry.ProviderType.QUALIFIED_PURCHASER;
        caps[3] = ProviderRegistry.ProviderType.JURISDICTION;
        ProviderRegistry(d.providerRegistry).addProvider(d.attestationProvider, "D01", "", caps);

        provider.registerSchemas();
        (d.idSchema, d.accSchema, d.taxSchema) = provider.getSchemas();

        bytes32[] memory schemas = new bytes32[](3);
        schemas[0] = d.idSchema;
        schemas[1] = d.accSchema;
        schemas[2] = d.taxSchema;
        ProviderRegistry.ProviderType[] memory schemaTypes = new ProviderRegistry.ProviderType[](3);
        schemaTypes[0] = ProviderRegistry.ProviderType.KYC_AML;
        schemaTypes[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;
        schemaTypes[2] = ProviderRegistry.ProviderType.KYC_AML;
        ProviderRegistry(d.providerRegistry).setSchemaCapabilities(schemas, schemaTypes);
        console.log("Schemas registered and bound");
    }

    /// @notice Load existing schema UIDs from a previous deployment config.
    /// @dev Tries the current nested layout (`.schemas.*`) first, then falls back to the
    ///      legacy flat layout (`.idSchema`, `.accSchema`, `.taxSchema`) used by older
    ///      deployment files. EAS schemas persist per chain — registering the same schema
    ///      string twice reverts with `AlreadyExists()`, so reusing the UID is mandatory.
    /// @return idSchema, accSchema, taxSchema
    function _loadExistingSchemas() internal view returns (bytes32, bytes32, bytes32) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/deployments.", vm.toString(block.chainid), ".json");

        try vm.readFile(path) returns (string memory json) {
            bytes32 idSchema = json.readBytes32Or(".schemas.idSchema", bytes32(0));
            bytes32 accSchema = json.readBytes32Or(".schemas.accSchema", bytes32(0));
            bytes32 taxSchema = json.readBytes32Or(".schemas.taxSchema", bytes32(0));
            if (idSchema == bytes32(0)) idSchema = json.readBytes32Or(".idSchema", bytes32(0));
            if (accSchema == bytes32(0)) accSchema = json.readBytes32Or(".accSchema", bytes32(0));
            if (taxSchema == bytes32(0)) taxSchema = json.readBytes32Or(".taxSchema", bytes32(0));
            if (idSchema != bytes32(0) && accSchema != bytes32(0) && taxSchema != bytes32(0)) {
                console.log("Loaded existing schemas from previous deployment");
                return (idSchema, accSchema, taxSchema);
            }
        } catch {}

        return (bytes32(0), bytes32(0), bytes32(0));
    }

    function _deployImplementations(Deployments memory d) internal {
        console.log("\n=== Deploying Implementations ===");
        d.companyImpl = address(new Company());
        d.tokenImpl = address(new ShareToken());
        d.vaultImpl = address(new Vault());
        d.vestingImpl = address(new VestingSchedule());
        d.optionPoolImpl = address(new OptionPool());
        d.safeImpl = address(new SAFE());
        d.fundraiseImpl = address(new Fundraise());
        d.convertibleNoteImpl = address(new ConvertibleNote());
        d.equityIssuanceImpl = address(new EquityIssuance());
        d.registryImpl = address(new ShareholderRegistry());
        d.snapshotEngineImpl = address(new SnapshotEngine());
        d.dataRoomImpl = address(new DataRoom());

        console.log("Company Implementation:", d.companyImpl);
        console.log("Token Implementation:", d.tokenImpl);
        console.log("Vault Implementation:", d.vaultImpl);
        console.log("Vesting Implementation:", d.vestingImpl);
        console.log("OptionPool Implementation:", d.optionPoolImpl);
        console.log("SAFE Implementation:", d.safeImpl);
        console.log("Fundraise Implementation:", d.fundraiseImpl);
        console.log("ConvertibleNote Implementation:", d.convertibleNoteImpl);
        console.log("EquityIssuance Implementation:", d.equityIssuanceImpl);
        console.log("ShareholderRegistry Implementation:", d.registryImpl);
    }

    function _deployFactory(Deployments memory d, FactoryConfig memory factoryConfig) internal {
        _deployFactoryImpl(d);
        _initFactory(d, factoryConfig);

        d.companyFactoryView = address(new CompanyFactoryView(d.companyFactory));
        console.log("CompanyFactoryView:", d.companyFactoryView);

        _deployRuleImplementations(d);
        _deployRuleRegistry(d);
    }

    function _deployRuleImplementations(Deployments memory d) internal {
        console.log("\n=== Deploying Cloneable Rule Implementations ===");
        d.ruleOFACImpl = address(new RuleOFAC());
        d.ruleKYCImpl = address(new RuleKYC());
        d.ruleCountryBlocklistImpl = address(new RuleCountryBlocklist());
        d.ruleAccreditedImpl = address(new RuleAccredited());
        d.ruleRegSImpl = address(new RuleRegS());
        d.ruleHoldingPeriodImpl = address(new RuleHoldingPeriod());
        console.log("RuleOFAC impl:            ", d.ruleOFACImpl);
        console.log("RuleKYC impl:             ", d.ruleKYCImpl);
        console.log("RuleCountryBlocklist impl:", d.ruleCountryBlocklistImpl);
        console.log("RuleAccredited impl:      ", d.ruleAccreditedImpl);
        console.log("RuleRegS impl:            ", d.ruleRegSImpl);
        console.log("RuleHoldingPeriod impl:   ", d.ruleHoldingPeriodImpl);
    }

    function _deployRuleRegistry(Deployments memory d) internal {
        console.log("\n=== Deploying RuleRegistry ===");
        RuleRegistry registryImpl = new RuleRegistry();
        d.ruleRegistryImpl = address(registryImpl);

        d.ruleRegistry =
            address(new ERC1967Proxy(d.ruleRegistryImpl, abi.encodeCall(RuleRegistry.initialize, (msg.sender))));
        console.log("RuleRegistry Implementation:", d.ruleRegistryImpl);
        console.log("RuleRegistry Proxy:", d.ruleRegistry);

        CompanyFactory(d.companyFactory).setRuleRegistry(d.ruleRegistry);
        console.log("  CompanyFactory wired to registry");
    }

    /// @notice Deploy the four ZK verifier contracts (one per Noir circuit).
    function _deployZKVerifiers(Deployments memory d) internal {
        console.log("\n=== Deploying ZK Verifiers ===");
        SharedHonkVerifier shared = new SharedHonkVerifier();
        d.sharedHonkVerifier = address(shared);
        console.log("Shared Honk verifier:      ", d.sharedHonkVerifier);

        d.conversionVerifier = address(new ConversionVerifier(shared));
        d.cnRepayVerifier = address(new CnRepayVerifier(shared));
        console.log("Conversion verifier:       ", d.conversionVerifier);
        console.log("CN repay verifier:         ", d.cnRepayVerifier);
    }

    /// @notice Seed the registry with the rule set for jurisdictions we support today.
    function _seedRules(Deployments memory d) internal {
        console.log("\n=== Seeding RuleRegistry ===");
        address chainalysisOracle = loadChainalysisOracleAddress();

        uint16[] memory ofacBaseline = new uint16[](4);
        ofacBaseline[0] = 192; // Cuba
        ofacBaseline[1] = 364; // Iran
        ofacBaseline[2] = 408; // North Korea
        ofacBaseline[3] = 760; // Syria

        // US Reg 501(a) accredited types — the default set for RuleAccredited in US jurisdiction.
        uint8[] memory usAccreditedTypes = new uint8[](5);
        usAccreditedTypes[0] = ShareholderSchemas.ACCREDITED_US_INCOME;
        usAccreditedTypes[1] = ShareholderSchemas.ACCREDITED_US_NET_WORTH;
        usAccreditedTypes[2] = ShareholderSchemas.ACCREDITED_US_PROFESSIONAL;
        usAccreditedTypes[3] = ShareholderSchemas.ACCREDITED_US_ENTITY;
        usAccreditedTypes[4] = ShareholderSchemas.ACCREDITED_US_FAMILY_OFFICE;

        IRuleRegistry.RuleConfig[] memory usRules = new IRuleRegistry.RuleConfig[](5);

        // Approved rule set for US C-Corp. Board picks which to attach per share class.
        usRules[0] = IRuleRegistry.RuleConfig({impl: d.ruleOFACImpl, initData: abi.encode(chainalysisOracle)});
        usRules[1] = IRuleRegistry.RuleConfig({
            impl: d.ruleKYCImpl, initData: abi.encode(d.providerRegistry, d.idSchema, ShareholderSchemas.KYC_NONE)
        });
        usRules[2] = IRuleRegistry.RuleConfig({
            impl: d.ruleCountryBlocklistImpl, initData: abi.encode(d.providerRegistry, d.idSchema, ofacBaseline)
        });
        usRules[3] = IRuleRegistry.RuleConfig({
            impl: d.ruleAccreditedImpl, initData: abi.encode(d.providerRegistry, d.accSchema, usAccreditedTypes)
        });
        // RegS: complianceEnd=0 is a placeholder - board must override at attach with a real deadline.
        usRules[4] = IRuleRegistry.RuleConfig({
            impl: d.ruleRegSImpl, initData: abi.encode(d.providerRegistry, d.idSchema, uint64(0))
        });
        RuleRegistry(d.ruleRegistry).setRules(840, 1, usRules);

        console.log("  US (840) / C-Corp (1) approved rules (board attaches as needed):");
        console.log("    OFAC, KYC, CountryBlocklist, Accredited (US Reg 501), RegS");
    }

    function _deployFactoryImpl(Deployments memory d) internal {
        console.log("\n=== Deploying CompanyFactory ===");
        CompanyFactory factoryImplementation = new CompanyFactory(
            d.companyImpl,
            d.tokenImpl,
            d.vaultImpl,
            d.vestingImpl,
            d.registryImpl,
            d.optionPoolImpl,
            d.safeImpl,
            d.fundraiseImpl,
            d.convertibleNoteImpl,
            d.equityIssuanceImpl,
            d.snapshotEngineImpl,
            d.dataRoomImpl,
            d.conversionVerifier,
            d.cnRepayVerifier
        );
        d.companyFactoryImplementation = address(factoryImplementation);
        console.log("CompanyFactory Implementation:", d.companyFactoryImplementation);
    }

    function _initFactory(Deployments memory d, FactoryConfig memory fc) internal {
        d.companyFactory = address(
            new ERC1967Proxy(
                d.companyFactoryImplementation,
                abi.encodeCall(
                    CompanyFactory.initialize,
                    (fc.treasury, fc.deploymentFee, msg.sender, fc.shareClassFee, fc.operator)
                )
            )
        );

        CompanyFactory f = CompanyFactory(d.companyFactory);
        console.log("CompanyFactory Proxy:", d.companyFactory);
        console.log("  Treasury:", f.treasury());
        console.log("  Operator:", f.operator());

        address payToken = loadDefaultPaymentTokenAddress();
        f.addPaymentTokenToAllowlist(payToken);
        console.log("  Default payment token:", payToken);
    }

    /// @notice Transfer ownership of all deployed contracts to the configured owner.
    function _finalizeOwnership(Deployments memory d, FactoryConfig memory fc) internal {
        console.log("\n=== Transferring Ownership ===");
        console.log("  Target owner:", fc.owner);

        ProviderRegistry(d.providerRegistry).transferOwnership(fc.owner);
        AttestationProvider(d.attestationProvider).transferOwnership(fc.owner);
        CompanyFactory(d.companyFactory).transferOwnership(fc.owner);
        RuleRegistry(d.ruleRegistry).transferOwnership(fc.owner);

        console.log("  ProviderRegistry owner:", ProviderRegistry(d.providerRegistry).owner());
        console.log("  AttestationProvider owner:", AttestationProvider(d.attestationProvider).owner());
        console.log("  CompanyFactory owner:", CompanyFactory(d.companyFactory).owner());
        console.log("  RuleRegistry owner:", RuleRegistry(d.ruleRegistry).owner());
    }

    /// @notice Save deployment data to JSON file
    function saveDeploymentToJson(Deployments memory d) internal {
        string memory path =
            string.concat(vm.projectRoot(), "/config/deployments.", vm.toString(block.chainid), ".json");

        string memory contractsJson = _serializeContracts(d);
        string memory cloneImplsJson = _serializeCloneImplementations(d);
        string memory schemasJson = _serializeSchemas(d);
        string memory configJson = _serializeConfig(d);

        string memory root = "deployments";
        string memory json;
        json = vm.serializeUint(root, "chainId", block.chainid);
        json = vm.serializeUint(root, "deploymentBlock", _currentBlockNumber());
        json = vm.serializeUint(root, "deploymentTimestamp", block.timestamp);
        json = vm.serializeUint(root, "schemaVersion", 2);
        json = vm.serializeString(root, "contracts", contractsJson);
        json = vm.serializeString(root, "cloneImplementations", cloneImplsJson);
        json = vm.serializeString(root, "schemas", schemasJson);
        json = vm.serializeString(root, "config", configJson);

        vm.writeJson(json, path);
        console.log("Written to:", path);
    }

    /// @dev Proxied contracts get `{proxy, implementation}`; non-proxied get `{address}`.
    function _serializeContracts(Deployments memory d) internal returns (string memory) {
        string memory contractsKey = "contracts";
        string memory json;

        json = vm.serializeString(
            contractsKey,
            "companyFactory",
            _proxyEntry("companyFactory.entry", d.companyFactory, d.companyFactoryImplementation)
        );
        json = vm.serializeString(
            contractsKey,
            "providerRegistry",
            _proxyEntry("providerRegistry.entry", d.providerRegistry, d.providerRegistryImpl)
        );
        json = vm.serializeString(
            contractsKey, "ruleRegistry", _proxyEntry("ruleRegistry.entry", d.ruleRegistry, d.ruleRegistryImpl)
        );

        json = vm.serializeString(
            contractsKey, "attestationProvider", _addressEntry("attestationProvider.entry", d.attestationProvider)
        );
        json = vm.serializeString(
            contractsKey, "companyFactoryView", _addressEntry("companyFactoryView.entry", d.companyFactoryView)
        );
        json = vm.serializeString(contractsKey, "eas", _addressEntry("eas.entry", loadEASAddress()));

        json = vm.serializeString(
            contractsKey, "sharedHonkVerifier", _addressEntry("sharedHonkVerifier.entry", d.sharedHonkVerifier)
        );
        json = vm.serializeString(
            contractsKey, "conversionVerifier", _addressEntry("conversionVerifier.entry", d.conversionVerifier)
        );
        json = vm.serializeString(
            contractsKey, "cnRepayVerifier", _addressEntry("cnRepayVerifier.entry", d.cnRepayVerifier)
        );

        return json;
    }

    function _proxyEntry(string memory entryKey, address proxy, address implementation)
        internal
        returns (string memory)
    {
        string memory json;
        json = vm.serializeAddress(entryKey, "proxy", proxy);
        json = vm.serializeAddress(entryKey, "implementation", implementation);
        return json;
    }

    function _addressEntry(string memory entryKey, address addr) internal returns (string memory) {
        return vm.serializeAddress(entryKey, "address", addr);
    }

    /// @dev EIP-1167 clone masters (not UUPS implementations — those live inside `contracts.<name>.implementation`).
    function _serializeCloneImplementations(Deployments memory d) internal returns (string memory) {
        string memory k = "cloneImplementations";
        string memory json;
        json = vm.serializeAddress(k, "company", d.companyImpl);
        json = vm.serializeAddress(k, "token", d.tokenImpl);
        json = vm.serializeAddress(k, "vault", d.vaultImpl);
        json = vm.serializeAddress(k, "vesting", d.vestingImpl);
        json = vm.serializeAddress(k, "optionPool", d.optionPoolImpl);
        json = vm.serializeAddress(k, "safe", d.safeImpl);
        json = vm.serializeAddress(k, "fundraise", d.fundraiseImpl);
        json = vm.serializeAddress(k, "convertibleNote", d.convertibleNoteImpl);
        json = vm.serializeAddress(k, "shareholderRegistry", d.registryImpl);
        json = vm.serializeAddress(k, "snapshotEngine", d.snapshotEngineImpl);
        json = vm.serializeAddress(k, "dataRoom", d.dataRoomImpl);
        // Cloneable rule masters — CompanyFactory clones these per share class via RuleRegistry.
        json = vm.serializeAddress(k, "ruleOFAC", d.ruleOFACImpl);
        json = vm.serializeAddress(k, "ruleKYC", d.ruleKYCImpl);
        json = vm.serializeAddress(k, "ruleCountryBlocklist", d.ruleCountryBlocklistImpl);
        json = vm.serializeAddress(k, "ruleAccredited", d.ruleAccreditedImpl);
        json = vm.serializeAddress(k, "ruleRegS", d.ruleRegSImpl);
        json = vm.serializeAddress(k, "ruleHoldingPeriod", d.ruleHoldingPeriodImpl);
        return json;
    }

    function _serializeSchemas(Deployments memory d) internal returns (string memory) {
        string memory k = "schemas";
        string memory json;
        json = vm.serializeBytes32(k, "idSchema", d.idSchema);
        json = vm.serializeBytes32(k, "accSchema", d.accSchema);
        json = vm.serializeBytes32(k, "taxSchema", d.taxSchema);
        return json;
    }

    function _serializeConfig(Deployments memory d) internal returns (string memory) {
        CompanyFactory f = CompanyFactory(d.companyFactory);
        string memory k = "config";
        string memory json;
        json = vm.serializeAddress(k, "owner", f.owner());
        json = vm.serializeAddress(k, "treasury", f.treasury());
        json = vm.serializeAddress(k, "operator", f.operator());
        json = vm.serializeUint(k, "deploymentFee", f.deploymentFee());
        json = vm.serializeUint(k, "shareClassFee", f.shareClassFee());
        json = vm.serializeAddress(k, "defaultPaymentToken", loadDefaultPaymentTokenAddress());
        return json;
    }

    struct FactoryConfig {
        address treasury;
        uint256 deploymentFee;
        uint256 shareClassFee;
        address owner;
        address operator;
    }

    /// @notice Load factory configuration from JSON or use defaults
    /// @param defaultAddress Default address to use for treasury and owner
    /// @return FactoryConfig struct with treasury, deploymentFee, and owner
    function loadCompanyFactoryConfig(address defaultAddress) internal view returns (FactoryConfig memory) {
        string memory root = vm.projectRoot();
        string memory configFile = string.concat("factory-config.", vm.toString(block.chainid), ".json");
        string memory path = string.concat(root, "/config/", configFile);

        try vm.readFile(path) returns (string memory json) {
            address treasury = json.readAddress(".treasury");
            uint256 deploymentFee = json.readUint(".deploymentFee");
            uint256 shareClassFee = json.readUint(".shareClassFee");
            address owner = json.readAddress(".owner");
            address _operator = json.readAddress(".operator");

            console.log("\n=== Factory Configuration (from config/%s) ===", configFile);
            console.log("Treasury:", treasury);
            console.log("Deployment Fee:", deploymentFee);
            console.log("Share Class Fee:", shareClassFee);
            console.log("Owner:", owner);
            console.log("Operator:", _operator);

            return FactoryConfig({
                treasury: treasury,
                deploymentFee: deploymentFee,
                shareClassFee: shareClassFee,
                owner: owner,
                operator: _operator
            });
        } catch {
            console.log("\n=== Factory Configuration (defaults) ===");
            console.log("%s not found, using deployer as treasury/owner/operator", configFile);
            console.log("Treasury:", defaultAddress);
            console.log("Deployment Fee: 0.1 ether");
            console.log("Share Class Fee: 0.01 ether");
            console.log("Owner:", defaultAddress);
            console.log("Operator:", defaultAddress);

            return FactoryConfig({
                treasury: defaultAddress,
                deploymentFee: 0.1 ether,
                shareClassFee: 0.01 ether,
                owner: defaultAddress,
                operator: defaultAddress
            });
        }
    }

    /// @notice Load Chainalysis oracle address based on chain
    /// @dev Mainnet: official oracle. Non-mainnet: mock from config (deployed by DeployDevelopment)
    /// @return Oracle address
    function loadChainalysisOracleAddress() internal view returns (address) {
        // Mainnet: Use official Chainalysis oracle
        if (block.chainid == 1) {
            return 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;
        }

        // Non-mainnet: Read mock oracle from mocks config
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/mocks.", vm.toString(block.chainid), ".json");

        try vm.readFile(path) returns (string memory json) {
            return json.readAddress(".mockChainalysisOracle");
        } catch {
            revert(string.concat("Mocks config not found: ", path, "\nRun DeployDevelopment first."));
        }
    }

    /// @notice Load EAS address based on chain
    /// @dev For mainnet/Sepolia, uses official EAS addresses
    ///      For localhost, reads from mocks config (deployed by DeployDevelopment)
    function loadEASAddress() internal view returns (address) {
        if (block.chainid == 1) return EAS_MAINNET;
        if (block.chainid == 11155111) return EAS_SEPOLIA;
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return EAS_BASE_SEPOLIA;
        if (block.chainid == ARB_SEPOLIA_CHAIN_ID) return EAS_ARB_SEPOLIA;
        if (block.chainid == ARB_ONE_CHAIN_ID) return EAS_ARB_ONE;

        // For localhost: Read from mocks config
        string memory root = vm.projectRoot();
        string memory chainIdStr = vm.toString(block.chainid);
        string memory path = string.concat(root, "/config/mocks.", chainIdStr, ".json");

        try vm.readFile(path) returns (string memory json) {
            return json.readAddress(".eas");
        } catch {
            revert(
                string.concat("Mocks config not found: ", path, "\nRun DeployDevelopment first on non-mainnet chains")
            );
        }
    }

    /// @notice Load default payment token to seed in CompanyFactory allowlist
    /// @dev Mainnet/Base Sepolia use fixed tokens. Other chains read mockUSD from mocks config.
    function loadDefaultPaymentTokenAddress() internal view returns (address) {
        if (block.chainid == 1) return AUSD_ETHEREUM;
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return AUSD_TESTNET;
        if (block.chainid == ARB_SEPOLIA_CHAIN_ID) return AUSD_TESTNET;

        // For localhost/dev chains: Read MockUSD from mocks config
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/mocks.", vm.toString(block.chainid), ".json");

        try vm.readFile(path) returns (string memory json) {
            return json.readAddress(".mockUSD");
        } catch {
            revert(string.concat("Mocks config not found for mockUSD: ", path, "\nRun DeployDevelopment first."));
        }
    }

    /// @notice Current chain's native block number. On Arbitrum chains returns L1. We want arbBlockNumber().
    function _currentBlockNumber() internal view returns (uint256) {
        if (block.chainid == ARB_ONE_CHAIN_ID || block.chainid == ARB_SEPOLIA_CHAIN_ID) {
            (bool ok, bytes memory ret) = address(0x0000000000000000000000000000000000000064)
                .staticcall(abi.encodeWithSignature("arbBlockNumber()"));
            if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        }
        return block.number;
    }
}
