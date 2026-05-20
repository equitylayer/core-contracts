// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FHE, euint128, ebool, InEuint128, InEbool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ICompany} from "./interfaces/ICompany.sol";
import {IFundraise} from "./interfaces/IFundraise.sol";
import {IVault} from "./interfaces/IVault.sol";
import {ShareToken} from "./ShareToken.sol";
import {SAFE} from "./SAFE.sol";
import {ConvertibleNote, MAX_INTEREST_RATE_BPS} from "./ConvertibleNote.sol";
import "CMTAT/contracts/interfaces/engine/IRuleEngine.sol";

// Window for the joint conversion to be applied. After expiry rollback via FN.rollbackConversion().
uint256 constant CONVERSION_EXPIRY = 14 days;

/**
 * @title Fundraise
 * @notice Manages fundraising rounds: SAFE rounds and priced rounds (Series A, B, etc.)
 * @dev Supports three round types:
 *      - SAFE: Issues SAFEs that convert to shares later
 *      - Notes: Issues CNs that convert to shares later and have an interest
 *      - PRICED: Issues shares directly at a fixed price per share
 */
contract Fundraise is IFundraise, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "0.9.0";

    // --------------------
    // Structs
    // --------------------
    // `RoundStatus`, `RoundType`, `Round`, `Investment` are declared on IFundraise so
    // every consumer (this impl, EquityIssuance, mocks, indexers, tests) references
    // one canonical definition (`IFundraise.RoundType.X`). `Reservation` and
    // `RoundParams` are impl-internal and stay here.
    struct Reservation {
        address investor;
        uint256 amount;
        euint128 valuationCap;
        euint128 discountBps;
        ebool mfn;
        ebool proRata;
        bool useCustomTerms;
        bool paid;
    }

    // --------------------
    // State
    // --------------------
    ICompany public company;

    mapping(uint256 => Round) internal _rounds;
    mapping(uint256 => mapping(address => Reservation)) internal _reservations;
    mapping(uint256 => Investment[]) internal _investments;
    mapping(uint256 => mapping(address => uint256)) internal _investorTotalAmount; // roundId → investor → sum of non-refunded amounts
    mapping(uint256 => mapping(address => bool)) public roundWhitelist;
    mapping(uint256 => uint256[]) internal _roundSAFEIds; // roundId → issued safeIds (SAFE rounds)
    mapping(uint256 => uint256[]) internal _roundNoteIds; // roundId → issued noteIds (NOTE rounds)
    mapping(uint256 => uint256) internal _roundSharesIssued; // roundId → total shares issued (PRICED rounds)
    mapping(address => uint256) public pendingRefunds; // Pull pattern for failed refunds
    uint256 public roundCount;

    uint256 public qualifiedFinancingThreshold;
    uint256 public qualifyingRoundId; // Priced that met the threshold (type(uint256).max = none)
    bool public qualifiedFinancingOccurred;

    // --------------------
    // Errors
    // --------------------
    error OnlyBoard();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidStatus();
    error InvalidRoundId();
    error InvalidInvestmentIndex();
    error RoundNotOpen();
    error RoundNotClosed();
    error DeadlinePassed();
    error BelowMinInvestment();
    error ExceedsMaxInvestment();
    error InvestmentTooSmall();
    error ExceedsHardCap();
    error NotReserved();
    error AlreadyPaid();
    error AlreadyRefunded();
    error TransferFailed();
    error InvalidDiscountRate();
    error InvalidInterestRate();
    error InvalidShareClass();
    error InvestorNotCompliant();
    error InvalidInvestor();
    error ReservationAmountMismatch();
    error NotWhitelisted();
    error NoPendingRefund();
    error PricedRoundRequiresPrice();
    error InvalidRoundType();
    error NoOp();
    error ThresholdCanOnlyDecrease();

    // --------------------
    // Events
    // --------------------
    event RoundCreated(
        uint256 indexed roundId,
        string name,
        uint256 valuationCap,
        uint256 discountBps,
        uint256 hardCap,
        address targetShareClass,
        string documentRef
    );
    event ReservationCreated(uint256 indexed roundId, address indexed investor, uint256 amount, bool useCustomTerms);
    event InvestmentReceived(
        uint256 indexed roundId, address indexed investor, uint256 amount, uint256 investmentIndex, uint256 timestamp
    );

    event InvestmentRefunded(
        uint256 indexed roundId, address indexed investor, uint256 amount, uint256 investmentIndex
    );
    event RoundClosed(uint256 indexed roundId, uint256 totalRaised, uint256 investorCount, string documentRef);
    event RoundFinalized(
        uint256 indexed roundId, uint256 totalRaised, uint256 investorCount, uint256 safesIssued, string documentRef
    );
    event PricedRoundFinalized(
        uint256 indexed roundId,
        uint256 totalRaised,
        uint256 investorCount,
        uint256 totalSharesIssued,
        string documentRef
    );
    event NoteRoundFinalized(
        uint256 indexed roundId, uint256 totalRaised, uint256 investorCount, uint256 notesIssued, string documentRef
    );
    event RoundCancelled(uint256 indexed roundId, uint256 totalRefunded, string documentRef);
    event WhitelistUpdated(uint256 indexed roundId, address indexed investor, bool whitelisted);
    event RefundFailed(uint256 indexed roundId, address indexed investor, uint256 amount);
    event QualifiedFinancingThresholdSet(uint256 threshold);
    event QualifiedFinancingTriggered(uint256 indexed roundId, uint256 amountRaised);
    event RefundClaimed(address indexed investor, uint256 amount);

    // --------------------
    // Modifiers
    // --------------------
    modifier onlyBoard() {
        if (msg.sender != company.board()) revert OnlyBoard();
        _;
    }

    // --------------------
    function initialize(address _company) external initializer {
        if (_company == address(0)) revert ZeroAddress();
        company = ICompany(_company);
        qualifyingRoundId = type(uint256).max; // No qualifying round yet
    }

    // --------------------
    // Round Management
    // --------------------

    /// @inheritdoc IFundraise
    function createRound(RoundParams calldata params) external onlyBoard returns (uint256 roundId) {
        if (params.targetShareClass == address(0)) revert ZeroAddress();
        if (params.maxInvestment > 0 && params.minInvestment > params.maxInvestment) revert InvalidStatus();

        if (params.roundType == RoundType.PRICED) {
            if (params.pricePerShare == 0) revert PricedRoundRequiresPrice();
            // PRICED rounds must not have SAFE/NOTE-specific params
            if (params.discountBps != 0 || params.valuationCap != 0) revert NoOp();
            if (params.interestRateBps != 0 || params.maturityDuration != 0) revert NoOp();
        } else if (params.roundType == RoundType.SAFE) {
            // SAFE rounds must not have pricePerShare or NOTE-specific params
            if (params.pricePerShare != 0) revert NoOp();
            if (params.interestRateBps != 0 || params.maturityDuration != 0) revert NoOp();
            if (params.discountBps > 9900) revert InvalidDiscountRate();
        } else {
            // CONVERTIBLE_NOTE rounds
            if (params.pricePerShare != 0) revert NoOp();
            if (params.discountBps > 9900) revert InvalidDiscountRate();
            if (params.maturityDuration == 0) revert ZeroAmount();
            if (params.interestRateBps > MAX_INTEREST_RATE_BPS) revert InvalidInterestRate();
        }

        // Validate share class belongs to this company
        try ShareToken(params.targetShareClass).companyAddress() returns (address tokenCompany) {
            if (tokenCompany != address(company)) revert InvalidShareClass();
        } catch {
            revert InvalidShareClass();
        }

        roundId = roundCount++;
        _rounds[roundId] = Round({
            name: params.name,
            roundType: params.roundType,
            valuationCap: params.valuationCap,
            discountBps: params.discountBps,
            pricePerShare: params.pricePerShare,
            interestRateBps: params.interestRateBps,
            maturityDuration: params.maturityDuration,
            allowEarlyRepayment: params.allowEarlyRepayment,
            mfn: params.mfn,
            proRata: params.proRata,
            whitelistOnly: params.whitelistOnly,
            documentRef: params.documentRef,
            minInvestment: params.minInvestment,
            maxInvestment: params.maxInvestment,
            targetRaise: params.targetRaise,
            hardCap: params.hardCap,
            deadline: params.deadline,
            totalRaised: 0,
            investorCount: 0,
            status: RoundStatus.OPEN,
            targetShareClass: params.targetShareClass,
            eTotalRaised: FHE.asEuint128(0)
        });
        FHE.allowThis(_rounds[roundId].eTotalRaised);
        FHE.allow(_rounds[roundId].eTotalRaised, company.board());
        FHE.allow(_rounds[roundId].eTotalRaised, company.operator());

        emit RoundCreated(
            roundId,
            params.name,
            params.valuationCap,
            params.discountBps,
            params.hardCap,
            params.targetShareClass,
            params.documentRef
        );
    }

    /// @inheritdoc IFundraise
    function closeRound(uint256 roundId) external onlyBoard {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.OPEN) revert RoundNotOpen();

        round.status = RoundStatus.CLOSED;

        emit RoundClosed(roundId, round.totalRaised, round.investorCount, round.documentRef);
    }

    // --------------------
    // Qualified Financing
    // --------------------

    /// @inheritdoc IFundraise
    function setQFT(uint256 threshold) external onlyBoard {
        // Check if any active SAFEs or Notes exist
        SAFE safeContract = SAFE(address(company.safe()));
        ConvertibleNote noteContract = ConvertibleNote(address(company.convertibleNote()));

        bool hasSAFEs = safeContract.getOutstandingSAFECount() > 0;
        bool hasNotes = noteContract.getOutstandingNoteCount() > 0;

        // No SAFEs or Notes yet = full flexibility
        if (!hasSAFEs && !hasNotes) {
            qualifiedFinancingThreshold = threshold;
            emit QualifiedFinancingThresholdSet(threshold);
            return;
        }

        // SAFEs or Notes exist = can only decrease (protects investors from board raising the bar)
        if (threshold > qualifiedFinancingThreshold) {
            revert ThresholdCanOnlyDecrease();
        }
        qualifiedFinancingThreshold = threshold;
        emit QualifiedFinancingThresholdSet(threshold);
    }

    /// @inheritdoc IFundraise
    function setDocumentRef(uint256 roundId, string calldata ref) external onlyBoard {
        if (roundId >= roundCount) revert InvalidRoundId();
        _rounds[roundId].documentRef = ref;
    }

    /// @inheritdoc IFundraise
    function finalizeRound(uint256 roundId) external onlyBoard nonReentrant {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.CLOSED) revert RoundNotClosed();

        round.status = RoundStatus.FINALIZED;

        if (round.roundType == RoundType.PRICED) {
            _finalizePricedRound(roundId, round);
        } else if (round.roundType == RoundType.SAFE) {
            _finalizeSafeRound(roundId, round);
        } else {
            _finalizeNoteRound(roundId, round);
        }

        if (round.totalRaised > 0) {
            IVault vault = company.vault();
            IERC20 token = company.paymentToken();
            token.forceApprove(address(vault), round.totalRaised);
            vault.depositToken(address(token), round.totalRaised);
        }
    }

    /**
     * @notice Internal: Finalize a SAFE round by issuing SAFEs
     * @param roundId The round ID
     * @param round The round storage reference
     */
    function _finalizeSafeRound(uint256 roundId, Round storage round) internal {
        SAFE safeContract = SAFE(address(company.safe()));
        Investment[] storage investments = _investments[roundId];
        uint256 len = investments.length;
        uint256 safesIssued = 0;

        // Cache values accessed in loop
        address targetShareClass = round.targetShareClass;
        string memory documentRef = round.documentRef;

        for (uint256 i = 0; i < len; i++) {
            Investment storage investment = investments[i];
            if (!investment.refunded) {
                FHE.allow(investment.eAmount, address(safeContract));
                FHE.allow(investment.valuationCap, address(safeContract));
                FHE.allow(investment.discountBps, address(safeContract));
                FHE.allow(investment.mfn, address(safeContract));
                FHE.allow(investment.proRata, address(safeContract));
                FHE.allow(investment.salt, address(safeContract));

                uint256 safeId = safeContract.issueSAFEFromFundraise(
                    investment.investor,
                    investment.termsCommitment,
                    investment.eAmount,
                    investment.valuationCap,
                    investment.discountBps,
                    investment.mfn,
                    investment.proRata,
                    investment.salt,
                    targetShareClass,
                    documentRef,
                    ""
                );
                _roundSAFEIds[roundId].push(safeId);
                safesIssued++;
            }
        }

        emit RoundFinalized(roundId, round.totalRaised, round.investorCount, safesIssued, round.documentRef);
    }

    /**
     * @notice Internal: Finalize a CONVERTIBLE_NOTE round by issuing Notes
     * @param roundId The round ID
     * @param round The round storage reference
     */
    function _finalizeNoteRound(uint256 roundId, Round storage round) internal {
        ConvertibleNote noteContract = ConvertibleNote(address(company.convertibleNote()));
        Investment[] storage investments = _investments[roundId];
        uint256 len = investments.length;
        uint256 notesIssued = 0;

        // Cache values accessed in loop
        address targetShareClass = round.targetShareClass;
        string memory documentRef = round.documentRef;
        uint256 interestRateBps = round.interestRateBps;
        uint256 maturityDuration = round.maturityDuration;

        // CN-specific: encrypt the round-level interest rate once (it's the same for every
        // Note in this round). Plaintext on Round, encrypted at the boundary into CN.
        euint128 encRate = FHE.asEuint128(uint128(interestRateBps));
        FHE.allowThis(encRate);
        FHE.allow(encRate, address(noteContract));

        for (uint256 i = 0; i < len; i++) {
            Investment storage investment = investments[i];
            if (!investment.refunded) {
                uint256 maturityDate = investment.timestamp + maturityDuration;

                // Grant CN contract access to the ciphertexts so it can re-grant via allowThis().
                FHE.allow(investment.eAmount, address(noteContract));
                FHE.allow(investment.valuationCap, address(noteContract));
                FHE.allow(investment.discountBps, address(noteContract));
                FHE.allow(investment.salt, address(noteContract));

                uint256 noteId = noteContract.issueNoteFromFundraise(
                    investment.investor,
                    investment.termsCommitment,
                    investment.eAmount,
                    encRate,
                    investment.valuationCap,
                    investment.discountBps,
                    investment.salt,
                    targetShareClass,
                    investment.timestamp,
                    maturityDate,
                    round.allowEarlyRepayment,
                    documentRef,
                    ""
                );
                _roundNoteIds[roundId].push(noteId);
                notesIssued++;
            }
        }

        emit NoteRoundFinalized(roundId, round.totalRaised, round.investorCount, notesIssued, round.documentRef);
    }

    /**
     * @notice Internal: Finalize a PRICED round by issuing shares directly
     * @param roundId The round ID
     * @param round The round storage reference
     * @dev Order: 1) Check qualified financing, 2) Auto-convert SAFEs/Notes, 3) Issue shares
     * @dev SAFEs and Notes convert at pre-money valuation (before new shares issued)
     */
    function _finalizePricedRound(uint256 roundId, Round storage round) internal {
        uint256 pricePerShare = round.pricePerShare;
        uint256 totalSharesOutstanding = company.getFullyDilutedShares();

        bool isQualified = round.totalRaised >= qualifiedFinancingThreshold;
        if (isQualified && !qualifiedFinancingOccurred) {
            qualifyingRoundId = roundId;
            qualifiedFinancingOccurred = true;
            emit QualifiedFinancingTriggered(roundId, round.totalRaised);
        }

        if (isQualified) {
            uint256 activeSafes = SAFE(address(company.safe())).getActiveSAFECount();
            uint256 activeNotes = ConvertibleNote(address(company.convertibleNote())).getActiveNoteCount();
            if (activeSafes > 0 || activeNotes > 0) {
                company.issuance()
                    .triggerConversion(
                        pricePerShare, totalSharesOutstanding, block.timestamp + CONVERSION_EXPIRY, round.documentRef
                    );
            }
        }

        // Mint priced-round shares via EquityIssuance (compliance + capacity enforced there).
        uint256 pricedSharesIssued = company.issuance().issueFromPricedRound(roundId, round.documentRef);
        _roundSharesIssued[roundId] = pricedSharesIssued;

        emit PricedRoundFinalized(
            roundId, round.totalRaised, round.investorCount, pricedSharesIssued, round.documentRef
        );
    }

    /// @inheritdoc IFundraise
    function triggerConversions(
        uint256 pricePerShare,
        uint256 fullyDiluted,
        uint256 expiresAt,
        string calldata documentRef
    ) external onlyBoard nonReentrant returns (uint256 conversionId) {
        return company.issuance().triggerConversion(pricePerShare, fullyDiluted, expiresAt, documentRef);
    }

    /// @inheritdoc IFundraise
    function cancelRound(uint256 roundId) external onlyBoard nonReentrant {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status == RoundStatus.FINALIZED || round.status == RoundStatus.CANCELLED) {
            revert InvalidStatus();
        }

        round.status = RoundStatus.CANCELLED;

        Investment[] storage investments = _investments[roundId];
        uint256 totalRefunded = 0;
        IERC20 token = company.paymentToken();

        for (uint256 i = 0; i < investments.length; i++) {
            Investment storage investment = investments[i];
            if (!investment.refunded) {
                investment.refunded = true;
                _investorTotalAmount[roundId][investment.investor] = 0;
                _reduceAmountsOnRefund(round, investment);
                try token.transfer(investment.investor, investment.amount) returns (bool success) {
                    if (!success) {
                        pendingRefunds[investment.investor] += investment.amount;
                        emit RefundFailed(roundId, investment.investor, investment.amount);
                    } else {
                        totalRefunded += investment.amount;
                    }
                } catch {
                    pendingRefunds[investment.investor] += investment.amount;
                    emit RefundFailed(roundId, investment.investor, investment.amount);
                }
            }
        }

        round.totalRaised = 0;
        round.investorCount = 0;
        // Force the encrypted total to a fresh encrypted zero. (Per-investment
        // mirrors above already subtracted; this is a defensive reset.)
        round.eTotalRaised = FHE.asEuint128(0);
        FHE.allowThis(round.eTotalRaised);
        FHE.allow(round.eTotalRaised, company.board());
        FHE.allow(round.eTotalRaised, company.operator());

        emit RoundCancelled(roundId, totalRefunded, round.documentRef);
    }

    /// @inheritdoc IFundraise
    function reserveSpot(
        uint256 roundId,
        address investor,
        uint256 amount,
        InEuint128 calldata valuationCap,
        InEuint128 calldata discountBps,
        InEbool calldata mfn,
        InEbool calldata proRata,
        bool useCustomTerms
    ) external onlyBoard {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.OPEN) revert RoundNotOpen();
        if (investor == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_reservations[roundId][investor].paid) revert AlreadyPaid();

        euint128 eCap = FHE.asEuint128(valuationCap);
        euint128 eDisc = FHE.asEuint128(discountBps);
        ebool eMfn = FHE.asEbool(mfn);
        ebool eProRata = FHE.asEbool(proRata);

        _reservations[roundId][investor] = Reservation({
            investor: investor,
            amount: amount,
            valuationCap: eCap,
            discountBps: eDisc,
            mfn: eMfn,
            proRata: eProRata,
            useCustomTerms: useCustomTerms,
            paid: false
        });

        // Grant viewing rights to investor / board / operator on each ciphertext.
        Reservation storage stored = _reservations[roundId][investor];
        _grantAllReservationTerms(stored, investor, company.board(), company.operator());

        emit ReservationCreated(roundId, investor, amount, useCustomTerms);
    }

    /// @inheritdoc IFundraise
    function invest(uint256 roundId, uint256 amount, bytes32 termsCommitment, InEuint128 calldata termsSalt)
        external
        nonReentrant
    {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.OPEN) revert RoundNotOpen();
        if (round.deadline > 0 && block.timestamp > round.deadline) revert DeadlinePassed();
        if (amount == 0) revert ZeroAmount();
        _assertInvestorAllowed(msg.sender, round.targetShareClass);

        Reservation storage reservation = _reservations[roundId][msg.sender];
        bool isReservedInvestor = reservation.investor != address(0);

        // NOTE: reservations bypass whitelist check.
        if (round.whitelistOnly && !isReservedInvestor && !roundWhitelist[roundId][msg.sender]) {
            revert NotWhitelisted();
        }

        uint256 investAmount = amount;
        uint256 priorTotal = _investorTotalAmount[roundId][msg.sender];

        if (isReservedInvestor) {
            // Reserved: Pays exact amount and not already paid. One SAFE/Note per reservation.
            if (reservation.paid) revert AlreadyPaid();
            if (investAmount != reservation.amount) revert ReservationAmountMismatch();
            reservation.paid = true;
        } else {
            // Regular investor: per-invest min, cumulative max.
            if (round.minInvestment > 0 && investAmount < round.minInvestment) revert BelowMinInvestment();
            if (round.maxInvestment > 0 && priorTotal + investAmount > round.maxInvestment) {
                revert ExceedsMaxInvestment();
            }
        }

        if (round.hardCap > 0 && round.totalRaised + investAmount > round.hardCap) {
            revert ExceedsHardCap();
        }

        // Refund paths mirror these reductions via _reduceAmountsOnRefund.
        euint128 eInvestAmount = FHE.asEuint128(uint128(investAmount));
        FHE.allowThis(eInvestAmount);
        FHE.allow(eInvestAmount, msg.sender);
        FHE.allow(eInvestAmount, company.board());
        FHE.allow(eInvestAmount, company.operator());

        uint256 complianceCheckSharesAllocated = 1;
        if (round.roundType == RoundType.PRICED) {
            uint256 wouldGetShares = (investAmount * 1e6) / round.pricePerShare;
            if (wouldGetShares == 0) revert InvestmentTooSmall();
            complianceCheckSharesAllocated = wouldGetShares;
        }

        _checkInvestorCompliance(round.targetShareClass, msg.sender, complianceCheckSharesAllocated);

        round.totalRaised += investAmount;
        round.eTotalRaised = FHE.add(round.eTotalRaised, eInvestAmount);
        FHE.allowThis(round.eTotalRaised);
        FHE.allow(round.eTotalRaised, company.board());
        FHE.allow(round.eTotalRaised, company.operator());

        if (priorTotal == 0) {
            round.investorCount++;
        }
        _investorTotalAmount[roundId][msg.sender] = priorTotal + investAmount;

        euint128 invCap;
        euint128 invDisc;
        ebool invMfn;
        ebool invProRata;
        if (isReservedInvestor && reservation.useCustomTerms) {
            invCap = reservation.valuationCap;
            invDisc = reservation.discountBps;
            invMfn = reservation.mfn;
            invProRata = reservation.proRata;
        } else {
            invCap = FHE.asEuint128(uint128(round.valuationCap));
            invDisc = FHE.asEuint128(uint128(round.discountBps));
            invMfn = FHE.asEbool(round.mfn);
            invProRata = FHE.asEbool(round.proRata);
        }

        euint128 eTermsSalt = FHE.asEuint128(termsSalt);

        uint256 investmentIndex = _investments[roundId].length;
        _investments[roundId].push(
            Investment({
                investor: msg.sender,
                amount: investAmount,
                timestamp: block.timestamp,
                refunded: false,
                eAmount: eInvestAmount,
                valuationCap: invCap,
                discountBps: invDisc,
                mfn: invMfn,
                proRata: invProRata,
                termsCommitment: termsCommitment,
                salt: eTermsSalt
            })
        );

        // Grant FHE viewing rights on the per-investor terms ciphertexts.
        Investment storage stored = _investments[roundId][investmentIndex];
        _grantAllInvestmentTerms(stored, msg.sender, company.board(), company.operator());

        company.paymentToken().safeTransferFrom(msg.sender, address(this), investAmount);

        emit InvestmentReceived(roundId, msg.sender, investAmount, investmentIndex, block.timestamp);
    }

    /// @inheritdoc IFundraise
    function refundInvestment(uint256 roundId, uint256 idx) external onlyBoard nonReentrant {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status == RoundStatus.FINALIZED || round.status == RoundStatus.CANCELLED) {
            revert InvalidStatus();
        }
        if (idx >= _investments[roundId].length) revert InvalidInvestmentIndex();

        Investment storage investment = _investments[roundId][idx];
        if (investment.refunded) revert AlreadyRefunded();

        investment.refunded = true;
        round.totalRaised -= investment.amount;

        uint256 newTotal = _investorTotalAmount[roundId][investment.investor] - investment.amount;
        _investorTotalAmount[roundId][investment.investor] = newTotal;
        if (newTotal == 0) {
            round.investorCount--;
        }

        _reduceAmountsOnRefund(round, investment);

        Reservation storage reservation = _reservations[roundId][investment.investor];
        if (reservation.investor != address(0) && reservation.paid) {
            reservation.paid = false;
        }

        try company.paymentToken().transfer(investment.investor, investment.amount) returns (bool success) {
            if (!success) {
                pendingRefunds[investment.investor] += investment.amount;
                emit RefundFailed(roundId, investment.investor, investment.amount);
            } else {
                emit InvestmentRefunded(roundId, investment.investor, investment.amount, idx);
            }
        } catch {
            pendingRefunds[investment.investor] += investment.amount;
            emit RefundFailed(roundId, investment.investor, investment.amount);
        }
    }

    /// @inheritdoc IFundraise
    function claimRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        if (amount == 0) revert NoPendingRefund();

        pendingRefunds[msg.sender] = 0;

        company.paymentToken().safeTransfer(msg.sender, amount);

        emit RefundClaimed(msg.sender, amount);
    }

    // --------------------
    // Whitelist Management
    // --------------------

    /// @inheritdoc IFundraise
    function addToWhitelist(uint256 roundId, address[] calldata investors) external onlyBoard {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.OPEN) revert RoundNotOpen();

        for (uint256 i = 0; i < investors.length; i++) {
            if (investors[i] != address(0)) {
                roundWhitelist[roundId][investors[i]] = true;
                emit WhitelistUpdated(roundId, investors[i], true);
            }
        }
    }

    /// @inheritdoc IFundraise
    function removeFromWhitelist(uint256 roundId, address[] calldata investors) external onlyBoard {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.OPEN) revert RoundNotOpen();

        for (uint256 i = 0; i < investors.length; i++) {
            if (investors[i] != address(0)) {
                roundWhitelist[roundId][investors[i]] = false;
                emit WhitelistUpdated(roundId, investors[i], false);
            }
        }
    }

    // --------------------
    // Internal Functions
    // --------------------

    /**
     * @notice Mirror a plaintext refund on the encrypted state.
     */
    function _reduceAmountsOnRefund(Round storage round, Investment storage investment) internal {
        round.eTotalRaised = FHE.sub(round.eTotalRaised, investment.eAmount);
        FHE.allowThis(round.eTotalRaised);
        FHE.allow(round.eTotalRaised, company.board());
        FHE.allow(round.eTotalRaised, company.operator());

        investment.eAmount = FHE.asEuint128(0);
        FHE.allowThis(investment.eAmount);
        FHE.allow(investment.eAmount, investment.investor);
        FHE.allow(investment.eAmount, company.board());
        FHE.allow(investment.eAmount, company.operator());
    }

    /// @notice Reject investments from system addresses
    function _assertInvestorAllowed(address investor, address targetShareClass) internal view {
        if (investor == address(this)) revert InvalidInvestor();
        if (investor == address(company)) revert InvalidInvestor();
        if (investor == company.board()) revert InvalidInvestor();
        if (investor == address(company.optionPool())) revert InvalidInvestor();
        if (investor == address(company.safe())) revert InvalidInvestor();
        if (investor == address(company.convertibleNote())) revert InvalidInvestor();
        if (investor == address(company.vault())) revert InvalidInvestor();
        if (investor == targetShareClass) revert InvalidInvestor();
    }

    /**
     * @notice Validate investor against RuleEngine
     * @param targetShareClass The share class to check against
     * @param investor The investor address
     * @param value Representative share amount for compliance checks
     */
    function _checkInvestorCompliance(address targetShareClass, address investor, uint256 value) internal view {
        ShareToken token = ShareToken(targetShareClass);

        try token.ruleEngine() returns (IRuleEngine ruleEngine) {
            if (address(ruleEngine) != address(0)) {
                // Check if transfer from zero address (minting) to investor is allowed
                // detectTransferRestriction returns 0 if transfer is allowed
                uint8 restrictionCode =
                    IRuleEngineERC1404(address(ruleEngine)).detectTransferRestriction(address(0), investor, value);
                if (restrictionCode != 0) {
                    revert InvestorNotCompliant();
                }
            }
        } catch {
            // If ruleEngine() fails, assume no rules (legacy compatibility)
        }
    }

    // --------------------
    // View Functions
    // --------------------

    /// @inheritdoc IFundraise
    function getRound(uint256 roundId) external view returns (Round memory) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _rounds[roundId];
    }

    /// @inheritdoc IFundraise
    function getInvestments(uint256 roundId) external view returns (Investment[] memory) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _investments[roundId];
    }

    /// @inheritdoc IFundraise
    function getRoundSAFEIds(uint256 roundId) external view returns (uint256[] memory) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _roundSAFEIds[roundId];
    }

    /// @inheritdoc IFundraise
    function getRoundNoteIds(uint256 roundId) external view returns (uint256[] memory) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _roundNoteIds[roundId];
    }

    /// @inheritdoc IFundraise
    function getRoundSharesIssued(uint256 roundId) external view returns (uint256) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _roundSharesIssued[roundId];
    }

    /// @inheritdoc IFundraise
    function getInvestment(uint256 roundId, uint256 investmentIndex) external view returns (Investment memory) {
        if (roundId >= roundCount) revert InvalidRoundId();
        if (investmentIndex >= _investments[roundId].length) revert InvalidInvestmentIndex();
        return _investments[roundId][investmentIndex];
    }

    /**
     * @notice Get reservation for an investor
     * @param roundId The round ID
     * @param investor The investor address
     * @return reservation The reservation data
     */
    function getReservation(uint256 roundId, address investor) external view returns (Reservation memory) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _reservations[roundId][investor];
    }

    /// @inheritdoc IFundraise
    function getInvestorTotal(uint256 roundId, address investor) external view returns (uint256) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _investorTotalAmount[roundId][investor];
    }

    /// @inheritdoc IFundraise
    function getInvestmentCount(uint256 roundId) external view returns (uint256) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return _investments[roundId].length;
    }

    /// @inheritdoc IFundraise
    function isWhitelisted(uint256 roundId, address investor) external view returns (bool) {
        if (roundId >= roundCount) revert InvalidRoundId();
        return roundWhitelist[roundId][investor];
    }

    /// @inheritdoc IFundraise
    function canInvest(uint256 roundId, address investor) external view returns (bool) {
        if (roundId >= roundCount) revert InvalidRoundId();
        Round storage round = _rounds[roundId];

        if (round.status != RoundStatus.OPEN) return false;
        if (round.deadline > 0 && block.timestamp > round.deadline) return false;
        if (!round.whitelistOnly) return true;
        if (_reservations[roundId][investor].investor != address(0)) return true;

        return roundWhitelist[roundId][investor];
    }

    // ============ FHE grant helpers ============

    /// @dev Grant viewing rights on every encrypted field of `r` to (a, b, c).
    function _grantAllReservationTerms(Reservation storage r, address a, address b, address c) private {
        _grantAll(r.valuationCap, a, b, c);
        _grantAll(r.discountBps, a, b, c);
        _grantAll(r.mfn, a, b, c);
        _grantAll(r.proRata, a, b, c);
    }

    /// @dev Grant viewing rights on every encrypted field of `inv` to (a, b, c). Excludes `eAmount`
    ///      which is granted separately at the boundary alongside totals.
    function _grantAllInvestmentTerms(Investment storage inv, address a, address b, address c) private {
        _grantAll(inv.valuationCap, a, b, c);
        _grantAll(inv.discountBps, a, b, c);
        _grantAll(inv.mfn, a, b, c);
        _grantAll(inv.proRata, a, b, c);
        _grantAll(inv.salt, a, b, c);
    }

    /// @dev `FHE.allowThis(h)` + `FHE.allow(h, x)` for three grantees. One per FHE type.
    function _grantAll(euint128 h, address a, address b, address c) private {
        FHE.allowThis(h);
        FHE.allow(h, a);
        FHE.allow(h, b);
        FHE.allow(h, c);
    }

    function _grantAll(ebool h, address a, address b, address c) private {
        FHE.allowThis(h);
        FHE.allow(h, a);
        FHE.allow(h, b);
        FHE.allow(h, c);
    }
}
