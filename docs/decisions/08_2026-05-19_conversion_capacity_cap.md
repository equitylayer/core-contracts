# Decision 08 – Conversion Capacity Cap (16 SAFEs + 16 CNs per Financing)

- **Date**: 2026-05-19
- **Status**: Accepted
- **See also**:
  - [Decision 07 – ZK vs FHE Division of Labour](07_2026-05-03_zk_fhe_division_of_labour.md)
- **Context**: The conversion path collapses what used to be two per-instrument batches (SAFE-only, CN-only) into one joint proof. The Noir circuit at `circuits/conversion/` is fixed-size at compile time; it allocates exactly `MAX_SAFES = MAX_NOTES = 16` slots and zero-pads unused ones. This decision picks the constant value and documents why splitting across proofs is unsafe.

## Options Considered

1. **Larger fixed cap (32+32, 64+64, …).** ❌ Constraint count, RAM, and proof time scale linearly with `MAX_*`. At 16+16 the circuit fits in ~8 GB RAM and produces a proof in ~10–20s native bb. At 64+64 it's ~32 GB / ~2 min. At 256+ slots we'd need distributed proving. Picking a cap larger than realistic round sizes burns cost forever for no benefit.

2. **No cap; split a financing across multiple proofs.** ❌ **Cryptographically wrong.** The YC post-money conversion coefficient
   ```
   CC = (fully_diluted + known_shares) * 1e18 / (1e18 - ratio_sum)
   ```
   is a function of `ratio_sum` and `known_shares` *across all converting instruments*. Splitting into two proofs means each computes its own CC against its own slice, ignoring the other's dilution. That's exactly the bug we're closing — running it as a workaround for the cap reintroduces it.

3. **Recursive aggregation (per-chunk sub-proofs + aggregator).** ❌ Sound but requires an aggregator circuit + recursive proof composition + extra verifier surface. Multi-week build for a problem no current customer has.

4. **16+16 fixed cap, revert above it.** ✅ Covers every realistic seed → Series A round; cheap proof time; small verifier; future-proof via verifier swap.

## Decision

`circuits/conversion/src/main.nr` declares:
```
global MAX_SAFES: u32 = 16;
global MAX_NOTES: u32 = 16;
```

`Fundraise.triggerConversions` enforces the cap at trigger time:
```solidity
if (safeIds.length > MAX_SAFES_PER_CONVERSION) revert TooManySafes();
if (noteIds.length > MAX_NOTES_PER_CONVERSION) revert TooManyNotes();
```

`MAX_SAFES_PER_CONVERSION` and `MAX_NOTES_PER_CONVERSION` (both `16`) are declared as file-level constants in `Fundraise.sol` and must remain in lockstep with the circuit's `MAX_*`.

## Rationale

**Why 16, not larger.** Modeling actual seed → A rounds: a friends-and-family round typically issues 3–8 SAFEs; a structured seed adds 5–10; a Series A converts the full set. Convertible notes are usually 1–3 per company. The 99th-percentile cap-table-stacking founder might cross 16 SAFEs by Series A; the typical one won't. 16 is the smallest value that comfortably covers expected reality without forcing every conversion to pay 32× the proof cost.

**Why a single proof, not multiple.** Already covered in §2 above — the FD-inconsistency bug is unavoidable when batches are split. The architectural fix (joining into one proof) only works if all active instruments fit in that one proof.

**Why a hard revert, not a silent truncation.** A silent overflow ("skip instruments past slot 16") would produce a partial conversion — wrong cap table, wrong share counts, no investor recourse. Revert puts the failure where it belongs: the board has to decide which instruments to cancel/repay before they fit, instead of the contract picking 16 of N for them.

**Why fixed at compile time, not configurable.** Noir doesn't support dynamic-sized circuits. Even if it did, each `MAX_*` value would produce a different VK and require a separate on-chain verifier. Picking one value + accepting the rebuild cost for upgrades is cheaper than maintaining a fleet of verifiers.

## Consequences

- **Hard ceiling on active-instrument count per financing.** Companies issuing more than 16 SAFEs or more than 16 CNs before the qualifying round will hit `TooManySafes` / `TooManyNotes` at `triggerConversions`. Mitigation: `SAFE.cancelSAFE` / `ConvertibleNote.cancelNote` (or `repayNote`) reduces the active count.

- **Verifier upgrade path is the relief valve.** Bumping the cap = recompile circuit with new `MAX_*`, run `bb write_solidity_verifier`, deploy new `ConversionVerifier` contract, rotate it on Fundraise (via a board-controlled setter on Fundraise — TODO if needed; not currently exposed). No data migration; the upgrade is purely a VK swap.

- **Operational watch.** Indexer should expose `activeSafeCount` + `activeNoteCount` per company so the board sees the ceiling approach. A 14-of-16 status should trigger ops attention before the 17th issuance attempt fails.

## Status

Accepted. Implemented in `circuits/conversion/` (16+16 slots), `Fundraise.sol` (`MAX_SAFES_PER_CONVERSION`, `MAX_NOTES_PER_CONVERSION`, `TooManySafes`, `TooManyNotes` revert), and `docs/FUNDRAISE_READINESS.md` §1.

To raise the cap in the future: change `MAX_SAFES` / `MAX_NOTES` in the circuit and the matching `MAX_*_PER_CONVERSION` constants in Fundraise, recompile, regenerate `ConversionVerifier`, rotate on chain. No storage migration needed.
