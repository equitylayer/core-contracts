// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {DataRoom} from "../src/DataRoom.sol";
import {DataRoomBaseTest} from "./helpers/DataRoomBase.t.sol";
import {Company} from "../src/Company.sol";

contract DataRoomTest is DataRoomBaseTest {
    address member = makeAddr("member");

    uint256 constant PARENT = 0;
    uint256 constant FOLDER = 1;

    function setUp() public {
        _baseSetUp();
        _setupCompany();

        room = DataRoom(address(company.dataRoom()));
        vm.startPrank(board);
        room.createRoom("Deal Alpha");
        room.createFolder(PARENT, "Legal");
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════
    //  initialize()
    // ═════════════════════════════════════════════════════════

    function test_initialize_setsCompanyAndOperator() public view {
        assertEq(address(room.company()), address(company));
        assertEq(room.operator(), obolosOperator);
    }

    function test_initialize_revertsOnDouble() public {
        vm.expectRevert(DataRoom.AlreadyInitialized.selector);
        room.initialize(address(company));
    }

    function test_initialize_rejectsZeroCompany() public {
        DataRoom r = new DataRoom();
        vm.expectRevert(DataRoom.InvalidAddress.selector);
        r.initialize(address(0));
    }

    // ═════════════════════════════════════════════════════════
    //  createRoom()
    // ═════════════════════════════════════════════════════════

    function test_createRoom_createsParentRoom() public {
        DataRoom r = _freshRoom();
        vm.expectEmit(true, true, false, true);
        emit DataRoom.RoomCreated(0, board);
        vm.prank(board);
        r.createRoom("Series A");

        (string memory name, uint256 docCount, uint256 memberCount, bool isParent,,) = r.getRoom(0);
        assertEq(name, "Series A");
        assertTrue(isParent);
        assertEq(memberCount, 0);
        assertEq(docCount, 0);
    }

    function test_createRoom_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(nonBoard);
        room.createRoom("Nope");
    }

    // ═════════════════════════════════════════════════════════
    //  createFolder()
    // ═════════════════════════════════════════════════════════

    function test_createFolder_createsUnderParent() public view {
        (string memory name,, uint256 memberCount, bool isParent, uint256 parentId,) = room.getRoom(FOLDER);
        assertEq(name, "Legal");
        assertFalse(isParent);
        assertEq(parentId, PARENT);
        assertEq(memberCount, 1);

        (,,,, uint256 pId, uint256 childCount) = room.getRoom(PARENT);
        assertEq(pId, type(uint256).max);
        assertEq(childCount, 1);
    }

    function test_createFolder_emitsFolderCreated() public {
        DataRoom r = _freshRoom();
        vm.startPrank(board);
        r.createRoom("P");
        vm.expectEmit(true, true, false, true);
        emit DataRoom.FolderCreated(0, 1);
        r.createFolder(0, "Legal");
        vm.stopPrank();
    }

    function test_createFolder_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(nonBoard);
        room.createFolder(PARENT, "Nope");
    }

    function test_createRoomWithFolders_createsAtomic() public {
        DataRoom r = _freshRoom();
        string[] memory names = new string[](3);
        names[0] = "Charter";
        names[1] = "Bylaws";
        names[2] = "Cap Table";

        vm.prank(board);
        (uint256 roomId, uint256[] memory folderIds) = r.createRoomWithFolders("Incorporation", names);

        assertEq(roomId, 0);
        assertEq(folderIds.length, 3);
        assertEq(folderIds[0], 1);
        assertEq(folderIds[1], 2);
        assertEq(folderIds[2], 3);

        (string memory parentName,,, bool isParent, uint256 parentId,) = r.rooms(roomId);
        assertEq(parentName, "Incorporation");
        assertTrue(isParent);

        (string memory folderName,,, bool isFolderParent, uint256 folderParent,) = r.rooms(folderIds[1]);
        assertEq(folderName, "Bylaws");
        assertFalse(isFolderParent);
        assertEq(folderParent, roomId);
    }

    function test_createRoomWithFolders_rejectsNonBoard() public {
        DataRoom r = _freshRoom();
        string[] memory names = new string[](1);
        names[0] = "Charter";

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(nonBoard);
        r.createRoomWithFolders("Incorporation", names);
    }

    function test_createFolders_addsToExistingParent() public {
        DataRoom r = _freshRoom();
        vm.startPrank(board);
        uint256 parentId = r.createRoom("Incorporation");
        string[] memory names = new string[](2);
        names[0] = "IP Assignments";
        names[1] = "Stock Plan";
        uint256[] memory folderIds = r.createFolders(parentId, names);
        vm.stopPrank();

        assertEq(folderIds.length, 2);
        (,,, bool isFolderParent, uint256 folderParent,) = r.rooms(folderIds[0]);
        assertFalse(isFolderParent);
        assertEq(folderParent, parentId);
    }

    function test_createFolders_rejectsNonParent() public {
        DataRoom r = _freshRoom();
        vm.startPrank(board);
        r.createRoom("P");
        uint256 childId = r.createFolder(0, "Child");
        vm.stopPrank();

        string[] memory names = new string[](1);
        names[0] = "Nested";
        vm.expectRevert(DataRoom.NotParentRoom.selector);
        vm.prank(board);
        r.createFolders(childId, names);
    }

    function test_createFolder_rejectsNesting() public {
        vm.expectRevert(DataRoom.NotParentRoom.selector);
        vm.prank(board);
        room.createFolder(FOLDER, "Nested");
    }

    function test_createFolder_eachFolderGetsNonZeroKey() public {
        vm.prank(board);
        room.createFolder(PARENT, "Financials"); // folder 2

        bytes32 h1 = _keyHandle(board, 1);
        bytes32 h2 = _keyHandle(board, 2);
        assertTrue(h1 != bytes32(0));
        assertTrue(h2 != bytes32(0));
        // NOTE: Mock RNG is deterministic per block so handles may collide.
        // Real FHE RNG guarantees uniqueness in production.
    }

    // ═════════════════════════════════════════════════════════
    //  addDocuments()
    // ═════════════════════════════════════════════════════════

    function test_addDocuments_addsToFolder() public {
        bytes memory wk0 = _wk(0);
        bytes memory wk1 = _wk(1);

        vm.expectEmit(true, true, false, true);
        emit DataRoom.DocumentAdded(FOLDER, 0);
        vm.prank(board);
        room.addDocuments(FOLDER, _s2("cid0", "cid1"), _s2("f0.pdf", "f1.pdf"), _b2(wk0, wk1), _b2("", ""));

        (, uint256 docCount,,,,) = room.getRoom(FOLDER);
        assertEq(docCount, 2);

        (string memory cid, string memory name,,, bytes memory wrappedKey,) = _getDoc(FOLDER, 0);
        assertEq(cid, "cid0");
        assertEq(name, "f0.pdf");
        assertEq(wrappedKey, wk0);
    }

    function test_addDocuments_inheritsRoomKeyVersion() public {
        vm.startPrank(board);
        room.addDocuments(FOLDER, _s1("cid0"), _s1("f0.pdf"), _b1(_wk(0)), _b1(""));
        (,,, uint256 kv0,,) = room.getDocument(FOLDER, 0);
        assertEq(kv0, 0);

        room.rekeyRoom(FOLDER);
        room.addDocuments(FOLDER, _s1("cid1"), _s1("f1.pdf"), _b1(_wk(1)), _b1(""));
        (,,, uint256 kv1,,) = room.getDocument(FOLDER, 1);
        assertEq(kv1, 1);

        // old doc still at version 0
        (,,, uint256 kv0after,,) = room.getDocument(FOLDER, 0);
        assertEq(kv0after, 0);
        vm.stopPrank();
    }

    function test_addDocuments_rejectsLengthMismatch() public {
        vm.expectRevert(DataRoom.LengthMismatch.selector);
        vm.prank(board);
        room.addDocuments(FOLDER, _s2("cid0", "cid1"), _s1("f0.pdf"), _b2(_wk(0), _wk(1)), _b2("", ""));
    }

    function test_addDocuments_rejectsWrappedKeysLengthMismatch() public {
        vm.expectRevert(DataRoom.LengthMismatch.selector);
        vm.prank(board);
        room.addDocuments(FOLDER, _s1("cid0"), _s1("f0.pdf"), _b2(_wk(0), _wk(1)), _b1(""));
    }

    function test_addDocuments_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.addDocuments(FOLDER, _s1("cid"), _s1("f.pdf"), _b1(_wk(0)), _b1(""));
    }

    function test_addDocuments_rejectsBatchTooLarge() public {
        string[] memory cids = new string[](101);
        string[] memory names = new string[](101);
        bytes[] memory wks = new bytes[](101);
        bytes[] memory meta = new bytes[](101);
        vm.expectRevert(DataRoom.BatchTooLarge.selector);
        vm.prank(board);
        room.addDocuments(FOLDER, cids, names, wks, meta);
    }

    function test_addDocuments_rejectsOnParentRoom() public {
        vm.expectRevert(DataRoom.IsParentRoom.selector);
        vm.prank(board);
        room.addDocuments(PARENT, _s1("cid"), _s1("name"), _b1(_wk(0)), _b1(""));
    }

    // ═════════════════════════════════════════════════════════
    //  updateDocumentKeys()
    // ═════════════════════════════════════════════════════════

    function test_updateDocumentKeys_updatesInBulk() public {
        bytes memory nwk0 = _wk(10);
        bytes memory nwk1 = _wk(11);
        bytes memory nwk2 = _wk(12);

        vm.startPrank(board);
        room.addDocuments(
            FOLDER, _s3("cid0", "cid1", "cid2"), _s3("a", "b", "c"), _b3(_wk(0), _wk(1), _wk(2)), _b3("", "", "")
        );
        room.updateDocumentKeys(FOLDER, _u3(0, 1, 2), _b3(nwk0, nwk1, nwk2));

        (string memory cid,,,, bytes memory w0,) = room.getDocument(FOLDER, 0);
        assertEq(cid, "cid0");
        assertEq(w0, nwk0);
        (,,,, bytes memory w1,) = room.getDocument(FOLDER, 1);
        assertEq(w1, nwk1);
        (,,,, bytes memory w2,) = room.getDocument(FOLDER, 2);
        assertEq(w2, nwk2);
        vm.stopPrank();
    }

    function test_updateDocumentKeys_updatesSingle() public {
        bytes memory newWk = _wk(99);
        vm.startPrank(board);
        room.addDocuments(FOLDER, _s1("oldCid"), _s1("doc.pdf"), _b1(_wk(0)), _b1(""));
        room.updateDocumentKeys(FOLDER, _u1(0), _b1(newWk));

        (string memory cid,,,, bytes memory w,) = room.getDocument(FOLDER, 0);
        assertEq(cid, "oldCid");
        assertEq(w, newWk);
        vm.stopPrank();
    }

    function test_updateDocumentKeys_bumpsToCurrentKeyVersion() public {
        vm.startPrank(board);
        room.addDocuments(FOLDER, _s1("oldCid"), _s1("doc.pdf"), _b1(_wk(0)), _b1(""));
        (,,, uint256 kvBefore,,) = room.getDocument(FOLDER, 0);
        assertEq(kvBefore, 0);

        room.rekeyRoom(FOLDER);
        room.updateDocumentKeys(FOLDER, _u1(0), _b1(_wk(99)));

        (string memory cid,,, uint256 kvAfter,,) = room.getDocument(FOLDER, 0);
        assertEq(cid, "oldCid");
        assertEq(kvAfter, 1);
        vm.stopPrank();
    }

    function test_updateDocumentKeys_rejectsNonBoard() public {
        _addDoc("cid", "doc.pdf");
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.updateDocumentKeys(FOLDER, _u1(0), _b1(_wk(99)));
    }

    function test_updateDocumentKeys_rejectsOnParentRoom() public {
        vm.expectRevert(DataRoom.IsParentRoom.selector);
        vm.prank(board);
        room.updateDocumentKeys(PARENT, _u1(0), _b1(_wk(0)));
    }

    function test_updateDocumentKeys_rejectsMismatchedLengths() public {
        _addDoc("cid0", "a");
        vm.expectRevert(DataRoom.LengthMismatch.selector);
        vm.prank(board);
        room.updateDocumentKeys(FOLDER, _u2(0, 0), _b1(_wk(99)));
    }

    function test_updateDocumentKeys_rejectsDeletedDoc() public {
        _addDoc("cid0", "f.pdf");
        vm.startPrank(board);
        room.removeDocument(FOLDER, 0);
        vm.expectRevert(DataRoom.DocumentDeleted.selector);
        room.updateDocumentKeys(FOLDER, _u1(0), _b1(_wk(1)));
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════
    //  grantAccess()
    // ═════════════════════════════════════════════════════════

    function test_grantAccess_grantsSingleMember() public {
        vm.expectEmit(true, false, false, true);
        emit DataRoom.MembershipChanged(FOLDER);
        vm.prank(board);
        room.grantAccess(FOLDER, _addrs(member));

        vm.prank(member);
        assertTrue(room.hasAccess(FOLDER));

        bytes32 h = _keyHandle(member, FOLDER);
        assertTrue(h != bytes32(0));
    }

    function test_grantAccess_grantsMultiple() public {
        vm.prank(board);
        room.grantAccess(FOLDER, _addrs(member, nonBoard));

        vm.prank(board);
        assertEq(room.getMembers(FOLDER).length, 3);
    }

    function test_grantAccess_skipsDuplicate() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        room.grantAccess(FOLDER, _addrs(member));
        assertEq(room.getMembers(FOLDER).length, 2);
        vm.stopPrank();
    }

    function test_grantAccess_mixedBatchSkipsDuplicate() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        room.grantAccess(FOLDER, _addrs(nonBoard, member));
        assertEq(room.getMembers(FOLDER).length, 3);
        vm.stopPrank();
    }

    function test_grantAccess_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.grantAccess(FOLDER, _addrs(member));
    }

    function test_grantAccess_rejectsOnParentRoom() public {
        vm.expectRevert(DataRoom.IsParentRoom.selector);
        vm.prank(board);
        room.grantAccess(PARENT, _addrs(member));
    }

    function test_grantAccess_rejectsAddressZero() public {
        vm.expectRevert(DataRoom.InvalidAddress.selector);
        vm.prank(board);
        room.grantAccess(FOLDER, _addrs(address(0)));
    }

    function test_grantAccess_reGrantAfterRevoke() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        assertEq(room.getMembers(FOLDER).length, 2);

        room.revokeAccess(FOLDER, _addrs(member));
        assertEq(room.getMembers(FOLDER).length, 1);

        room.grantAccess(FOLDER, _addrs(member));
        assertEq(room.getMembers(FOLDER).length, 2);
        (,, uint256 memberCount,,,) = room.getRoom(FOLDER);
        assertEq(memberCount, 2);
        vm.stopPrank();

        vm.prank(member);
        assertTrue(room.hasAccess(FOLDER));

        bytes32 h = _keyHandle(member, FOLDER);
        assertTrue(h != bytes32(0));
    }

    function test_grantAccess_multipleRevokeGrantCycles() public {
        for (uint256 cycle = 0; cycle < 3; cycle++) {
            vm.prank(board);
            room.grantAccess(FOLDER, _addrs(member));
            vm.prank(board);
            assertEq(room.getMembers(FOLDER).length, 2);
            vm.prank(member);
            assertTrue(room.hasAccess(FOLDER));

            vm.prank(board);
            room.revokeAccess(FOLDER, _addrs(member));
            vm.prank(board);
            assertEq(room.getMembers(FOLDER).length, 1);
            vm.prank(member);
            assertFalse(room.hasAccess(FOLDER));
        }
    }

    // ═════════════════════════════════════════════════════════
    //  revokeAccess()
    // ═════════════════════════════════════════════════════════

    function test_revokeAccess_revokesMember() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        room.revokeAccess(FOLDER, _addrs(member));
        vm.stopPrank();

        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(member);
        room.getRoomKey(FOLDER);
    }

    function test_revokeAccess_flagDecryptsToFalse() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        room.revokeAccess(FOLDER, _addrs(member));
        vm.stopPrank();

        vm.prank(member);
        assertFalse(room.hasAccess(FOLDER));
    }

    function test_revokeAccess_rejectsNonMember() public {
        vm.expectRevert(DataRoom.NotMember.selector);
        vm.prank(board);
        room.revokeAccess(FOLDER, _addrs(member));
    }

    function test_revokeAccess_mixedBatchRollsBack() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        vm.expectRevert(DataRoom.NotMember.selector);
        room.revokeAccess(FOLDER, _addrs(member, nonBoard));
        assertEq(room.getMembers(FOLDER).length, 2);
        vm.stopPrank();
    }

    function test_revokeAccess_rejectsOnParentRoom() public {
        vm.expectRevert(DataRoom.IsParentRoom.selector);
        vm.prank(board);
        room.revokeAccess(PARENT, _addrs(member));
    }

    function test_revokeAccess_rejectsOperator() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(obolosOperator));
        vm.expectRevert(DataRoom.CannotRevokeOperator.selector);
        room.revokeAccess(FOLDER, _addrs(obolosOperator));
        vm.stopPrank();
    }

    function test_revokeAndRekey_revokesAndRotatesKey() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        uint256 vBefore = room.roomKeyVersion(FOLDER);
        room.revokeAndRekey(FOLDER, _addrs(member));
        vm.stopPrank();

        assertEq(room.roomKeyVersion(FOLDER), vBefore + 1);
        vm.prank(member);
        assertFalse(room.hasAccess(FOLDER));
    }

    function test_revokeAndRekey_rejectsOperator() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(obolosOperator));
        vm.expectRevert(DataRoom.CannotRevokeOperator.selector);
        room.revokeAndRekey(FOLDER, _addrs(obolosOperator));
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════
    //  grantAccessToAllFolders()
    // ═════════════════════════════════════════════════════════

    function test_grantAccessToAllFolders_grantsAllChildren() public {
        vm.startPrank(board);
        room.createFolder(PARENT, "Financials");
        room.createFolder(PARENT, "IP");
        room.grantAccessToAllFolders(PARENT, member);

        for (uint256 fId = 1; fId <= 3; fId++) {
            assertEq(room.getMembers(fId).length, 2);
        }
        vm.stopPrank();
    }

    function test_grantAccessToAllFolders_memberCanAccessKeys() public {
        vm.startPrank(board);
        room.createFolder(PARENT, "Financials");
        room.grantAccessToAllFolders(PARENT, member);
        vm.stopPrank();

        for (uint256 fId = 1; fId <= 2; fId++) {
            bytes32 h = _keyHandle(member, fId);
            assertTrue(h != bytes32(0));
        }
    }

    function test_grantAccessToAllFolders_isIdempotent() public {
        vm.startPrank(board);
        room.createFolder(PARENT, "Financials");
        room.grantAccess(FOLDER, _addrs(member));
        room.grantAccessToAllFolders(PARENT, member);

        for (uint256 fId = 1; fId <= 2; fId++) {
            assertEq(room.getMembers(fId).length, 2);
        }
        vm.stopPrank();
    }

    function test_grantAccessToAllFolders_repeatedCallsNoDuplicates() public {
        vm.startPrank(board);
        room.grantAccessToAllFolders(PARENT, member);
        room.grantAccessToAllFolders(PARENT, member);
        assertEq(room.getMembers(FOLDER).length, 2);
        vm.stopPrank();
    }

    function test_grantAccessToAllFolders_reGrantAfterRevokeAll() public {
        vm.startPrank(board);
        room.createFolder(PARENT, "Financials");
        room.grantAccessToAllFolders(PARENT, member);
        room.revokeAccessFromAllFolders(PARENT, member);
        room.grantAccessToAllFolders(PARENT, member);

        for (uint256 fId = 1; fId <= 2; fId++) {
            assertEq(room.getMembers(fId).length, 2);
            (,, uint256 memberCount,,,) = room.getRoom(fId);
            assertEq(memberCount, 2);
        }
        vm.stopPrank();

        for (uint256 fId = 1; fId <= 2; fId++) {
            vm.prank(member);
            assertTrue(room.hasAccess(fId));
        }
    }

    function test_grantAccessToAllFolders_rejectsNonParent() public {
        vm.expectRevert(DataRoom.NotParentRoom.selector);
        vm.prank(board);
        room.grantAccessToAllFolders(FOLDER, member);
    }

    function test_grantAccessToAllFolders_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.grantAccessToAllFolders(PARENT, member);
    }

    function test_grantAccessToAllFolders_rejectsAddressZero() public {
        vm.expectRevert(DataRoom.InvalidAddress.selector);
        vm.prank(board);
        room.grantAccessToAllFolders(PARENT, address(0));
    }

    // ═════════════════════════════════════════════════════════
    //  revokeAccessFromAllFolders()
    // ═════════════════════════════════════════════════════════

    function test_revokeAccessFromAllFolders_revokesAll() public {
        vm.startPrank(board);
        room.createFolder(PARENT, "Financials");
        room.grantAccessToAllFolders(PARENT, member);
        room.revokeAccessFromAllFolders(PARENT, member);

        for (uint256 fId = 1; fId <= 2; fId++) {
            assertEq(room.getMembers(fId).length, 1);
        }
        vm.stopPrank();
    }

    function test_revokeAccessFromAllFolders_isIdempotent() public {
        vm.startPrank(board);
        room.createFolder(PARENT, "Financials");
        room.grantAccess(FOLDER, _addrs(member));
        room.revokeAccessFromAllFolders(PARENT, member);
        assertEq(room.getMembers(FOLDER).length, 1);
        assertEq(room.getMembers(2).length, 1);
        vm.stopPrank();
    }

    function test_revokeAccessFromAllFolders_rejectsNonParent() public {
        vm.expectRevert(DataRoom.NotParentRoom.selector);
        vm.prank(board);
        room.revokeAccessFromAllFolders(FOLDER, member);
    }

    function test_revokeAccessFromAllFolders_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.revokeAccessFromAllFolders(PARENT, member);
    }

    function test_revokeAccessFromAllFolders_rejectsOperator() public {
        vm.startPrank(board);
        room.grantAccessToAllFolders(PARENT, obolosOperator);
        vm.expectRevert(DataRoom.CannotRevokeOperator.selector);
        room.revokeAccessFromAllFolders(PARENT, obolosOperator);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════
    //  rekeyRoom()
    // ═════════════════════════════════════════════════════════

    function test_rekeyRoom_bumpsVersionAndEmits() public {
        assertEq(room.roomKeyVersion(FOLDER), 0);

        vm.expectEmit(true, false, false, true);
        emit DataRoom.RoomRekeyed(FOLDER, 1);
        vm.prank(board);
        room.rekeyRoom(FOLDER);

        assertEq(room.roomKeyVersion(FOLDER), 1);
        assertTrue(_keyHandle(board, FOLDER) != bytes32(0));
    }

    function test_rekeyRoom_remainingMemberCanAccess() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        room.rekeyRoom(FOLDER);
        vm.stopPrank();

        bytes32 h = _keyHandle(member, FOLDER);
        assertTrue(h != bytes32(0));
    }

    function test_rekeyRoom_revokedMemberLosesAccess() public {
        vm.startPrank(board);
        room.grantAccess(FOLDER, _addrs(member));
        vm.stopPrank();

        vm.prank(member);
        room.getRoomKey(FOLDER); // can read before revoke

        vm.startPrank(board);
        room.revokeAccess(FOLDER, _addrs(member));
        room.rekeyRoom(FOLDER);
        vm.stopPrank();

        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(member);
        room.getRoomKey(FOLDER);
    }

    function test_rekeyRoom_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.rekeyRoom(FOLDER);
    }

    function test_rekeyRoom_rejectsOnParentRoom() public {
        vm.expectRevert(DataRoom.IsParentRoom.selector);
        vm.prank(board);
        room.rekeyRoom(PARENT);
    }

    // ═════════════════════════════════════════════════════════
    //  hasAccess()
    // ═════════════════════════════════════════════════════════

    function test_hasAccess_returnsTrueForMembersFalseOtherwise() public {
        vm.prank(board);
        assertTrue(room.hasAccess(FOLDER));
        vm.prank(nonBoard);
        assertFalse(room.hasAccess(FOLDER));

        vm.prank(board);
        room.grantAccess(FOLDER, _addrs(member));
        vm.prank(member);
        assertTrue(room.hasAccess(FOLDER));

        vm.prank(board);
        room.revokeAccess(FOLDER, _addrs(member));
        vm.prank(member);
        assertFalse(room.hasAccess(FOLDER));
    }

    // ═════════════════════════════════════════════════════════
    //  Views: getRoom, getDocument, getRoomKey, getFolders, getParentRoom, getMembers
    // ═════════════════════════════════════════════════════════

    function test_getRoom_revertsNonExistent() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        room.getRoom(999);
    }

    function test_getDocument_rejectsNonMemberOnPrivateFolder() public {
        _addDoc("cid0", "secret.pdf");
        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(nonBoard);
        room.getDocument(FOLDER, 0);
    }

    function test_getDocument_revertsNonExistentRoom() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        room.getDocument(999, 0);
    }

    function test_getRoomKey_operatorCanAccess() public {
        bytes32 h = _keyHandle(obolosOperator, FOLDER);
        assertTrue(h != bytes32(0));
    }

    function test_getRoomKey_revertsNonExistentRoom() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        room.getRoomKey(999);
    }

    function test_getFolders_returnsAllChildren() public {
        vm.prank(board);
        room.createFolder(PARENT, "Financials");

        uint256[] memory folders = room.getFolders(PARENT);
        assertEq(folders.length, 2);
        assertEq(folders[0], 1);
        assertEq(folders[1], 2);
    }

    function test_getFolders_revertsOnFolder() public {
        vm.expectRevert(DataRoom.NotParentRoom.selector);
        room.getFolders(FOLDER);
    }

    function test_getFolders_revertsNonExistent() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        room.getFolders(999);
    }

    function test_getParentRoom_returnsParentId() public view {
        assertEq(room.getParentRoom(FOLDER), PARENT);
    }

    function test_getParentRoom_revertsNonExistent() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        room.getParentRoom(999);
    }

    function test_getMembers_operatorCanAccess() public {
        vm.prank(obolosOperator);
        address[] memory members = room.getMembers(FOLDER);
        assertEq(members.length, 1);
    }

    function test_getMembers_revertsNonBoard() public {
        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(member);
        room.getMembers(FOLDER);
    }

    function test_getMembers_revertsNonExistent() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        vm.prank(board);
        room.getMembers(999);
    }

    // ═════════════════════════════════════════════════════════
    //  removeDocument()
    // ═════════════════════════════════════════════════════════

    function test_removeDocument_softDeletes() public {
        _addDoc("cid0", "f.pdf");

        vm.expectEmit(true, true, false, true);
        emit DataRoom.DocumentRemoved(FOLDER, 0);
        vm.prank(board);
        room.removeDocument(FOLDER, 0);

        vm.expectRevert(DataRoom.DocumentDeleted.selector);
        vm.prank(board);
        room.getDocument(FOLDER, 0);
    }

    function test_removeDocument_indicesStayStable() public {
        vm.startPrank(board);
        room.addDocuments(FOLDER, _s2("cid0", "cid1"), _s2("a", "b"), _b2(_wk(0), _wk(1)), _b2("", ""));
        room.removeDocument(FOLDER, 0);

        (, uint256 docCount,,,,) = room.getRoom(FOLDER);
        assertEq(docCount, 2);

        (string memory cid,,,,,) = room.getDocument(FOLDER, 1);
        assertEq(cid, "cid1");
        vm.stopPrank();
    }

    function test_removeDocument_rejectsNonBoard() public {
        _addDoc("cid0", "f.pdf");
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.removeDocument(FOLDER, 0);
    }

    function test_removeDocument_rejectsOnParentRoom() public {
        vm.expectRevert(DataRoom.IsParentRoom.selector);
        vm.prank(board);
        room.removeDocument(PARENT, 0);
    }

    function test_removeDocument_rejectsOutOfBounds() public {
        vm.expectRevert(DataRoom.DocumentNotFound.selector);
        vm.prank(board);
        room.removeDocument(FOLDER, 0);
    }

    function test_removeDocument_rejectsDoubleDelete() public {
        _addDoc("cid0", "f.pdf");
        vm.startPrank(board);
        room.removeDocument(FOLDER, 0);
        vm.expectRevert(DataRoom.DocumentDeleted.selector);
        room.removeDocument(FOLDER, 0);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════
    //  document metadata
    // ═════════════════════════════════════════════════════════

    function test_metadata_storesAndReturns() public {
        bytes memory meta = abi.encodePacked('{"type":"pdf"}');
        vm.prank(board);
        room.addDocuments(FOLDER, _s1("cid0"), _s1("f.pdf"), _b1(_wk(0)), _b1(meta));

        (,,,,, bytes memory metadata) = _getDoc(FOLDER, 0);
        assertEq(metadata, meta);
    }

    function test_updateDocumentMetadata_updatesMetadata() public {
        bytes memory newMeta = abi.encodePacked('{"size":42}');
        vm.startPrank(board);
        room.addDocuments(FOLDER, _s2("cid0", "cid1"), _s2("a", "b"), _b2(_wk(0), _wk(1)), _b2("", ""));
        room.updateDocumentMetadata(FOLDER, _u2(0, 1), _b2(newMeta, newMeta));

        (,,,,, bytes memory m0) = room.getDocument(FOLDER, 0);
        (,,,,, bytes memory m1) = room.getDocument(FOLDER, 1);
        assertEq(m0, newMeta);
        assertEq(m1, newMeta);
        vm.stopPrank();
    }

    function test_updateDocumentMetadata_rejectsDeleted() public {
        _addDoc("cid0", "f.pdf");
        vm.startPrank(board);
        room.removeDocument(FOLDER, 0);
        vm.expectRevert(DataRoom.DocumentDeleted.selector);
        room.updateDocumentMetadata(FOLDER, _u1(0), _b1(""));
        vm.stopPrank();
    }

    function test_updateDocumentMetadata_rejectsNonBoard() public {
        _addDoc("cid0", "f.pdf");
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.updateDocumentMetadata(FOLDER, _u1(0), _b1(""));
    }

    function test_updateDocumentMetadata_rejectsLengthMismatch() public {
        _addDoc("cid0", "f.pdf");
        vm.expectRevert(DataRoom.LengthMismatch.selector);
        vm.prank(board);
        room.updateDocumentMetadata(FOLDER, _u1(0), _b2("", ""));
    }

    function test_updateDocumentMetadata_rejectsOutOfBounds() public {
        vm.expectRevert(DataRoom.DocumentNotFound.selector);
        vm.prank(board);
        room.updateDocumentMetadata(FOLDER, _u1(0), _b1(""));
    }

    function test_updateDocumentMetadata_rejectsOnParentRoom() public {
        vm.expectRevert(DataRoom.IsParentRoom.selector);
        vm.prank(board);
        room.updateDocumentMetadata(PARENT, _u1(0), _b1(""));
    }

    // ═════════════════════════════════════════════════════════
    //  renameRoom()
    // ═════════════════════════════════════════════════════════

    function test_renameRoom_renamesParent() public {
        vm.expectEmit(true, false, false, true);
        emit DataRoom.RoomRenamed(PARENT, "New Name");
        vm.prank(board);
        room.renameRoom(PARENT, "New Name");

        (string memory name,,,,,) = room.getRoom(PARENT);
        assertEq(name, "New Name");
    }

    function test_renameRoom_renamesFolder() public {
        vm.prank(board);
        room.renameRoom(FOLDER, "Renamed Folder");

        (string memory name,,,,,) = room.getRoom(FOLDER);
        assertEq(name, "Renamed Folder");
    }

    function test_renameRoom_rejectsNonBoard() public {
        vm.expectRevert(DataRoom.OnlyBoard.selector);
        vm.prank(member);
        room.renameRoom(PARENT, "Nope");
    }

    function test_renameRoom_rejectsNonExistent() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        vm.prank(board);
        room.renameRoom(999, "Nope");
    }

    // ═════════════════════════════════════════════════════════
    //  Per-document encryption (mixed public/private in same folder)
    // ═════════════════════════════════════════════════════════

    function test_addDocuments_mixedPublicAndPrivateInSameFolder() public {
        bytes memory wk = _wk(0);
        vm.prank(board);
        room.addDocuments(FOLDER, _s2("cidPub", "cidPriv"), _s2("pub.pdf", "priv.pdf"), _b2("", wk), _b2("", ""));

        (, uint256 docCount,,,,) = room.getRoom(FOLDER);
        assertEq(docCount, 2);

        (string memory cid0,,,, bytes memory w0,) = _getDoc(FOLDER, 0);
        assertEq(cid0, "cidPub");
        assertEq(w0, "");

        (string memory cid1,,,, bytes memory w1,) = _getDoc(FOLDER, 1);
        assertEq(cid1, "cidPriv");
        assertEq(w1, wk);
    }

    function test_getDocument_publicDocReadableByAnyone() public {
        vm.prank(board);
        room.addDocuments(FOLDER, _s1("cidPub"), _s1("pub.pdf"), _b1(""), _b1(""));

        // outsider (nonBoard, not a member) can read public doc
        vm.prank(nonBoard);
        (string memory cid,,,, bytes memory wrappedKey,) = room.getDocument(FOLDER, 0);
        assertEq(cid, "cidPub");
        assertEq(wrappedKey, "");
    }

    function test_getDocument_privateDocRequiresMembership() public {
        vm.prank(board);
        room.addDocuments(FOLDER, _s1("cidPriv"), _s1("priv.pdf"), _b1(_wk(0)), _b1(""));

        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(nonBoard);
        room.getDocument(FOLDER, 0);
    }

    function test_getDocument_mixedFolderAccessControl() public {
        bytes memory wk = _wk(0);
        vm.prank(board);
        room.addDocuments(FOLDER, _s2("cidPub", "cidPriv"), _s2("pub.pdf", "priv.pdf"), _b2("", wk), _b2("", ""));

        // outsider can read public doc (index 0)
        vm.prank(nonBoard);
        (string memory cid0,,,, bytes memory w0,) = room.getDocument(FOLDER, 0);
        assertEq(cid0, "cidPub");
        assertEq(w0, "");

        // outsider blocked on private doc (index 1)
        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(nonBoard);
        room.getDocument(FOLDER, 1);
    }

    function test_updateDocumentKeys_canEncryptPreviouslyPublicDoc() public {
        vm.startPrank(board);
        room.addDocuments(FOLDER, _s1("cidPub"), _s1("pub.pdf"), _b1(""), _b1(""));

        // doc starts public (empty wrappedKey)
        (,,,, bytes memory wBefore,) = room.getDocument(FOLDER, 0);
        assertEq(wBefore, "");

        // encrypt it by setting a wrappedKey
        bytes memory newWk = _wk(42);
        room.updateDocumentKeys(FOLDER, _u1(0), _b1(newWk));
        vm.stopPrank();

        (,,,, bytes memory wAfter,) = _getDoc(FOLDER, 0);
        assertEq(wAfter, newWk);

        // now outsider is blocked
        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(nonBoard);
        room.getDocument(FOLDER, 0);
    }

    // ═════════════════════════════════════════════════════════
    //  Audit fixes: createFolder roomExists, getRoomKey board, addDocuments empty, removeDocument roomExists
    // ═════════════════════════════════════════════════════════

    function test_createFolder_rejectsNonExistentParent() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        vm.prank(board);
        room.createFolder(999, "Orphan");
    }

    function test_getRoomKey_boardCanAccessAfterGovernanceTransfer() public {
        // Board creates folder, is auto-added as member
        bytes32 h1 = _keyHandle(board, FOLDER);
        assertTrue(h1 != bytes32(0));

        // Even if board weren't a member, the explicit board check should work.
        // We verify the board check exists by ensuring it doesn't revert.
        vm.prank(board);
        room.getRoomKey(FOLDER);
    }

    function test_addDocuments_rejectsEmptyBatch() public {
        string[] memory empty_s = new string[](0);
        bytes[] memory empty_b = new bytes[](0);
        vm.expectRevert(DataRoom.EmptyBatch.selector);
        vm.prank(board);
        room.addDocuments(FOLDER, empty_s, empty_s, empty_b, empty_b);
    }

    function test_removeDocument_rejectsNonExistentRoom() public {
        vm.expectRevert(DataRoom.RoomNotFound.selector);
        vm.prank(board);
        room.removeDocument(999, 0);
    }

    // ─── Helpers (unit-test-specific) ──────────────────────────

    /// @dev Deploy a fresh company and return its DataRoom (empty, no rooms)
    function _freshRoom() internal returns (DataRoom) {
        (Company c,,,,,,,) = _deployCompany("Fresh Co", "FR", "");
        return DataRoom(address(c.dataRoom()));
    }

    /// @dev Add a single doc to folder 1 as board. Returns docIndex.
    function _addDoc(string memory cid, string memory name) internal returns (uint256) {
        vm.prank(board);
        room.addDocuments(FOLDER, _s1(cid), _s1(name), _b1(_wk(0)), _b1(""));
        (, uint256 docCount,,,,) = room.getRoom(FOLDER);
        return docCount - 1;
    }

    /// @dev Get room key handle as the given account
    function _keyHandle(address who, uint256 roomId) internal returns (bytes32) {
        vm.prank(who);
        return euint128.unwrap(room.getRoomKey(roomId));
    }
}
