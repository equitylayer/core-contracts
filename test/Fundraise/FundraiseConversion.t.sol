// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./FundraiseBase.t.sol";
import {ConvertibleNote} from "../../src/ConvertibleNote.sol";
import {EquityIssuance} from "../../src/EquityIssuance.sol";
import {MockSanctionsList} from "../Rules/mocks/MockSanctionsList.sol";

/// @title FundraiseConversionTest
/// @notice Covers the joint SAFE+CN conversion lifecycle that lives on EquityIssuance:
///         `triggerConversion`, `applyConversion`, `rollbackConversion`, the
///         `onlyIssuance`-gated child hooks, and `conversionPublicInputs` layout.
///         Triggering is `onlyFundraise`, so tests prank as Fundraise for that step.
contract FundraiseConversionTest is FundraiseBaseTest {
    ConvertibleNote noteContract;

    bytes32 constant SAFE_TERMS = keccak256("safe-terms:investor1");
    bytes32 constant NOTE_TERMS = keccak256("note-terms:investor2");

    function setUp() public override {
        super.setUp();
        noteContract = ConvertibleNote(address(company.convertibleNote()));

        // Seed founder shares so fully_diluted > 0 (required by `_triggerConversions`).
        vm.prank(board);
        issuance.issueGrant("Common", founder, 1_000_000e6, "founder shares", "");
    }

    // ---------------- helpers ----------------

    function _safeCipher(address sender) internal returns (ISAFE.TermsCiphertext memory) {
        return ISAFE.TermsCiphertext({
            investmentAmount: createInEuint128(100_000e6, sender),
            valuationCap: createInEuint128(5_000_000e6, sender),
            discountBps: createInEuint128(2000, sender),
            mfn: createInEbool(false, sender),
            proRata: createInEbool(true, sender)
        });
    }

    function _noteCipher(address sender) internal returns (IConvertibleNote.TermsCiphertext memory) {
        return IConvertibleNote.TermsCiphertext({
            principal: createInEuint128(250_000e6, sender),
            interestRateBps: createInEuint128(600, sender),
            valuationCap: createInEuint128(8_000_000e6, sender),
            discountBps: createInEuint128(2000, sender)
        });
    }

    function _issueSAFE(address holder, bytes32 commitment) internal returns (uint256 safeId) {
        ISAFE.TermsCiphertext memory cipher = _safeCipher(board);
        InEuint128 memory salt = createInEuint128(0, board);
        vm.prank(board);
        return safeContract.issueSAFE(
            holder, commitment, cipher, salt, address(shareToken), "ipfs://safe", block.timestamp, ""
        );
    }

    function _issueNote(address holder, bytes32 commitment) internal returns (uint256 noteId) {
        IConvertibleNote.TermsCiphertext memory cipher = _noteCipher(board);
        InEuint128 memory salt = createInEuint128(0, board);
        vm.prank(board);
        return noteContract.issueNote(
            holder,
            commitment,
            cipher,
            salt,
            address(shareToken),
            block.timestamp,
            block.timestamp + 365 days,
            true,
            "ipfs://note",
            ""
        );
    }

    function _trigger(uint256 expiresAt) internal returns (uint256 conversionId) {
        uint256 fd = company.getFullyDilutedShares();
        vm.prank(address(fundraise));
        return issuance.triggerConversion(PRICE_PER_SHARE, fd, expiresAt, "ipfs://doc");
    }

    function _safeResult(uint256 safeId, uint256 shares, bytes32 commitment)
        internal
        pure
        returns (ISAFE.ConversionResult[] memory results)
    {
        results = new ISAFE.ConversionResult[](1);
        results[0] = ISAFE.ConversionResult({safeId: safeId, sharesIssued: shares, sharesCommitment: commitment});
    }

    function _noteResult(uint256 noteId, uint256 shares, bytes32 commitment)
        internal
        pure
        returns (IConvertibleNote.ConversionResult[] memory results)
    {
        results = new IConvertibleNote.ConversionResult[](1);
        results[0] =
            IConvertibleNote.ConversionResult({noteId: noteId, sharesIssued: shares, sharesCommitment: commitment});
    }

    // ---------------- initialize ----------------

    function test_Initialize_RevertsZeroVerifier() public {
        // Verifier now lives on EquityIssuance; Fundraise.initialize is single-arg.
        EquityIssuance fresh = new EquityIssuance();
        vm.expectRevert(EquityIssuance.ZeroAddress.selector);
        fresh.initialize(address(company), address(fundraise), address(0));
    }

    // ---------------- triggerConversions ----------------

    function test_TriggerConversions_OpensBatchWithActiveSafes() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);

        uint256 expiresAt = block.timestamp + 7 days;
        uint256 conversionId = _trigger(expiresAt);

        IEquityIssuance.Conversion memory batch = issuance.getConversion(conversionId);
        assertEq(batch.conversionId, conversionId);
        assertEq(batch.safeIds.length, 1);
        assertEq(batch.safeIds[0], safeId);
        assertEq(batch.noteIds.length, 0);
        assertEq(batch.pricePerShare, PRICE_PER_SHARE);
        assertEq(batch.fullyDiluted, company.getFullyDilutedShares());
        assertEq(batch.expiresAt, expiresAt);
        assertFalse(batch.applied);
        assertFalse(batch.rolledBack);

        // SAFE is now PendingConversion and excluded from convertible view.
        ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeId);
        assertTrue(safe_.status == ISAFE.Status.PendingConversion);
        assertEq(safe_.conversionId, conversionId);
        assertEq(safeContract.getActiveSAFECount(), 0);
        assertEq(safeContract.getActiveSAFEs().length, 0);
        assertEq(safeContract.getOutstandingSAFECount(), 1);
        assertEq(issuance.conversionCount(), 1);
    }

    function test_TriggerConversions_MixedSafeAndNote() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 noteId = _issueNote(investor2, NOTE_TERMS);

        uint256 conversionId = _trigger(block.timestamp + 7 days);

        IEquityIssuance.Conversion memory batch = issuance.getConversion(conversionId);
        assertEq(batch.safeIds.length, 1);
        assertEq(batch.noteIds.length, 1);
        assertEq(batch.safeIds[0], safeId);
        assertEq(batch.noteIds[0], noteId);

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.status == IConvertibleNote.Status.PendingConversion);
        assertEq(note.conversionId, conversionId);
        assertEq(noteContract.getActiveNoteCount(), 0);
        assertEq(noteContract.getActiveNotes().length, 0);
        assertEq(noteContract.getOutstandingNoteCount(), 1);
    }

    function test_SetQFT_PendingConversionStillBlocksIncrease() public {
        _issueSAFE(investor1, SAFE_TERMS);
        _trigger(block.timestamp + 7 days);

        uint256 currentThreshold = fundraise.qualifiedFinancingThreshold();
        vm.prank(board);
        vm.expectRevert(Fundraise.ThresholdCanOnlyDecrease.selector);
        fundraise.setQFT(currentThreshold + 1);
    }

    function test_TriggerConversions_RevertsNoActiveInstruments() public {
        vm.prank(address(fundraise));
        vm.expectRevert(EquityIssuance.NoActiveInstruments.selector);
        issuance.triggerConversion(PRICE_PER_SHARE, 1_000_000e6, block.timestamp + 1 days, "");
    }

    function test_TriggerConversions_RevertsZeroPrice() public {
        _issueSAFE(investor1, SAFE_TERMS);
        uint256 fd = company.getFullyDilutedShares();
        vm.prank(address(fundraise));
        vm.expectRevert(EquityIssuance.ZeroAmount.selector);
        issuance.triggerConversion(0, fd, block.timestamp + 1 days, "");
    }

    function test_TriggerConversions_RevertsZeroFullyDiluted() public {
        _issueSAFE(investor1, SAFE_TERMS);
        vm.prank(address(fundraise));
        vm.expectRevert(EquityIssuance.ZeroAmount.selector);
        issuance.triggerConversion(PRICE_PER_SHARE, 0, block.timestamp + 1 days, "");
    }

    function test_TriggerConversions_RevertsInvalidExpiry() public {
        _issueSAFE(investor1, SAFE_TERMS);
        vm.prank(address(fundraise));
        vm.expectRevert(EquityIssuance.InvalidExpiry.selector);
        // expiresAt at-or-before now is invalid (zero means "no expiry" and is allowed)
        issuance.triggerConversion(PRICE_PER_SHARE, 1_000_000e6, block.timestamp, "");
    }

    function test_TriggerConversions_OnlyFundraise() public {
        _issueSAFE(investor1, SAFE_TERMS);
        // Board can't bypass Fundraise to trigger directly.
        vm.prank(board);
        vm.expectRevert(EquityIssuance.OnlyFundraise.selector);
        issuance.triggerConversion(PRICE_PER_SHARE, 1_000_000e6, block.timestamp + 1 days, "");
    }

    // ---------------- applyConversions ----------------

    function test_ApplyConversions_SafeOnly_IssuesShares() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        bytes32 sharesCommitment = keccak256("shares:investor1");
        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, sharesCommitment);
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        conversionVerifier.setExpectedPublicInputs(
            issuance.conversionPublicInputs(conversionId, safeResults, noteResults)
        );
        uint256 totalShares = issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");

        assertEq(totalShares, 50_000e6);
        IEquityIssuance.Conversion memory batch = issuance.getConversion(conversionId);
        assertTrue(batch.applied);
        assertFalse(batch.rolledBack);

        ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeId);
        assertTrue(safe_.status == ISAFE.Status.Converted);
        assertEq(safe_.sharesIssued, 50_000e6);
        assertEq(safe_.sharesCommitment, sharesCommitment);
        assertEq(shareToken.balanceOf(investor1), 50_000e6);
    }

    function test_ApplyConversions_MixedSafeAndNote_IssuesBoth() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 noteId = _issueNote(investor2, NOTE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, keccak256("safe-shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = _noteResult(noteId, 30_000e6, keccak256("note-shares"));

        conversionVerifier.setExpectedPublicInputs(
            issuance.conversionPublicInputs(conversionId, safeResults, noteResults)
        );
        uint256 totalShares = issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");

        assertEq(totalShares, 80_000e6);
        assertEq(shareToken.balanceOf(investor1), 50_000e6);
        assertEq(shareToken.balanceOf(investor2), 30_000e6);

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.status == IConvertibleNote.Status.Converted);
        assertEq(note.sharesIssued, 30_000e6);
    }

    function test_ApplyConversions_RevertsInvalidProof() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, keccak256("shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        conversionVerifier.setValid(false);
        vm.expectRevert(EquityIssuance.InvalidConversionProof.selector);
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");
    }

    function test_ApplyConversions_RevertsLengthMismatch() public {
        _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        ISAFE.ConversionResult[] memory safeResults = new ISAFE.ConversionResult[](0);
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");
    }

    function test_ApplyConversions_RevertsResultBindingMismatch() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        // wrong safeId in the result — should fail the binding check in conversionPublicInputs
        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId + 999, 50_000e6, keccak256("shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");
    }

    function test_ApplyConversions_RevertsExpired() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 expiresAt = block.timestamp + 7 days;
        uint256 conversionId = _trigger(expiresAt);

        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, keccak256("shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        vm.warp(expiresAt + 1);
        vm.expectRevert(EquityIssuance.ConversionExpired.selector);
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");
    }

    function test_ApplyConversions_RevertsAlreadyApplied() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, keccak256("shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        conversionVerifier.setExpectedPublicInputs(
            issuance.conversionPublicInputs(conversionId, safeResults, noteResults)
        );
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");

        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");
    }

    function test_ApplyConversions_RevertsUnknownId() public {
        ISAFE.ConversionResult[] memory safeResults = new ISAFE.ConversionResult[](0);
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);
        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.applyConversion(999, safeResults, noteResults, "proof", "");
    }

    /// @dev Pre-extraction, compliance only ran at invest-time; a SAFE holder
    /// whose status changed between invest and conversion would silently mint
    /// to a non-compliant address. After extraction every mint runs through
    /// `Equity._mint` and re-checks the rule engine, so the conversion
    /// transaction reverts cleanly. This test pins that behavior.
    function test_ApplyConversions_RevertsWhenInvestorBecomesNonCompliant() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        // Wire a sanctions rule on the share class and sanction investor1 AFTER
        // the SAFE was issued (mirrors a real "KYC lapsed mid-round" scenario).
        (, MockSanctionsList oracle) = _setupSanctionsValidationRule();
        oracle.addToSanctionsList(investor1);

        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, keccak256("shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        conversionVerifier.setExpectedPublicInputs(
            issuance.conversionPublicInputs(conversionId, safeResults, noteResults)
        );

        vm.expectRevert(EquityIssuance.InvestorNotCompliant.selector);
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");

        // SAFE is now in a stuck PendingConversion state: status flip happened
        // in Phase 1 before the Phase 2 mint reverted. Wait, actually the whole
        // tx reverts atomically -- so the SAFE returns to PendingConversion since
        // the apply failed entirely. Confirm by re-checking status.
        ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeId);
        assertTrue(safe_.status == ISAFE.Status.PendingConversion);
    }

    // ---------------- rollbackConversions ----------------

    function test_RollbackConversions_AfterExpiry_ReactivatesInstruments() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 noteId = _issueNote(investor2, NOTE_TERMS);
        uint256 expiresAt = block.timestamp + 7 days;
        uint256 conversionId = _trigger(expiresAt);

        vm.warp(expiresAt + 1);
        issuance.rollbackConversion(conversionId);

        IEquityIssuance.Conversion memory batch = issuance.getConversion(conversionId);
        assertTrue(batch.rolledBack);
        assertFalse(batch.applied);

        ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeId);
        assertTrue(safe_.status == ISAFE.Status.Active);
        assertEq(safe_.conversionId, 0);

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.status == IConvertibleNote.Status.Active);
        assertEq(note.conversionId, 0);

        // After rollback, instruments are re-eligible.
        assertEq(safeContract.getActiveSAFEs().length, 1);
        assertEq(noteContract.getActiveNotes().length, 1);
    }

    function test_RollbackConversions_RevertsBeforeExpiry() public {
        _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        vm.expectRevert(EquityIssuance.ConversionNotExpired.selector);
        issuance.rollbackConversion(conversionId);
    }

    function test_RollbackConversions_RevertsAfterApply() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 expiresAt = block.timestamp + 7 days;
        uint256 conversionId = _trigger(expiresAt);

        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, keccak256("shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);
        conversionVerifier.setExpectedPublicInputs(
            issuance.conversionPublicInputs(conversionId, safeResults, noteResults)
        );
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");

        vm.warp(expiresAt + 1);
        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.rollbackConversion(conversionId);
    }

    function test_RollbackConversions_RevertsUnknownId() public {
        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.rollbackConversion(999);
    }

    // ---------------- privileged hook auth (only EquityIssuance) ----------------

    function test_SafeHooks_OnlyIssuance() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256[] memory ids = new uint256[](1);
        ids[0] = safeId;
        ISAFE.ConversionResult[] memory results = _safeResult(safeId, 1, keccak256("x"));

        vm.expectRevert(SAFE.OnlyIssuance.selector);
        safeContract._markPendingConversion(0, ids);

        vm.expectRevert(SAFE.OnlyIssuance.selector);
        safeContract._applyConversion(0, results, "");

        vm.expectRevert(SAFE.OnlyIssuance.selector);
        safeContract._rollbackConversion(0, ids);
    }

    function test_NoteHooks_OnlyIssuance() public {
        uint256 noteId = _issueNote(investor2, NOTE_TERMS);
        uint256[] memory ids = new uint256[](1);
        ids[0] = noteId;
        IConvertibleNote.ConversionResult[] memory results = _noteResult(noteId, 1, keccak256("x"));

        vm.expectRevert(ConvertibleNote.OnlyIssuance.selector);
        noteContract._markPendingConversion(0, ids);

        vm.expectRevert(ConvertibleNote.OnlyIssuance.selector);
        noteContract._applyConversion(0, results, "");

        vm.expectRevert(ConvertibleNote.OnlyIssuance.selector);
        noteContract._rollbackConversion(0, ids);
    }

    // ---------------- public-input layout ----------------

    function test_ConversionPublicInputs_LayoutMatchesCircuit() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 noteId = _issueNote(investor2, NOTE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        bytes32 safeShareCommit = keccak256("safe-shares");
        bytes32 noteShareCommit = keccak256("note-shares");
        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, safeShareCommit);
        IConvertibleNote.ConversionResult[] memory noteResults = _noteResult(noteId, 30_000e6, noteShareCommit);

        bytes32[] memory inputs = issuance.conversionPublicInputs(conversionId, safeResults, noteResults);

        // Layout: 4 header scalars + 3 * 16 SAFE slots + 5 * 16 CN slots = 132
        assertEq(inputs.length, 4 + 3 * 16 + 5 * 16);

        // Header.
        assertEq(uint256(inputs[0]), conversionId);
        assertEq(uint256(inputs[1]), PRICE_PER_SHARE);
        assertEq(uint256(inputs[2]), company.getFullyDilutedShares());
        assertEq(uint256(inputs[3]), block.timestamp);

        // SAFE slot 0.
        assertEq(inputs[4], SAFE_TERMS);
        assertEq(uint256(inputs[4 + 16]), 50_000e6);
        assertEq(inputs[4 + 2 * 16], safeShareCommit);

        // CN slot 0 sits right after the SAFE region (52).
        uint256 cnBase = 4 + 3 * 16;
        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertEq(inputs[cnBase], NOTE_TERMS);
        assertEq(uint256(inputs[cnBase + 16]), note.issuedAt);
        assertEq(uint256(inputs[cnBase + 2 * 16]), note.maturityDate);
        assertEq(uint256(inputs[cnBase + 3 * 16]), 30_000e6);
        assertEq(inputs[cnBase + 4 * 16], noteShareCommit);
    }

    // ---------------- cancelConversion (board early-cancel) ----------------

    function test_CancelConversion_BoardCanCancelImmediately() public {
        // Pre-extraction the board had to wait 14 days for expiry before rolling
        // a stuck conversion back. cancelConversion shortcuts that.
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 noteId = _issueNote(investor2, NOTE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        // Both instruments are PendingConversion before cancel.
        assertTrue(safeContract.getSAFE(safeId).status == ISAFE.Status.PendingConversion);
        assertTrue(noteContract.getNote(noteId).status == IConvertibleNote.Status.PendingConversion);

        vm.prank(board);
        issuance.cancelConversion(conversionId);

        IEquityIssuance.Conversion memory batch = issuance.getConversion(conversionId);
        assertTrue(batch.rolledBack);
        assertFalse(batch.applied);

        // Both instruments returned to Active and are eligible for re-trigger.
        assertTrue(safeContract.getSAFE(safeId).status == ISAFE.Status.Active);
        assertTrue(noteContract.getNote(noteId).status == IConvertibleNote.Status.Active);
        assertEq(safeContract.getActiveSAFEs().length, 1);
        assertEq(noteContract.getActiveNotes().length, 1);
    }

    function test_CancelConversion_OnlyBoard() public {
        _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        vm.prank(investor1);
        vm.expectRevert(EquityIssuance.OnlyBoard.selector);
        issuance.cancelConversion(conversionId);
    }

    function test_CancelConversion_RevertsAfterApply() public {
        uint256 safeId = _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        ISAFE.ConversionResult[] memory safeResults = _safeResult(safeId, 50_000e6, keccak256("shares"));
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);
        conversionVerifier.setExpectedPublicInputs(
            issuance.conversionPublicInputs(conversionId, safeResults, noteResults)
        );
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");

        vm.prank(board);
        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.cancelConversion(conversionId);
    }

    function test_CancelConversion_RevertsAfterRollback() public {
        _issueSAFE(investor1, SAFE_TERMS);
        uint256 expiresAt = block.timestamp + 7 days;
        uint256 conversionId = _trigger(expiresAt);

        vm.warp(expiresAt + 1);
        issuance.rollbackConversion(conversionId);

        vm.prank(board);
        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.cancelConversion(conversionId);
    }

    function test_CancelConversion_RevertsUnknownId() public {
        vm.prank(board);
        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.cancelConversion(999);
    }

    function test_CancelConversion_DoubleCancelReverts() public {
        _issueSAFE(investor1, SAFE_TERMS);
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        vm.prank(board);
        issuance.cancelConversion(conversionId);

        vm.prank(board);
        vm.expectRevert(EquityIssuance.InvalidConversion.selector);
        issuance.cancelConversion(conversionId);
    }

    // ---------------- instrument cap (16+16) ----------------

    function test_TriggerConversion_RevertsTooManySafes() public {
        // Issue 17 SAFEs; trigger should hit the 16-cap revert.
        for (uint256 i = 0; i < 17; i++) {
            _issueSAFE(investor1, keccak256(abi.encode("safe", i)));
        }
        assertEq(safeContract.getActiveSAFEs().length, 17);

        uint256 fd = company.getFullyDilutedShares();
        vm.prank(address(fundraise));
        vm.expectRevert(EquityIssuance.TooManySafes.selector);
        issuance.triggerConversion(PRICE_PER_SHARE, fd, block.timestamp + 1 days, "");
    }

    function test_TriggerConversion_RevertsTooManyNotes() public {
        // Issue 17 CNs (no SAFEs, so the SAFE-cap check passes first).
        for (uint256 i = 0; i < 17; i++) {
            _issueNote(investor2, keccak256(abi.encode("note", i)));
        }
        assertEq(noteContract.getActiveNotes().length, 17);

        uint256 fd = company.getFullyDilutedShares();
        vm.prank(address(fundraise));
        vm.expectRevert(EquityIssuance.TooManyNotes.selector);
        issuance.triggerConversion(PRICE_PER_SHARE, fd, block.timestamp + 1 days, "");
    }

    function test_TriggerConversion_AcceptsExactlySixteenOfEach() public {
        // Boundary: 16 SAFEs + 16 CNs is fine, 17 of either is not.
        for (uint256 i = 0; i < 16; i++) {
            _issueSAFE(investor1, keccak256(abi.encode("safe", i)));
            _issueNote(investor2, keccak256(abi.encode("note", i)));
        }

        uint256 conversionId = _trigger(block.timestamp + 1 days);
        IEquityIssuance.Conversion memory batch = issuance.getConversion(conversionId);
        assertEq(batch.safeIds.length, 16);
        assertEq(batch.noteIds.length, 16);
    }

    // ---------------- Phase-2 mint binding ----------------

    /// @dev Pins that the conversion mint goes to the SAFE's stored `investor`
    /// address, not anywhere the result vector could nominate. `safeResults`
    /// only carries `(safeId, sharesIssued, sharesCommitment)` -- the recipient
    /// is read from `safeContract.getSAFE(safeId).investor` in Phase 2. This
    /// test catches any future drift that would let attackers redirect mints.
    function test_ApplyConversion_MintsToStoredInvestor() public {
        // Two SAFEs to two different investors. Apply mints to each respective
        // holder; neither can be redirected via results.
        uint256 safeId1 = _issueSAFE(investor1, keccak256("inv1-terms"));
        uint256 safeId2 = _issueSAFE(investor2, keccak256("inv2-terms"));
        uint256 conversionId = _trigger(block.timestamp + 7 days);

        ISAFE.ConversionResult[] memory safeResults = new ISAFE.ConversionResult[](2);
        safeResults[0] =
            ISAFE.ConversionResult({safeId: safeId1, sharesIssued: 10_000e6, sharesCommitment: keccak256("c1")});
        safeResults[1] =
            ISAFE.ConversionResult({safeId: safeId2, sharesIssued: 25_000e6, sharesCommitment: keccak256("c2")});
        IConvertibleNote.ConversionResult[] memory noteResults = new IConvertibleNote.ConversionResult[](0);

        conversionVerifier.setExpectedPublicInputs(
            issuance.conversionPublicInputs(conversionId, safeResults, noteResults)
        );
        issuance.applyConversion(conversionId, safeResults, noteResults, "proof", "");

        // Stored investor receives shares, not the caller or any other party.
        assertEq(shareToken.balanceOf(investor1), 10_000e6);
        assertEq(shareToken.balanceOf(investor2), 25_000e6);
        assertEq(shareToken.balanceOf(address(this)), 0); // not the test contract
        assertEq(shareToken.balanceOf(board), 0); // not the board
    }
}
