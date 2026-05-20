# Decision 07 – ZK vs FHE Division of Labour

- **Date**: 2026-05-03
- **Status**: Accepted
- **See also**:
  - [Decision 03 – Privacy Lifecycle Strategy](03_2025-10-27-PRIVACY_DECISION.md)
  - [Decision 04 – Optional Privacy & ShareholderID](04_2025-12-14_optional_privacy_shareholder_id.md)
  - [Decision 05 – FHE Provider: Fhenix over Zama](05_2026-03-21_fhenix_fhe_provider.md)
- **Context**: We use both ZK (Aztec UltraHonk via `nargo` + `bb`) and FHE (Cofhe). Decision 04 introduced ZK proofs for shareholder-ID privacy; Decision 05 picked Fhenix as the FHE provider for DataRoom. As we plan to extend privacy to OptionPool, Vesting, share transfers, and Fundraise, the question recurs: which technology fits which surface? This decision captures the rule.

## Options Considered

1. **All-ZK.** Use ZK proofs for every privacy-touching surface, including stateful balances and running totals. ❌ Stateful encrypted balances are awkward in ZK; require nullifier sets, accumulators, or per-op proofs.
2. **All-FHE.** Replace the SAFE/CN ZK rails with FHE-based selective disclosure. ❌ Conversion math (division-heavy, dual-path-branching, per-slot batch loops) is FHE's worst case. See Rationale §2.
3. **Hybrid with explicit division of labour.** ZK for compute-heavy proofs over private values; FHE for stateful encrypted records and simple aggregations. ✅

## Decision

| Surface | Tech | Rationale |
|---|---|---|
| **SAFE issuance — manual** (`issueSAFE` direct) | FHE | Board supplies plaintext terms → contract encrypts via `FHE.encrypt(...)` → stored as `euint256` per field. No binding required (no second source). |
| **SAFE issuance — Fundraise-bound** (`issueSAFEFromFundraise`) | FHE | SAFE reads Fundraise's `euint256` payment ciphertext directly and stores it as `safe.inv`. Binding is **structural** (which contract reads which storage slot), not cryptographic — no proof, no `commitmentVerifier`. |
| **Unified SAFE/CN conversion** (YC post-money + dual-path optimality) | ZK | Division-heavy; dual-path branching; fixed-size loops. Only ZK is tractable. Prover decrypts the FHE state via Cofhe, then runs `conversion` against the plaintext. |
| **CN issuance** (manual / Fundraise-bound) | FHE | Mirror of SAFE. |
| **CN batch conversion** (with interest accrual) | ZK | Mirror of SAFE plus simple interest math. |
| **Shareholder ↔ wallet identity link** | ZK | Per Decision 04. |
| **DataRoom** (encrypted document keys, access control) | FHE (Cofhe) | Per Decision 05. |
| **Fundraise running totals + per-investor amounts** | FHE | Encrypted accumulator; per-investor `euint256` amount; SAFE/CN issuance reads the ciphertext. |
| **OptionPool grants** | FHE | Simple per-grant records (amount, strike, schedule); no division-heavy math. |
| **VestingSchedule unlocks** | FHE | Linear vesting math (`elapsed * total / duration` with plaintext `block.timestamp`); few ops, low cost. |
| **Share transfers** (encrypted ERC-20) | FHE | Canonical FHE use case; stateful encrypted balances; impossible-by-construction in ZK without mixers/nullifiers. |

The two stacks coexist on the same EVM chain; no chain split required (Cofhe is tooling, not a separate L1).

The unifying rule: **the conversion math forces ZK; everything else uses FHE.** Issuance is FHE; conversion is ZK. The boundary between them is a Cofhe threshold-network decryption call inside the off-chain prover at conversion time.

## Rationale

### 1. ZK earns its place by carrying compute-heavy proofs

The SAFE/CN conversion math has structural properties that make ZK the only viable option:

- **Division-heavy.** `CC = (fully_diluted + known_shares) * 1e18 / (1e18 - ratio_sum)`, plus per-slot share-count divisions. Division on encrypted values is FHE's worst case (Newton-Raphson approximations or repeated subtraction, often 100×–1000× the cost of multiplication, with no exact integer quotient guarantee).
- **Dual-path branching.** "Investor gets the better deal" requires comparing cap-path shares vs discount-path shares per dual SAFE. FHE has no data-dependent control flow; the equivalent is `FHE.select(cond, then, else)` after computing *both* paths. ZK takes a single witness path.
- **Per-slot batch loops.** MAX_SAFES = 16 is a constant in the circuit. ZK pays the loop cost once at proof generation; FHE would pay it every batch on chain through the coprocessor.

Cost order-of-magnitude: a SAFE batch conversion ZK proof is ~5–30s of off-chain prover time and ~500k gas to verify on-chain. The FHE equivalent would be many seconds of coprocessor work *per batch*, with all the async-result UX overhead.

### 2. FHE earns its place by holding stateful encrypted records

Where FHE excels is exactly where ZK struggles:

- **Encrypted balances across many ops** (share transfers): natural with `euint256`, infeasible in ZK without nullifier accumulators.
- **Encrypted running totals** (Fundraise): single `FHE.add()` per investment, no proof generation, no off-chain prover dependency.
- **Per-grant encrypted records** (OptionPool, Vesting): low op count, simple math, plaintext `block.timestamp` for time-based logic.
- **Selective disclosure** (DataRoom): Cofhe's threshold network handles per-recipient decryption.

The math in these surfaces is overwhelmingly addition/comparison/select, with few or no divisions on encrypted values.

