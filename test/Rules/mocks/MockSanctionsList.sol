// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title MockSanctionsList
/// @notice Mock sanctions oracle for testing RuleSanctionList
/// @dev Simulates a simple sanctions list without Chainlink dependency
contract MockSanctionsList {
    mapping(address => bool) private _sanctioned;

    event AddressAddedToSanctionsList(address indexed addr);
    event AddressRemovedFromSanctionsList(address indexed addr);

    /// @notice Check if an address is sanctioned
    /// @param addr Address to check
    /// @return true if sanctioned, false otherwise
    function isSanctioned(address addr) external view returns (bool) {
        return _sanctioned[addr];
    }

    /// @notice Add an address to the sanctions list (test helper)
    /// @param addr Address to sanction
    function addToSanctionsList(address addr) external {
        _sanctioned[addr] = true;
        emit AddressAddedToSanctionsList(addr);
    }

    /// @notice Remove an address from the sanctions list (test helper)
    /// @param addr Address to remove
    function removeFromSanctionsList(address addr) external {
        _sanctioned[addr] = false;
        emit AddressRemovedFromSanctionsList(addr);
    }

    /// @notice Batch add addresses to sanctions list
    /// @param addrs Addresses to sanction
    function addToSanctionsListBatch(address[] calldata addrs) external {
        for (uint256 i = 0; i < addrs.length; i++) {
            _sanctioned[addrs[i]] = true;
            emit AddressAddedToSanctionsList(addrs[i]);
        }
    }
}
