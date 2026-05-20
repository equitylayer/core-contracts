// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title IRuleCountryBlocklist
/// @notice Identity interface for the country-blocklist rule family.
interface IRuleCountryBlocklist {
    function addCountry(uint16 countryCode) external;
    function removeCountry(uint16 countryCode) external;
    function setCountries(uint16[] calldata countryCodes) external;
}
