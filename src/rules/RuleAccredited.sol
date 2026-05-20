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
import {IRuleAccredited} from "../interfaces/rules/IRuleAccredited.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {Attestation} from "@eas/contracts/Common.sol";

/// @title RuleAccredited
/// @notice Transfer restriction rule that requires recipients to be attested as accredited investors.
/// @dev Reads the D01Accreditation schema. Fail-CLOSED: no attestation, expired, revoked, or the
///      attested `accreditationType` not in the configured acceptedTypes set → reject. Designed for
///      US Reg D 506(c) (accredited-only) and jurisdictional equivalents (UK FCA HNW, CH FinSA pro).
///      The `acceptedTypes` argument tells the rule which codes count as "accredited" for its context.
contract RuleAccredited is
    Initializable,
    ERC165,
    RuleValidateTransfer,
    RuleCommonInvariantStorage,
    IRuleCloneable,
    IRuleAccredited
{
    string public constant VERSION = "0.9.0";

    uint8 public constant CODE_RECIPIENT_NOT_ACCREDITED = 50;
    uint8 public constant CODE_ATTESTATION_EXPIRED = 51;
    uint8 public constant CODE_ATTESTATION_REVOKED = 52;
    uint8 public constant CODE_ACCREDITATION_TYPE_NOT_ACCEPTED = 53;
    uint8 public constant CODE_SCHEMA_MISMATCH = 54;

    /// @notice Cap on accepted-types array length. Matches the discrete set of ACCREDITED_* codes in
    ///         ShareholderSchemas (currently ~9 across all jurisdictions) with headroom.
    uint8 public constant MAX_ACCEPTED_TYPES = 32;

    ICompany public company;
    ProviderRegistry public registry;
    bytes32 public accreditationSchema;

    /// @dev Membership check for `accreditationType` in the accepted set. O(1) test vs array scan.
    mapping(uint8 => bool) private _acceptedType;
    uint8[] private _acceptedTypes;

    event AcceptedTypesUpdated(uint8[] oldTypes, uint8[] newTypes);

    error OnlyBoard();
    error ZeroAddress();
    error ZeroSchema();
    error EmptyAcceptedTypes();
    error TooManyAcceptedTypes();
    error DuplicateAcceptedType(uint8 t);

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRuleCloneable
    /// @param initData `abi.encode(address providerRegistry, bytes32 accreditationSchema, uint8[] acceptedTypes)`
    /// @param _company Company contract (board queried dynamically so rotations take effect immediately).
    function initialize(bytes calldata initData, address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();

        (address _registry, bytes32 _accreditationSchema, uint8[] memory _types) =
            abi.decode(initData, (address, bytes32, uint8[]));

        if (_registry == address(0)) revert ZeroAddress();
        if (_accreditationSchema == bytes32(0)) revert ZeroSchema();
        if (_types.length == 0) revert EmptyAcceptedTypes();
        if (_types.length > MAX_ACCEPTED_TYPES) revert TooManyAcceptedTypes();

        company = ICompany(_company);
        registry = ProviderRegistry(_registry);
        accreditationSchema = _accreditationSchema;
        _writeAcceptedTypes(_types);
    }

    /// @dev Advertises {IRuleCloneable} (for the registry's publish probe) and {IRuleAccredited}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IRuleCloneable).interfaceId || interfaceId == type(IRuleAccredited).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ============ Board management ============

    /// @notice Replace the set of accepted accreditation type codes.
    /// @dev Pass an empty array via `setAcceptedTypes` → revert. Use `removeRule` at the registry
    ///      level to disable the rule entirely; board-level changes just narrow or broaden the set.
    function setAcceptedTypes(uint8[] calldata types) external onlyBoard {
        if (types.length == 0) revert EmptyAcceptedTypes();
        if (types.length > MAX_ACCEPTED_TYPES) revert TooManyAcceptedTypes();

        uint8[] memory old = _acceptedTypes;
        _clearAcceptedTypes();

        uint8[] memory newTypes = new uint8[](types.length);
        for (uint256 i = 0; i < types.length; i++) {
            newTypes[i] = types[i];
        }
        _writeAcceptedTypes(newTypes);

        emit AcceptedTypesUpdated(old, newTypes);
    }

    function _writeAcceptedTypes(uint8[] memory types) internal {
        for (uint256 i = 0; i < types.length; i++) {
            if (_acceptedType[types[i]]) revert DuplicateAcceptedType(types[i]);
            _acceptedType[types[i]] = true;
            _acceptedTypes.push(types[i]);
        }
    }

    function _clearAcceptedTypes() internal {
        uint256 len = _acceptedTypes.length;
        for (uint256 i = 0; i < len; i++) {
            delete _acceptedType[_acceptedTypes[i]];
        }
        delete _acceptedTypes;
    }

    // ============ Views ============

    /// @notice Return the configured accepted accreditation type codes.
    function getAcceptedTypes() external view returns (uint8[] memory) {
        return _acceptedTypes;
    }

    /// @notice True if the given accreditation type code is currently accepted.
    function isTypeAccepted(uint8 t) external view returns (bool) {
        return _acceptedType[t];
    }

    // ============ Transfer validation ============

    /// @notice Reject transfers where the recipient isn't attested as accredited (of an accepted type).
    /// @dev Fail-closed: no attestation or attestation not matching → reject.
    function detectTransferRestriction(address from, address to, uint256 value) public view override returns (uint8) {
        (from, value);
        // Burns are unaffected (to == address(0) has no attestation to inspect).
        if (to == address(0)) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);

        bytes32 uid = registry.getAttestation(accreditationSchema, to);
        if (uid == bytes32(0)) return CODE_RECIPIENT_NOT_ACCREDITED;

        Attestation memory att = IEAS(registry.eas()).getAttestation(uid);
        if (att.schema != accreditationSchema) return CODE_SCHEMA_MISMATCH;
        if (att.revocationTime != 0) return CODE_ATTESTATION_REVOKED;
        if (att.expirationTime != 0 && att.expirationTime < block.timestamp) return CODE_ATTESTATION_EXPIRED;

        ShareholderSchemas.AccreditationData memory data = ShareholderSchemas.decodeAccreditation(att.data);
        if (!_acceptedType[data.accreditationType]) return CODE_ACCREDITATION_TYPE_NOT_ACCEPTED;

        return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
    }

    /// @notice Same as `detectTransferRestriction`; the spender isn't part of the accreditation check.
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
        return restrictionCode == CODE_RECIPIENT_NOT_ACCREDITED || restrictionCode == CODE_ATTESTATION_EXPIRED
            || restrictionCode == CODE_ATTESTATION_REVOKED || restrictionCode == CODE_ACCREDITATION_TYPE_NOT_ACCEPTED
            || restrictionCode == CODE_SCHEMA_MISMATCH;
    }

    function messageForTransferRestriction(uint8 restrictionCode) external pure override returns (string memory) {
        if (restrictionCode == CODE_RECIPIENT_NOT_ACCREDITED) return "Recipient is not attested as accredited";
        if (restrictionCode == CODE_ATTESTATION_EXPIRED) return "Accreditation attestation has expired";
        if (restrictionCode == CODE_ATTESTATION_REVOKED) return "Accreditation attestation has been revoked";
        if (restrictionCode == CODE_ACCREDITATION_TYPE_NOT_ACCEPTED) {
            return "Recipient accreditation type is not accepted";
        }
        if (restrictionCode == CODE_SCHEMA_MISMATCH) return "Attestation schema mismatch";
        return TEXT_CODE_NOT_FOUND;
    }

    /// @dev Reserved storage for future variables (e.g. per-address overrides) without shifting slots.
    uint256[47] private __gap;
}
