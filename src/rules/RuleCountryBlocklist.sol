// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {RuleValidateTransfer} from "Rules/rules/validation/abstract/RuleValidateTransfer.sol";
import {RuleCommonInvariantStorage} from "Rules/rules/validation/abstract/RuleCommonInvariantStorage.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ProviderRegistry} from "../attestations/ProviderRegistry.sol";
import {ShareholderSchemas} from "../attestations/ShareholderSchemas.sol";
import {ICompany} from "../interfaces/ICompany.sol";
import {IRuleCloneable} from "../interfaces/rules/IRuleCloneable.sol";
import {IRuleCountryBlocklist} from "../interfaces/rules/IRuleCountryBlocklist.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {Attestation} from "@eas/contracts/Common.sol";

/// @title RuleCountryBlocklist
/// @notice Blocks transfers where either party resides in a sanctioned/blocked country.
/// @dev Country is read from the recipient's (or sender's) D01Identity attestation. If no attestation
///      exists, the rule falls open — delegating "is this address verified at all" to a co-attached
///      KYC rule so the two rules compose without stepping on each other. This also means mints to
///      fresh addresses (`from == address(0)`) don't fail here purely for lack of an attestation.
contract RuleCountryBlocklist is
    Initializable,
    ERC165,
    RuleValidateTransfer,
    RuleCommonInvariantStorage,
    IRuleCloneable,
    IRuleCountryBlocklist
{
    string public constant VERSION = "0.9.0";

    uint8 public constant CODE_SENDER_COUNTRY_BLOCKED = 41;
    uint8 public constant CODE_RECIPIENT_COUNTRY_BLOCKED = 42;

    /// @notice Hard cap on the blocklist size. Keeps gas bounded and mirrors OFAC's 17-country SDN list
    ///         (with headroom). Admins replace the list wholesale when they need broader coverage.
    uint256 public constant MAX_COUNTRIES = 64;

    ICompany public company;
    ProviderRegistry public registry;
    bytes32 public idSchema;

    mapping(uint16 => bool) private _blocked;
    uint16[] private _blockedList;
    /// @dev Index into `_blockedList` (1-based; 0 means not present).
    mapping(uint16 => uint256) private _blockedIndex;

    event CountryAdded(uint16 indexed countryCode);
    event CountryRemoved(uint16 indexed countryCode);
    event CountriesReplaced(uint16[] countryCodes);

    error OnlyBoard();
    error ZeroAddress();
    error ZeroSchema();
    error ZeroCountry();
    error DuplicateCountry(uint16 countryCode);
    error CountryNotBlocked(uint16 countryCode);
    error TooManyCountries();

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRuleCloneable
    /// @param initData `abi.encode(address providerRegistry, bytes32 idSchema, uint16[] blockedCountryCodes)`
    /// @param _company Company contract (board queried dynamically so rotations take effect immediately).
    function initialize(bytes calldata initData, address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();

        (address _registry, bytes32 _idSchema, uint16[] memory _initial) =
            abi.decode(initData, (address, bytes32, uint16[]));

        if (_registry == address(0)) revert ZeroAddress();
        if (_idSchema == bytes32(0)) revert ZeroSchema();
        if (_initial.length > MAX_COUNTRIES) revert TooManyCountries();

        company = ICompany(_company);
        registry = ProviderRegistry(_registry);
        idSchema = _idSchema;

        for (uint256 i = 0; i < _initial.length; i++) {
            _addCountry(_initial[i]);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IRuleCloneable).interfaceId || interfaceId == type(IRuleCountryBlocklist).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ============ Board management ============

    /// @notice Add a country to the blocklist.
    function addCountry(uint16 countryCode) external onlyBoard {
        _addCountry(countryCode);
    }

    /// @notice Remove a country from the blocklist.
    function removeCountry(uint16 countryCode) external onlyBoard {
        if (!_blocked[countryCode]) revert CountryNotBlocked(countryCode);

        uint256 idx = _blockedIndex[countryCode] - 1;
        uint256 last = _blockedList.length - 1;
        if (idx != last) {
            uint16 moved = _blockedList[last];
            _blockedList[idx] = moved;
            _blockedIndex[moved] = idx + 1;
        }
        _blockedList.pop();
        delete _blockedIndex[countryCode];
        delete _blocked[countryCode];

        emit CountryRemoved(countryCode);
    }

    /// @notice Replace the entire blocklist.
    /// @dev Wholesale swap; emits one `CountriesReplaced` instead of N add/remove events so indexers
    ///      don't have to reconstruct intermediate states.
    function setCountries(uint16[] calldata countryCodes) external onlyBoard {
        if (countryCodes.length > MAX_COUNTRIES) revert TooManyCountries();

        // Clear existing list first so duplicates within the new set are caught by `_addCountry`.
        uint256 len = _blockedList.length;
        for (uint256 i = 0; i < len; i++) {
            delete _blocked[_blockedList[i]];
            delete _blockedIndex[_blockedList[i]];
        }
        delete _blockedList;

        for (uint256 i = 0; i < countryCodes.length; i++) {
            _addCountry(countryCodes[i]);
        }

        emit CountriesReplaced(countryCodes);
    }

    function _addCountry(uint16 countryCode) internal {
        if (countryCode == 0) revert ZeroCountry();
        if (_blocked[countryCode]) revert DuplicateCountry(countryCode);
        if (_blockedList.length >= MAX_COUNTRIES) revert TooManyCountries();

        _blocked[countryCode] = true;
        _blockedList.push(countryCode);
        _blockedIndex[countryCode] = _blockedList.length;

        emit CountryAdded(countryCode);
    }

    // ============ Views ============

    /// @notice Check if a country is on the blocklist.
    function isCountryBlocked(uint16 countryCode) external view returns (bool) {
        return _blocked[countryCode];
    }

    /// @notice Return the full blocklist (ordered by insertion, with swap-and-pop on removal).
    function getBlockedCountries() external view returns (uint16[] memory) {
        return _blockedList;
    }

    /// @notice Number of countries currently on the blocklist.
    function blockedCountryCount() external view returns (uint256) {
        return _blockedList.length;
    }

    // ============ Transfer validation ============

    /// @notice Reject transfers where `from` or `to` is attested as residing in a blocked country.
    /// @dev Un-attested addresses fall open — single responsibility lives with the KYC rule.
    function detectTransferRestriction(address from, address to, uint256 value) public view override returns (uint8) {
        value;
        // Burn: no recipient to screen.
        if (to == address(0)) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);

        // Sender (skip mints where `from == address(0)`)
        if (from != address(0) && _isBlocked(from)) return CODE_SENDER_COUNTRY_BLOCKED;
        if (_isBlocked(to)) return CODE_RECIPIENT_COUNTRY_BLOCKED;

        return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
    }

    /// @notice Same as `detectTransferRestriction`; the spender's residency is not part of the test
    ///         (OFAC covers spender identity via its own rule).
    function detectTransferRestrictionFrom(address spender, address from, address to, uint256 value)
        public
        view
        override
        returns (uint8)
    {
        spender;
        return detectTransferRestriction(from, to, value);
    }

    function canReturnTransferRestrictionCode(uint8 restrictionCode) external pure override returns (bool) {
        return restrictionCode == CODE_SENDER_COUNTRY_BLOCKED || restrictionCode == CODE_RECIPIENT_COUNTRY_BLOCKED;
    }

    function messageForTransferRestriction(uint8 restrictionCode) external pure override returns (string memory) {
        if (restrictionCode == CODE_SENDER_COUNTRY_BLOCKED) return "Sender resides in a blocked country";
        if (restrictionCode == CODE_RECIPIENT_COUNTRY_BLOCKED) return "Recipient resides in a blocked country";
        return TEXT_CODE_NOT_FOUND;
    }

    function _isBlocked(address account) internal view returns (bool) {
        bytes32 uid = registry.getAttestation(idSchema, account);
        if (uid == bytes32(0)) return false;

        Attestation memory att = IEAS(registry.eas()).getAttestation(uid);
        if (att.schema != idSchema) return false;
        if (att.revocationTime != 0) return false;
        if (att.expirationTime != 0 && att.expirationTime < block.timestamp) return false;

        ShareholderSchemas.IdentityData memory data = ShareholderSchemas.decodeIdentity(att.data);
        return _blocked[data.countryCode];
    }

    /// @dev Reserved storage for future variables (e.g. per-address overrides) without shifting slots.
    uint256[48] private __gap;
}
