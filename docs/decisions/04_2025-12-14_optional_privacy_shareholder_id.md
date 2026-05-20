# Business Decision: Optional Privacy and ShareholderID

**Date:** 2025-12-14
**Status:** Decided
**Related:** [Proposal 17 - Privacy Virtual Accounts](../proposals/17_PRIVACY_VIRTUAL_ACCOUNTS.md), [Proposal 18 - ShareholderID Registry](../proposals/18_SHAREHOLDER_ID_REGISTRY.md)

## Context

Following our privacy decision (03), we need to refine how privacy applies to companies and how shareholders interact with the system through multiple wallets.

---

## Decisions

### 1. Optional Privacy at ShareholderID Level

**Decision:** Privacy is a shareholder choice, tied to the ShareholderID. The shareholder who wants privacy pays for it.

- Not every shareholder requires or wants their holdings private
- Privacy has costs (gas for encryption, proof generation/verification)
- The shareholder who benefits from privacy should bear the cost
- Allows flexibility: some shareholders public, others private within the same cap table
- Company/protocol does NOT subsidize individual privacy choices

**Key Insight:** Privacy moves from being a company-wide blanket decision to a shareholder-level choice.

---

### 2. ShareholderID: Multi-Wallet Identity with Usernames

**Decision:** Introduce a new on-chain identity type (ShareholderID) that allows a single shareholder to own multiple wallets. Shareholders can choose a human-readable username as their ID.

**Core features:**
- One shareholder = one ShareholderID = multiple wallets
- Human-readable username (e.g., `alice`, `acme-corp`)
- Wallets hold shares and attestations (KYC, accreditation, etc.)
- Multi-wallet provides operational security (cold/hot separation)
- Optional: hide wallet↔ShareholderID links via ZK proofs for privacy

**Usernames & Namespaces:**
- Shareholder picks unique username
- Companies can have namespaces: `acme/alice`, `acme/bob`
- Namespace owner can create/transfer usernames within their namespace

---

### 3. Centralized Registry for D01

**Decision:** One global ShareholderID Registry for the entire D01 platform.

- NOT per-company registries
- KYC once → hold shares in any company on D01
- Benefits:
  - Single identity across all companies
  - No re-KYC for each company
  - Portable reputation/attestations
  - Simpler user experience
  - Network effects

---

### 4. Share Creation at ShareholderID Level

**Decision:** Shares can only be created (minted) to a ShareholderID, not directly to individual wallets.

- Ensures all shareholders have verified on-chain identity before receiving shares
- Maintains compliance: KYC/AML verification at ShareholderID level
- Shareholder distributes shares across their linked wallets as needed
- Simplifies cap table management: one identity = one shareholder entry
- All share operations go through a Router contract

---

### 5. Virtual ShareholderIDs (Company-Created Placeholders)

**Decision:** Companies can create "virtual" ShareholderIDs and assign them to real shareholders later.

**Use cases:**
- Employee option pools - reserve shares before hires are made
- Pending deals - allocate shares while negotiating, assign after closing
- Pre-KYC allocation - set up cap table structure before recipients complete verification
- Escrow/holding - shares held in limbo until conditions are met

**Constraints:**
- Virtual ShareholderIDs cannot transfer shares (locked until assigned)
- Assignment is one-time and irreversible
- Company controls assignment

---

## Implications

### For Companies
- Minting operations target ShareholderIDs, not raw addresses
- Cap table counts ShareholderIDs, not individual wallets
- Cap table may contain mix of public and private shareholders
- Can create virtual placeholders for pending allocations

### For Shareholders
- Must have a ShareholderID to receive shares
- Can manage multiple wallets under one identity
- Choose privacy level and pay accordingly
- Pick a human-readable username

### For Compliance
- KYC/AML verification at ShareholderID level
- All wallets under a ShareholderID inherit the same compliance status
- Regulators can see the full picture when needed (viewing keys)

---

## Next Steps

See [Proposal 18 - ShareholderID Registry](../proposals/18_SHAREHOLDER_ID_REGISTRY.md) for technical design and open questions.
