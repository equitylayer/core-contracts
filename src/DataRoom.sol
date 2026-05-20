// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FHE, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ICompany} from "./interfaces/ICompany.sol";
import {IDataRoom} from "./interfaces/IDataRoom.sol";

/// @title DataRoom
/// @notice Trustless data room with FHE-encrypted access control.
contract DataRoom is IDataRoom {
    // Errors
    error OnlyBoard();
    error RoomNotFound();
    error NotMember();
    error Unauthorized();
    error LengthMismatch();
    error NotParentRoom();
    error IsParentRoom();
    error BatchTooLarge();
    error InvalidAddress();
    error AlreadyInitialized();
    error DocumentNotFound();
    error DocumentDeleted();
    error EmptyBatch();
    error CannotRevokeOperator();

    struct Room {
        string name;
        uint256 documentCount;
        uint256 memberCount;
        bool isParent;
        uint256 parentId;
        uint256 childCount;
    }

    struct Document {
        string cid;
        string name;
        uint256 createdAt;
        bytes wrappedKey;
        bytes metadata;
        bool deleted;
    }

    uint256 public constant NO_PARENT = type(uint256).max;
    uint256 public constant MAX_BATCH_SIZE = 100;

    ICompany public override company;
    bool private _initialized;

    uint256 public override roomCount;
    mapping(uint256 => Room) public rooms;
    mapping(uint256 => mapping(uint256 => Document)) internal _documents;

    /// @dev FHE-encrypted folder key (root secret for AES key wrapping)
    mapping(uint256 => euint128) private _roomKey;
    mapping(uint256 => uint256) public roomKeyVersion;
    mapping(uint256 => mapping(uint256 => uint256)) public documentKeyVersion;

    /// @dev Packed member array: slots 0..memberCount-1 are always active members.
    mapping(uint256 => mapping(uint256 => address)) private _members;
    /// @dev Reverse lookup: member address → slot index in _members.
    mapping(uint256 => mapping(address => uint256)) private _memberIndex;
    mapping(uint256 => mapping(address => bool)) private _isMember;

    /// @dev parentId => child index => roomId
    mapping(uint256 => mapping(uint256 => uint256)) private _children;

    // Public Events
    event RoomCreated(uint256 indexed roomId, address indexed creator);
    event FolderCreated(uint256 indexed parentId, uint256 indexed roomId);
    event DocumentAdded(uint256 indexed roomId, uint256 indexed docIndex);
    event MembershipChanged(uint256 indexed roomId);
    event RoomRekeyed(uint256 indexed roomId, uint256 newVersion);
    event DocumentRemoved(uint256 indexed roomId, uint256 indexed docIndex);
    event RoomRenamed(uint256 indexed roomId, string newName);

    // Modifiers
    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    modifier notParentRoom(uint256 roomId) {
        if (rooms[roomId].isParent) revert IsParentRoom();
        _;
    }

    modifier roomExists(uint256 roomId) {
        if (roomId >= roomCount) revert RoomNotFound();
        _;
    }

    // Initializer

    /// @inheritdoc IDataRoom
    function initialize(address _company) external {
        if (_initialized) revert AlreadyInitialized();
        if (_company == address(0)) revert InvalidAddress();
        _initialized = true;
        company = ICompany(_company);
    }

    /// @inheritdoc IDataRoom
    function operator() public view returns (address) {
        return company.operator();
    }

    // Room Management

    /// @inheritdoc IDataRoom
    function createRoom(string calldata name) external onlyBoard returns (uint256 roomId) {
        return _createRoom(name);
    }

    /// @inheritdoc IDataRoom
    function createFolder(uint256 parentId, string calldata name)
        external
        onlyBoard
        roomExists(parentId)
        returns (uint256 roomId)
    {
        return _createFolder(parentId, name);
    }

    /// @inheritdoc IDataRoom
    function createRoomWithFolders(string calldata name, string[] calldata folderNames)
        external
        onlyBoard
        returns (uint256 roomId, uint256[] memory folderIds)
    {
        roomId = _createRoom(name);
        folderIds = new uint256[](folderNames.length);
        for (uint256 i = 0; i < folderNames.length; i++) {
            folderIds[i] = _createFolder(roomId, folderNames[i]);
        }
    }

    /// @inheritdoc IDataRoom
    function createFolders(uint256 parentId, string[] calldata names)
        external
        onlyBoard
        roomExists(parentId)
        returns (uint256[] memory folderIds)
    {
        folderIds = new uint256[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            folderIds[i] = _createFolder(parentId, names[i]);
        }
    }

    function _createRoom(string memory name) internal returns (uint256 roomId) {
        roomId = roomCount++;
        rooms[roomId] =
            Room({name: name, documentCount: 0, memberCount: 0, isParent: true, parentId: NO_PARENT, childCount: 0});
        emit RoomCreated(roomId, msg.sender);
    }

    function _createFolder(uint256 parentId, string memory name) internal returns (uint256 roomId) {
        Room storage parent = rooms[parentId];
        if (!parent.isParent) revert NotParentRoom();

        roomId = roomCount++;
        rooms[roomId] =
            Room({name: name, documentCount: 0, memberCount: 0, isParent: false, parentId: parentId, childCount: 0});

        _children[parentId][parent.childCount] = roomId;
        parent.childCount++;

        euint128 key = FHE.randomEuint128();
        _roomKey[roomId] = key;
        FHE.allowThis(key);
        FHE.allow(key, operator());

        _grantUser(roomId, msg.sender);

        emit FolderCreated(parentId, roomId);
    }

    /// @inheritdoc IDataRoom
    function renameRoom(uint256 roomId, string calldata newName) external onlyBoard roomExists(roomId) {
        rooms[roomId].name = newName;
        emit RoomRenamed(roomId, newName);
    }

    // Document Management

    /// @inheritdoc IDataRoom
    function addDocuments(
        uint256 roomId,
        string[] calldata cids,
        string[] calldata names,
        bytes[] calldata wrappedKeys,
        bytes[] calldata metadata
    ) external onlyBoard roomExists(roomId) notParentRoom(roomId) {
        if (cids.length == 0) revert EmptyBatch();
        if (cids.length != names.length || cids.length != wrappedKeys.length || cids.length != metadata.length) {
            revert LengthMismatch();
        }
        if (cids.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < cids.length;) {
            uint256 docIndex = rooms[roomId].documentCount++;
            _documents[roomId][docIndex] = Document({
                cid: cids[i],
                name: names[i],
                createdAt: block.timestamp,
                wrappedKey: wrappedKeys[i],
                metadata: metadata[i],
                deleted: false
            });
            documentKeyVersion[roomId][docIndex] = roomKeyVersion[roomId];
            emit DocumentAdded(roomId, docIndex);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IDataRoom
    function removeDocument(uint256 roomId, uint256 docIndex)
        external
        onlyBoard
        roomExists(roomId)
        notParentRoom(roomId)
    {
        if (docIndex >= rooms[roomId].documentCount) revert DocumentNotFound();
        if (_documents[roomId][docIndex].deleted) revert DocumentDeleted();
        _documents[roomId][docIndex].deleted = true;
        emit DocumentRemoved(roomId, docIndex);
    }

    /// @inheritdoc IDataRoom
    function updateDocumentMetadata(uint256 roomId, uint256[] calldata docIndices, bytes[] calldata metadata)
        external
        onlyBoard
        roomExists(roomId)
        notParentRoom(roomId)
    {
        if (docIndices.length != metadata.length) revert LengthMismatch();
        if (docIndices.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        uint256 docCount = rooms[roomId].documentCount;
        for (uint256 i = 0; i < docIndices.length;) {
            if (docIndices[i] >= docCount) revert DocumentNotFound();
            if (_documents[roomId][docIndices[i]].deleted) revert DocumentDeleted();
            _documents[roomId][docIndices[i]].metadata = metadata[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IDataRoom
    function updateDocumentKeys(uint256 roomId, uint256[] calldata docIndices, bytes[] calldata newWrappedKeys)
        external
        onlyBoard
        roomExists(roomId)
        notParentRoom(roomId)
    {
        if (docIndices.length != newWrappedKeys.length) revert LengthMismatch();
        if (docIndices.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        uint256 docCount = rooms[roomId].documentCount;
        for (uint256 i = 0; i < docIndices.length;) {
            if (docIndices[i] >= docCount) revert DocumentNotFound();
            if (_documents[roomId][docIndices[i]].deleted) revert DocumentDeleted();
            _documents[roomId][docIndices[i]].wrappedKey = newWrappedKeys[i];
            documentKeyVersion[roomId][docIndices[i]] = roomKeyVersion[roomId];
            unchecked {
                ++i;
            }
        }
    }

    // ─── Access Group Management

    /// @inheritdoc IDataRoom
    function grantAccess(uint256 roomId, address[] calldata users)
        external
        onlyBoard
        roomExists(roomId)
        notParentRoom(roomId)
    {
        if (users.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < users.length;) {
            if (users[i] == address(0)) revert InvalidAddress();
            _grantUser(roomId, users[i]);
            unchecked {
                ++i;
            }
        }
        emit MembershipChanged(roomId);
    }

    /// @inheritdoc IDataRoom
    function revokeAccess(uint256 roomId, address[] calldata users)
        external
        onlyBoard
        roomExists(roomId)
        notParentRoom(roomId)
    {
        _revokeAccess(roomId, users);
    }

    /// @inheritdoc IDataRoom
    function revokeAndRekey(uint256 roomId, address[] calldata users)
        external
        onlyBoard
        roomExists(roomId)
        notParentRoom(roomId)
    {
        _revokeAccess(roomId, users);
        _rekeyRoom(roomId);
    }

    /// @inheritdoc IDataRoom
    function grantAccessToAllFolders(uint256 parentId, address user) external onlyBoard roomExists(parentId) {
        if (user == address(0)) revert InvalidAddress();
        Room storage parent = rooms[parentId];
        if (!parent.isParent) revert NotParentRoom();

        for (uint256 i = 0; i < parent.childCount;) {
            uint256 roomId = _children[parentId][i];
            _grantUser(roomId, user);
            emit MembershipChanged(roomId);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IDataRoom
    function revokeAccessFromAllFolders(uint256 parentId, address user) external onlyBoard roomExists(parentId) {
        if (user == operator()) revert CannotRevokeOperator();
        Room storage parent = rooms[parentId];
        if (!parent.isParent) revert NotParentRoom();

        for (uint256 i = 0; i < parent.childCount;) {
            uint256 roomId = _children[parentId][i];
            if (_isMember[roomId][user]) {
                _removeUser(roomId, user);
                emit MembershipChanged(roomId);
            }
            unchecked {
                ++i;
            }
        }
    }

    // Key Management

    /// @inheritdoc IDataRoom
    function rekeyRoom(uint256 roomId) external onlyBoard roomExists(roomId) notParentRoom(roomId) {
        _rekeyRoom(roomId);
    }

    // ─── Internal Helpers

    /// @dev Grant a single user access to a folder. Skips if already a member.
    function _grantUser(uint256 roomId, address user) internal {
        if (_isMember[roomId][user]) return;

        uint256 slot = rooms[roomId].memberCount++;
        _members[roomId][slot] = user;
        _memberIndex[roomId][user] = slot;
        _isMember[roomId][user] = true;

        FHE.allow(_roomKey[roomId], user);
    }

    /// @dev Remove a user from the packed member array (swap-and-pop).
    function _removeUser(uint256 roomId, address user) internal {
        uint256 slot = _memberIndex[roomId][user];
        uint256 lastSlot = rooms[roomId].memberCount - 1;

        if (slot != lastSlot) {
            address lastMember = _members[roomId][lastSlot];
            _members[roomId][slot] = lastMember;
            _memberIndex[roomId][lastMember] = slot;
        }

        delete _members[roomId][lastSlot];
        delete _memberIndex[roomId][user];
        _isMember[roomId][user] = false;
        rooms[roomId].memberCount--;
    }

    function _revokeAccess(uint256 roomId, address[] calldata users) internal {
        if (users.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < users.length;) {
            address user = users[i];
            if (user == operator()) revert CannotRevokeOperator();
            if (!_isMember[roomId][user]) revert NotMember();
            _removeUser(roomId, user);
            unchecked {
                ++i;
            }
        }
        emit MembershipChanged(roomId);
    }

    function _rekeyRoom(uint256 roomId) internal {
        euint128 newKey = FHE.randomEuint128();
        _roomKey[roomId] = newKey;
        roomKeyVersion[roomId]++;
        FHE.allowThis(newKey);
        FHE.allow(newKey, operator());

        // Only iterates active members (packed array)
        uint256 count = rooms[roomId].memberCount;
        for (uint256 i = 0; i < count;) {
            FHE.allow(newKey, _members[roomId][i]);
            unchecked {
                ++i;
            }
        }

        emit RoomRekeyed(roomId, roomKeyVersion[roomId]);
    }

    // Views

    /// @inheritdoc IDataRoom
    function hasAccess(uint256 roomId) external view roomExists(roomId) returns (bool) {
        return _isMember[roomId][msg.sender];
    }

    /// @notice Get the encrypted folder key handle. Only decryptable if granted FHE access.
    /// @param roomId The folder to get the key for.
    function getRoomKey(uint256 roomId) external view roomExists(roomId) notParentRoom(roomId) returns (euint128) {
        if (msg.sender != company.board() && msg.sender != operator() && !_isMember[roomId][msg.sender]) {
            revert Unauthorized();
        }
        return _roomKey[roomId];
    }

    /// @inheritdoc IDataRoom
    function getDocument(uint256 roomId, uint256 docIndex)
        external
        view
        roomExists(roomId)
        returns (
            string memory cid,
            string memory name,
            uint256 createdAt,
            uint256 keyVersion,
            bytes memory wrappedKey,
            bytes memory metadata
        )
    {
        if (docIndex >= rooms[roomId].documentCount) revert DocumentNotFound();
        Document storage doc = _documents[roomId][docIndex];
        if (doc.deleted) revert DocumentDeleted();
        if (doc.wrappedKey.length > 0) {
            if (msg.sender != company.board() && msg.sender != operator() && !_isMember[roomId][msg.sender]) {
                revert Unauthorized();
            }
        }
        return (doc.cid, doc.name, doc.createdAt, documentKeyVersion[roomId][docIndex], doc.wrappedKey, doc.metadata);
    }

    /// @inheritdoc IDataRoom
    function getRoom(uint256 roomId)
        external
        view
        roomExists(roomId)
        returns (
            string memory name,
            uint256 documentCount,
            uint256 memberCount,
            bool isParent,
            uint256 parentId,
            uint256 childCount
        )
    {
        Room storage room = rooms[roomId];
        return (room.name, room.documentCount, room.memberCount, room.isParent, room.parentId, room.childCount);
    }

    /// @inheritdoc IDataRoom
    function getFolders(uint256 parentId) external view roomExists(parentId) returns (uint256[] memory) {
        Room storage parent = rooms[parentId];
        if (!parent.isParent) revert NotParentRoom();

        uint256[] memory result = new uint256[](parent.childCount);
        for (uint256 i = 0; i < parent.childCount;) {
            result[i] = _children[parentId][i];
            unchecked {
                ++i;
            }
        }
        return result;
    }

    /// @inheritdoc IDataRoom
    function getParentRoom(uint256 roomId) external view roomExists(roomId) returns (uint256) {
        return rooms[roomId].parentId;
    }

    /// @inheritdoc IDataRoom
    function getMembers(uint256 roomId) external view roomExists(roomId) returns (address[] memory) {
        if (msg.sender != company.board() && msg.sender != operator()) revert Unauthorized();

        uint256 count = rooms[roomId].memberCount;
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count;) {
            result[i] = _members[roomId][i];
            unchecked {
                ++i;
            }
        }
        return result;
    }
}
