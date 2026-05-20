// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {RuleValidateTransfer} from "Rules/rules/validation/abstract/RuleValidateTransfer.sol";
import {RuleCommonInvariantStorage} from "Rules/rules/validation/abstract/RuleCommonInvariantStorage.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICompany} from "../interfaces/ICompany.sol";
import {IRuleCloneable} from "../interfaces/rules/IRuleCloneable.sol";
import {IRuleHoldingPeriod} from "../interfaces/rules/IRuleHoldingPeriod.sol";

/// @title RuleHoldingPeriod
/// @notice Enforces a per-lot holding period (Rule 144-style) on restricted shares.
/// @dev Sidecar lot tracking — each `recordIssuance` call appends a lot with an unlock timestamp.
///      A holder's transferable balance is `balanceOf(holder) - lockedBalance(holder)`. Lots naturally
///      expire as time passes; `reconcile` prunes expired lots for gas savings but is not required
///      for correctness.
///      Design notes:
///        - Lots are created only on issuance via `recordIssuance`, not on secondary transfers. A
///          receiver of restricted shares doesn't inherit the sender's lots — those new shares are
///          unrestricted from this rule's perspective. This is a simplification vs. full Rule 144
///          "tacking"; document in offering docs which issuances the rule covers.
///        - Cross-transfer lot consumption is implicit: if a holder has both locked and unlocked
///          balance, their unlocked portion is usable. Post-transfer, the locked portion remains.
///        - `recordIssuance` is only callable by the Company contract (the issuer path). Board must
///          wire Company.issueShares to notify the rule, or use a dedicated issuer flow.
contract RuleHoldingPeriod is
    Initializable,
    ERC165,
    RuleValidateTransfer,
    RuleCommonInvariantStorage,
    IRuleCloneable,
    IRuleHoldingPeriod
{
    string public constant VERSION = "0.9.0";

    uint8 public constant CODE_INSUFFICIENT_UNLOCKED_BALANCE = 60;

    /// @notice Hard cap on lots per holder. Keeps canTransfer gas bounded.
    uint256 public constant MAX_LOTS_PER_HOLDER = 50;

    struct Lot {
        uint128 amount;
        uint64 unlockTime;
    }

    ICompany public company;
    IERC20 public token;
    uint32 public holdingPeriodSeconds;

    /// @dev Lots per holder. New lots append; expired lots can be pruned via `reconcile`.
    mapping(address => Lot[]) private _lots;

    event IssuanceRecorded(address indexed account, uint256 amount, uint64 unlockTime);
    event HoldingPeriodUpdated(uint32 oldPeriod, uint32 newPeriod);
    event LotsReconciled(address indexed account, uint256 removedCount);

    error OnlyBoard();
    error OnlyCompany();
    error ZeroAddress();
    error ZeroAmount();
    error AmountOverflow();
    error TooManyLots();

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRuleCloneable
    /// @param initData `abi.encode(address token, uint32 holdingPeriodSeconds)`
    function initialize(bytes calldata initData, address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();

        (address _token, uint32 _holdingPeriodSeconds) = abi.decode(initData, (address, uint32));
        if (_token == address(0)) revert ZeroAddress();

        company = ICompany(_company);
        token = IERC20(_token);
        holdingPeriodSeconds = _holdingPeriodSeconds;
    }

    /// @dev Advertises {IRuleCloneable} and {IRuleHoldingPeriod}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IRuleCloneable).interfaceId || interfaceId == type(IRuleHoldingPeriod).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ============ Issuance recording ============

    /// @inheritdoc IRuleHoldingPeriod
    function recordIssuance(address account, uint256 amount) external {
        if (msg.sender != address(company)) revert OnlyCompany();
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert AmountOverflow();
        if (_lots[account].length >= MAX_LOTS_PER_HOLDER) revert TooManyLots();

        uint64 unlock = uint64(block.timestamp) + holdingPeriodSeconds;
        _lots[account].push(Lot({amount: uint128(amount), unlockTime: unlock}));
        emit IssuanceRecorded(account, amount, unlock);
    }

    // ============ Board management ============

    /// @inheritdoc IRuleHoldingPeriod
    function setHoldingPeriod(uint32 newPeriodSeconds) external onlyBoard {
        uint32 old = holdingPeriodSeconds;
        holdingPeriodSeconds = newPeriodSeconds;
        emit HoldingPeriodUpdated(old, newPeriodSeconds);
    }

    /// @notice Prune expired lots for `account` (reduces storage and gas on future transfers).
    /// @dev Public / anyone can call. Not required for correctness — canTransfer ignores expired lots.
    function reconcile(address account) external {
        Lot[] storage lots = _lots[account];
        uint256 i = 0;
        uint256 removed = 0;
        while (i < lots.length) {
            if (lots[i].unlockTime <= block.timestamp) {
                // swap-and-pop
                uint256 last = lots.length - 1;
                if (i != last) lots[i] = lots[last];
                lots.pop();
                unchecked {
                    removed++;
                }
                // don't advance i; new entry at i must also be checked
            } else {
                unchecked {
                    i++;
                }
            }
        }
        if (removed > 0) emit LotsReconciled(account, removed);
    }

    // ============ Views ============

    /// @notice Sum of amounts across all unexpired lots for `account`.
    function lockedBalance(address account) public view returns (uint256 locked) {
        Lot[] storage lots = _lots[account];
        for (uint256 i = 0; i < lots.length; i++) {
            if (lots[i].unlockTime > block.timestamp) {
                unchecked {
                    locked += lots[i].amount;
                }
            }
        }
    }

    /// @notice Amount currently transferable for `account` (balance minus locked).
    function unlockedBalance(address account) public view returns (uint256) {
        uint256 balance = token.balanceOf(account);
        uint256 locked = lockedBalance(account);
        return balance > locked ? balance - locked : 0;
    }

    /// @notice Raw lot list for `account` (including expired entries until reconciled).
    function getLots(address account) external view returns (Lot[] memory) {
        return _lots[account];
    }

    /// @notice Number of lots recorded for `account` (expired + active until reconciled).
    function lotCount(address account) external view returns (uint256) {
        return _lots[account].length;
    }

    // ============ Transfer validation ============

    /// @notice Reject transfers that would dip into the sender's locked balance.
    function detectTransferRestriction(address from, address to, uint256 value) public view override returns (uint8) {
        to;
        // Mints have no sender balance to lock.
        if (from == address(0)) return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
        if (unlockedBalance(from) < value) return CODE_INSUFFICIENT_UNLOCKED_BALANCE;
        return uint8(REJECTED_CODE_BASE.TRANSFER_OK);
    }

    /// @notice Same as `detectTransferRestriction`; spender has no bearing on the holding-period check.
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
        return restrictionCode == CODE_INSUFFICIENT_UNLOCKED_BALANCE;
    }

    function messageForTransferRestriction(uint8 restrictionCode) external pure override returns (string memory) {
        if (restrictionCode == CODE_INSUFFICIENT_UNLOCKED_BALANCE) {
            return "Sender has insufficient unlocked balance (holding period active)";
        }
        return TEXT_CODE_NOT_FOUND;
    }

    /// @dev Reserved storage for future variables without shifting slot layout.
    uint256[47] private __gap;
}
