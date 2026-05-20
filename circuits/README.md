# obolos ZK Circuits

Noir circuits backing the privacy-preserving SAFE / ConvertibleNote flows

## Layout

| Circuit | Purpose |
|---|---|
| `conversion/` | Proves the unified SAFE + Convertible Note conversion math for a qualified financing, verified at `Fundraise.applyConversions`. |
| `cn_repayment/` | Proves full Convertible Note repayment amount, verified at `ConvertibleNote.repayNote`. |

Both are workspace members in `Nargo.toml`, sharing the `conversion_math` library.

## Toolchain

Tested with:

- `nargo 1.0.0-beta.20`
- `bb 4.0.4` (Barretenberg, the proving backend)

Install instructions in the [project README](../README.md#prerequisites). After install, verify:

```bash
nargo --version
bb --version
```

## Build

From this directory (`circuits/`):

```bash
# Compile both circuits -> target/*.json
nargo compile --workspace

# Run the in-circuit unit tests
nargo test --workspace
```

Or from the repo root:

```bash
make circuits
```

## Generate Solidity verifier contracts

The on-chain verifier contracts (one per circuit) are generated from the compiled
artifacts via Barretenberg. Two `bb` calls per circuit: `write_vk` produces a
verification key with the right oracle hash for EVM (keccak), then
`write_solidity_verifier` consumes that vk and emits Solidity.

```bash
# From circuits/, after nargo compile.
# --oracle_hash keccak is REQUIRED for EVM-target verifiers; omitting it produces
# a poseidon-oracle vk that won't match the keccak-based Solidity verifier.
bb write_vk -b target/conversion.json -o target/conversion.vk --oracle_hash keccak
bb write_solidity_verifier -k target/conversion.vk/vk -o target/ConversionVerifier.sol -t evm

# Or via the Makefile target:
make verifiers
```

The generated `.sol` files land in `target/` and embed the full verification key
as constants. Port the generated verification-key constants into the per-circuit
wrapper in `src/zk-verifiers/`; the wrappers delegate proof verification to
`SharedHonkVerifier` to stay under the EIP-170 size limit.

Note: the auto-generated verifier exposes:

```solidity
function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
```

This is consumed via the `IZKVerifier` interface, which matches Noir's natural
`bytes32[]` shape. `Fundraise.applyConversions` and `ConvertibleNote.repayNote`
build the public-input arrays in the order declared by each circuit's `main.nr`.

## Generate proofs (off-chain prover)

The same `bb` binary produces proofs from a witness:

```bash
# Prepare witness inputs in Prover.toml (see noir-lang docs for format).
nargo execute               # produces target/<package>.gz (witness)
bb prove -b target/<package>.json -w target/<package>.gz -o target/proof
```

The resulting proof bytes are passed to the Solidity verifier via
`Fundraise.applyConversions(..., proof, ...)` or `ConvertibleNote.repayNote(..., proof)`.

## Hash primitive

All commitments use **Poseidon2**, via the `conversion_math::poseidon2_hash`
helper that wraps the public `std::hash::poseidon2_permutation` with the same
fixed-length sponge `Poseidon2::hash` uses internally (the stdlib helper itself
is `pub(crate)` in Noir 1.0.0-beta.20). Output is byte-equivalent to bb.js's
`poseidon2Hash` and to the `@zkpassport/poseidon2` npm package used off-chain.

Any change to the hash must land in **all three** places together — the circuit
(`conversion_math::poseidon2_hash`), the dapp's investor-side commitment
(`dapp/src/lib/commitments.ts`), and the backend prover's recomputation
(`services/backend/src/modules/prover/poseidon2.ts`). They must produce the same
hash of the same field tuple in the same order.

## Current scope

`conversion/` implements the YC math for:

- Cap-only SAFEs / Notes
- Discount-only SAFEs / Notes
- Dual SAFEs / Notes (both cap AND discount) with optimal-path resolution
- Pure-MFN SAFEs / no-cap-no-disc Notes (convert at round price)

### Dual-path resolution

The prover supplies a `path_choice` per instrument as private witness:

```
0 = inactive (padding)
1 = cap path
2 = discount path
3 = no-terms path (no cap, no discount; converts at round price)
```

The circuit verifies the choice is **optimal**: for every dual instrument
(cap > 0 AND disc > 0) the chosen path's resulting share count must be
greater than or equal to the candidate from the other path. This forces
the prover to pick the path that yields more shares, matching the legacy
`_computeBatchConversion`'s `max(cap_shares, discount_shares)` semantics
without requiring iteration inside the circuit.

Comparisons cast Field to u128 (Field is order-less in finite-field algebra).
Value ranges fit u128 comfortably:

- `inv` / `principal` / `cap` / `shares` -- fiat amounts up to 1e18 max
- `CC` -- can reach ~1e36 in extreme cases, still under u128 max (~3.4e38)

### Batch size

`MAX_SAFES` / `MAX_NOTES` is currently **16**. Larger batches require recompiling
the circuit with a larger constant. Each additional slot adds approximately
constant overhead to the constraint count (commitment opening + path constraint
+ share constraint).

## Repayment circuit

ConvertibleNote repayment proves `total_repayment == principal + accrued_interest`
against committed terms. The circuit lives at `circuits/cn_repayment/` and is
wired to `ConvertibleNote.repayNote` through `CnRepayVerifier`.

## Files generated by builds (gitignored)

- `target/*.json`            — compiled circuit artifacts
- `target/vk*`               — verification keys
- `target/contract*.sol`     — generated Solidity verifiers
- `target/*.gz`              — witnesses
- `target/proof`             — generated proofs
