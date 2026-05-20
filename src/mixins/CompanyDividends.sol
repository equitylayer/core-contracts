// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./CompanyStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICMTATSnapshot} from "CMTAT/contracts/mocks/library/snapshot/ICMTATSnapshot.sol";
import {ISnapshotEngineExtended} from "../interfaces/ISnapshotEngineExtended.sol";

/// @title CompanyDividends
/// @notice Handles dividend declaration and distribution
abstract contract CompanyDividends is CompanyStorage, ReentrancyGuard {
    uint256 public constant MAX_DIVIDEND_BATCH_SIZE = 100;

    // --------------------
    // Events
    // --------------------
    event DividendDeclared(
        uint256 indexed dividendId,
        uint256 totalAmount,
        uint256 totalShares,
        uint256 recordDate,
        uint256 paymentDate,
        string documentRef
    );
    event DividendClassSnapshotCreated(
        uint256 indexed dividendId, address indexed shareToken, string className, uint256 snapshotId
    );
    event DividendPrepared(uint256 indexed dividendId, uint256 holderCount, uint256 distributionShares);
    event DividendBatchDistributed(uint256 indexed dividendId, uint256 batchAmount, uint256 remainingAmount);
    event DividendDistributed(uint256 indexed dividendId, uint256 totalDistributed, string documentRef);
    event DividendPaidToShareholder(uint256 indexed dividendId, address indexed shareholder, uint256 amount);
    event DividendPaymentFailed(uint256 indexed dividendId, address indexed shareholder, uint256 amount);
    event DividendClaimed(address indexed shareholder, uint256 amount);

    // Errors
    error NoPendingDividend();

    // --------------------
    // Dividend Declaration
    // --------------------

    /// @notice Declare a dividend, snapshot every share class, and populate the distribution queue atomically.
    /// @param totalAmount Total amount to be distributed as dividends
    /// @param paymentDate Block timestamp when dividends can be claimed (must be > now)
    /// @param documentRef Optional doc (obolos:// URI or hash) authorizing the dividend
    /// @return dividendId The ID of the created dividend
    function declareDividend(uint256 totalAmount, uint256 paymentDate, string calldata documentRef)
        external
        onlyBoard
        nonReentrant
        returns (uint256 dividendId)
    {
        if (totalAmount == 0) revert ZeroAmount();
        if (paymentDate <= block.timestamp) revert InvalidInput();
        if (shareClassNames.length == 0) revert NotFound();
        // guard against 2 dividends in same block
        if (dividendCount > 0 && dividends[dividendCount].recordDate == block.timestamp) {
            revert InvalidState();
        }
        if (vault.availableBalance() < totalAmount) revert InsufficientCapacity();

        uint256 recordDate = block.timestamp;
        dividendCount++;
        dividendId = dividendCount;

        Dividend storage dividend = dividends[dividendId];
        dividend.totalAmount = totalAmount;
        dividend.recordDate = recordDate;
        dividend.paymentDate = paymentDate;
        dividendRemainingAmt[dividendId] = totalAmount;

        for (uint256 i = 0; i < shareClassNames.length; i++) {
            string memory className = shareClassNames[i];
            ShareToken token = shares[className].token;
            if (address(token) == address(0)) revert NotFound();

            ISnapshotEngineExtended engine = ISnapshotEngineExtended(address(token.snapshotEngine()));
            if (address(engine) == address(0)) revert SnapshotEngineNotConfigured();

            engine.createInstantSnapshot();

            dividendSnapshots[dividendId][_classKey(className)] = DividendClassSnapshot({snapshotId: recordDate});
            emit DividendClassSnapshotCreated(dividendId, address(token), className, recordDate);
        }

        uint256 distributionShares = _populateDistributionQueue(dividendId);
        vault.reserveDividend(totalAmount);

        emit DividendDeclared(dividendId, totalAmount, distributionShares, recordDate, paymentDate, documentRef);
    }

    // --------------------
    // Dividend Distribution
    // --------------------

    /// @dev Enumerate eligible holders at the snapshot.
    function _populateDistributionQueue(uint256 dividendId) private returns (uint256 distributionShares) {
        address[] memory holders = _getAllDividendShareholders(dividendId);
        if (holders.length == 0) revert NotFound();

        distributionShares = _getShareholderTotalSharesForDistribution(dividendId, holders);
        if (distributionShares == 0) revert InsufficientCapacity();

        dividendDistributionShares[dividendId] = distributionShares;
        address[] storage queue = _unpaidHolders[dividendId];
        for (uint256 i = 0; i < holders.length; i++) {
            queue.push(holders[i]);
        }

        emit DividendPrepared(dividendId, holders.length, distributionShares);
    }

    /// @notice Pop up to `count` holders off the dividend queue and pay them.
    function distributeDividendBatch(uint256 dividendId, uint256 count) external onlyBoard nonReentrant {
        if (dividendId == 0 || dividendId > dividendCount) revert NotFound();
        if (count == 0 || count > MAX_DIVIDEND_BATCH_SIZE) revert InvalidInput();

        Dividend storage dividend = dividends[dividendId];
        if (dividend.distributed) revert InvalidState();
        if (block.timestamp < dividend.paymentDate) revert InvalidState();

        address[] storage queue = _unpaidHolders[dividendId];
        uint256 qlen = queue.length;
        if (qlen == 0) revert InvalidState();

        uint256 toPop = count > qlen ? qlen : count;
        address[] memory popped = new address[](toPop);
        uint256 included;
        for (uint256 i = 0; i < toPop; i++) {
            address holder = queue[queue.length - 1];
            queue.pop();
            if (excludedFromDividends[holder]) {
                continue; // post-prepare exclusion → dust to vault
            }
            popped[included] = holder;
            included++;
        }

        if (included > 0) {
            address[] memory batch = new address[](included);
            for (uint256 i = 0; i < included; i++) {
                batch[i] = popped[i];
            }

            (uint256[] memory payouts, uint256 expectedTotal) = _calculateDividendPayouts(
                dividendId, batch, dividend.totalAmount, dividendDistributionShares[dividendId]
            );
            dividendRemainingAmt[dividendId] -= expectedTotal;
            uint256 totalDistributed = _executePayouts(dividendId, batch, payouts);
            emit DividendBatchDistributed(dividendId, totalDistributed, dividendRemainingAmt[dividendId]);
        }

        if (queue.length == 0) {
            dividend.distributed = true;
            uint256 dust = dividendRemainingAmt[dividendId];
            if (dust > 0) {
                // release dust
                vault.releaseDividend(dust);
                dividendRemainingAmt[dividendId] = 0;
            }
            emit DividendDistributed(dividendId, dividend.totalAmount - dust, "");
        }
    }

    /// @notice Recipient can claim all dividends
    function claimDividend() external nonReentrant {
        uint256 amount = pendingDividends[msg.sender];
        if (amount == 0) revert NoPendingDividend();

        pendingDividends[msg.sender] = 0;

        vault.releaseDividend(amount);
        vault.withdrawToken(address(paymentToken), msg.sender, amount);

        emit DividendClaimed(msg.sender, amount);
    }

    // --------------------
    // View Functions
    // --------------------

    /// @notice Calculate dividend amount for a specific shareholder
    /// @param dividendId The ID of the dividend
    /// @param shareholder Shareholder's address
    /// @return amount The dividend amount the shareholder is entitled to
    function calculateDividendAmount(uint256 dividendId, address shareholder) external view returns (uint256) {
        if (dividendId == 0 || dividendId > dividendCount) revert NotFound();
        if (excludedFromDividends[shareholder]) return 0;
        if (shareholder == address(vault) || shareholder == address(vestingSchedule)) return 0;

        uint256 distributionShares = dividendDistributionShares[dividendId];
        if (distributionShares == 0) {
            // Dividend not yet prepared — fall back to auto-exclusions only. Manually-excluded
            (uint256 totalShares, uint256 excludedShares) = _getDividendShareCounts(dividendId);
            if (totalShares <= excludedShares) return 0;
            distributionShares = totalShares - excludedShares;
        }

        uint256 holderShares = _getShareholderTotalShares(dividendId, shareholder);
        if (holderShares == 0) return 0;

        return (dividends[dividendId].totalAmount * holderShares) / distributionShares;
    }

    /// @notice Get total shares across all classes for a dividend
    /// @param dividendId The ID of the dividend
    /// @return totalShares Total shares across all classes
    function dividendTotalShares(uint256 dividendId) public view returns (uint256) {
        if (dividendId == 0 || dividendId > dividendCount) revert NotFound();
        (uint256 totalShares,) = _getDividendShareCounts(dividendId);
        return totalShares;
    }

    // --------------------
    // Internal Helper Functions
    // --------------------

    /// @dev Resolve (totalShares, excludedShares) for a dividend.
    /// @dev Uses snapshotTotalSupplyStrict to explicitly handle missing snapshots (audit 4.1).
    /// @dev Before recordDate, returns (0, 0) — snapshot data is not yet available.
    function _getDividendShareCounts(uint256 dividendId)
        private
        view
        returns (uint256 totalShares, uint256 excludedShares)
    {
        Dividend storage dividend = dividends[dividendId];
        if (block.timestamp < dividend.recordDate) return (0, 0);

        for (uint256 i = 0; i < shareClassNames.length; i++) {
            string memory className = shareClassNames[i];
            DividendClassSnapshot storage snapshot = dividendSnapshots[dividendId][_classKey(className)];
            if (snapshot.snapshotId == 0) continue;

            ShareToken token = shares[className].token;
            if (address(token) == address(0)) continue;

            ISnapshotEngineExtended engine = ISnapshotEngineExtended(address(token.snapshotEngine()));
            if (address(engine) == address(0)) revert SnapshotEngineNotConfigured();

            // Strict check: if snapshot total supply not materialized (no mint/burn since recordDate),
            // fall back to current supply explicitly — safe because supply hasn't changed.
            (bool exists, uint256 supply) = engine.snapshotTotalSupplyStrict(snapshot.snapshotId);
            if (!exists) {
                supply = token.totalSupply();
            }
            totalShares += supply;

            ICMTATSnapshot snapshotQuery = ICMTATSnapshot(address(engine));
            excludedShares += _getExcludedSharesForClass(snapshotQuery, snapshot.snapshotId);
        }
    }

    /// @dev Calculate dividend payouts for shareholders using batch queries for gas efficiency
    function _calculateDividendPayouts(
        uint256 dividendId,
        address[] memory shareholders,
        uint256 totalAmount,
        uint256 totalShares
    ) private view returns (uint256[] memory payouts, uint256 expectedTotal) {
        payouts = new uint256[](shareholders.length);
        uint256[] memory shareholderTotals = new uint256[](shareholders.length);

        for (uint256 i = 0; i < shareholders.length; i++) {
            if (dividendClaimed[dividendId][shareholders[i]]) revert InvalidState();
            if (excludedFromDividends[shareholders[i]]) revert InvalidState();
        }

        // For each share class, batch query all shareholder balances
        string[] storage classNames = shareClassNames;
        for (uint256 j = 0; j < classNames.length; j++) {
            bytes32 classKey = _classKey(classNames[j]);
            DividendClassSnapshot storage snapshot = dividendSnapshots[dividendId][classKey];

            if (snapshot.snapshotId == 0) continue;

            ShareToken token = shares[classNames[j]].token;
            if (address(token) == address(0)) continue;

            ISnapshotEngine engine = token.snapshotEngine();
            if (address(engine) == address(0)) revert SnapshotEngineNotConfigured();

            // Batch for gas efficiency
            ICMTATSnapshot snapshotQuery = ICMTATSnapshot(address(engine));
            (uint256[] memory balances,) = snapshotQuery.snapshotInfoBatch(snapshot.snapshotId, shareholders);

            for (uint256 i = 0; i < shareholders.length; i++) {
                shareholderTotals[i] += balances[i];
            }
        }

        for (uint256 i = 0; i < shareholders.length; i++) {
            if (shareholderTotals[i] > 0) {
                uint256 dividendAmount = (totalAmount * shareholderTotals[i]) / totalShares;
                payouts[i] = dividendAmount;
                expectedTotal += dividendAmount;
            }
        }
    }

    /// @dev Get total shares for a single shareholder across all classes
    /// @dev Used by calculateDividendAmount view function (for UI/queries)
    /// @dev For batch distribution, use _calculateDividendPayouts which uses snapshotInfoBatch
    function _getShareholderTotalShares(uint256 dividendId, address shareholder) private view returns (uint256 total) {
        string[] storage classNames = shareClassNames;

        for (uint256 j = 0; j < classNames.length; j++) {
            bytes32 classKey = _classKey(classNames[j]);
            DividendClassSnapshot storage snapshot = dividendSnapshots[dividendId][classKey];

            if (snapshot.snapshotId == 0) continue;

            ShareToken token = shares[classNames[j]].token;
            if (address(token) == address(0)) continue;

            ISnapshotEngine engine = token.snapshotEngine();
            if (address(engine) == address(0)) revert SnapshotEngineNotConfigured();

            ICMTATSnapshot snapshotQuery = ICMTATSnapshot(address(engine));
            uint256 shareholderBalance = snapshotQuery.snapshotBalanceOf(snapshot.snapshotId, shareholder);

            total += shareholderBalance;
        }
    }

    /// @dev Execute dividend payments with pull pattern fallback.
    function _executePayouts(uint256 dividendId, address[] memory shareholders, uint256[] memory payouts)
        private
        returns (uint256 totalDistributed)
    {
        for (uint256 i = 0; i < shareholders.length; i++) {
            if (payouts[i] > 0) {
                dividendClaimed[dividendId][shareholders[i]] = true;
                vault.releaseDividend(payouts[i]);
                try vault.withdrawToken(address(paymentToken), shareholders[i], payouts[i]) {
                    totalDistributed += payouts[i];
                    emit DividendPaidToShareholder(dividendId, shareholders[i], payouts[i]);
                } catch {
                    vault.reserveDividend(payouts[i]);
                    pendingDividends[shareholders[i]] += payouts[i];
                    emit DividendPaymentFailed(dividendId, shareholders[i], payouts[i]);
                }
            }
        }
    }

    function _getExcludedSharesForClass(ICMTATSnapshot snapshotQuery, uint256 snapshotId)
        private
        view
        returns (uint256 totalExcluded)
    {
        totalExcluded += snapshotQuery.snapshotBalanceOf(snapshotId, address(vault));
        totalExcluded += snapshotQuery.snapshotBalanceOf(snapshotId, address(vestingSchedule));
    }

    /// @dev Calculate total shares for the provided shareholders across all classes
    function _getShareholderTotalSharesForDistribution(uint256 dividendId, address[] memory shareholders)
        private
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < shareholders.length; i++) {
            total += _getShareholderTotalShares(dividendId, shareholders[i]);
        }
    }

    /// @dev Get all shareholders across all share classes, excluding vault and vesting
    /// @dev Only includes shareholders who had non-zero balance at record date
    /// @dev Uses transient storage (EIP-1153) for O(1) dedup instead of O(n) inner loop
    function _getAllDividendShareholders(uint256 dividendId) private returns (address[] memory) {
        uint256 maxHolders = 0;
        for (uint256 i = 0; i < shareClassNames.length; i++) {
            ShareToken token = shares[shareClassNames[i]].token;
            if (address(token) != address(0)) {
                maxHolders += shareholderRegistry.getShareholderCount(address(token));
            }
        }

        address[] memory allHolders = new address[](maxHolders);
        uint256 holderCount = 0;

        for (uint256 i = 0; i < shareClassNames.length; i++) {
            string memory className = shareClassNames[i];
            bytes32 classKey = _classKey(className);
            DividendClassSnapshot storage snapshot = dividendSnapshots[dividendId][classKey];

            if (snapshot.snapshotId == 0) continue;

            ShareToken token = shares[className].token;
            if (address(token) == address(0)) continue;

            ISnapshotEngine engine = token.snapshotEngine();
            if (address(engine) == address(0)) revert SnapshotEngineNotConfigured();
            ICMTATSnapshot snapshotQuery = ICMTATSnapshot(address(engine));

            address[] memory classHolders = shareholderRegistry.getShareholders(address(token));

            for (uint256 j = 0; j < classHolders.length; j++) {
                address holder = classHolders[j];

                if (holder == address(vault) || holder == address(vestingSchedule)) {
                    continue;
                }

                if (excludedFromDividends[holder]) {
                    continue;
                }

                uint256 balanceAtSnapshot = snapshotQuery.snapshotBalanceOf(snapshot.snapshotId, holder);
                if (balanceAtSnapshot == 0) {
                    continue;
                }

                bool alreadySeen = _tsDedup(dividendId, holder);

                if (!alreadySeen) {
                    allHolders[holderCount] = holder;
                    holderCount++;
                }
            }
        }

        address[] memory result = new address[](holderCount);
        for (uint256 i = 0; i < holderCount; i++) {
            result[i] = allHolders[i];
        }

        return result;
    }

    /// @dev O(1) dedup using transient storage, salted by dividendId to avoid cross-call collisions
    function _tsDedup(uint256 dividendId, address holder) private returns (bool seen) {
        assembly ("memory-safe") {
            mstore(0x00, dividendId)
            mstore(0x20, holder)
            let slot := keccak256(0x00, 0x40)
            seen := tload(slot)
            if iszero(seen) { tstore(slot, 1) }
        }
    }
}
