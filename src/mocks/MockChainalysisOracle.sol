// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockChainalysisOracle
/// @notice Mock implementation of Chainalysis sanctions oracle for local testing
/// @dev Only deploy this on localhost/testnet, NOT mainnet (use real oracle on mainnet)
contract MockChainalysisOracle is Ownable {
    mapping(address => bool) private _sanctioned;

    event AddressAddedToSanctionsList(address indexed addr);
    event AddressRemovedFromSanctionsList(address indexed addr);

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Check if an address is sanctioned
    /// @dev Returns false for address(0) to avoid reverts during minting/burning
    function isSanctioned(address addr) external view returns (bool) {
        if (addr == address(0)) {
            return false;
        }
        return _sanctioned[addr];
    }

    /// @notice Add an address to the sanctions list
    /// @param addr Address to sanction
    function addToSanctionsList(address addr) external onlyOwner {
        require(addr != address(0), "Cannot sanction zero address");
        _sanctioned[addr] = true;
        emit AddressAddedToSanctionsList(addr);
    }

    /// @notice Add multiple addresses to the sanctions list
    /// @param addrs Array of addresses to sanction
    function addToSanctionsListMultiple(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            require(addrs[i] != address(0), "Cannot sanction zero address");
            _sanctioned[addrs[i]] = true;
            emit AddressAddedToSanctionsList(addrs[i]);
        }
    }

    /// @notice Remove an address from the sanctions list
    /// @param addr Address to remove from sanctions
    function removeFromSanctionsList(address addr) external onlyOwner {
        _sanctioned[addr] = false;
        emit AddressRemovedFromSanctionsList(addr);
    }
}
