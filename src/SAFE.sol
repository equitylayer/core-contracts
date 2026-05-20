// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FHE, euint128, ebool, InEuint128, InEbool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ICompany} from "./interfaces/ICompany.sol";
import {IFundraise} from "./interfaces/IFundraise.sol";
import {ISAFE} from "./interfaces/ISAFE.sol";
import {IEquityIssuance} from "./interfaces/IEquityIssuance.sol";
import {ShareToken} from "./ShareToken.sol";

/**
 * @title SAFE
 * @notice Manages SAFE (Simple Agreement for Future Equity) instruments using term commitments.
 */
contract SAFE is ISAFE, Initializable, ReentrancyGuard {
    string public constant VERSION = "0.10.0";

    ICompany public company;
    IFundraise public fundraise;
    IEquityIssuance public issuance;

    mapping(uint256 => SAFEInstrument) public safes;
    mapping(address => uint256[]) public investorSAFEs;
    uint256 public safeCount;
    uint256[] private activeSAFEIds;
    mapping(uint256 => uint256) private safeIdToIndex;

    // Custom errors
    error OnlyBoard();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidSAFEId();
    error NotActive();
    error NoSharesIssued();
    error InvalidShareClass();
    error OnlyFundraise();
    error OnlyIssuance();
    error NoQualifiedFinancing();
    error InvalidIssuedAt();
    error InvalidCommitment();
    error InvalidConversion();

    // Events. Sensitive payloads (terms, share counts) live in `encryptedMemo` blobs intended
    // to be ECIES-encrypted to (investor, company viewing key) by the off-chain producer.
    event SAFEIssued(
        uint256 indexed safeId,
        address indexed investor,
        bytes32 indexed termsCommitment,
        address targetShareClass,
        uint256 timestamp,
        string documentRef,
        bytes encryptedMemo
    );
    event SAFEConverted(
        uint256 indexed conversionId,
        uint256 indexed safeId,
        address indexed investor,
        bytes32 sharesCommitment,
        bytes encryptedSharesMemo
    );
    event SAFECancelled(uint256 indexed safeId, uint256 timestamp, string documentRef);

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

    function initialize(address _company, address _fundraise, address _issuance) external initializer {
        if (_company == address(0)) revert ZeroAddress();
        if (_fundraise == address(0)) revert ZeroAddress();
        if (_issuance == address(0)) revert ZeroAddress();
        company = ICompany(_company);
        fundraise = IFundraise(_fundraise);
        issuance = IEquityIssuance(_issuance);
    }

    /// @inheritdoc ISAFE
    function canConvertSAFEs() public view returns (bool) {
        uint256 threshold = fundraise.qualifiedFinancingThreshold();
        bool occurred = fundraise.qualifiedFinancingOccurred();
        if (threshold == 0) return true;
        return occurred;
    }

    // ============ Issuance ============

    /// @inheritdoc ISAFE
    function issueSAFE(
        address investor,
        bytes32 termsCommitment,
        TermsCiphertext calldata terms,
        InEuint128 calldata salt,
        address targetShareClass,
        string calldata documentRef,
        uint256 issuedAt,
        bytes calldata encryptedMemo
    ) external onlyBoard nonReentrant returns (uint256 safeId) {
        if (issuedAt == 0 || issuedAt > block.timestamp) revert InvalidIssuedAt();

        IssueSAFEParams memory p;
        p.investor = investor;
        p.termsCommitment = termsCommitment;
        p.inv = FHE.asEuint128(terms.investmentAmount);
        p.cap = FHE.asEuint128(terms.valuationCap);
        p.disc = FHE.asEuint128(terms.discountBps);
        p.mfn = FHE.asEbool(terms.mfn);
        p.proRata = FHE.asEbool(terms.proRata);
        p.salt = FHE.asEuint128(salt);
        p.targetShareClass = targetShareClass;
        p.issuedAt = issuedAt;
        p.documentRef = documentRef;
        p.encryptedMemo = encryptedMemo;
        return _issueSAFE(p);
    }

    /// @inheritdoc ISAFE
    function issueSAFEFromFundraise(
        address investor,
        bytes32 termsCommitment,
        euint128 inv,
        euint128 cap,
        euint128 disc,
        ebool mfn,
        ebool proRata,
        euint128 salt,
        address targetShareClass,
        string calldata documentRef,
        bytes calldata encryptedMemo
    ) external onlyFundraise nonReentrant returns (uint256 safeId) {
        IssueSAFEParams memory p;
        p.investor = investor;
        p.termsCommitment = termsCommitment;
        p.inv = inv;
        p.cap = cap;
        p.disc = disc;
        p.mfn = mfn;
        p.proRata = proRata;
        p.salt = salt;
        p.targetShareClass = targetShareClass;
        p.issuedAt = block.timestamp;
        p.documentRef = documentRef;
        p.encryptedMemo = encryptedMemo;
        return _issueSAFE(p);
    }

    /// @inheritdoc ISAFE
    function cancelSAFE(uint256 safeId, string calldata documentRef) external onlyBoard nonReentrant {
        SAFEInstrument storage safe_ = safes[safeId];
        if (safe_.termsCommitment == bytes32(0)) revert InvalidSAFEId();
        if (safe_.status != Status.Active) revert NotActive();

        safe_.status = Status.Cancelled;
        _removeSAFE(safeId);

        emit SAFECancelled(safeId, block.timestamp, documentRef);
    }

    // ============ Conversion ============

    /// @inheritdoc ISAFE
    function _markPendingConversion(uint256 conversionId, uint256[] calldata safeIds) external onlyIssuance {
        for (uint256 i = 0; i < safeIds.length; i++) {
            uint256 safeId = safeIds[i];
            SAFEInstrument storage safe_ = safes[safeId];
            if (safe_.status != Status.Active) revert InvalidConversion();
            safe_.status = Status.PendingConversion;
            safe_.conversionId = conversionId;
        }
    }

    /// @inheritdoc ISAFE
    function _applyConversion(
        uint256 conversionId,
        ConversionResult[] calldata results,
        bytes calldata encryptedSharesMemo
    ) external onlyIssuance nonReentrant returns (uint256 totalSharesIssued) {
        for (uint256 i = 0; i < results.length; i++) {
            uint256 safeId = results[i].safeId;
            SAFEInstrument storage safe_ = safes[safeId];
            if (safe_.status != Status.PendingConversion || safe_.conversionId != conversionId) {
                revert InvalidConversion();
            }
            if (results[i].sharesIssued == 0) revert NoSharesIssued();
            if (results[i].sharesCommitment == bytes32(0)) revert InvalidCommitment();

            safe_.status = Status.Converted;
            safe_.convertedAt = block.timestamp;
            safe_.sharesIssued = results[i].sharesIssued;
            safe_.sharesCommitment = results[i].sharesCommitment;

            _removeSAFE(safeId);

            emit SAFEConverted(conversionId, safeId, safe_.investor, results[i].sharesCommitment, encryptedSharesMemo);
            totalSharesIssued += results[i].sharesIssued;
        }
    }

    /// @inheritdoc ISAFE
    function _rollbackConversion(uint256 conversionId, uint256[] calldata safeIds) external onlyIssuance {
        for (uint256 i = 0; i < safeIds.length; i++) {
            uint256 safeId = safeIds[i];
            SAFEInstrument storage safe_ = safes[safeId];
            if (safe_.status != Status.PendingConversion || safe_.conversionId != conversionId) continue;
            safe_.status = Status.Active;
            safe_.conversionId = 0;
        }
    }

    // ============ Internal ============

    function _issueSAFE(IssueSAFEParams memory p) private returns (uint256 safeId) {
        if (p.investor == address(0)) revert ZeroAddress();
        if (p.targetShareClass == address(0)) revert ZeroAddress();
        if (p.termsCommitment == bytes32(0)) revert InvalidCommitment();

        try ShareToken(p.targetShareClass).companyAddress() returns (address tokenCompany) {
            if (tokenCompany != address(company)) revert InvalidShareClass();
        } catch {
            revert InvalidShareClass();
        }

        safeId = safeCount++;

        SAFEInstrument storage safe_ = safes[safeId];
        safe_.safeId = safeId;
        safe_.investor = p.investor;
        safe_.status = Status.Active;
        safe_.termsCommitment = p.termsCommitment;
        safe_.targetShareClass = p.targetShareClass;
        safe_.issuedAt = p.issuedAt;
        safe_.documentRef = p.documentRef;
        safe_.inv = p.inv;
        safe_.cap = p.cap;
        safe_.disc = p.disc;
        safe_.mfn = p.mfn;
        safe_.proRata = p.proRata;
        safe_.salt = p.salt;

        _grantAllTerms(safe_, p.investor, company.board(), company.operator());

        investorSAFEs[p.investor].push(safeId);
        safeIdToIndex[safeId] = activeSAFEIds.length;
        activeSAFEIds.push(safeId);

        emit SAFEIssued(
            safeId, p.investor, p.termsCommitment, p.targetShareClass, p.issuedAt, p.documentRef, p.encryptedMemo
        );
    }

    /// @dev Grant FHE viewing rights on every encrypted field of `safe_` to (a, b, c).
    function _grantAllTerms(SAFEInstrument storage safe_, address a, address b, address c) private {
        _grantAll(safe_.inv, a, b, c);
        _grantAll(safe_.cap, a, b, c);
        _grantAll(safe_.disc, a, b, c);
        _grantAll(safe_.mfn, a, b, c);
        _grantAll(safe_.proRata, a, b, c);
        _grantAll(safe_.salt, a, b, c);
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

    function _removeSAFE(uint256 safeId) private {
        uint256 index = safeIdToIndex[safeId];
        uint256 lastIndex = activeSAFEIds.length - 1;
        if (index != lastIndex) {
            uint256 lastSAFEId = activeSAFEIds[lastIndex];
            activeSAFEIds[index] = lastSAFEId;
            safeIdToIndex[lastSAFEId] = index;
        }
        activeSAFEIds.pop();
        delete safeIdToIndex[safeId];
    }

    // ============ Public-input arrays (for ZK verifiers) ============
    // ============ Views ============

    /// @inheritdoc ISAFE
    function getSAFE(uint256 safeId) external view returns (SAFEInstrument memory safe_) {
        safe_ = safes[safeId];
        if (safe_.termsCommitment == bytes32(0)) revert InvalidSAFEId();
    }

    /// @inheritdoc ISAFE
    function getInvestorSAFEs(address investor) external view returns (uint256[] memory safeIds) {
        return investorSAFEs[investor];
    }

    /// @inheritdoc ISAFE
    function getActiveSAFECount() public view returns (uint256 count) {
        for (uint256 i = 0; i < activeSAFEIds.length; i++) {
            if (safes[activeSAFEIds[i]].status == Status.Active) {
                count++;
            }
        }
    }

    /// @inheritdoc ISAFE
    function getActiveSAFEs() external view returns (uint256[] memory safeIds) {
        uint256 count = getActiveSAFECount();
        safeIds = new uint256[](count);
        uint256 cursor = 0;
        for (uint256 i = 0; i < activeSAFEIds.length; i++) {
            uint256 safeId = activeSAFEIds[i];
            if (safes[safeId].status == Status.Active) safeIds[cursor++] = safeId;
        }
    }

    /// @inheritdoc ISAFE
    function getOutstandingSAFECount() external view returns (uint256 count) {
        return activeSAFEIds.length;
    }
}
