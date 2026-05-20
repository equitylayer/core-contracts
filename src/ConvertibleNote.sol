// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FHE, euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ICompany} from "./interfaces/ICompany.sol";
import {IFundraise} from "./interfaces/IFundraise.sol";
import {IConvertibleNote} from "./interfaces/IConvertibleNote.sol";
import {IEquityIssuance} from "./interfaces/IEquityIssuance.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IZKVerifier} from "./interfaces/IZKVerifier.sol";
import {ShareToken} from "./ShareToken.sol";

uint256 constant MAX_INTEREST_RATE_BPS = 5000;

/**
 * @title ConvertibleNote
 * @notice Manages Convertible Note instruments using term commitments.
 */
contract ConvertibleNote is IConvertibleNote, Initializable, ReentrancyGuard {
    string public constant VERSION = "0.10.0";

    /// @notice Maximum Notes per conversion batch. Increasing this requires recompiling the circuit

    /// @notice Recency bounds for the `currentTime` public input of `repayNote`.
    /// Caller-provided `currentTime` must satisfy
    ///   `block.timestamp - REPAY_PROOF_MAX_AGE <= currentTime <= block.timestamp + REPAY_PROOF_MAX_FUTURE`.
    /// Worst-case investor loss is bounded by `interest(REPAY_PROOF_MAX_AGE)` -- e.g.
    /// for a 6% APR / $250k note that's ~$1.71/hr, negligible vs total accrual.
    uint256 public constant REPAY_PROOF_MAX_AGE = 1 hours;
    uint256 public constant REPAY_PROOF_MAX_FUTURE = 5 minutes;

    ICompany public company;
    IFundraise public fundraise;
    IEquityIssuance public issuance;
    IZKVerifier public repayVerifier;

    mapping(uint256 => NoteInstrument) public notes;
    mapping(address => uint256[]) public investorNotes;
    uint256 public noteCount;
    uint256[] private activeNoteIds;
    mapping(uint256 => uint256) private noteIdToIndex;

    error OnlyBoard();
    error OnlyInvestor();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidNoteId();
    error NotActive();
    error NoSharesIssued();
    error InvalidShareClass();
    error OnlyFundraise();
    error OnlyIssuance();
    error InvalidIssuedAt();
    error InvalidMaturityDate();
    error InvalidCommitment();
    error InvalidVerifier();
    error InvalidConversion();
    error InvalidRepayProof();
    error EarlyRepaymentNotAllowed();
    error EarlyRepaymentLocked();
    error RepayTransferFailed();
    error ZeroRepayment();
    error StaleProofTime();

    // Sensitive payloads (terms, share counts) live in `encryptedMemo` blobs intended to be
    // ECIES-encrypted to (investor, company viewing key) by the off-chain producer.
    event NoteIssued(
        uint256 indexed noteId,
        address indexed investor,
        bytes32 indexed termsCommitment,
        address targetShareClass,
        uint256 issuedAt,
        uint256 maturityDate,
        bool allowEarlyRepayment,
        string documentRef,
        bytes encryptedMemo
    );
    event NoteConverted(
        uint256 indexed conversionId,
        uint256 indexed noteId,
        address indexed investor,
        bytes32 sharesCommitment,
        bytes encryptedSharesMemo
    );
    event NoteCancelled(uint256 indexed noteId, uint256 timestamp, string documentRef);
    event NoteRepaid(uint256 indexed noteId, address indexed investor, uint256 totalRepayment, uint256 repaidAt);
    event EarlyRepaymentToggled(uint256 indexed noteId, address indexed investor, bool allowed);

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    modifier onlyFundraise() {
        if (msg.sender != address(fundraise)) revert OnlyFundraise();
        _;
    }

    modifier onlyIssuance() {
        if (msg.sender != address(issuance)) revert OnlyIssuance();
        _;
    }

    function initialize(address _company, address _fundraise, address _issuance, address _repayVerifier)
        external
        initializer
    {
        if (_company == address(0)) revert ZeroAddress();
        if (_fundraise == address(0)) revert ZeroAddress();
        if (_issuance == address(0)) revert ZeroAddress();
        if (_repayVerifier == address(0)) revert ZeroAddress();
        company = ICompany(_company);
        fundraise = IFundraise(_fundraise);
        issuance = IEquityIssuance(_issuance);
        repayVerifier = IZKVerifier(_repayVerifier);
    }

    /// @inheritdoc IConvertibleNote
    function canConvertNotes() public view returns (bool) {
        uint256 threshold = fundraise.qualifiedFinancingThreshold();
        bool occurred = fundraise.qualifiedFinancingOccurred();
        if (threshold == 0) return true;
        return occurred;
    }

    // ============ Issuance ============

    /// @inheritdoc IConvertibleNote
    function issueNote(
        address investor,
        bytes32 termsCommitment,
        TermsCiphertext calldata terms,
        InEuint128 calldata salt,
        address targetShareClass,
        uint256 issuedAt,
        uint256 maturityDate,
        bool allowEarlyRepayment,
        string calldata documentRef,
        bytes calldata encryptedMemo
    ) external onlyBoard nonReentrant returns (uint256 noteId) {
        if (issuedAt == 0 || issuedAt > block.timestamp) revert InvalidIssuedAt();
        if (maturityDate <= issuedAt) revert InvalidMaturityDate();

        IssueNoteParams memory p;
        p.investor = investor;
        p.termsCommitment = termsCommitment;
        p.principal = FHE.asEuint128(terms.principal);
        p.rateBps = FHE.asEuint128(terms.interestRateBps);
        p.cap = FHE.asEuint128(terms.valuationCap);
        p.disc = FHE.asEuint128(terms.discountBps);
        p.salt = FHE.asEuint128(salt);
        p.targetShareClass = targetShareClass;
        p.issuedAt = issuedAt;
        p.maturityDate = maturityDate;
        p.allowEarlyRepayment = allowEarlyRepayment;
        p.documentRef = documentRef;
        p.encryptedMemo = encryptedMemo;
        return _issueNote(p);
    }

    /// @inheritdoc IConvertibleNote
    function issueNoteFromFundraise(
        address investor,
        bytes32 termsCommitment,
        euint128 principal,
        euint128 rateBps,
        euint128 cap,
        euint128 disc,
        euint128 salt,
        address targetShareClass,
        uint256 issuedAt,
        uint256 maturityDate,
        bool allowEarlyRepayment,
        string calldata documentRef,
        bytes calldata encryptedMemo
    ) external onlyFundraise nonReentrant returns (uint256 noteId) {
        if (issuedAt == 0 || issuedAt > block.timestamp) revert InvalidIssuedAt();
        if (maturityDate <= issuedAt) revert InvalidMaturityDate();
        if (maturityDate <= block.timestamp) revert InvalidMaturityDate();

        IssueNoteParams memory p;
        p.investor = investor;
        p.termsCommitment = termsCommitment;
        p.principal = principal;
        p.rateBps = rateBps;
        p.cap = cap;
        p.disc = disc;
        p.salt = salt;
        p.targetShareClass = targetShareClass;
        p.issuedAt = issuedAt;
        p.maturityDate = maturityDate;
        p.allowEarlyRepayment = allowEarlyRepayment;
        p.documentRef = documentRef;
        p.encryptedMemo = encryptedMemo;
        return _issueNote(p);
    }

    /// @inheritdoc IConvertibleNote
    function cancelNote(uint256 noteId, string calldata documentRef) external onlyBoard nonReentrant {
        NoteInstrument storage note = notes[noteId];
        if (note.termsCommitment == bytes32(0)) revert InvalidNoteId();
        if (note.status != Status.Active) revert NotActive();

        note.status = Status.Cancelled;
        _removeNote(noteId);

        emit NoteCancelled(noteId, block.timestamp, documentRef);
    }

    /// @inheritdoc IConvertibleNote
    function toggleEarlyRepayment(uint256 noteId, bool allowed) external {
        NoteInstrument storage note = notes[noteId];
        if (note.termsCommitment == bytes32(0)) revert InvalidNoteId();
        if (msg.sender != note.investor) revert OnlyInvestor();
        if (note.status != Status.Active) revert NotActive();
        if (note.allowEarlyRepayment && !allowed) revert EarlyRepaymentLocked();

        note.allowEarlyRepayment = allowed;
        emit EarlyRepaymentToggled(noteId, msg.sender, allowed);
    }

    // ============ Conversion (privileged hooks; orchestration on EquityIssuance) ============

    /// @inheritdoc IConvertibleNote
    function _markPendingConversion(uint256 conversionId, uint256[] calldata noteIds) external onlyIssuance {
        for (uint256 i = 0; i < noteIds.length; i++) {
            uint256 noteId = noteIds[i];
            NoteInstrument storage note = notes[noteId];
            if (note.status != Status.Active) revert InvalidConversion();
            note.status = Status.PendingConversion;
            note.conversionId = conversionId;
        }
    }

    /// @inheritdoc IConvertibleNote
    function _applyConversion(
        uint256 conversionId,
        ConversionResult[] calldata results,
        bytes calldata encryptedSharesMemo
    ) external onlyIssuance nonReentrant returns (uint256 totalSharesIssued) {
        for (uint256 i = 0; i < results.length; i++) {
            uint256 noteId = results[i].noteId;
            NoteInstrument storage note = notes[noteId];
            if (note.status != Status.PendingConversion || note.conversionId != conversionId) {
                revert InvalidConversion();
            }
            if (results[i].sharesIssued == 0) revert NoSharesIssued();
            if (results[i].sharesCommitment == bytes32(0)) revert InvalidCommitment();

            note.status = Status.Converted;
            note.convertedAt = block.timestamp;
            note.sharesIssued = results[i].sharesIssued;
            note.sharesCommitment = results[i].sharesCommitment;

            _removeNote(noteId);

            emit NoteConverted(conversionId, noteId, note.investor, results[i].sharesCommitment, encryptedSharesMemo);
            totalSharesIssued += results[i].sharesIssued;
        }
    }

    /// @inheritdoc IConvertibleNote
    function _rollbackConversion(uint256 conversionId, uint256[] calldata noteIds) external onlyIssuance {
        for (uint256 i = 0; i < noteIds.length; i++) {
            uint256 noteId = noteIds[i];
            NoteInstrument storage note = notes[noteId];
            if (note.status != Status.PendingConversion || note.conversionId != conversionId) continue;
            note.status = Status.Active;
            note.conversionId = 0;
        }
    }

    // ============ Repayment ============

    /// @inheritdoc IConvertibleNote
    function repayNote(uint256 noteId, uint256 totalRepayment, uint256 currentTime, bytes calldata proof)
        external
        onlyBoard
        nonReentrant
    {
        NoteInstrument storage note = notes[noteId];
        if (note.termsCommitment == bytes32(0)) revert InvalidNoteId();
        if (note.status != Status.Active) revert NotActive();
        if (totalRepayment == 0) revert ZeroRepayment();
        if (address(repayVerifier) == address(0)) revert InvalidVerifier();
        if (
            currentTime > block.timestamp + REPAY_PROOF_MAX_FUTURE
                || currentTime + REPAY_PROOF_MAX_AGE < block.timestamp
        ) {
            revert StaleProofTime();
        }
        if (block.timestamp < note.maturityDate && !note.allowEarlyRepayment) {
            revert EarlyRepaymentNotAllowed();
        }

        bytes32[] memory publicInputs = noteRepaymentPublicInputs(noteId, totalRepayment, currentTime);
        if (!repayVerifier.verify(proof, publicInputs)) revert InvalidRepayProof();

        note.status = Status.Repaid;
        _removeNote(noteId);

        bool ok = company.vault().repay(note.investor, totalRepayment);
        if (!ok) revert RepayTransferFailed();

        emit NoteRepaid(noteId, note.investor, totalRepayment, block.timestamp);
    }

    /// @inheritdoc IConvertibleNote
    function noteRepaymentPublicInputs(uint256 noteId, uint256 totalRepayment, uint256 currentTime)
        public
        view
        returns (bytes32[] memory inputs)
    {
        NoteInstrument storage note = notes[noteId];
        if (note.termsCommitment == bytes32(0)) revert InvalidNoteId();

        inputs = new bytes32[](5);
        inputs[0] = note.termsCommitment;
        inputs[1] = bytes32(note.issuedAt);
        inputs[2] = bytes32(note.maturityDate);
        inputs[3] = bytes32(currentTime);
        inputs[4] = bytes32(totalRepayment);
    }

    // ============ Internal ============

    function _issueNote(IssueNoteParams memory p) private returns (uint256 noteId) {
        if (p.investor == address(0)) revert ZeroAddress();
        if (p.targetShareClass == address(0)) revert ZeroAddress();
        if (p.termsCommitment == bytes32(0)) revert InvalidCommitment();

        try ShareToken(p.targetShareClass).companyAddress() returns (address tokenCompany) {
            if (tokenCompany != address(company)) revert InvalidShareClass();
        } catch {
            revert InvalidShareClass();
        }

        noteId = noteCount++;

        NoteInstrument storage note = notes[noteId];
        note.noteId = noteId;
        note.investor = p.investor;
        note.status = Status.Active;
        note.termsCommitment = p.termsCommitment;
        note.targetShareClass = p.targetShareClass;
        note.issuedAt = p.issuedAt;
        note.maturityDate = p.maturityDate;
        note.allowEarlyRepayment = p.allowEarlyRepayment;
        note.documentRef = p.documentRef;
        note.principal = p.principal;
        note.rateBps = p.rateBps;
        note.cap = p.cap;
        note.disc = p.disc;
        note.salt = p.salt;

        _grantAllTerms(note, p.investor, company.board(), company.operator());

        investorNotes[p.investor].push(noteId);
        noteIdToIndex[noteId] = activeNoteIds.length;
        activeNoteIds.push(noteId);

        emit NoteIssued(
            noteId,
            p.investor,
            p.termsCommitment,
            p.targetShareClass,
            p.issuedAt,
            p.maturityDate,
            p.allowEarlyRepayment,
            p.documentRef,
            p.encryptedMemo
        );
    }

    /// @dev Grant FHE viewing rights on the Note's encrypted fields to investor / board / operator.
    function _grantAllTerms(NoteInstrument storage note, address a, address b, address c) private {
        _grantAll(note.principal, a, b, c);
        _grantAll(note.rateBps, a, b, c);
        _grantAll(note.cap, a, b, c);
        _grantAll(note.disc, a, b, c);
        _grantAll(note.salt, a, b, c);
    }

    /// @dev `FHE.allowThis(h)` + `FHE.allow(h, x)` for three grantees.
    function _grantAll(euint128 h, address a, address b, address c) private {
        FHE.allowThis(h);
        FHE.allow(h, a);
        FHE.allow(h, b);
        FHE.allow(h, c);
    }

    function _removeNote(uint256 noteId) private {
        uint256 index = noteIdToIndex[noteId];
        uint256 lastIndex = activeNoteIds.length - 1;
        if (index != lastIndex) {
            uint256 lastNoteId = activeNoteIds[lastIndex];
            activeNoteIds[index] = lastNoteId;
            noteIdToIndex[lastNoteId] = index;
        }
        activeNoteIds.pop();
        delete noteIdToIndex[noteId];
    }

    // ============ Views ============

    /// @inheritdoc IConvertibleNote
    function getNote(uint256 noteId) external view returns (NoteInstrument memory note) {
        note = notes[noteId];
        if (note.termsCommitment == bytes32(0)) revert InvalidNoteId();
    }

    /// @inheritdoc IConvertibleNote
    function getInvestorNotes(address investor) external view returns (uint256[] memory) {
        return investorNotes[investor];
    }

    /// @inheritdoc IConvertibleNote
    function getActiveNoteCount() public view returns (uint256 count) {
        for (uint256 i = 0; i < activeNoteIds.length; i++) {
            if (notes[activeNoteIds[i]].status == Status.Active) {
                count++;
            }
        }
    }

    /// @inheritdoc IConvertibleNote
    function getActiveNotes() external view returns (uint256[] memory noteIds) {
        uint256 count = getActiveNoteCount();
        noteIds = new uint256[](count);
        uint256 cursor = 0;
        for (uint256 i = 0; i < activeNoteIds.length; i++) {
            uint256 noteId = activeNoteIds[i];
            if (notes[noteId].status == Status.Active) noteIds[cursor++] = noteId;
        }
    }

    /// @inheritdoc IConvertibleNote
    function getOutstandingNoteCount() external view returns (uint256 count) {
        return activeNoteIds.length;
    }
}
