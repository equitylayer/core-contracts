// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./Company.sol";
import "./ShareToken.sol";
import "./Vault.sol";
import "./ShareholderRegistry.sol";
import "./VestingSchedule.sol";
import "./OptionPool.sol";
import "./SAFE.sol";
import "./Fundraise.sol";
import "./ConvertibleNote.sol";
import "./EquityIssuance.sol";
import "./interfaces/IVault.sol";
import "./interfaces/ICompany.sol";
import "./interfaces/ISAFE.sol";
import "./interfaces/IFundraise.sol";
import "./interfaces/IConvertibleNote.sol";
import "./interfaces/IDataRoom.sol";
import "./interfaces/IEquityIssuance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SnapshotEngine} from "./SnapshotEngine.sol";
import {ISnapshotEngine} from "CMTAT/contracts/interfaces/engine/ISnapshotEngine.sol";
import {IRuleEngine} from "CMTAT/contracts/interfaces/engine/IRuleEngine.sol";
import {RuleEngine} from "RuleEngine/src/RuleEngine.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IRuleRegistry} from "./interfaces/rules/IRuleRegistry.sol";

/// @title CompanyFactory that deploys a company and its basic
/// @notice Factory using EIP-1167 minimal proxies for gas-efficient deployments
contract CompanyFactory is
    ICompanyFactory,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using Clones for address;

    string public constant VERSION = "0.9.0";

    // Implementation addresses (deployed once, cloned many times)
    address public immutable companyImplementation;
    address public immutable shareTokenImplementation;
    address public immutable vaultImplementation;
    address public immutable vestingImplementation;
    address public immutable shareholderRegistryImplementation;
    address public immutable optionPoolImplementation;
    address public immutable safeImplementation;
    address public immutable fundraiseImplementation;
    address public immutable convertibleNoteImplementation;
    address public immutable equityIssuanceImplementation;
    address public immutable snapshotEngineImplementation;
    address public immutable dataRoomImplementation;
    address public immutable conversionVerifier;
    address public immutable cnRepayVerifier;

    address public treasury;
    address public operator;
    uint256 public deploymentFee = type(uint256).max; // No deployments until fee is set
    uint256 public shareClassFee;

    mapping(uint256 => address) public companyRegistry;
    mapping(address => uint256) public companyToId;
    uint256 public companyCount;
    mapping(address => bool) public paymentTokenAllowed;
    address[] public paymentTokenAllowlist;
    IRuleRegistry public ruleRegistry;

    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 private constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 private constant SNAPSHOOTER_ROLE = keccak256("SNAPSHOOTER_ROLE");
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Struct containing all deployed contract addresses
    struct DeploymentResult {
        uint256 companyId;
        address companyAddress;
        address payable vaultAddress;
        address vestingAddress;
        address registryAddress;
        address optionPoolAddress;
        address safeAddress;
        address fundraiseAddress;
        address convertibleNoteAddress;
        address equityIssuanceAddress;
        address dataRoomAddress;
    }

    // Custom errors (saves gas vs require strings)
    error ZeroAddress();
    error NotAContract();
    error InsufficientFee();
    error EmptyString();
    error NotRegisteredCompany();
    error FeeTransferFailed();
    error PaymentTokenNotAllowed();

    event CompanyDeployed(
        uint256 indexed companyId,
        address indexed companyAddress,
        address indexed board,
        address vault,
        address vestingSchedule,
        address shareholderRegistry,
        address optionPool,
        address safe,
        address fundraise,
        address convertibleNote,
        address equityIssuance,
        address dataRoom
    );
    event ShareClassDeployed(
        address indexed company,
        address indexed token,
        address indexed ruleEngine,
        string tokenSymbol,
        uint256 authorizedShares
    );
    event DeploymentFeeUpdated(uint256 oldFee, uint256 newFee);
    event ShareClassFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeeCollected(address indexed payer, uint256 amount);
    event PaymentTokenAllowlistUpdated(address indexed token, bool allowed);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event RuleRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _companyImpl,
        address _shareTokenImpl,
        address _vaultImpl,
        address _vestingImpl,
        address _shareholderRegistryImpl,
        address _optionPoolImpl,
        address _safeImpl,
        address _fundraiseImpl,
        address _convertibleNoteImpl,
        address _equityIssuanceImpl,
        address _snapshotEngineImpl,
        address _dataRoomImpl,
        address _conversionVerifier,
        address _cnRepayVerifier
    ) {
        if (_companyImpl == address(0)) revert ZeroAddress();
        if (_shareTokenImpl == address(0)) revert ZeroAddress();
        if (_vaultImpl == address(0)) revert ZeroAddress();
        if (_vestingImpl == address(0)) revert ZeroAddress();
        if (_shareholderRegistryImpl == address(0)) revert ZeroAddress();
        if (_optionPoolImpl == address(0)) revert ZeroAddress();
        if (_safeImpl == address(0)) revert ZeroAddress();
        if (_fundraiseImpl == address(0)) revert ZeroAddress();
        if (_convertibleNoteImpl == address(0)) revert ZeroAddress();
        if (_equityIssuanceImpl == address(0)) revert ZeroAddress();
        if (_snapshotEngineImpl == address(0)) revert ZeroAddress();
        if (_dataRoomImpl == address(0)) revert ZeroAddress();
        if (_conversionVerifier == address(0)) revert ZeroAddress();
        if (_cnRepayVerifier == address(0)) revert ZeroAddress();

        companyImplementation = _companyImpl;
        shareTokenImplementation = _shareTokenImpl;
        vaultImplementation = _vaultImpl;
        vestingImplementation = _vestingImpl;
        shareholderRegistryImplementation = _shareholderRegistryImpl;
        optionPoolImplementation = _optionPoolImpl;
        safeImplementation = _safeImpl;
        fundraiseImplementation = _fundraiseImpl;
        convertibleNoteImplementation = _convertibleNoteImpl;
        equityIssuanceImplementation = _equityIssuanceImpl;
        snapshotEngineImplementation = _snapshotEngineImpl;
        dataRoomImplementation = _dataRoomImpl;
        conversionVerifier = _conversionVerifier;
        cnRepayVerifier = _cnRepayVerifier;

        _disableInitializers();
    }

    /// @notice Initialize the factory
    /// @param _treasury Address that receives deployment fees
    /// @param _deploymentFee Initial deployment fee in wei (can be 0 for free)
    /// @param _owner Initial owner of the factory
    /// @param _shareClassFee Initial share class fee in wei (default: 0.01 ether)
    /// @param _operator Platform operator address (always has DataRoom decrypt access)
    function initialize(
        address _treasury,
        uint256 _deploymentFee,
        address _owner,
        uint256 _shareClassFee,
        address _operator
    ) public initializer {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_operator == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __Pausable_init();

        treasury = _treasury;
        deploymentFee = _deploymentFee;
        shareClassFee = _shareClassFee;
        operator = _operator;
    }

    /// @notice Deploy a company (without share classes)
    /// @param _companyName Company name
    /// @param _ticker Company ticker symbol
    /// @param _metadataUri IPFS or legal document pointer
    /// @param _countryCode ISO 3166-1 numeric country code (e.g., 840=US, 826=GB, 756=CH)
    /// @param _entityType Entity type - convention per jurisdiction, not validated on-chain:
    ///        US: 1=C-Corp, 2=S-Corp | UK: 1=Ltd, 2=PLC | CH: 1=AG, 2=GmbH, 3=SA
    /// @param _paymentToken ERC20 stablecoin to handle settlement
    /// @return result Struct containing all deployed contract addresses
    function deployCompany(
        string memory _companyName,
        string memory _ticker,
        string memory _metadataUri,
        uint16 _countryCode,
        uint8 _entityType,
        IERC20 _paymentToken
    ) external payable nonReentrant whenNotPaused returns (DeploymentResult memory result) {
        if (msg.value < deploymentFee) {
            revert InsufficientFee();
        }
        if (bytes(_companyName).length == 0) revert EmptyString();
        if (bytes(_ticker).length == 0) revert EmptyString();
        if (_countryCode == 0) revert EmptyString();
        if (address(_paymentToken) == address(0)) revert ZeroAddress();
        if (!paymentTokenAllowed[address(_paymentToken)]) revert PaymentTokenNotAllowed();

        // 1. Clone Company (EIP-1167 minimal proxy)
        result.companyAddress = companyImplementation.clone();

        // 2. Clone ShareholderRegistry (EIP-1167 minimal proxy)
        result.registryAddress = shareholderRegistryImplementation.clone();
        ShareholderRegistry(result.registryAddress).initialize(result.companyAddress);

        // 3. Clone Vault (EIP-1167 minimal proxy)
        result.vaultAddress = payable(vaultImplementation.clone());
        Vault(result.vaultAddress).initialize(ICompany(result.companyAddress));

        // 4. Clone VestingSchedule (EIP-1167 minimal proxy)
        result.vestingAddress = vestingImplementation.clone();
        VestingSchedule(result.vestingAddress).initialize(result.companyAddress);

        // 5. Clone OptionPool (EIP-1167 minimal proxy)
        result.optionPoolAddress = optionPoolImplementation.clone();
        OptionPool(result.optionPoolAddress).initialize(result.companyAddress);

        // 6. Clone Fundraise (EIP-1167 minimal proxy)
        result.fundraiseAddress = fundraiseImplementation.clone();
        Fundraise(result.fundraiseAddress).initialize(result.companyAddress);

        // 7. Clone EquityIssuance (EIP-1167 minimal proxy)
        result.equityIssuanceAddress = equityIssuanceImplementation.clone();
        EquityIssuance(result.equityIssuanceAddress)
            .initialize(result.companyAddress, result.fundraiseAddress, conversionVerifier);

        // 8. Clone SAFE (EIP-1167 minimal proxy)
        result.safeAddress = safeImplementation.clone();
        SAFE(result.safeAddress)
            .initialize(result.companyAddress, result.fundraiseAddress, result.equityIssuanceAddress);

        // 9. Clone ConvertibleNote (EIP-1167 minimal proxy)
        result.convertibleNoteAddress = convertibleNoteImplementation.clone();
        ConvertibleNote(result.convertibleNoteAddress)
            .initialize(result.companyAddress, result.fundraiseAddress, result.equityIssuanceAddress, cnRepayVerifier);

        // 10. Clone DataRoom (EIP-1167 minimal proxy) - owner = Company, operator = platform
        result.dataRoomAddress = dataRoomImplementation.clone();
        IDataRoom(result.dataRoomAddress).initialize(result.companyAddress);

        // 11. Initialize Company clone
        _initCompany(result, _paymentToken, _companyName, _ticker, _metadataUri, _countryCode, _entityType);

        // 11. Register the deployed company
        companyCount++;
        result.companyId = companyCount;
        companyRegistry[result.companyId] = result.companyAddress;
        companyToId[result.companyAddress] = result.companyId;

        // 12. Collect deployment fee
        if (msg.value > 0) {
            (bool success,) = treasury.call{value: msg.value}("");
            if (!success) revert FeeTransferFailed();
            emit FeeCollected(msg.sender, msg.value);
        }

        emit CompanyDeployed(
            result.companyId,
            result.companyAddress,
            msg.sender,
            result.vaultAddress,
            result.vestingAddress,
            result.registryAddress,
            result.optionPoolAddress,
            result.safeAddress,
            result.fundraiseAddress,
            result.convertibleNoteAddress,
            result.equityIssuanceAddress,
            result.dataRoomAddress
        );
    }

    /// @inheritdoc ICompanyFactory
    /// @dev Called by Company contracts to create share classes. Requires `shareClassFee`.
    function deployShareClass(
        uint256 authorizedShares,
        string memory tokenName,
        string memory tokenSymbol,
        address tokenOwner
    ) external payable nonReentrant whenNotPaused returns (address tokenAddress) {
        if (msg.value < shareClassFee) revert InsufficientFee();
        if (companyToId[msg.sender] == 0) revert NotRegisteredCompany();
        if (tokenOwner == address(0)) revert ZeroAddress();
        if (authorizedShares == 0) revert EmptyString();

        // 1. Clone ShareToken (EIP-1167)
        tokenAddress = shareTokenImplementation.clone();

        // 2. Clone snapshot engine
        SnapshotEngine snapshotEngine = SnapshotEngine(snapshotEngineImplementation.clone());
        snapshotEngine.initialize(ERC20Upgradeable(tokenAddress), address(this));

        // 3. Deploy RuleEngine (forwarded is 0x for now)
        RuleEngine ruleEngine = new RuleEngine(address(this), address(0), tokenAddress);

        // 4. Initialize token
        ShareToken(tokenAddress)
            .initialize(
                address(this),
                tokenName,
                tokenSymbol,
                authorizedShares,
                ISnapshotEngine(address(snapshotEngine)),
                IRuleEngine(address(ruleEngine)),
                Company(msg.sender).shareholderRegistry()
            );

        // 5. Apply roles.
        _setupTokenRoles(tokenAddress, msg.sender, tokenOwner, snapshotEngine, ruleEngine);

        // 7. Collect Fees
        if (msg.value > 0) {
            (bool success,) = treasury.call{value: msg.value}("");
            if (!success) revert FeeTransferFailed();
            emit FeeCollected(msg.sender, msg.value);
        }

        emit ShareClassDeployed(msg.sender, tokenAddress, address(ruleEngine), tokenSymbol, authorizedShares);
    }

    /// @dev Role wiring extracted to keep `deployShareClass` under the stack limit.
    function _setupTokenRoles(
        address tokenAddress,
        address companyAddr,
        address tokenOwner,
        SnapshotEngine snapshotEngine,
        RuleEngine ruleEngine
    ) internal {
        address equityIssuanceAddr = address(Company(companyAddr).issuance());
        ShareToken(tokenAddress).setCompanyAddress(companyAddr);
        ShareToken(tokenAddress).setIssuanceAddress(equityIssuanceAddr);
        ShareToken(tokenAddress).grantRole(MINTER_ROLE, equityIssuanceAddr);
        ShareToken(tokenAddress).grantRole(BURNER_ROLE, address(Company(companyAddr).vestingSchedule()));

        // Snapshot engine roles
        snapshotEngine.grantRole(SNAPSHOOTER_ROLE, tokenOwner);
        snapshotEngine.grantRole(SNAPSHOOTER_ROLE, companyAddr);

        // Admin rotation: Company stays as persistent admin; tokenOwner (board) is added; factory renounces
        ShareToken(tokenAddress).grantRole(DEFAULT_ADMIN_ROLE, companyAddr);
        ShareToken(tokenAddress).grantRole(DEFAULT_ADMIN_ROLE, tokenOwner);
        ShareToken(tokenAddress).renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        snapshotEngine.grantRole(DEFAULT_ADMIN_ROLE, companyAddr);
        snapshotEngine.grantRole(DEFAULT_ADMIN_ROLE, tokenOwner);
        snapshotEngine.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        ruleEngine.grantRole(DEFAULT_ADMIN_ROLE, companyAddr);
        ruleEngine.grantRole(DEFAULT_ADMIN_ROLE, tokenOwner);
        ruleEngine.renounceRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    // --------------------
    // Admin Functions
    // --------------------

    /// @notice Update the deployment fee (for company creation)
    /// @param newFee New deployment fee in wei
    function setDeploymentFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = deploymentFee;
        deploymentFee = newFee;
        emit DeploymentFeeUpdated(oldFee, newFee);
    }

    /// @notice Update the share class fee (for share class creation)
    /// @param newFee New share class fee in wei
    function setShareClassFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = shareClassFee;
        shareClassFee = newFee;
        emit ShareClassFeeUpdated(oldFee, newFee);
    }

    /// @notice Update the treasury address
    /// @param newTreasury New treasury address
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /// @notice Add a token to the payment token allowlist
    /// @param token ERC20 token address
    function addPaymentTokenToAllowlist(address token) public onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (paymentTokenAllowed[token]) return;

        paymentTokenAllowed[token] = true;
        paymentTokenAllowlist.push(token);

        emit PaymentTokenAllowlistUpdated(token, true);
    }

    /// @notice Remove a token from the payment token allowlist
    /// @param token ERC20 token address
    function removePaymentTokenFromAllowlist(address token) public onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (!paymentTokenAllowed[token]) return;

        paymentTokenAllowed[token] = false;

        uint256 length = paymentTokenAllowlist.length;
        for (uint256 i = 0; i < length; i++) {
            if (paymentTokenAllowlist[i] == token) {
                paymentTokenAllowlist[i] = paymentTokenAllowlist[length - 1];
                paymentTokenAllowlist.pop();
                break;
            }
        }

        emit PaymentTokenAllowlistUpdated(token, false);
    }

    /// @notice Update the platform operator address
    /// @param newOperator New operator address
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorUpdated(oldOperator, newOperator);
    }

    /// @notice Set (or unset) the protocol RuleRegistry
    /// @dev Pass `address(0)` to disable auto-rule application on future share class deploys.
    function setRuleRegistry(address newRegistry) external onlyOwner {
        if (newRegistry != address(0) && newRegistry.code.length == 0) revert NotAContract();
        address oldRegistry = address(ruleRegistry);
        ruleRegistry = IRuleRegistry(newRegistry);
        emit RuleRegistryUpdated(oldRegistry, newRegistry);
    }

    /// @notice Emergency pause of deployments
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume deployments
    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------
    // Internal Helpers
    // --------------------

    function _initCompany(
        DeploymentResult memory r,
        IERC20 _paymentToken,
        string memory _companyName,
        string memory _ticker,
        string memory _metadataUri,
        uint16 _countryCode,
        uint8 _entityType
    ) internal {
        Company.InitParams memory p;
        p.board = msg.sender;
        p.vault = IVault(r.vaultAddress);
        p.factory = ICompanyFactory(address(this));
        p.shareholderRegistry = ShareholderRegistry(r.registryAddress);
        p.vestingSchedule = VestingSchedule(r.vestingAddress);
        p.optionPool = OptionPool(r.optionPoolAddress);
        p.safe = ISAFE(r.safeAddress);
        p.fundraise = IFundraise(r.fundraiseAddress);
        p.convertibleNote = IConvertibleNote(r.convertibleNoteAddress);
        p.issuance = IEquityIssuance(r.equityIssuanceAddress);
        p.dataRoom = IDataRoom(r.dataRoomAddress);
        p.paymentToken = _paymentToken;
        p.name = _companyName;
        p.ticker = _ticker;
        p.metadataUri = _metadataUri;
        p.countryCode = _countryCode;
        p.entityType = _entityType;
        Company(r.companyAddress).initialize(p);
    }

    /// @dev Required by UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
