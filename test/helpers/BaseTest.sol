// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "forge-std/Test.sol";
import {CoFheTest} from "@cofhe/mock-contracts/foundry/CoFheTest.sol";
import "../../src/Company.sol";
import "../../src/ShareToken.sol";
import "../../src/Vault.sol";
import "../../src/VestingSchedule.sol";
import "../../src/OptionPool.sol";
import "../../src/SAFE.sol";
import "../../src/Fundraise.sol";
import "../../src/ConvertibleNote.sol";
import "../../src/EquityIssuance.sol";
import "../../src/CompanyFactory.sol";
import "../../src/ShareholderRegistry.sol";
import "../../src/interfaces/IVault.sol";
import "../../src/interfaces/ICompanyFactory.sol";
import "../../src/interfaces/ISAFE.sol";
import "../../src/interfaces/IFundraise.sol";
import "../../src/interfaces/IConvertibleNote.sol";
import "../../src/interfaces/IEquityIssuance.sol";
import {SnapshotEngine} from "../../src/SnapshotEngine.sol";
import {DataRoom} from "../../src/DataRoom.sol";
import {IDataRoom} from "../../src/interfaces/IDataRoom.sol";
import {ProviderRegistry} from "../../src/attestations/ProviderRegistry.sol";
import {AttestationProvider} from "../../src/attestations/AttestationProvider.sol";
import {ShareholderSchemas} from "../../src/attestations/ShareholderSchemas.sol";
import {MockUSD} from "../../src/mocks/MockUSD.sol";
import {MockZKVerifier} from "../../src/mocks/MockZKVerifier.sol";
import {RuleKYC} from "../../src/rules/RuleKYC.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ISnapshotEngine} from "CMTAT/contracts/interfaces/engine/ISnapshotEngine.sol";
import {IRuleEngine} from "CMTAT/contracts/interfaces/engine/IRuleEngine.sol";
import {RuleEngine} from "RuleEngine/src/RuleEngine.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ===================
// Generic Test Helper Contracts
// ===================

/// @dev Helper contract that can toggle between accepting and rejecting ETH
/// @dev Useful for testing failed refund scenarios and pull payment patterns
/// @dev Defaults to rejecting ETH (rejectETH = true)
contract RejectEther {
    bool public rejectETH = true;

    function setRejectETH(bool _reject) external {
        rejectETH = _reject;
    }

    receive() external payable {
        if (rejectETH) {
            revert("ETH rejected");
        }
    }
}

