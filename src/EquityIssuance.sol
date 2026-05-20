// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ICompany} from "./interfaces/ICompany.sol";
import {IFundraise} from "./interfaces/IFundraise.sol";
import {ISAFE} from "./interfaces/ISAFE.sol";
import {IConvertibleNote} from "./interfaces/IConvertibleNote.sol";
import {IZKVerifier} from "./interfaces/IZKVerifier.sol";
import {ShareToken} from "./ShareToken.sol";
import {SAFE} from "./SAFE.sol";
import {ConvertibleNote} from "./ConvertibleNote.sol";
import {VestingSchedule} from "./VestingSchedule.sol";
import {OptionPool} from "./OptionPool.sol";
import {IEquityIssuance} from "./interfaces/IEquityIssuance.sol";
import {IRuleEngine, IRuleEngineERC1404} from "CMTAT/contracts/interfaces/engine/IRuleEngine.sol";

uint256 constant MAX_SAFES_PER_CONVERSION = 16;
uint256 constant MAX_NOTES_PER_CONVERSION = 16;

/// @title EquityIssuance
contract EquityIssuance is IEquityIssuance, Initializable, ReentrancyGuard {
    string public constant VERSION = "0.1.0";

    ICompany public company;
    IFundraise public fundraise;
    IZKVerifier public conversionVerifier;

    mapping(uint256 => IEquityIssuance.Conversion) internal _conversions;
    uint256 public conversionCount;

    error OnlyBoard();
    error OnlyFundraise();
    error OnlyOptionPool();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidShareClass();
    error InvestorNotCompliant();
    error TooManySafes();
    error TooManyNotes();
    error NoActiveInstruments();
    error InvalidConversion();
    error InvalidConversionProof();
    error ConversionExpired();
    error ConversionNotExpired();
    error InvalidVerifier();
    error InvalidExpiry();
    error NoOp();
    error WouldConsumeOptionPoolCapacity();

    /// @notice Mirrors the legacy `Company.SharesIssued` semantics: `className` is the
    ///         token's ERC20 name (indexed for indexer filters).
    event SharesIssued(
        string indexed className, address indexed to, uint256 amount, string purpose, string documentRef
    );
    event ConversionRequested(
        uint256 indexed conversionId,
        bytes32 indexed idsHash,
        uint256 safeCount,
        uint256 noteCount,
        uint256 pricePerShare,
        uint256 fullyDiluted,
        uint256 currentTime,
        uint256 expiresAt,
        string documentRef
    );
    event ConversionApplied(uint256 indexed conversionId, uint256 totalSharesIssued);
    event ConversionRolledBack(uint256 indexed conversionId);

    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    modifier onlyFundraise() {
        if (msg.sender != address(fundraise)) revert OnlyFundraise();
        _;
    }

    modifier onlyOptionPool() {
        if (msg.sender != address(company.optionPool())) revert OnlyOptionPool();
        _;
    }

    function initialize(address _company, address _fundraise, address _conversionVerifier) external initializer {
        if (_company == address(0)) revert ZeroAddress();
        if (_fundraise == address(0)) revert ZeroAddress();
        if (_conversionVerifier == address(0)) revert ZeroAddress();
        company = ICompany(_company);
        fundraise = IFundraise(_fundraise);
        conversionVerifier = IZKVerifier(_conversionVerifier);
    }

    // ============ Share emission ============

    /// @inheritdoc IEquityIssuance
    function issueGrant(
        string calldata className,
        address to,
        uint256 amount,
        string calldata purpose,
        string calldata documentRef
    ) external onlyBoard nonReentrant {
        ShareToken token = company.getShareToken(className);
        if (address(token) == address(0)) revert InvalidShareClass();
        _mint(token, to, amount, purpose, documentRef);
    }

    /// @inheritdoc IEquityIssuance
    function issueGrantWithVesting(
        ShareToken token,
        address beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable,
        string calldata documentRef
    ) external onlyBoard nonReentrant returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert ZeroAddress();

        VestingSchedule vesting = VestingSchedule(address(company.vestingSchedule()));
        _mint(token, address(vesting), amount, "Vesting schedule", documentRef);

        scheduleId = vesting.createSchedule(
            beneficiary, address(token), amount, startTime, cliffDuration, vestingDuration, revocable, documentRef
        );
    }

    /// @inheritdoc IEquityIssuance
    function issueFromExercise(ShareToken token, address to, uint256 amount) external onlyOptionPool nonReentrant {
        _mint(token, to, amount, "Option exercise", "");
    }

    /// @inheritdoc IEquityIssuance
    function issueFromPricedRound(uint256 roundId, string calldata documentRef)
        external
        onlyFundraise
        nonReentrant
        returns (uint256 totalSharesIssued)
    {
        IFundraise.Round memory round = fundraise.getRound(roundId);
        ShareToken token = ShareToken(round.targetShareClass);
        uint256 pricePerShare = round.pricePerShare;

        IFundraise.Investment[] memory investments = fundraise.getInvestments(roundId);
        for (uint256 i = 0; i < investments.length; i++) {
            if (investments[i].refunded) continue;
            uint256 shares = (investments[i].amount * 1e6) / pricePerShare;
            if (shares == 0) continue;
            _mint(token, investments[i].investor, shares, "Priced Round", documentRef);
            totalSharesIssued += shares;
        }
    }

    // ============ Joint conversion lifecycle ============

    /// @inheritdoc IEquityIssuance
    /// @dev Reverts with `TooManySafes` / `TooManyNotes` past the circuit's compile-time cap.
    function triggerConversion(
        uint256 pricePerShare,
        uint256 fullyDiluted,
        uint256 expiresAt,
        string calldata documentRef
    ) external onlyFundraise nonReentrant returns (uint256 conversionId) {
        if (pricePerShare == 0 || fullyDiluted == 0) revert ZeroAmount();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert InvalidExpiry();

        SAFE safeContract = SAFE(address(company.safe()));
        ConvertibleNote noteContract = ConvertibleNote(address(company.convertibleNote()));

        uint256[] memory safeIds = safeContract.getActiveSAFEs();
        uint256[] memory noteIds = noteContract.getActiveNotes();

        if (safeIds.length == 0 && noteIds.length == 0) revert NoActiveInstruments();
        if (safeIds.length > MAX_SAFES_PER_CONVERSION) revert TooManySafes();
        if (noteIds.length > MAX_NOTES_PER_CONVERSION) revert TooManyNotes();

        conversionId = conversionCount++;
        IEquityIssuance.Conversion storage batch = _conversions[conversionId];
        batch.conversionId = conversionId;
        batch.safeIds = safeIds;
        batch.noteIds = noteIds;
        batch.pricePerShare = pricePerShare;
        batch.fullyDiluted = fullyDiluted;
        batch.currentTime = block.timestamp;
        batch.requestedAt = block.timestamp;
        batch.expiresAt = expiresAt;
        batch.documentRef = documentRef;

        if (safeIds.length > 0) safeContract._markPendingConversion(conversionId, safeIds);
        if (noteIds.length > 0) noteContract._markPendingConversion(conversionId, noteIds);

        // idsHash is emitted only -- indexers use it to dedupe batch identity; it
        // is NOT stored, since the per-result `xxxId == batch.xxxIds[i]` check in
        // `conversionPublicInputs` already binds results to the locked-in id list.
        emit ConversionRequested(
            conversionId,
            keccak256(abi.encode(safeIds, noteIds)),
            safeIds.length,
            noteIds.length,
            pricePerShare,
            fullyDiluted,
            block.timestamp,
            expiresAt,
            documentRef
        );
    }

    /// @inheritdoc IEquityIssuance
    function applyConversion(
        uint256 conversionId,
        ISAFE.ConversionResult[] calldata safeResults,
        IConvertibleNote.ConversionResult[] calldata noteResults,
        bytes calldata proof,
        bytes calldata encryptedSharesMemo
    ) external nonReentrant returns (uint256 totalSharesIssued) {
        IEquityIssuance.Conversion storage batch = _conversions[conversionId];
        if (batch.safeIds.length == 0 && batch.noteIds.length == 0) revert InvalidConversion();
        if (batch.applied || batch.rolledBack) revert InvalidConversion();
        if (batch.expiresAt != 0 && block.timestamp > batch.expiresAt) revert ConversionExpired();
        if (address(conversionVerifier) == address(0)) revert InvalidVerifier();
        if (safeResults.length != batch.safeIds.length) revert InvalidConversion();
        if (noteResults.length != batch.noteIds.length) revert InvalidConversion();

        bytes32[] memory publicInputs = conversionPublicInputs(conversionId, safeResults, noteResults);
        if (!conversionVerifier.verify(proof, publicInputs)) revert InvalidConversionProof();

        batch.applied = true;

        SAFE safeContract = SAFE(address(company.safe()));
        ConvertibleNote noteContract = ConvertibleNote(address(company.convertibleNote()));

        // Phase 1: state flips. SAFE/CN return shares attested for the batch summary; no mint here.
        if (batch.safeIds.length > 0) {
            totalSharesIssued += safeContract._applyConversion(conversionId, safeResults, encryptedSharesMemo);
        }
        if (batch.noteIds.length > 0) {
            totalSharesIssued += noteContract._applyConversion(conversionId, noteResults, encryptedSharesMemo);
        }

        // Phase 2: mint via `_mint` so compliance runs per recipient.
        for (uint256 i = 0; i < safeResults.length; i++) {
            ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeResults[i].safeId);
            _mint(
                ShareToken(safe_.targetShareClass),
                safe_.investor,
                safeResults[i].sharesIssued,
                "SAFE conversion",
                batch.documentRef
            );
        }
        for (uint256 i = 0; i < noteResults.length; i++) {
            IConvertibleNote.NoteInstrument memory note = noteContract.getNote(noteResults[i].noteId);
            _mint(
                ShareToken(note.targetShareClass),
                note.investor,
                noteResults[i].sharesIssued,
                "Convertible Note conversion",
                batch.documentRef
            );
        }

        emit ConversionApplied(conversionId, totalSharesIssued);
    }

    /// @inheritdoc IEquityIssuance
    function rollbackConversion(uint256 conversionId) external nonReentrant {
        IEquityIssuance.Conversion storage batch = _conversions[conversionId];
        if (batch.safeIds.length == 0 && batch.noteIds.length == 0) revert InvalidConversion();
        if (batch.applied || batch.rolledBack) revert InvalidConversion();
        if (batch.expiresAt == 0 || block.timestamp <= batch.expiresAt) revert ConversionNotExpired();

        batch.rolledBack = true;
        _restoreInstruments(batch);
        emit ConversionRolledBack(conversionId);
    }

    /// @inheritdoc IEquityIssuance
    function cancelConversion(uint256 conversionId) external onlyBoard nonReentrant {
        IEquityIssuance.Conversion storage batch = _conversions[conversionId];
        if (batch.safeIds.length == 0 && batch.noteIds.length == 0) revert InvalidConversion();
        if (batch.applied || batch.rolledBack) revert InvalidConversion();

        batch.rolledBack = true;
        _restoreInstruments(batch);
        emit ConversionRolledBack(conversionId);
    }

    /// @inheritdoc IEquityIssuance
    function conversionPublicInputs(
        uint256 conversionId,
        ISAFE.ConversionResult[] memory safeResults,
        IConvertibleNote.ConversionResult[] memory noteResults
    ) public view returns (bytes32[] memory inputs) {
        IEquityIssuance.Conversion storage batch = _conversions[conversionId];
        if (batch.safeIds.length == 0 && batch.noteIds.length == 0) revert InvalidConversion();

        SAFE safeContract = SAFE(address(company.safe()));
        ConvertibleNote noteContract = ConvertibleNote(address(company.convertibleNote()));

        uint256 safeBase = 4;
        uint256 cnBase = 4 + 3 * MAX_SAFES_PER_CONVERSION;
        inputs = new bytes32[](4 + 3 * MAX_SAFES_PER_CONVERSION + 5 * MAX_NOTES_PER_CONVERSION);

        inputs[0] = bytes32(conversionId);
        inputs[1] = bytes32(batch.pricePerShare);
        inputs[2] = bytes32(batch.fullyDiluted);
        inputs[3] = bytes32(batch.currentTime);

        for (uint256 i = 0; i < batch.safeIds.length; i++) {
            ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(batch.safeIds[i]);
            if (safeResults[i].safeId != batch.safeIds[i]) revert InvalidConversion();
            inputs[safeBase + i] = safe_.termsCommitment;
            inputs[safeBase + MAX_SAFES_PER_CONVERSION + i] = bytes32(safeResults[i].sharesIssued);
            inputs[safeBase + 2 * MAX_SAFES_PER_CONVERSION + i] = safeResults[i].sharesCommitment;
        }

        for (uint256 i = 0; i < batch.noteIds.length; i++) {
            IConvertibleNote.NoteInstrument memory note = noteContract.getNote(batch.noteIds[i]);
            if (noteResults[i].noteId != batch.noteIds[i]) revert InvalidConversion();
            inputs[cnBase + i] = note.termsCommitment;
            inputs[cnBase + MAX_NOTES_PER_CONVERSION + i] = bytes32(note.issuedAt);
            inputs[cnBase + 2 * MAX_NOTES_PER_CONVERSION + i] = bytes32(note.maturityDate);
            inputs[cnBase + 3 * MAX_NOTES_PER_CONVERSION + i] = bytes32(noteResults[i].sharesIssued);
            inputs[cnBase + 4 * MAX_NOTES_PER_CONVERSION + i] = noteResults[i].sharesCommitment;
        }
    }

    /// @inheritdoc IEquityIssuance
    function getConversion(uint256 conversionId) external view returns (IEquityIssuance.Conversion memory batch) {
        batch = _conversions[conversionId];
        if (batch.safeIds.length == 0 && batch.noteIds.length == 0) revert InvalidConversion();
    }

    // ============ Internal ============

    function _restoreInstruments(IEquityIssuance.Conversion storage batch) private {
        SAFE safeContract = SAFE(address(company.safe()));
        ConvertibleNote noteContract = ConvertibleNote(address(company.convertibleNote()));
        if (batch.safeIds.length > 0) safeContract._rollbackConversion(batch.conversionId, batch.safeIds);
        if (batch.noteIds.length > 0) noteContract._rollbackConversion(batch.conversionId, batch.noteIds);
    }

    function _mint(ShareToken token, address to, uint256 amount, string memory purpose, string memory documentRef)
        private
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to == address(this)) revert NoOp();
        if (to == address(company)) revert NoOp();
        if (to == company.board()) revert NoOp();
        if (to == address(company.optionPool())) revert NoOp();
        if (to == address(company.safe())) revert NoOp();
        if (to == address(company.convertibleNote())) revert NoOp();
        if (to == address(company.fundraise())) revert NoOp();
        if (to == address(company.shareholderRegistry())) revert NoOp();
        if (to == address(token)) revert NoOp();

        _checkOptionPoolCapacity(token, amount);

        if (to != address(company.vestingSchedule())) {
            _checkInvestorCompliance(token, to, amount);
        }

        token.issueShares(to, amount);
        emit SharesIssued(token.name(), to, amount, purpose, documentRef);
    }

    function _checkOptionPoolCapacity(ShareToken token, uint256 amount) private view {
        OptionPool optionPool = company.optionPool();
        uint256 poolSize = optionPool.getPoolSize(address(token));
        uint256 outstandingOptions = optionPool.getOutstandingOptions(address(token));

        if (poolSize == 0 && outstandingOptions == 0) {
            return;
        }

        uint256 currentSupply = token.totalSupply();
        uint256 authorizedShares = token.authorizedShares();
        uint256 totalOptionCapacity = poolSize + outstandingOptions;
        if (currentSupply + amount + totalOptionCapacity > authorizedShares) {
            revert WouldConsumeOptionPoolCapacity();
        }
    }

    function _checkInvestorCompliance(ShareToken token, address investor, uint256 value) private view {
        try token.ruleEngine() returns (IRuleEngine ruleEngine) {
            if (address(ruleEngine) != address(0)) {
                uint8 restrictionCode =
                    IRuleEngineERC1404(address(ruleEngine)).detectTransferRestriction(address(0), investor, value);
                if (restrictionCode != 0) {
                    revert InvestorNotCompliant();
                }
            }
        } catch {
            // No rule engine = no rules.
        }
    }
}