### 3. The two layers compose cleanly

The boundary is well-defined:

- **FHE produces encrypted state** (Fundraise running total, OptionPool grant record, encrypted balance).
- **At a known disclosure event** (round close, exercise, transfer settlement), the relevant ciphertext is decrypted via the Cofhe threshold network.
- **ZK then operates on the now-plaintext value** via the prover, producing the issuance/conversion proof, which the contract verifies.

Concrete handoff for Fundraise → SAFE issuance:
1. Investor invests during open round; amount stored as `euint256` in Fundraise.
2. Round closes; `closeRound()` triggers batch decryption to the company's key.
3. Off-chain prover receives plaintext amounts, builds `payment_commitment = Pedersen([round_id, investor, amount, timestamp])`, generates `safe_issuance_binding` ZK proof.
4. SAFE contract verifies the proof via `commitmentVerifier.verify(proof, publicInputs)`.

No new cryptographic primitives required — each layer uses what it natively supports.

### 4. Chain-agnosticism is preserved where it matters

ZK proofs verify on any EVM chain. Cofhe requires coprocessor connectivity but doesn't force a chain change. Therefore:

- SAFE/CN issuance can deploy on Ethereum mainnet or any L2.
- DataRoom/OptionPool/Vesting/Fundraise/share transfers require Cofhe to be available on the target chain.
- A company suite deployed today targets a Cofhe-supported chain. Cap-table-only minimal deployments (no FHE features) could in principle deploy on chains without Cofhe, though in practice we don't ship such a configuration.

## Trade-offs

- **Two privacy stacks to learn and maintain.** Contributors and auditors need to understand both. Mitigated by clean separation: each contract uses one or the other, never both for the same field.
- **Off-chain prover infrastructure required.** ZK rails need a service (in `services/` or `dapp/`) that holds witness data, runs `bb prove`, and submits proofs. This is a real piece of work the FHE-only path would avoid.
- **Cofhe migration treadmill.** Fhenix's tooling evolves rapidly (e.g., the 0.4.x → 0.5.x split that moved Foundry helpers into `@cofhe/foundry-plugin`). Each upstream version requires re-evaluation. Mitigated by Decision 05's choice — Fhenix's coprocessor model means migrations affect tooling, not chain commitment.
- **Joint-round coordination.** When SAFEs and CNs convert in the same priced round, both ZK circuits must see a coherent `fully_diluted`. Tracked as [Issue #142](https://github.com/equitylayer/contracts/issues/142).
- **Cofhe as a runtime dependency.** Encrypted-balance share transfers require Cofhe's threshold network for selective decryption. If Cofhe is unavailable, dependent contracts can't function. This is a single point of failure the all-ZK path would avoid (at the cost of being unable to do encrypted balances at all).

## Why the hybrid (rationale 4: structural binding > cryptographic binding)

Two separate issuance paths exist on `SAFE.sol` / `ConvertibleNote.sol`:

1. **Manual** — board calls `issueSAFE(investor, terms)` directly. No second source of truth, so no cross-binding is required and no proof was ever needed for this path. The issuance ZK circuits never ran here.
2. **Fundraise-bound** — the *only* place the `safe_issuance_binding` circuit earned its keep — it proved the SAFE's `inv` matches the Fundraise's recorded payment.

In the hybrid model, the Fundraise-bound path becomes structural rather than cryptographic:

```
Fundraise stores:                   euint256 amountOf[roundId][investor]
SAFE.issueSAFEFromFundraise reads:  fundraise.amountOf[roundId][investor]
SAFE.inv stored as:                 the same ciphertext, copied directly
```

The contract reads the Fundraise's encrypted amount and stores it as the SAFE's terms. There is nothing to prove — the binding is enforced by *which contract reads which storage slot*. No off-chain prover, no ZK circuit, no `commitmentVerifier` call at issuance time.

The manual path is similar (plaintext terms → FHE encrypt → store), with the Pedersen-blinding-factor custody story going away.

## Wins

- **No off-chain prover invoked at issuance.** Prover is only needed at conversion (rare, once per priced round). Issuance is the high-frequency path; eliminating prover dependency there is significant.
- **No witness-custody problem.** Pre-hybrid required investors or the company to retain `(inv, blinding)` between issuance and conversion. Hybrid: the encrypted state on chain *is* the recoverable witness; Cofhe threshold decryption recovers it on demand at conversion time.
- **Cap-table queries become native.** Company decrypts via its key for cap-table maintenance / dividend / pro-rata calculations, rather than maintaining a parallel off-chain plaintext store.
- **Two ZK circuits + two verifier wrappers go away.**
- **One unified privacy story** across the company suite — every contract now uses FHE for state, ZK for compute.

## Costs

- **Cofhe runtime dependency at issuance**, not just at conversion. SAFE issuance becomes blocked if Cofhe is unreachable. Pre-hybrid: SAFEs could be issued even if Cofhe was offline.
- **Loss of forever-verifiable on-chain commitments.** Pedersen commitments are immutable and re-openable forever (with the witness). FHE ciphertexts depend on the threshold network for decryption. If Cofhe is shut down or rotates keys badly, encrypted SAFEs become opaque.
- **One-bit leak per Fundraise-bound issuance** if the contract enforces `FHE.eq(safe.inv, fundraise.amount)` and decrypts the resulting `ebool`. Negligible in practice; the binding is structural anyway, so this enforcement is optional.
- **Threshold-network access at conversion.** The prover decrypts every SAFE in the batch via Cofhe (~6 fields × 16 slots = ~96 decryption ops per batch). Manageable, not free.