/// @title BaseTest
/// @notice Base test setup that mimics production deployment
abstract contract BaseTest is CoFheTest {
    Company company;
    ShareToken shareToken;
    Vault vault;
    VestingSchedule vestingSchedule;
    CompanyFactory factory;
    SnapshotEngine snapshotEngine;
    RuleEngine ruleEngine;
    MockUSD musd;
    MockZKVerifier conversionVerifier;
    MockZKVerifier cnRepayVerifier;
    /// @notice Cached EquityIssuance reference. Tests should call `issuance.issueGrant(...)`
    /// directly rather than `issuance.issueGrant(...)`, since the chained form
    /// consumes a `vm.prank` on the getter call.
    EquityIssuance issuance;

    // Attestation infrastructure (initialized by _setupEAS)
    address eas;
    ProviderRegistry providerRegistry;
    AttestationProvider attestationProvider;
    bytes32 identitySchema;
    bytes32 accreditationSchema;
    bytes32 taxSchema;

    // Test addresses
    address board = address(0x1234);
    address nonBoard = address(0x5678);
    address investor = address(0xBEEF);
    address employee = address(0xCAFE);
    address founder = address(0xFACE);
    address factoryOwner = address(0xF1);
    address treasury = address(0xF2);
    address obolosOperator = address(0xD01);
    address attestationOperator = address(0xA1);

    // Shared test constants (MUSD = 6 decimals)
    uint256 constant CAP_5M = 5_000_000e6;
    uint256 constant CAP_10M = 10_000_000e6;
    uint256 constant CAP_20M = 20_000_000e6;
    uint256 constant DISCOUNT_20PCT = 2000; // 20% in basis points
    uint256 constant PRICE_PER_SHARE = 1e6; // $1/share

    // Events
    event BoardChanged(address indexed oldBoard, address indexed newBoard, string documentRef);

    /// @dev Base initialization that all tests can use
    function _baseSetUp() internal {
        // Deploy MockUSD (payment token for all business operations)
        musd = new MockUSD();
        conversionVerifier = new MockZKVerifier();
        cnRepayVerifier = new MockZKVerifier();

        // Deploy implementation contracts for factory
        Company companyImpl = new Company();
        ShareToken tokenImpl = new ShareToken();
        Vault vaultImpl = new Vault();
        VestingSchedule vestingImpl = new VestingSchedule();
        ShareholderRegistry registryImpl = new ShareholderRegistry();
        OptionPool optionPoolImpl = new OptionPool();
        SAFE safeImpl = new SAFE();
        Fundraise fundraiseImpl = new Fundraise();
        ConvertibleNote convertibleNoteImpl = new ConvertibleNote();
        EquityIssuance equityIssuanceImpl = new EquityIssuance();
        SnapshotEngine snapshotEngineImpl = new SnapshotEngine();
        DataRoom dataRoomImpl = new DataRoom();
        CompanyFactory factoryImpl = new CompanyFactory(
            address(companyImpl),
            address(tokenImpl),
            address(vaultImpl),
            address(vestingImpl),
            address(registryImpl),
            address(optionPoolImpl),
            address(safeImpl),
            address(fundraiseImpl),
            address(convertibleNoteImpl),
            address(equityIssuanceImpl),
            address(snapshotEngineImpl),
            address(dataRoomImpl),
            address(conversionVerifier),
            address(cnRepayVerifier)
        );

        // Deploy factory as UUPS proxy
        bytes memory initData = abi.encodeWithSelector(
            CompanyFactory.initialize.selector,
            treasury,
            0.1 ether, // Deployment fee for tests
            factoryOwner,
            0.05 ether, // Share class fee
            obolosOperator
        );
        address factoryProxy = address(new ERC1967Proxy(address(factoryImpl), initData));
        factory = CompanyFactory(factoryProxy);

        vm.prank(factoryOwner);
        factory.addPaymentTokenToAllowlist(address(musd));
    }

    // ============ EAS / Attestation Setup ============

    /// @dev Deploy real EAS infrastructure: SchemaRegistry + EAS + ProviderRegistry + AttestationProvider
    /// @dev Uses EASDeployer helper (0.8.28) to avoid pragma conflict with BaseTest (^0.8.35).
    ///      vm.getCode breaks with multi-solc, so we read artifact JSON + deploy with CREATE.
    function _setupEAS() internal {
        // Deploy EASDeployer (compiled with 0.8.28 via EASDeployer.sol)
        bytes memory deployerBytecode = _readArtifactBytecode("EASDeployer.sol", "EASDeployer");
        address easDeployer;
        assembly {
            easDeployer := create(0, add(deployerBytecode, 0x20), mload(deployerBytecode))
        }
        require(easDeployer != address(0), "EASDeployer deployment failed");
        (bool ok, bytes memory ret) = easDeployer.call(abi.encodeWithSignature("deploy()"));
        require(ok, "EASDeployer.deploy() failed");
        address schemaRegistry;
        (eas, schemaRegistry) = abi.decode(ret, (address, address));

        ProviderRegistry registryImpl = new ProviderRegistry();
        providerRegistry = ProviderRegistry(
            address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(ProviderRegistry.initialize, (board, eas))))
        );

        attestationProvider = new AttestationProvider(
            eas, address(providerRegistry), board, bytes32(0), keccak256("test:terms"), keccak256("test:payment")
        );

        ProviderRegistry.ProviderType[] memory caps = new ProviderRegistry.ProviderType[](4);
        caps[0] = ProviderRegistry.ProviderType.KYC_AML;
        caps[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;
        caps[2] = ProviderRegistry.ProviderType.QUALIFIED_PURCHASER;
        caps[3] = ProviderRegistry.ProviderType.JURISDICTION;

        vm.startPrank(board);
        providerRegistry.addProvider(address(attestationProvider), "D01 Provider", "", caps);
        attestationProvider.registerSchemas();
        attestationProvider.addOperator(attestationOperator);

        // Bind schemas to capability types
        (identitySchema, accreditationSchema, taxSchema) = attestationProvider.getSchemas();
        bytes32[] memory schemas = new bytes32[](3);
        schemas[0] = identitySchema;
        schemas[1] = accreditationSchema;
        schemas[2] = taxSchema;
        ProviderRegistry.ProviderType[] memory schemaTypes = new ProviderRegistry.ProviderType[](3);
        schemaTypes[0] = ProviderRegistry.ProviderType.KYC_AML;
        schemaTypes[1] = ProviderRegistry.ProviderType.ACCREDITED_INVESTOR;
        schemaTypes[2] = ProviderRegistry.ProviderType.KYC_AML;
        providerRegistry.setSchemaCapabilities(schemas, schemaTypes);
        vm.stopPrank();
    }

    /// @dev Convenience: attest identity for a recipient with given KYC level
    function _attestIdentity(address recipient, uint8 kycLevel, uint64 expiration) internal returns (bytes32) {
        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.IdentityData({
            providerId: "obolos:test",
            externalId: "",
            countryCode: 840,
            isUSPerson: true,
            investorType: ShareholderSchemas.INVESTOR_INDIVIDUAL,
            entityName: "",
            kycLevel: kycLevel,
            sanctionsCleared: true,
            verifiedAt: 0
        });
        vm.prank(attestationOperator);
        return attestationProvider.attestIdentity(recipient, data, expiration);
    }

    // ============ Rule Test Setup ============

    /// @dev Full rule test setup: factory + company + token + EAS + rules
    function _setupRuleTest() internal {
        _baseSetUp();
        _setupEAS();

        ShareholderRegistry registry = new ShareholderRegistry();
        VestingSchedule vesting = new VestingSchedule();
        OptionPool optionPool = new OptionPool();
        SAFE safeContract = new SAFE();
        Fundraise fundraise = new Fundraise();
        ConvertibleNote noteContract = new ConvertibleNote();
        EquityIssuance issuanceContract = new EquityIssuance();
        company = new Company();
        registry.initialize(address(company));
        vesting.initialize(address(company));
        optionPool.initialize(address(company));
        fundraise.initialize(address(company));
        issuanceContract.initialize(address(company), address(fundraise), address(conversionVerifier));
        safeContract.initialize(address(company), address(fundraise), address(issuanceContract));
        noteContract.initialize(
            address(company), address(fundraise), address(issuanceContract), address(cnRepayVerifier)
        );
        DataRoom dataRoomContract = new DataRoom();
        dataRoomContract.initialize(address(company));
        company.initialize(
            Company.InitParams({
                board: board,
                vault: IVault(address(vault)),
                factory: ICompanyFactory(address(factory)),
                shareholderRegistry: registry,
                vestingSchedule: vesting,
                optionPool: optionPool,
                safe: ISAFE(address(safeContract)),
                fundraise: IFundraise(address(fundraise)),
                convertibleNote: IConvertibleNote(address(noteContract)),
                issuance: IEquityIssuance(address(issuanceContract)),
                dataRoom: IDataRoom(address(dataRoomContract)),
                paymentToken: IERC20(address(musd)),
                name: "Test Company",
                ticker: "TEST",
                metadataUri: "",
                countryCode: 840,
                entityType: 1
            })
        );

        (shareToken, snapshotEngine, ruleEngine) = _deployToken("Common Stock", "CS", 1_000_000);
        shareToken.grantRole(shareToken.MINTER_ROLE(), address(issuanceContract));
        shareToken.setCompanyAddress(address(company));
        shareToken.setIssuanceAddress(address(issuanceContract));
        issuance = issuanceContract;
        _deployAndAddRules();
        _issueInitialShares();
        _transferAdminToBoard();
    }

    /// @dev Override this to deploy your rule contracts and add them to RuleEngine
    function _deployAndAddRules() internal virtual {}

    /// @dev Override this to issue initial shares for your test scenario
    function _issueInitialShares() internal virtual {}

    /// @dev Transfer admin roles from test contract to board
    function _transferAdminToBoard() internal {
        shareToken.grantRole(shareToken.DEFAULT_ADMIN_ROLE(), board);
        shareToken.renounceRole(shareToken.DEFAULT_ADMIN_ROLE(), address(this));
        ruleEngine.grantRole(ruleEngine.DEFAULT_ADMIN_ROLE(), board);
        ruleEngine.renounceRole(ruleEngine.DEFAULT_ADMIN_ROLE(), address(this));
    }

    // ============ Token Deployment ============

    /// @dev Deploy a token with engines - mimics production CompanyFactory.deployShareClass()
    /// @param name Token name
    /// @param symbol Token symbol
    /// @param authorizedShares Initial authorized shares
    /// @return token The deployed ShareToken
    /// @return snapshot The deployed SnapshotEngine
    /// @return rule The deployed RuleEngine (no rules added by default)
    function _deployToken(string memory name, string memory symbol, uint256 authorizedShares)
        internal
        returns (ShareToken token, SnapshotEngine snapshot, RuleEngine rule)
    {
        // 1. Deploy token (EIP-1167 clone in production, direct deploy in tests)
        token = new ShareToken();

        // 2. Deploy snapshot engine with real token address (required for dividends)
        snapshot = new SnapshotEngine();
        snapshot.initialize(
            ERC20Upgradeable(address(token)),
            address(this) // Admin (Factory in production)
        );

        // 3. Deploy RuleEngine (production-style: always deployed, rules added later)
        rule = new RuleEngine(
            address(this), // Admin (board in production)
            address(0), // No forwarder for tests
            address(token) // Token contract
        );

        // 3.5. Deploy ShareholderRegistry
        ShareholderRegistry registry = new ShareholderRegistry();
        registry.initialize(address(this)); // Initialize with company address

        // 4. Initialize token with both engines
        token.initialize(
            address(this), // Admin (Factory in production)
            name,
            symbol,
            authorizedShares,
            ISnapshotEngine(address(snapshot)),
            IRuleEngine(address(rule)),
            registry // Shareholder tracking
        );

        // 5. Register token on registry (production does this in _createShareClass)
        registry.registerToken(address(token));
    }

    // ============ Company Deployment ============

    /// @dev Deploy a company through the factory (returns all deployed contracts)
    function _deployCompany(string memory companyName, string memory ticker, string memory metadataUri)
        internal
        returns (
            Company deployedCompany,
            Vault deployedVault,
            VestingSchedule deployedVesting,
            ShareholderRegistry deployedRegistry,
            OptionPool deployedOptionPool,
            SAFE deployedSAFE,
            Fundraise deployedFundraise,
            ConvertibleNote deployedConvertibleNote
        )
    {
        vm.deal(board, 10 ether);
        vm.prank(board);
        CompanyFactory.DeploymentResult memory result =
            factory.deployCompany{value: 0.1 ether}(companyName, ticker, metadataUri, 840, 1, IERC20(address(musd)));

        deployedCompany = Company(result.companyAddress);
        deployedVault = Vault(payable(result.vaultAddress));
        deployedVesting = VestingSchedule(result.vestingAddress);
        deployedRegistry = ShareholderRegistry(result.registryAddress);
        deployedOptionPool = OptionPool(result.optionPoolAddress);
        deployedSAFE = SAFE(result.safeAddress);
        deployedFundraise = Fundraise(result.fundraiseAddress);
        deployedConvertibleNote = ConvertibleNote(result.convertibleNoteAddress);
        // Cache the EquityIssuance reference so tests can `vm.prank(board); issuance.issueGrant(...)`
        // without the chained `.issuance()` call eating the prank.
        issuance = EquityIssuance(result.equityIssuanceAddress);

        return (
            deployedCompany,
            deployedVault,
            deployedVesting,
            deployedRegistry,
            deployedOptionPool,
            deployedSAFE,
            deployedFundraise,
            deployedConvertibleNote
        );
    }

    /// @dev Setup a complete company for testing (stores in contract state variables)
    function _setupCompany() internal {
        SAFE deployedSAFE;
        ShareholderRegistry deployedRegistry;
        (company, vault, vestingSchedule, deployedRegistry,, deployedSAFE,,) =
            _deployCompany("Test Company Inc", "TEST", "ipfs://test-metadata");

        // Create the first share class via factory (0 parValue = no-par for US)
        vm.prank(board);
        company.createShareClassWithToken{value: 0.05 ether}(
            "Common", "Test Company Shares", "TCS", 1000000, 1e6, 1, 0, ""
        );

        // Get the created token and its engines
        shareToken = ShareToken(company.getShareClass("Common").token);
        snapshotEngine = SnapshotEngine(address(shareToken.snapshotEngine()));
        ruleEngine = RuleEngine(address(shareToken.ruleEngine()));
    }

    /// @dev Deploy company with custom share class parameters
    function _deployCompanyWithShareClass(
        string memory companyName,
        string memory ticker,
        string memory className,
        string memory tokenName,
        string memory tokenSymbol,
        uint256 authorizedShares
    )
        internal
        returns (
            Company deployedCompany,
            Vault deployedVault,
            VestingSchedule deployedVesting,
            ShareholderRegistry deployedRegistry,
            OptionPool deployedOptionPool,
            SAFE deployedSAFE,
            ShareToken deployedShareToken,
            Fundraise deployedFundraise
        )
    {
        // Deploy company (ignore convertibleNote return)
        (
            deployedCompany,
            deployedVault,
            deployedVesting,
            deployedRegistry,
            deployedOptionPool,
            deployedSAFE,
            deployedFundraise,
        ) = _deployCompany(companyName, ticker, "ipfs://metadata");

        // Create share class (0 parValue = no-par for US)
        vm.prank(board);
        deployedCompany.createShareClassWithToken{value: 0.05 ether}(
            className, tokenName, tokenSymbol, authorizedShares, 1e6, 1, 0, ""
        );

        // Get the created token
        deployedShareToken = deployedCompany.getShareToken(className);
    }

    /// @dev Quick helper to deploy a standard test company with 10M authorized shares
    function _deployStandardCompany()
        internal
        returns (
            Company deployedCompany,
            Vault deployedVault,
            VestingSchedule deployedVesting,
            ShareholderRegistry deployedRegistry,
            OptionPool deployedOptionPool,
            SAFE deployedSAFE,
            ShareToken deployedShareToken,
            Fundraise deployedFundraise
        )
    {
        return _deployCompanyWithShareClass("Test Corp", "TEST", "Common", "Test Corp Common", "TEST-C", 10_000_000e6);
    }

    // ============ SnapshotEngine Helper ============

    /// @dev Create and initialize a new SnapshotEngine (replaces old constructor pattern)
    function _newSnapshotEngine(address token_) internal returns (SnapshotEngine) {
        SnapshotEngine se = new SnapshotEngine();
        se.initialize(ERC20Upgradeable(token_), address(this));
        return se;
    }

    // ============ Rule Deployment Helpers ============
    function _deployRuleKYC(address company_, address registry_, bytes32 idSchema_, uint8 requiredKycLevel_)
        internal
        returns (RuleKYC)
    {
        RuleKYC impl = new RuleKYC();
        address clone = Clones.clone(address(impl));
        RuleKYC(clone).initialize(abi.encode(registry_, idSchema_, requiredKycLevel_), company_);
        return RuleKYC(clone);
    }

    // ============ MockUSD Helpers ============

    /// @dev Mint MUSD to a recipient and approve a spender
    function _mintAndApprove(address recipient, uint256 amount, address spender) internal {
        musd.mint(recipient, amount);
        vm.prank(recipient);
        musd.approve(spender, amount);
    }

    /// @dev Mint MUSD to a recipient (no approval)
    function _fundMUSD(address recipient, uint256 amount) internal {
        musd.mint(recipient, amount);
    }

    function _distributeDividend(Company target, uint256 dividendId) internal {
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(target.board());
            target.distributeDividendBatch(dividendId, 100);
            (,,, bool distributed) = target.dividends(dividendId);
            if (distributed) return;
        }
        revert("queue never drained");
    }

    // ============ Fundraise Helpers ============

    /// @dev Returns a IFundraise.RoundParams with sensible SAFE defaults.
    ///      Override fields you care about after calling this.
    function _defaultRoundParams() internal view returns (IFundraise.RoundParams memory p) {
        p.name = "Test Round";
        p.roundType = IFundraise.RoundType.SAFE;
        p.valuationCap = CAP_10M;
        p.discountBps = DISCOUNT_20PCT;
        p.documentRef = "ipfs://safe-doc";
        p.targetShareClass = address(shareToken);
    }

    /// @dev Helper that pre-computes the FHE salt, then pranks `inv` and calls invest.
    function _invest(Fundraise fr, uint256 roundId, address inv, uint256 amount) internal {
        InEuint128 memory salt = createInEuint128(0, inv);
        vm.prank(inv);
        fr.invest(roundId, amount, keccak256("test:terms"), salt);
    }

    /// @dev Variant for tests that expect the invest call to revert.
    function _investExpectRevert(Fundraise fr, uint256 roundId, address inv, uint256 amount, bytes4 selector) internal {
        InEuint128 memory salt = createInEuint128(0, inv);
        vm.prank(inv);
        vm.expectRevert(selector);
        fr.invest(roundId, amount, keccak256("test:terms"), salt);
    }

    /// @dev Invest in a round, close it, and finalize it in one call.
    function _investAndFinalize(Fundraise fr, uint256 roundId, address inv, uint256 amount) internal {
        _mintAndApprove(inv, amount, address(fr));
        _invest(fr, roundId, inv, amount);
        vm.startPrank(board);
        fr.closeRound(roundId);
        fr.finalizeRound(roundId);
        vm.stopPrank();
    }

    // ============ Artifact Helpers ============

    /// @dev Read creation bytecode from a compiled artifact JSON.
    ///      Workaround for vm.getCode() failing under multi-solc compilation.
    function _readArtifactBytecode(string memory fileName, string memory contractName) internal returns (bytes memory) {
        string memory path = string.concat("out/", fileName, "/", contractName, ".json");
        try vm.readFile(path) returns (string memory json) {
            return vm.parseJsonBytes(json, ".bytecode.object");
        } catch {
            revert(string.concat("Failed to read artifact: ", path));
        }
    }
}
