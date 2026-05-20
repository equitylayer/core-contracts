# Decision 05 – FHE Provider: Fhenix over Zama

- **Date**: 2026-03-21
- **Status**: Accepted
- **Context**: DataRoom requires Fully Homomorphic Encryption (FHE) for on-chain access control, encrypted folder keys that only authorized members can decrypt. Two viable FHE coprocessor providers were evaluated: Fhenix and Zama (fhEVM).

## Options Considered

1. **Zama (fhEVM)** — Pioneer in blockchain FHE, full fhEVM toolkit ❌
2. **Fhenix (CoFHE)** — Coprocessor-based FHE with lighter on-chain footprint ✅

## Decision

Use Fhenix CoFHE as the FHE provider for DataRoom encryption.

## Rationale

### 1. Cost Model
Zama charges per-operation fees for FHE computations (encrypt, decrypt, re-encrypt). For DataRoom, every `grantAccess`, `revokeAndRekey`, and `createFolder` call triggers FHE operations. At scale (many folders, many members), Zama's per-op fees become significant.

Fhenix uses a coprocessor model where FHE operations are offloaded, resulting in lower marginal cost per operation.

### 2. Developer Support
Fhenix provided direct engineering support during integration, including guidance on:
- EIP-1167 clone compatibility (clones don't inherit constructor storage, requiring `FHE.setCoprocessor()` in `initialize()`)
- Access control patterns with `FHE.allow()` / `FHE.allowThis()`
- Key rotation flows for `rekeyRoom()`

### 3. Integration Simplicity
Fhenix's API surface is minimal for our use case:
- `FHE.randomEuint128()` — generate folder keys
- `FHE.allow(handle, address)` — grant decryption access
- `FHE.allowThis(handle)` — allow contract to hold the key

No need for homomorphic computation (add, multiply on ciphertexts) — we only use FHE for access-controlled key storage.

## Trade-offs

- Fhenix is newer with a smaller ecosystem than Zama
- Zama has more audited FHE primitives for complex computation (not needed here)
- Vendor lock-in: `euint128` type and `FHE.*` calls are Fhenix-specific

## Implementation Notes

- Import: `@fhenixprotocol/cofhe-contracts/FHE.sol`
- Clone pattern requires explicit coprocessor setup — handled in `DataRoom.initialize()`
- Operator always gets `FHE.allow()` on key generation and rekey for compliance escrow
