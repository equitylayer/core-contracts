// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";
import {ConvertibleNote} from "../src/ConvertibleNote.sol";
import {MockZKVerifier} from "../src/mocks/MockZKVerifier.sol";

contract ConvertibleNoteTest is BaseTest {
    ConvertibleNote noteContract;
    Fundraise fundraise;
    OptionPool optionPool;
    SAFE safeContract;
    // conversionVerifier inherited from BaseTest (one mock for joint SAFE+CN conversion);
    // repayVerifier inherited too.

    address investor1 = address(0x1001);
    address investor2 = address(0x1002);

    bytes32 constant TERMS_COMMITMENT = keccak256("terms:investor1:note");
    bytes32 constant SHARES_COMMITMENT = keccak256("shares:investor1:note");

    function _termsCipher(address sender) internal returns (IConvertibleNote.TermsCiphertext memory) {
        return IConvertibleNote.TermsCiphertext({
            principal: createInEuint128(250_000e6, sender),
            interestRateBps: createInEuint128(600, sender),
            valuationCap: createInEuint128(8_000_000e6, sender),
            discountBps: createInEuint128(2000, sender)
        });
    }

    function setUp() public {
        _baseSetUp();

        ShareholderRegistry deployedRegistry;
        (company, vault, vestingSchedule, deployedRegistry, optionPool, safeContract, shareToken, fundraise) =
            _deployStandardCompany();
        noteContract = ConvertibleNote(address(company.convertibleNote()));
    }

    function test_Initialize_RevertsWithZeroRepayVerifier() public {
        ConvertibleNote fresh = new ConvertibleNote();
        // Cache issuance address before expectRevert -- the chained `company.issuance()`
        // would burn the expected revert.
        address issuanceAddr = address(company.issuance());
        vm.expectRevert(ConvertibleNote.ZeroAddress.selector);
        fresh.initialize(address(company), address(fundraise), issuanceAddr, address(0));
    }

    // Conversion-flow tests (request/apply/rollback) moved to Fundraise tests after the
    // joint conversion refactor — see `Fundraise.triggerConversions` / `applyConversions` /
    // `rollbackConversions`. CN no longer owns conversion state or verification.

    function test_IssueNote_StoresCommitment() public {
        IConvertibleNote.TermsCiphertext memory cipher = _termsCipher(board);
        InEuint128 memory salt = createInEuint128(0, board);
        vm.prank(board);
        uint256 noteId = noteContract.issueNote(
            investor1,
            TERMS_COMMITMENT,
            cipher,
            salt,
            address(shareToken),
            block.timestamp,
            block.timestamp + 365 days,
            true,
            "ipfs://private-note",
            ""
        );

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertEq(note.investor, investor1);
        assertEq(note.termsCommitment, TERMS_COMMITMENT);
        assertEq(note.targetShareClass, address(shareToken));
        assertTrue(note.status == IConvertibleNote.Status.Active);
        assertEq(noteContract.getActiveNoteCount(), 1);
        assertEq(note.allowEarlyRepayment, true);
    }

    function test_CancelNote() public {
        uint256 noteId = _issueNote();
        vm.prank(board);
        noteContract.cancelNote(noteId, "ipfs://cancellation");

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.status == IConvertibleNote.Status.Cancelled);
        assertEq(noteContract.getActiveNoteCount(), 0);
    }

    function test_ToggleEarlyRepayment_OnlyInvestor() public {
        uint256 noteId = _issueNote();

        vm.expectRevert(ConvertibleNote.OnlyInvestor.selector);
        vm.prank(board);
        noteContract.toggleEarlyRepayment(noteId, true);

        vm.prank(investor1);
        noteContract.toggleEarlyRepayment(noteId, true);

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.allowEarlyRepayment);
    }

    function test_ToggleEarlyRepayment_CannotRevoke() public {
        uint256 noteId = _issueNote();

        vm.startPrank(investor1);
        noteContract.toggleEarlyRepayment(noteId, true);

        // One-way unlock: once true, investor cannot lock back to false.
        vm.expectRevert(ConvertibleNote.EarlyRepaymentLocked.selector);
        noteContract.toggleEarlyRepayment(noteId, false);
        vm.stopPrank();

        // Re-asserting true is a no-op (idempotent).
        vm.prank(investor1);
        noteContract.toggleEarlyRepayment(noteId, true);

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.allowEarlyRepayment);
    }

    // ===================
    // Repay Tests
    // ===================

    bytes constant REPAY_PROOF = hex"";
    uint256 constant REPAY_AMOUNT = 270_000e6; // principal + accrued interest at maturity

    function _setupRepay() internal {
        // Fund the vault so it can pay out the repayment.
        musd.mint(address(vault), REPAY_AMOUNT * 10);
    }

    function _issueNoteWithEarlyRepay(bool allowEarly) internal returns (uint256 noteId) {
        return _issueNoteWithMaturity(allowEarly, block.timestamp + 365 days);
    }

    function _issueNoteWithMaturity(bool allowEarly, uint256 maturityDate) internal returns (uint256 noteId) {
        IConvertibleNote.TermsCiphertext memory cipher = _termsCipher(board);
        InEuint128 memory salt = createInEuint128(0, board);
        vm.prank(board);
        return noteContract.issueNote(
            investor1,
            TERMS_COMMITMENT,
            cipher,
            salt,
            address(shareToken),
            block.timestamp,
            maturityDate,
            allowEarly,
            "ipfs://private-note",
            ""
        );
    }

    function test_RepayNote_AtMaturitySucceeds() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(false);

        // Past maturity → early-repayment flag doesn't matter.
        vm.warp(block.timestamp + 366 days);

        uint256 balanceBefore = musd.balanceOf(investor1);

        vm.expectEmit(true, true, false, true);
        emit ConvertibleNote.NoteRepaid(noteId, investor1, REPAY_AMOUNT, block.timestamp);

        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.status == IConvertibleNote.Status.Repaid);
        assertEq(musd.balanceOf(investor1), balanceBefore + REPAY_AMOUNT);
        assertEq(noteContract.getActiveNoteCount(), 0);
    }

    function test_RepayNote_PreMaturityRequiresAllowFlag() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(false);

        // Pre-maturity, allowEarlyRepayment = false → revert.
        vm.expectRevert(ConvertibleNote.EarlyRepaymentNotAllowed.selector);
        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);
    }

    function test_RepayNote_PreMaturityUsesBlockTimeNotProofTime() public {
        _setupRepay();
        uint256 maturityDate = block.timestamp + 2 minutes;
        uint256 noteId = _issueNoteWithMaturity(false, maturityDate);

        vm.expectRevert(ConvertibleNote.EarlyRepaymentNotAllowed.selector);
        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, maturityDate, REPAY_PROOF);
    }

    function test_RepayNote_PreMaturityAllowedWhenFlagSet() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);

        // Pre-maturity, allowEarlyRepayment = true → succeeds.
        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);

        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);
        assertTrue(note.status == IConvertibleNote.Status.Repaid);
    }

    function test_RepayNote_RevertsOnRepeat() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);

        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);

        vm.expectRevert(ConvertibleNote.NotActive.selector);
        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);
    }

    function test_RepayNote_RevertsInvalidNote() public {
        _setupRepay();

        vm.expectRevert(ConvertibleNote.InvalidNoteId.selector);
        vm.prank(board);
        noteContract.repayNote(99, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);
    }

    function test_RepayNote_RevertsZeroRepayment() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);

        vm.expectRevert(ConvertibleNote.ZeroRepayment.selector);
        vm.prank(board);
        noteContract.repayNote(noteId, 0, block.timestamp, REPAY_PROOF);
    }

    function test_RepayNote_RevertsInvalidProof() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);

        cnRepayVerifier.setValid(false);

        vm.expectRevert(ConvertibleNote.InvalidRepayProof.selector);
        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);
    }

    function test_RepayNote_OnlyBoard() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);

        vm.expectRevert(ConvertibleNote.OnlyBoard.selector);
        vm.prank(investor1);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);
    }

    function test_RepayNote_ChecksExpectedPublicInputs() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);
        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);

        bytes32[] memory expected = new bytes32[](5);
        expected[0] = note.termsCommitment;
        expected[1] = bytes32(note.issuedAt);
        expected[2] = bytes32(note.maturityDate);
        expected[3] = bytes32(block.timestamp);
        expected[4] = bytes32(REPAY_AMOUNT);

        cnRepayVerifier.setExpectedPublicInputs(expected);

        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, block.timestamp, REPAY_PROOF);

        note = noteContract.getNote(noteId);
        assertTrue(note.status == IConvertibleNote.Status.Repaid);
    }

    function test_NoteRepaymentPublicInputs_BuildsCorrectArray() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);
        IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteId);

        bytes32[] memory inputs = noteContract.noteRepaymentPublicInputs(noteId, REPAY_AMOUNT, block.timestamp);
        assertEq(inputs.length, 5);
        assertEq(inputs[0], note.termsCommitment);
        assertEq(uint256(inputs[1]), note.issuedAt);
        assertEq(uint256(inputs[2]), note.maturityDate);
        assertEq(uint256(inputs[3]), block.timestamp);
        assertEq(uint256(inputs[4]), REPAY_AMOUNT);
    }

    function test_RepayNote_RevertsStaleFuture() public {
        _setupRepay();
        uint256 noteId = _issueNoteWithEarlyRepay(true);

        // currentTime > block.timestamp + REPAY_PROOF_MAX_FUTURE
        uint256 futureTime = block.timestamp + 10 minutes;
        vm.expectRevert(ConvertibleNote.StaleProofTime.selector);
        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, futureTime, REPAY_PROOF);
    }

    function test_RepayNote_RevertsStaleOld() public {
        _setupRepay();
        // Issue at t = 1_000_000 so the maturity (+365d) is well above the warped time below.
        vm.warp(1_000_000);
        uint256 noteId = _issueNoteWithEarlyRepay(true);

        // Warp 2 hours forward; a proof generated at t=1_000_000 is now > REPAY_PROOF_MAX_AGE old.
        vm.warp(1_000_000 + 2 hours);

        vm.expectRevert(ConvertibleNote.StaleProofTime.selector);
        vm.prank(board);
        noteContract.repayNote(noteId, REPAY_AMOUNT, 1_000_000, REPAY_PROOF);
    }

    function _issueNote() internal returns (uint256 noteId) {
        IConvertibleNote.TermsCiphertext memory cipher = _termsCipher(board);
        InEuint128 memory salt = createInEuint128(0, board);
        vm.prank(board);
        return noteContract.issueNote(
            investor1,
            TERMS_COMMITMENT,
            cipher,
            salt,
            address(shareToken),
            block.timestamp,
            block.timestamp + 365 days,
            false,
            "ipfs://private-note",
            ""
        );
    }

    function _finalizePricedRound() internal {
        // Founders must have minted before Notes can convert (CC formula needs fully_diluted > 0).
        vm.prank(board);
        issuance.issueGrant("Common", founder, 1_000_000e6, "founder shares", "");

        IFundraise.RoundParams memory p = _defaultRoundParams();
        p.roundType = IFundraise.RoundType.PRICED;
        p.valuationCap = 0;
        p.discountBps = 0;
        p.pricePerShare = PRICE_PER_SHARE;
        p.documentRef = "ipfs://priced-round";

        vm.prank(board);
        uint256 roundId = fundraise.createRound(p);

        _mintAndApprove(investor2, 10e6, address(fundraise));
        _invest(fundraise, roundId, investor2, 10e6);

        vm.startPrank(board);
        fundraise.closeRound(roundId);
        fundraise.finalizeRound(roundId);
        vm.stopPrank();
    }

    function _singleResult(uint256 noteId, uint256 sharesIssued)
        internal
        pure
        returns (IConvertibleNote.ConversionResult[] memory results)
    {
        results = new IConvertibleNote.ConversionResult[](1);
        results[0] = IConvertibleNote.ConversionResult({
            noteId: noteId, sharesIssued: sharesIssued, sharesCommitment: SHARES_COMMITMENT
        });
    }

    function _singleUint(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _singleBytes32(bytes32 value) internal pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = value;
    }
}
