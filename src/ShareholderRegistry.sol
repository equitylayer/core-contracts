// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/// @title ShareholderRegistry
/// @notice Tracks all shareholders per share token for easy enumeration
/// @dev Called by ShareToken on every transfer to maintain up-to-date shareholder lists
contract ShareholderRegistry {
    string public constant VERSION = "0.9.0";

    address public company;
    bool private _initialized;

    mapping(address => address[]) private _shareholders;
    /// @notice (1-based, 0 means not present)
    mapping(address => mapping(address => uint256)) private _shareholderIndex;
    mapping(address => mapping(address => bool)) private _isHolder;

    uint256 private _totalUniqueShareholders;
    /// @notice Number of share classes each address currently holds tokens in
    mapping(address => uint256) private _shareClassCount;

    /// @notice Allowlist of registered share tokens
    mapping(address => bool) public registeredTokens;

    // ============ Events ============
    event ShareholderAdded(address indexed shareToken, address indexed shareholder);
    event ShareholderRemoved(address indexed shareToken, address indexed shareholder);
    event TokenRegistered(address indexed shareToken);

    // ============ Errors ============
    error OnlyCompany();
    error OnlyShareToken();
    error InvalidShareToken();
    error AlreadyInitialized();
    error ZeroAddress();

    // ============ Modifiers ============
    modifier onlyCompany() {
        if (msg.sender != company) revert OnlyCompany();
        _;
    }

    // ============ Initializer ============
    /// @notice Initialize the registry
    /// @param _company Address of the company that owns this registry
    function initialize(address _company) external {
        if (_initialized) revert AlreadyInitialized();
        if (_company == address(0)) revert ZeroAddress();
        _initialized = true;
        company = _company;
    }

    // ============ Core Functions ============

    /// @notice Register a share token so it can call updateOnTransfer
    /// @param shareToken Address of the share token to register
    function registerToken(address shareToken) external onlyCompany {
        if (shareToken == address(0)) revert ZeroAddress();
        registeredTokens[shareToken] = true;
        emit TokenRegistered(shareToken);
    }

    /// @notice Update shareholder list on transfer
    /// @dev Called by ShareToken after every transfer
    /// @param shareToken Address of the share token (share class)
    /// @param from Sender address (address(0) for minting)
    /// @param to Recipient address (address(0) for burning)
    /// @param fromBalance New balance of sender after transfer
    /// @param toBalance New balance of recipient after transfer
    function updateOnTransfer(address shareToken, address from, address to, uint256 fromBalance, uint256 toBalance)
        external
    {
        if (msg.sender != shareToken) revert OnlyShareToken();
        if (!registeredTokens[shareToken]) revert InvalidShareToken();

        if (to != address(0) && toBalance > 0 && !_isHolder[shareToken][to]) {
            _addShareholder(shareToken, to);
        }

        if (from != address(0) && fromBalance == 0 && _isHolder[shareToken][from]) {
            _deactivateShareholder(shareToken, from);
        }
    }

    // ============ View Functions ============

    /// @notice Get all shareholders for a specific share class
    /// @param shareToken Address of the share token
    /// @return Array of shareholder addresses
    function getShareholders(address shareToken) external view returns (address[] memory) {
        return _shareholders[shareToken];
    }

    /// @notice Get number of shareholders for a specific share class
    /// @param shareToken Address of the share token
    /// @return Number of shareholders
    function getShareholderCount(address shareToken) external view returns (uint256) {
        return _shareholders[shareToken].length;
    }

    /// @notice Check if an address is a shareholder of a specific share class
    /// @param shareToken Address of the share token
    /// @param account Address to check
    /// @return True if account is a shareholder
    function isHolder(address shareToken, address account) external view returns (bool) {
        return _isHolder[shareToken][account];
    }

    /// @notice Get total number of unique shareholders across all share classes
    /// @return Total unique shareholders
    function getTotalUniqueShareholders() external view returns (uint256) {
        return _totalUniqueShareholders;
    }

    /// @notice Get paginated list of shareholders
    /// @param shareToken Address of the share token
    /// @param offset Starting index
    /// @param limit Maximum number of results
    /// @return shareholders Array of shareholder addresses
    /// @return total Total number of shareholders
    function getShareholdersPaginated(address shareToken, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory shareholders, uint256 total)
    {
        address[] memory allShareholders = _shareholders[shareToken];
        total = allShareholders.length;

        if (offset >= total) {
            return (new address[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLength = end - offset;
        shareholders = new address[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            shareholders[i] = allShareholders[offset + i];
        }

        return (shareholders, total);
    }

    // ============ Internal Functions ============

    /// @notice Add a shareholder to the registry
    /// @param shareToken Address of the share token
    /// @param shareholder Address of the shareholder
    function _addShareholder(address shareToken, address shareholder) internal {
        if (_shareholderIndex[shareToken][shareholder] == 0) {
            _shareholders[shareToken].push(shareholder);
            _shareholderIndex[shareToken][shareholder] = _shareholders[shareToken].length; // 1-based index
        }
        _isHolder[shareToken][shareholder] = true;

        _shareClassCount[shareholder]++;
        if (_shareClassCount[shareholder] == 1) {
            _totalUniqueShareholders++;
        }

        emit ShareholderAdded(shareToken, shareholder);
    }

    /// @notice Remove a shareholder from the registry on zero balance using swap-and-pop.
    /// @param shareToken Address of the share token
    /// @param shareholder Address of the shareholder
    function _deactivateShareholder(address shareToken, address shareholder) internal {
        uint256 idx = _shareholderIndex[shareToken][shareholder]; // 1-based
        if (idx != 0) {
            address[] storage list = _shareholders[shareToken];
            uint256 lastIdx = list.length;
            if (idx != lastIdx) {
                address lastHolder = list[lastIdx - 1];
                list[idx - 1] = lastHolder;
                _shareholderIndex[shareToken][lastHolder] = idx;
            }
            list.pop();
            delete _shareholderIndex[shareToken][shareholder];
        }
        delete _isHolder[shareToken][shareholder];

        _shareClassCount[shareholder]--;
        if (_shareClassCount[shareholder] == 0) {
            _totalUniqueShareholders--;
        }

        emit ShareholderRemoved(shareToken, shareholder);
    }
}
