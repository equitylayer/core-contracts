// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "./IVault.sol";
import {ISAFE} from "./ISAFE.sol";
import {IFundraise} from "./IFundraise.sol";
import {IConvertibleNote} from "./IConvertibleNote.sol";
import {IDataRoom} from "./IDataRoom.sol";
import {IEquityIssuance} from "./IEquityIssuance.sol";
import {ShareToken} from "../ShareToken.sol";
import {ShareholderRegistry} from "../ShareholderRegistry.sol";
import {VestingSchedule} from "../VestingSchedule.sol";
import {OptionPool} from "../OptionPool.sol";

/// @notice External surface of `Company`. Most members are public state vars whose
///         auto-getters satisfy these signatures; the impl marks them `override`.
interface ICompany {
    /// @notice Strategic admin -- holds DEFAULT_ADMIN_ROLE on RuleEngine / ShareToken.
    function board() external view returns (address);

    /// @notice Treasury / dividend custody.
    function vault() external view returns (IVault);

    /// @notice ISO 3166-1 numeric country code.
    function countryCode() external view returns (uint16);

    /// @notice Entity type -- interpretation depends on jurisdiction
    ///         (US: 1=C-Corp, 2=S-Corp; UK: 1=Ltd, 2=PLC; CH: 1=AG, 2=GmbH, 3=SA).
    function entityType() external view returns (uint8);

    function vestingSchedule() external view returns (VestingSchedule);

    function optionPool() external view returns (OptionPool);

    function safe() external view returns (ISAFE);

    function fundraise() external view returns (IFundraise);

    function convertibleNote() external view returns (IConvertibleNote);

    /// @notice Single share-emission gate.
    function issuance() external view returns (IEquityIssuance);

    function shareholderRegistry() external view returns (ShareholderRegistry);

    function dataRoom() external view returns (IDataRoom);

    function paymentToken() external view returns (IERC20);

    /// @notice Platform operator (FHE key holder). Derived live from the factory.
    function operator() external view returns (address);

    /// @notice Get the ShareToken for a specific share class.
    /// @param className The share class name (e.g. "Common", "Preferred Series A").
    function getShareToken(string memory className) external view returns (ShareToken);

    /// @notice Total shares outstanding across ALL share classes.
    /// @return total Sum of `totalSupply()` for every share class token.
    function getTotalSharesOutstanding() external view returns (uint256 total);

    /// @notice Fully diluted shares (issued + option pool + outstanding options).
    /// @return total Sum of issued shares + full option-pool reservation + granted-but-unexercised options.
    /// @dev Excludes unconverted SAFEs/Notes (share count unknown until a priced round sets the price).
    function getFullyDilutedShares() external view returns (uint256 total);
}
