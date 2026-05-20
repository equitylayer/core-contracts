// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ICompany} from "./ICompany.sol";

/// @title IDataRoom
/// @notice Trustless data room with FHE-encrypted access control. Each Company
///         clones one; rooms are folders that scope document access. Members
///         receive an FHE-encrypted folder key; documents within carry per-doc
///         wrapped keys (empty wrappedKey = public).
interface IDataRoom {
    /// @notice One-time initializer for an EIP-1167 clone.
    function initialize(address _company) external;

    /// @notice Create a new top-level room (a folder of folders).
    function createRoom(string calldata name) external returns (uint256 roomId);

    /// @notice Create a folder under `parentId` (which must itself be a parent room).
    function createFolder(uint256 parentId, string calldata name) external returns (uint256 roomId);

    /// @notice Atomically create a parent room and a set of child folders in one tx.
    /// @param  name          name of the new parent room
    /// @param  folderNames   names of the child folders to create under it
    /// @return roomId        id of the new parent room
    /// @return folderIds     ids of the created folders, aligned with `folderNames`
    function createRoomWithFolders(string calldata name, string[] calldata folderNames)
        external
        returns (uint256 roomId, uint256[] memory folderIds);

    /// @notice Add multiple folders to an existing parent room in one tx.
    /// @param  parentId      id of an existing parent room
    /// @param  names         names of the folders to create
    /// @return folderIds     ids of the created folders, aligned with `names`
    function createFolders(uint256 parentId, string[] calldata names) external returns (uint256[] memory folderIds);

    /// @notice Rename a room. Board only.
    function renameRoom(uint256 roomId, string calldata newName) external;

    /// @notice Bulk add documents to a folder. Each doc carries its own wrapped key
    ///         (empty `wrappedKey` = public doc).
    function addDocuments(
        uint256 roomId,
        string[] calldata cids,
        string[] calldata names,
        bytes[] calldata wrappedKeys,
        bytes[] calldata metadata
    ) external;

    /// @notice Soft-delete a document (sets `deleted = true`).
    function removeDocument(uint256 roomId, uint256 docIndex) external;

    /// @notice Bulk-update document metadata.
    function updateDocumentMetadata(uint256 roomId, uint256[] calldata docIndices, bytes[] calldata metadata) external;

    /// @notice Grant folder access to a batch of users. Idempotent on duplicates.
    function grantAccess(uint256 roomId, address[] calldata users) external;

    /// @notice Revoke folder access from a batch of users.
    function revokeAccess(uint256 roomId, address[] calldata users) external;

    /// @notice Revoke access + rekey the folder. Required to "evict" a member.
    function revokeAndRekey(uint256 roomId, address[] calldata users) external;

    /// @notice Grant `user` access to every folder under `parentId`.
    function grantAccessToAllFolders(uint256 parentId, address user) external;

    /// @notice Revoke `user`'s access across every folder under `parentId`.
    function revokeAccessFromAllFolders(uint256 parentId, address user) external;

    /// @notice Rekey a folder (members keep access, eavesdroppers don't).
    function rekeyRoom(uint256 roomId) external;

    /// @notice Bulk-update document wrapped keys (e.g. after a folder rekey).
    function updateDocumentKeys(uint256 roomId, uint256[] calldata docIndices, bytes[] calldata newWrappedKeys) external;

    /// @notice Whether the caller is a member of `roomId`.
    function hasAccess(uint256 roomId) external view returns (bool);

    /// @notice Room metadata.
    function getRoom(uint256 roomId)
        external
        view
        returns (
            string memory name,
            uint256 documentCount,
            uint256 memberCount,
            bool isParent,
            uint256 parentId,
            uint256 childCount
        );

    /// @notice Document metadata + ciphertext blobs. Reverts on out-of-range or deleted docs.
    function getDocument(uint256 roomId, uint256 docIndex)
        external
        view
        returns (
            string memory cid,
            string memory name,
            uint256 createdAt,
            uint256 keyVersion,
            bytes memory wrappedKey,
            bytes memory metadata
        );

    /// @notice Child room ids of a parent room.
    function getFolders(uint256 parentId) external view returns (uint256[] memory);

    /// @notice Active members of a room (caller-visible addresses only).
    function getMembers(uint256 roomId) external view returns (address[] memory);

    /// @notice Parent room id (or `type(uint256).max` for top-level rooms).
    function getParentRoom(uint256 roomId) external view returns (uint256);

    /// @notice Number of rooms ever created.
    function roomCount() external view returns (uint256);

    /// @notice The owning Company.
    function company() external view returns (ICompany);

    /// @notice Platform operator (FHE key holder). Derived live from the factory.
    function operator() external view returns (address);
}
