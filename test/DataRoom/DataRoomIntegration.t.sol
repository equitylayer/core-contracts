// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {CoFheTest} from "@cofhe/mock-contracts/foundry/CoFheTest.sol";
import {euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {DataRoom} from "../../src/DataRoom.sol";
import {DataRoomBaseTest} from "../helpers/DataRoomBase.t.sol";

/// @title DataRoomIntegrationTest
/// @notice End-to-end workflow tests for the DataRoom contract.
///         Each test simulates a realistic multi-step scenario that
///         exercises state transitions across rooms, folders, members,
///         documents, and key rotation.
contract DataRoomIntegrationTest is DataRoomBaseTest {
    address investorA = makeAddr("investorA");
    address investorB = makeAddr("investorB");
    address lawyer = makeAddr("lawyer");
    address auditor = makeAddr("auditor");

    function setUp() public {
        _baseSetUp();
        _setupCompany();
        room = DataRoom(address(company.dataRoom()));
    }

    // ═══════════════════════════════════════════════════════════════
    //  1. Full deal room lifecycle: create → share → revoke → rekey
    // ═══════════════════════════════════════════════════════════════

    /// @notice Simulates a Series A due diligence deal room.
    ///   Board sets up rooms/folders, uploads docs, grants investor access,
    ///   investor reads docs, deal falls through, board revokes investor,
    ///   rekeys folders, re-wraps doc keys — old investor fully locked out.
    function test_dealRoomLifecycle() public {
        // ── Setup: board creates room structure ──
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Series A");
        uint256 legalId = room.createFolder(parentId, "Legal");
        uint256 financialsId = room.createFolder(parentId, "Financials");

        // ── Upload documents to each folder ──
        room.addDocuments(
            legalId,
            _s2("bafyCOA", "bafyNDA"),
            _s2("certificate_of_incorporation.pdf", "nda_template.pdf"),
            _b2(_wk(1), _wk(2)),
            _b2('{"type":"legal"}', '{"type":"legal"}')
        );
        room.addDocuments(
            financialsId, _s1("bafyPL"), _s1("profit_loss_2025.xlsx"), _b1(_wk(3)), _b1('{"type":"financial"}')
        );

        // ── Grant investor access to all folders ──
        room.grantAccessToAllFolders(parentId, investorA);
        vm.stopPrank();

        // ── Investor reads documents ──
        vm.startPrank(investorA);
        assertTrue(room.hasAccess(legalId));
        assertTrue(room.hasAccess(financialsId));

        (string memory cid,,,, bytes memory wk,) = room.getDocument(legalId, 0);
        assertEq(cid, "bafyCOA");
        assertTrue(wk.length > 0);

        (cid,,,, wk,) = room.getDocument(financialsId, 0);
        assertEq(cid, "bafyPL");
        assertTrue(wk.length > 0);

        // Investor can get room keys
        euint128 legalKey = room.getRoomKey(legalId);
        euint128 finKey = room.getRoomKey(financialsId);
        assertTrue(euint128.unwrap(legalKey) != bytes32(0));
        assertTrue(euint128.unwrap(finKey) != bytes32(0));
        vm.stopPrank();

        // ── Deal falls through — revoke investor + rekey both folders ──
        vm.startPrank(board);
        room.revokeAndRekey(legalId, _addrs(investorA));
        room.revokeAndRekey(financialsId, _addrs(investorA));

        // Re-wrap document keys with new room key
        room.updateDocumentKeys(legalId, _u2(0, 1), _b2(_wk(100), _wk(101)));
        room.updateDocumentKeys(financialsId, _u1(0), _b1(_wk(102)));
        vm.stopPrank();

        // ── Verify: investor fully locked out ──
        vm.startPrank(investorA);
        assertFalse(room.hasAccess(legalId));
        assertFalse(room.hasAccess(financialsId));

        vm.expectRevert(DataRoom.Unauthorized.selector);
        room.getRoomKey(legalId);

        vm.expectRevert(DataRoom.Unauthorized.selector);
        room.getRoomKey(financialsId);

        vm.expectRevert(DataRoom.Unauthorized.selector);
        room.getDocument(legalId, 0);
        vm.stopPrank();

        // ── Verify: key versions bumped, doc keys updated ──
        assertEq(room.roomKeyVersion(legalId), 1);
        assertEq(room.roomKeyVersion(financialsId), 1);

        (,,, uint256 kv,,) = _getDoc(legalId, 0);
        assertEq(kv, 1);
        (,,, kv,,) = _getDoc(legalId, 1);
        assertEq(kv, 1);
        (,,, kv,,) = _getDoc(financialsId, 0);
        assertEq(kv, 1);

        // ── Board still has full access ──
        vm.prank(board);
        assertTrue(room.hasAccess(legalId));
        vm.prank(board);
        room.getRoomKey(legalId);
    }

    // ═══════════════════════════════════════════════════════════════
    //  2. Multi-folder permission isolation
    // ═══════════════════════════════════════════════════════════════

    /// @notice Investor A has access to Legal only, Investor B to Financials only.
    ///         Each can only see their assigned folder's documents.
    function test_folderIsolation_investorsSeeDifferentFolders() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Fundraise");
        uint256 legalId = room.createFolder(parentId, "Legal");
        uint256 finId = room.createFolder(parentId, "Financials");

        room.addDocuments(legalId, _s1("cidLegal"), _s1("legal.pdf"), _b1(_wk(1)), _b1(""));
        room.addDocuments(finId, _s1("cidFin"), _s1("financials.xlsx"), _b1(_wk(2)), _b1(""));

        room.grantAccess(legalId, _addrs(investorA));
        room.grantAccess(finId, _addrs(investorB));
        vm.stopPrank();

        // investorA: Legal YES, Financials NO
        vm.prank(investorA);
        assertTrue(room.hasAccess(legalId));
        vm.prank(investorA);
        assertFalse(room.hasAccess(finId));

        vm.prank(investorA);
        room.getDocument(legalId, 0); // succeeds

        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(investorA);
        room.getDocument(finId, 0);

        // investorB: Financials YES, Legal NO
        vm.prank(investorB);
        assertFalse(room.hasAccess(legalId));
        vm.prank(investorB);
        assertTrue(room.hasAccess(finId));

        vm.prank(investorB);
        room.getDocument(finId, 0); // succeeds

        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(investorB);
        room.getDocument(legalId, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  3. Rekey preserves remaining members, excludes revoked
    // ═══════════════════════════════════════════════════════════════

    /// @notice Two investors have access. One is revoked + rekey. The remaining
    ///         investor retains access and can read the new key. The revoked one cannot.
    function test_rekeyAfterPartialRevoke_preservesRemainingMember() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Deal");
        uint256 folderId = room.createFolder(parentId, "Docs");

        room.addDocuments(folderId, _s1("cidDoc"), _s1("term_sheet.pdf"), _b1(_wk(1)), _b1(""));
        room.grantAccess(folderId, _addrs(investorA, investorB));
        vm.stopPrank();

        // Both can access
        vm.prank(investorA);
        assertTrue(room.hasAccess(folderId));
        vm.prank(investorB);
        assertTrue(room.hasAccess(folderId));

        // Revoke investorA + rekey
        vm.prank(board);
        room.revokeAndRekey(folderId, _addrs(investorA));

        // investorA locked out
        vm.prank(investorA);
        assertFalse(room.hasAccess(folderId));
        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(investorA);
        room.getRoomKey(folderId);

        // investorB still has access to new key
        vm.prank(investorB);
        assertTrue(room.hasAccess(folderId));
        vm.prank(investorB);
        euint128 key = room.getRoomKey(folderId);
        assertTrue(euint128.unwrap(key) != bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //  4. Document lifecycle: add → soft-delete → verify stable indices
    // ═══════════════════════════════════════════════════════════════

    /// @notice Upload 3 docs, delete the middle one, verify remaining docs
    ///         are unaffected and indices stay stable. Then add a new doc and
    ///         confirm it takes the next sequential index.
    function test_documentLifecycle_deleteAndContinue() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Archive");
        uint256 folderId = room.createFolder(parentId, "Reports");

        room.addDocuments(
            folderId,
            _s3("cid0", "cid1", "cid2"),
            _s3("q1.pdf", "q2.pdf", "q3.pdf"),
            _b3(_wk(0), _wk(1), _wk(2)),
            _b3("", "", "")
        );

        // Delete middle doc
        room.removeDocument(folderId, 1);

        // doc 0 still readable
        (string memory c0,,,,,) = room.getDocument(folderId, 0);
        assertEq(c0, "cid0");

        // doc 1 is deleted
        vm.expectRevert(DataRoom.DocumentDeleted.selector);
        room.getDocument(folderId, 1);

        // doc 2 still readable at same index
        (string memory c2,,,,,) = room.getDocument(folderId, 2);
        assertEq(c2, "cid2");

        // Add a new doc — takes index 3 (not 1)
        room.addDocuments(folderId, _s1("cid3"), _s1("q4.pdf"), _b1(_wk(3)), _b1(""));
        (string memory c3,,,,,) = room.getDocument(folderId, 3);
        assertEq(c3, "cid3");

        (, uint256 docCount,,,,) = room.getRoom(folderId);
        assertEq(docCount, 4); // total slots including deleted
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  5. Mixed public/private folder workflow
    // ═══════════════════════════════════════════════════════════════

    /// @notice A folder contains both public and private documents.
    ///         Non-members can read public docs but not private ones.
    ///         Board later encrypts a public doc, locking out outsiders.
    function test_mixedPublicPrivateWorkflow() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Investor Portal");
        uint256 folderId = room.createFolder(parentId, "Shared");

        // Public pitch deck + private term sheet
        room.addDocuments(
            folderId,
            _s2("cidPitch", "cidTerms"),
            _s2("pitch_deck.pdf", "term_sheet.pdf"),
            _b2("", _wk(1)), // empty wrappedKey = public
            _b2('{"public":true}', '{"confidential":true}')
        );
        vm.stopPrank();

        // Outsider reads public doc
        vm.prank(auditor);
        (string memory cid,,,, bytes memory wk,) = room.getDocument(folderId, 0);
        assertEq(cid, "cidPitch");
        assertEq(wk.length, 0);

        // Outsider blocked from private doc
        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(auditor);
        room.getDocument(folderId, 1);

        // Board encrypts the pitch deck (previously public)
        vm.prank(board);
        room.updateDocumentKeys(folderId, _u1(0), _b1(_wk(99)));

        // Now outsider blocked from both docs
        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(auditor);
        room.getDocument(folderId, 0);

        vm.expectRevert(DataRoom.Unauthorized.selector);
        vm.prank(auditor);
        room.getDocument(folderId, 1);

        // Granted member can read both
        vm.prank(board);
        room.grantAccess(folderId, _addrs(investorA));

        vm.startPrank(investorA);
        (cid,,,, wk,) = room.getDocument(folderId, 0);
        assertEq(cid, "cidPitch");
        assertTrue(wk.length > 0); // now encrypted
        (cid,,,, wk,) = room.getDocument(folderId, 1);
        assertEq(cid, "cidTerms");
        assertTrue(wk.length > 0);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  6. Bulk grant → bulk revoke → re-grant cycle
    // ═══════════════════════════════════════════════════════════════

    /// @notice Grant 4 members across all folders, revoke all via parent,
    ///         re-grant selectively. Verifies member counts stay accurate
    ///         through the full cycle.
    function test_bulkGrantRevokeRegrantCycle() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("M&A");
        uint256 f1 = room.createFolder(parentId, "Legal");
        uint256 f2 = room.createFolder(parentId, "Tax");
        uint256 f3 = room.createFolder(parentId, "IP");

        // Grant all 4 users to all folders
        address[] memory users = new address[](4);
        users[0] = investorA;
        users[1] = investorB;
        users[2] = lawyer;
        users[3] = auditor;

        for (uint256 i = 0; i < users.length; i++) {
            room.grantAccessToAllFolders(parentId, users[i]);
        }

        // Each folder: board (auto) + 4 users = 5
        for (uint256 fId = f1; fId <= f3; fId++) {
            (,, uint256 mc,,,) = room.getRoom(fId);
            assertEq(mc, 5);
        }

        // Revoke all 4 from all folders
        for (uint256 i = 0; i < users.length; i++) {
            room.revokeAccessFromAllFolders(parentId, users[i]);
        }

        // Each folder: board only = 1
        for (uint256 fId = f1; fId <= f3; fId++) {
            (,, uint256 mc,,,) = room.getRoom(fId);
            assertEq(mc, 1);
        }

        // Re-grant only lawyer to Legal, only auditor to Tax
        room.grantAccess(f1, _addrs(lawyer));
        room.grantAccess(f2, _addrs(auditor));

        (,, uint256 mc1,,,) = room.getRoom(f1);
        assertEq(mc1, 2); // board + lawyer
        (,, uint256 mc2,,,) = room.getRoom(f2);
        assertEq(mc2, 2); // board + auditor
        (,, uint256 mc3,,,) = room.getRoom(f3);
        assertEq(mc3, 1); // board only

        vm.stopPrank();

        // Verify isolation
        vm.prank(lawyer);
        assertTrue(room.hasAccess(f1));
        vm.prank(lawyer);
        assertFalse(room.hasAccess(f2));

        vm.prank(auditor);
        assertFalse(room.hasAccess(f1));
        vm.prank(auditor);
        assertTrue(room.hasAccess(f2));
    }

    // ═══════════════════════════════════════════════════════════════
    //  7. Multi-rekey: key version tracks across multiple rotations
    // ═══════════════════════════════════════════════════════════════

    /// @notice Rekey a folder 3 times. Docs added at different key versions
    ///         track their version correctly. updateDocumentKeys stamps the
    ///         current version.
    function test_multiRekey_docKeyVersionsTrackCorrectly() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Vault");
        uint256 folderId = room.createFolder(parentId, "Secrets");

        // Doc at version 0
        room.addDocuments(folderId, _s1("cidV0"), _s1("v0.pdf"), _b1(_wk(0)), _b1(""));
        (,,, uint256 kv0,,) = room.getDocument(folderId, 0);
        assertEq(kv0, 0);

        // Rekey → version 1, add doc
        room.rekeyRoom(folderId);
        room.addDocuments(folderId, _s1("cidV1"), _s1("v1.pdf"), _b1(_wk(1)), _b1(""));
        (,,, uint256 kv1,,) = room.getDocument(folderId, 1);
        assertEq(kv1, 1);

        // Rekey → version 2, add doc
        room.rekeyRoom(folderId);
        room.addDocuments(folderId, _s1("cidV2"), _s1("v2.pdf"), _b1(_wk(2)), _b1(""));
        (,,, uint256 kv2,,) = room.getDocument(folderId, 2);
        assertEq(kv2, 2);

        // Rekey → version 3
        room.rekeyRoom(folderId);
        assertEq(room.roomKeyVersion(folderId), 3);

        // Old docs still at their original versions
        (,,, kv0,,) = room.getDocument(folderId, 0);
        assertEq(kv0, 0);
        (,,, kv1,,) = room.getDocument(folderId, 1);
        assertEq(kv1, 1);

        // Re-wrap doc 0 — stamps to current version 3
        room.updateDocumentKeys(folderId, _u1(0), _b1(_wk(30)));
        (,,, uint256 kv0after,,) = room.getDocument(folderId, 0);
        assertEq(kv0after, 3);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  8. Operator immutability: cannot be revoked from any folder
    // ═══════════════════════════════════════════════════════════════

    /// @notice Operator is protected from revocation via single-folder revoke,
    ///         revokeAndRekey, and revokeAccessFromAllFolders.
    function test_operatorCannotBeRevokedFromAnyPath() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Protected");
        uint256 folderId = room.createFolder(parentId, "Data");

        room.grantAccess(folderId, _addrs(obolosOperator));

        // Single revoke
        vm.expectRevert(DataRoom.CannotRevokeOperator.selector);
        room.revokeAccess(folderId, _addrs(obolosOperator));

        // Revoke + rekey
        vm.expectRevert(DataRoom.CannotRevokeOperator.selector);
        room.revokeAndRekey(folderId, _addrs(obolosOperator));

        // Revoke from all folders
        vm.expectRevert(DataRoom.CannotRevokeOperator.selector);
        room.revokeAccessFromAllFolders(parentId, obolosOperator);

        vm.stopPrank();

        // Operator still has access
        vm.prank(obolosOperator);
        room.getRoomKey(folderId);
    }

    // ═══════════════════════════════════════════════════════════════
    //  9. Non-board callers blocked from all mutations
    // ═══════════════════════════════════════════════════════════════

    /// @notice A granted member has read-only access. They cannot create rooms,
    ///         add docs, grant/revoke access, rekey, or remove docs.
    function test_memberCannotMutateAnything() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("ReadOnly");
        uint256 folderId = room.createFolder(parentId, "Data");
        room.addDocuments(folderId, _s1("cid"), _s1("file.pdf"), _b1(_wk(0)), _b1(""));
        room.grantAccess(folderId, _addrs(investorA));
        vm.stopPrank();

        // Member can read
        vm.prank(investorA);
        assertTrue(room.hasAccess(folderId));
        vm.prank(investorA);
        room.getDocument(folderId, 0);

        // But cannot mutate
        vm.startPrank(investorA);

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.createRoom("Nope");

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.createFolder(parentId, "Nope");

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.addDocuments(folderId, _s1("x"), _s1("x"), _b1(""), _b1(""));

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.removeDocument(folderId, 0);

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.grantAccess(folderId, _addrs(investorB));

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.revokeAccess(folderId, _addrs(board));

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.rekeyRoom(folderId);

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.renameRoom(folderId, "Nope");

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.updateDocumentKeys(folderId, _u1(0), _b1(_wk(1)));

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.updateDocumentMetadata(folderId, _u1(0), _b1(""));

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.grantAccessToAllFolders(parentId, investorB);

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.revokeAccessFromAllFolders(parentId, board);

        vm.expectRevert(DataRoom.OnlyBoard.selector);
        room.revokeAndRekey(folderId, _addrs(board));

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  10. Room hierarchy: parent ↔ folder relationship integrity
    // ═══════════════════════════════════════════════════════════════

    /// @notice Multiple parent rooms, each with folders. Verify getFolders,
    ///         getParentRoom, and that operations on one parent's folders
    ///         don't affect another parent's folders.
    function test_multipleParentRooms_isolatedHierarchies() public {
        vm.startPrank(board);

        uint256 p1 = room.createRoom("Series A");
        uint256 p2 = room.createRoom("Series B");

        uint256 p1f1 = room.createFolder(p1, "A-Legal");
        uint256 p1f2 = room.createFolder(p1, "A-Financial");
        uint256 p2f1 = room.createFolder(p2, "B-Legal");

        // Verify parent-child relationships
        uint256[] memory p1Folders = room.getFolders(p1);
        assertEq(p1Folders.length, 2);
        assertEq(p1Folders[0], p1f1);
        assertEq(p1Folders[1], p1f2);

        uint256[] memory p2Folders = room.getFolders(p2);
        assertEq(p2Folders.length, 1);
        assertEq(p2Folders[0], p2f1);

        assertEq(room.getParentRoom(p1f1), p1);
        assertEq(room.getParentRoom(p1f2), p1);
        assertEq(room.getParentRoom(p2f1), p2);

        // Grant investor to all of p1 — should NOT affect p2
        room.grantAccessToAllFolders(p1, investorA);
        vm.stopPrank();

        vm.prank(investorA);
        assertTrue(room.hasAccess(p1f1));
        vm.prank(investorA);
        assertTrue(room.hasAccess(p1f2));
        vm.prank(investorA);
        assertFalse(room.hasAccess(p2f1));

        // Revoke from all of p1 — p2 unaffected (investor was never a member)
        vm.prank(board);
        room.revokeAccessFromAllFolders(p1, investorA);

        vm.prank(investorA);
        assertFalse(room.hasAccess(p1f1));
    }

    // ═══════════════════════════════════════════════════════════════
    //  11. Document metadata update workflow
    // ═══════════════════════════════════════════════════════════════

    /// @notice Upload docs with metadata, update metadata in bulk, verify
    ///         CIDs and wrapped keys are unaffected by metadata changes.
    function test_metadataUpdatePreservesDocIntegrity() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Compliance");
        uint256 folderId = room.createFolder(parentId, "KYC");

        bytes memory wk0 = _wk(10);
        bytes memory wk1 = _wk(11);
        room.addDocuments(
            folderId,
            _s2("cidPassport", "cidProofAddr"),
            _s2("passport.jpg", "utility_bill.pdf"),
            _b2(wk0, wk1),
            _b2('{"status":"pending"}', '{"status":"pending"}')
        );

        // Update metadata to approved
        room.updateDocumentMetadata(folderId, _u2(0, 1), _b2('{"status":"approved"}', '{"status":"approved"}'));

        // Verify CIDs and wrappedKeys unchanged
        (string memory cid0,,,, bytes memory w0, bytes memory m0) = room.getDocument(folderId, 0);
        assertEq(cid0, "cidPassport");
        assertEq(w0, wk0);
        assertEq(m0, '{"status":"approved"}');

        (string memory cid1,,,, bytes memory w1, bytes memory m1) = room.getDocument(folderId, 1);
        assertEq(cid1, "cidProofAddr");
        assertEq(w1, wk1);
        assertEq(m1, '{"status":"approved"}');
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  12. Rename doesn't affect access or documents
    // ═══════════════════════════════════════════════════════════════

    function test_renamePreservesStateIntegrity() public {
        vm.startPrank(board);
        uint256 parentId = room.createRoom("Old Name");
        uint256 folderId = room.createFolder(parentId, "Old Folder");

        room.addDocuments(folderId, _s1("cidX"), _s1("x.pdf"), _b1(_wk(0)), _b1(""));
        room.grantAccess(folderId, _addrs(investorA));

        room.renameRoom(parentId, "New Name");
        room.renameRoom(folderId, "New Folder");
        vm.stopPrank();

        // Names changed
        (string memory pName,,,,,) = room.getRoom(parentId);
        assertEq(pName, "New Name");
        (string memory fName,,,,,) = room.getRoom(folderId);
        assertEq(fName, "New Folder");

        // Access preserved
        vm.prank(investorA);
        assertTrue(room.hasAccess(folderId));

        // Document intact
        (string memory cid,,,,,) = _getDoc(folderId, 0);
        assertEq(cid, "cidX");
    }

    // ═══════════════════════════════════════════════════════════════
    //  13. Parallel deal rooms on same DataRoom contract
    // ═══════════════════════════════════════════════════════════════

    /// @notice Two concurrent deals with different investors. Actions on
    ///         one deal don't leak into the other.
    function test_parallelDeals_fullyIsolated() public {
        vm.startPrank(board);
        uint256 dealA = room.createRoom("Deal A");
        uint256 dealAFolder = room.createFolder(dealA, "Docs");
        room.addDocuments(dealAFolder, _s1("cidA"), _s1("a.pdf"), _b1(_wk(1)), _b1(""));
        room.grantAccess(dealAFolder, _addrs(investorA));

        uint256 dealB = room.createRoom("Deal B");
        uint256 dealBFolder = room.createFolder(dealB, "Docs");
        room.addDocuments(dealBFolder, _s1("cidB"), _s1("b.pdf"), _b1(_wk(2)), _b1(""));
        room.grantAccess(dealBFolder, _addrs(investorB));
        vm.stopPrank();

        // investorA: Deal A YES, Deal B NO
        vm.prank(investorA);
        assertTrue(room.hasAccess(dealAFolder));
        vm.prank(investorA);
        assertFalse(room.hasAccess(dealBFolder));

        // investorB: Deal B YES, Deal A NO
        vm.prank(investorB);
        assertTrue(room.hasAccess(dealBFolder));
        vm.prank(investorB);
        assertFalse(room.hasAccess(dealAFolder));

        // Revoke investorA from Deal A — investorB on Deal B unaffected
        vm.prank(board);
        room.revokeAndRekey(dealAFolder, _addrs(investorA));

        vm.prank(investorB);
        assertTrue(room.hasAccess(dealBFolder));
        vm.prank(investorB);
        room.getRoomKey(dealBFolder); // still works
    }
}
