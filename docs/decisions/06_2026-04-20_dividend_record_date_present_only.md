# Decision 06 – Dividend Record Date Is Present-Only

- **Date**: 2026-04-20
- **Status**: Accepted
- **Context**: `Company.declareDividend` previously accepted any `recordDate` within a 90-day forward window (capped by `MAX_RECORD_DATE_DELAY`), inherited from the CMTAT migration. Reviewing the code path surfaced two problems: (1) future record dates reintroduced a frontrunning vector the original pre-CMTAT audit had explicitly forbidden, and (2) any gap between record date and queue-build (`prepareDividendDistribution`) is the exact window where registry compaction can silently drop holders who sell to zero. Narrowing the allowed range closes both.

## Options Considered

1. **Present + future (status quo)** — flexible, matches traditional equity practice where boards announce in advance. Reintroduces frontrunning; interacts badly with registry compaction. ❌
2. **Present + past** — frontrun-safe (nobody can buy retroactively). Requires a pre-existing snapshot; CMTAT doesn't snapshot automatically. Adds API surface (`declareDividendAtSnapshot`) for a use case nobody has asked for. ⏸ Deferred.
3. **Present only** — `recordDate = block.timestamp`, always fresh `createInstantSnapshot`. Simplest, eliminates both issues. ✅

## Decision

`declareDividend(totalAmount, paymentDate, documentRef)` always uses `block.timestamp` as the record date. Future record dates are rejected (implicit: no way to pass one). Past record dates are not supported.

## Rationale

### 1. Anti-frontrunning (restoring original design intent)

The [2025-10-23 pre-CMTAT audit](../audits/SECURITY_AUDIT_2025-10-23.md) required `recordDate <= block.timestamp`:

> This prevents frontrunning by requiring the record date to be in the past, so shares cannot be bought after the board decides to declare a dividend.

When the system migrated to CMTAT (commit `7dd0ec9`), `scheduleSnapshot` from CMTAT accepts only future timestamps, so `createInstantSnapshot` was added as a bridge. The code ended up supporting both directions — the anti-frontrunning invariant was silently inverted. Dropping future restores the original design.

### 2. Queue-build gap

`prepareDividendDistribution` enumerates the `ShareholderRegistry`, which [compacts on zero-balance transfers](../../src/ShareholderRegistry.sol#L171) (Decision made alongside this one). If record date is in the future, any holder who sells to zero between `recordDate` and `prepareDividendDistribution` disappears from the registry before prepare reads it, even though the CMTAT snapshot still shows their record-date balance. Their slice becomes dust released to vault on finalize; they never get paid. Present-only record dates collapse that window to zero at declaration — the registry is an accurate reflection of the record-date holder set.

A smaller version of this gap still exists between `declareDividend` and `prepareDividendDistribution` (both can happen in the same block but typically don't). That narrower gap is the motivation for the follow-up work on indexer-supplied prepare.

### 3. Simpler API

Removed:
- Second `declareDividend(amount, recordDate, paymentDate, doc)` overload
- `MAX_RECORD_DATE_DELAY` constant
- `scheduleSnapshot` try/catch branch
- `SnapshotSchedulingFailed` error
- `SnapshotErrors` import
- `block.timestamp < dividend.recordDate` dead check in `prepareDividendDistribution`

The single remaining `declareDividend` is half its previous size.

## Trade-offs

- **No advance announcement with on-chain record-date binding**: boards who want to give shareholders notice must do it off-chain (board meeting minutes, investor communication) and then declare when the record date arrives. This matches how most cap-table tooling already operates.
- **No retroactive dividends**: if the board realizes they should have declared off a prior snapshot, they can't. `declareDividendAtSnapshot` is the escape hatch if this becomes real (Option 2 above). Tracked as future work, not implemented.
- **Same-block multiple declares**: each declare calls `createInstantSnapshot` on every share class. If two declares land in the same block, the second's snapshot creation may collide (CMTAT rejects duplicate timestamps). This edge case was not an issue with the future-scheduled path. Current view: unlikely to hit in practice; if it does, the board just submits in separate blocks.

## Implementation Notes

- Contract: [CompanyDividends.sol](../../src/mixins/CompanyDividends.sol) — `declareDividend` hardcodes `recordDate = block.timestamp`, emits `DividendClassSnapshotCreated(dividendId, shareToken, className, snapshotId)` per class for indexer correlation.
- Tests removed: `test_DeclareDividendWithFutureRecordDate*`, `test_PrepareDistribution_RevertsBeforeRecordDate`.
- Tests updated: `test_DividendPaysHolderWhoTransferredAwayAllShares` → `test_DividendMissesHolderWhoSoldBetweenDeclareAndPrepare_Limitation` documents the remaining declare→prepare gap as a known limitation.

## Related

- Decision 02 (CMTAT Migration) — where the future-record-date path entered the codebase.
- Proposal 01 (Batched Dividend Payouts, implemented) — the queue/prepare design this interacts with.
- **Follow-up (not a decision yet)**: indexer-supplied `prepareDividendDistribution(id, address[])` would close the declare→prepare gap entirely by reconstructing the record-date holder set from `Transfer` events instead of the compacted registry. Deferred to a future ADR once we have the indexer in place.
