# Privacy Decision: Complete Lifecycle Strategy

**Date:** 2025-10-27 (updated 2025-10-28, 2025-12-14)
**Status:** Decided
**See also:** [Decision 04 - Optional Privacy & ShareholderID](04_2025-12-14_optional_privacy_shareholder_id.md)

> **Update 2025-12-14:** This decision is extended by Decision 04, which introduces:
> - **Optional privacy at shareholder level** (not company-wide)
> - **ShareholderID** - multi-wallet identity with usernames
> - **Shareholder pays** for their own privacy costs
> - **ZK proofs** for hiding wallet↔ShareholderID links

## Problem

Current implementation stores ALL data publicly on-chain:
- Shareholder addresses and balances
- Transfer amounts
- Vesting schedules
- SAFE investments
- Dividend payments

**This is unacceptable for production.**

No serious startup will use a public cap table where:
- Competitors see ownership structure
- VCs see each other's stakes
- Employees see founder equity
- Acquisition valuations are exposed

**Additionally:** We need a strategy for the complete company lifecycle:
- **Private phase:** Cap table privacy is critical
- **IPO transition:** How do we handle the private → public transition?
- **Public phase:** SEC requires transparency, but how do we scale to millions of retail holders?

---

## Solution: Privacy-Preserving Technologies

### **Option 1: Merkle Tree Commitments** 🎯 **RECOMMENDED FOR PHASE 1**

**Technology**: Merkle trees with off-chain storage

**How it works:**
- Store Merkle root on-chain (single bytes32 hash)
- Keep actual balances/holders off-chain or encrypted
- Shareholders prove ownership with Merkle proofs
- Board/regulators can access full tree when needed

**Pros:**
- ✅ Simple to implement (1-2 weeks)
- ✅ Very low gas costs (just updating root hash)
- ✅ Privacy without complexity
- ✅ Battle-tested technology (Uniswap, OpenSea use this)
- ✅ Can selectively reveal to regulators
- ✅ Prevents public cap table scraping

**Cons:**
- ⚠️ Requires off-chain data availability
- ⚠️ Not as strong privacy as dedicated chains
- ⚠️ Root updater needs to be trusted OR use fraud proofs

**Privacy level:**
- Cap table NOT publicly enumerable
- Individual holdings NOT visible without proof
- Regulators can request full tree
- Shareholders can prove ownership when needed

---

### **Option 2: Private Blockchain / Confidential Assets** 🔮 **FUTURE**

**Technology**: Deploy to privacy-focused chains

**How it works:**
- Use existing blockchain with built-in privacy features
- All transactions/state private by default
- Selective disclosure to authorized parties (viewing keys)
- Compliance through regulated validator sets

**Platforms:**
- **Partisia Blockchain** (MPC + ZK, privacy by default)
- **Secret Network** (Confidential smart contracts)
- **Oasis Network** (Confidential ParaTime)
- **Aleo** (ZK-native blockchain)
- **Penumbra** (Private DeFi chain)

**Pros:**
- ✅ Privacy built into the chain
- ✅ Better performance than L1 privacy solutions
- ✅ Designed for confidential assets
- ✅ Regulatory compliance features via viewing keys
- ✅ Simpler than retrofitting privacy onto Ethereum

**Cons:**
- ⚠️ Less mature ecosystems
- ⚠️ Smaller validator sets (less decentralization)
- ⚠️ Different security models
- ⚠️ Less tooling/developer support
- ⚠️ Bridge complexity to Ethereum

---

### **Option 3: Fully Homomorphic Encryption (FHE)** 🔬 **EXPERIMENTAL**

**Technology**: Zama fhEVM (encrypted computation on Ethereum)

**How it works:**
- Balances and amounts stored as encrypted values on-chain
- Computation happens on encrypted data (transfers, compliance checks)
- Only authorized parties can decrypt (board, regulators)
- Standard EVM deployment with FHE precompiles

**Pros:**
- ✅ True on-chain privacy (no off-chain data dependency)
- ✅ Stays on Ethereum (no bridge risk)
- ✅ Computation on encrypted data (revolutionary)
- ✅ Viewing keys for selective disclosure
- ✅ KYC/compliance checks still work (encrypted amounts, public identity)

**Cons:**
- ⚠️ NOT production-ready yet (as of 2025)
- ⚠️ High gas costs (FHE operations expensive)
- ⚠️ Performance constraints (slower than plaintext)
- ⚠️ Immature tooling and libraries
- ⚠️ Unknown regulatory acceptance

**Key insight from FHE:**
Privacy (encrypted balances) ≠ Compliance (KYC/sanctions)
- Even with encrypted balances, KYC checks are PUBLIC
- Sanctions screening is PUBLIC (must be to work)
- Only AMOUNTS stay private, not identities

---

## Comparison

| Feature | Merkle Trees | Private Chains | FHE (Zama) |
|---------|--------------|----------------|------------|
| **Privacy Level** | Medium (hides enumeration) | High (full confidentiality) | High (encrypted on-chain) |
| **Maturity** | ✅ Battle-tested (2015+) | Growing (2020+) | ⚠️ Experimental (2024+) |
| **Gas Cost** | Very Low | Low-Medium | ⚠️ High |
| **Implementation** | ✅ Simple (1-2 weeks) | Moderate (4-8 weeks) | Moderate (unknown complexity) |
| **Production Ready** | ✅ YES (now) | ✅ YES (select chains) | ❌ NO (not yet) |
| **Developer Tools** | ✅ Excellent | Good (chain-specific) | ⚠️ Limited |
| **Platforms** | Any EVM chain | Partisia, Secret, Oasis | Ethereum (when ready) |
| **Decentralization** | ✅ High (use any L1) | Lower (smaller validator sets) | ✅ High (Ethereum) |
| **Selective Disclosure** | ✅ Easy | ✅ Via viewing keys | ✅ Via decryption keys |
| **Regulatory Compliance** | ✅ Can share full tree | ✅ Viewing keys for auditors | ✅ Board can decrypt |

---

## Privacy Lifecycle: Private → Public Companies

### The Fundamental Tension

**Private Companies:**
- Cap table is confidential business information
- VCs don't want competitors seeing their stakes
- Founders don't want employees seeing dilution details
- Privacy is CRITICAL for competitive advantage

**Public Companies:**
- SEC requires disclosure of holders >5% ownership
- Form S-1 (IPO filing) includes major shareholders
- 13D/13G filings for large positions (public, ongoing)
- Transparency is MANDATORY by law

**Key insight:** Privacy requirements change dramatically at IPO.

### Token Lifecycle Strategy

#### Phase 1: Private Company (Seed → Series C)
**Use:** Merkle trees (short-term) OR FHE (if production-ready)
- Encrypted/hidden balances
- Cap table not publicly enumerable
- VCs can't see each other's positions
- Board has full visibility
- Regulators get access on request

**Compliance stays public:**
- KYC verification (IdentityRegistry)
- Sanctions screening (always enforced)
- Transfer restrictions (accredited investor checks)

#### Phase 2: IPO (Going Public)
**Two-token migration model:**

1. **Decrypt final cap table** (board generates snapshot)
2. **File S-1 with SEC** (disclose everything - required by law)
3. **Deploy new public token** (standard ERC-20, visible balances)
4. **Migrate shareholders** (burn private token → mint public token)
5. **Retire private token** (no longer used)

**What changes:**
- ❌ Privacy: GONE (balances now visible to anyone)
- ✅ Compliance: STAYS (KYC/sanctions still enforced)
- ✅ Liquidity: INCREASED (public markets, more buyers)

#### Phase 3: Public Company
**Use:** Standard ERC-20 with compliance layer (CMTAT fills this role with Sanctions + Centralized KYC allowance + Broker allowance)
- Balances fully visible (like traditional stocks)
- But still enforce KYC/sanctions (can't bypass compliance)
- Broker-dealers aggregate retail positions (see below)

**SEC requirements:**
- Shareholders >5% must file publicly (13D/13G)
- Insider trades public (Form 4)
- Quarterly institutional holdings (13F)
- No privacy allowed - this is a feature for investor protection

### Critical Insight: Privacy ≠ Compliance

**Privacy = Hiding balances/amounts**
- Needed while PRIVATE
- Lost when going PUBLIC (by law)
- Protects competitive information

**Compliance = KYC/sanctions/transfer rules**
- Needed ALWAYS (private AND public)
- Never goes away
- Protects against money laundering, terrorist financing

**Example:** Even public companies:
- ✅ Must verify KYC before allowing transfers
- ✅ Must screen against sanctions lists (OFAC)
- ✅ Must enforce lockups, insider restrictions
- ❌ Cannot hide who owns shares (transparency required)

---

## Retail Investor Privacy: Broker-Dealer Model

### The Problem with Pure On-Chain

If every retail investor holds tokens directly:
- **Cap table bloat:** Millions of on-chain addresses
- **Privacy exposure:** Every 0.000001% holder is public
- **Gas costs:** Unsustainable for mass adoption
- **Doxxing risk:** Addresses correlated with identities

**Example:** Apple has 16 billion shares across millions of holders. All visible on-chain = disaster.

### The Solution: Aggregation via Brokers

**Model (exactly like traditional stocks + crypto exchanges):**

```
ON-CHAIN POSITIONS (visible):
├─ Founders: 35%
├─ VC Funds: 25%
├─ Institutional Investors: 15%
├─ Robinhood Securities: 10% ◄─ Aggregated
├─ Schwab Digital: 8% ◄─ Aggregated
└─ Coinbase Securities: 5% ◄─ Aggregated

OFF-CHAIN (Robinhood's internal ledger):
├─ Alice: 10 shares
├─ Bob: 5 shares
├─ Carol: 100 shares
└─ ... (500,000 retail users)
    Total: Matches 10% on-chain position
```

### How It Works

**Direct Holders (Self-Custody):**
- Founders, VCs, institutions, sophisticated individuals
- Trade on-chain (visible, pay gas fees)
- Full control (your keys, your tokens)
- Can use DeFi, voting, etc.

**Custodial Holders (Via Broker):**
- Retail investors, small positions
- Broker holds shares on-chain (one big position)
- Individual ownership tracked off-chain (broker's database)
- Trades between broker clients = instant, zero gas, private
- Can withdraw to self-custody anytime

**Benefits:**
- ✅ Privacy for retail (not doxxed on blockchain)
- ✅ Scalability (50-100 on-chain addresses vs millions)
- ✅ Zero gas fees for retail trades (internal settlement)
- ✅ Familiar UX (app-based, like Robinhood)
- ✅ SEC-compliant (broker-dealers are already regulated)

**Implementation:**
- No special smart contract code needed
- Brokers are just KYC'd entities (via IdentityRegistry)
- They hold shares like anyone else
- They handle retail KYC, reporting, compliance
- We just enable the infrastructure

**Real-world precedent:**
This is exactly how Coinbase works:
- Holds billions in BTC/ETH on-chain (aggregated)
- Millions of users off-chain (internal tracking)
- When you "buy Bitcoin," no on-chain transaction happens (unless you withdraw)

### Our Role vs Broker Role

**What we build:**
- ✅ Smart contracts with compliance
- ✅ IdentityRegistry for KYC
- ✅ APIs for broker integration
- ✅ Corporate actions (dividends, voting)

**What brokers build:**
- ✅ Retail trading platforms
- ✅ Internal ledger systems
- ✅ Retail KYC/onboarding
- ✅ SEC/FINRA compliance (they're already licensed)

**We enable brokers. We don't become one.**

---

## Decision Matrix

### **For 2025 Launch → Merkle Trees** 🎯

**Why:**
1. ✅ **Production-ready NOW**
   - OpenZeppelin MerkleProof library
   - Used by Uniswap, Optimism, etc.
   - Battle-tested for years

2. ✅ **Minimal gas costs**
   - Root update: ~21k gas (SSTORE)
   - Verification: ~50k gas (hashing)
   - Cheap for any startup

3. ✅ **Simple to implement**
   - No new dependencies
   - Clear documentation
   - Fast development (1-2 weeks)

4. ✅ **Regulatory compatible**
   - Board can share full tree with regulators
   - Shareholders prove ownership when needed
   - Transparent when required

**Limitations to understand:**
- ⚠️ **Not true ownership** - Merkle root is just a commitment, actual token balances still need separate tracking
- ⚠️ **Centralized updates** - Someone trusted must compute and post new roots (board, or use fraud proofs)
- ⚠️ **Data availability** - Need off-chain storage (IPFS, Arweave, or centralized DB)

**Timeline:**
- **Week 1**: Implement Merkle tree contract
- **Week 2**: Build tree generation scripts
- **Week 3**: Testing + integration
- **Week 4**: Deploy to testnet

---

### **For 2026+ → Consider Private Chain Migration** 🔮

**Why wait:**
1. ⚠️ Need to assess ecosystem maturity
2. ⚠️ Bridge security to Ethereum needs validation
3. ⚠️ Tooling/auditor availability growing
4. ⚠️ Regulatory acceptance still emerging

**But private chains are PERFECT for cap tables:**
- Native privacy (no retrofitting needed)
- Better performance than privacy-on-Ethereum
- Viewing keys for selective disclosure
- Designed for confidential assets
- Lower operational complexity

**Watch these projects:**
- **Partisia Blockchain** (MPC + ZK, strongest compliance story)
- **Secret Network** (most mature, good tooling)
- **Oasis Sapphire** (EVM-compatible confidential ParaTime)
- **Aleo** (ZK-native, interesting model)

**Decision point:** Late 2025
- If bridge security proven → consider migration
- If major tokenized assets deploy → validate at scale
- If regulators accept viewing key model → assess compliance

---

## Recommended Approach

### **Phase 1 (2025):** Merkle Tree Implementation

**Target Platform:** Any EVM chain (Ethereum, Polygon, Base, Arbitrum)

**Architecture layers:**
1. **Public state (on-chain):** Company registration, share classes, compliance rules, Merkle root hash
2. **Private state (off-chain):** Full cap table stored on IPFS/encrypted, shareholder balances, vesting schedules
3. **Selective disclosure:** Shareholders get Merkle proofs to prove ownership, board has full tree, regulators get access on request

**Implementation steps:**
1. Add Merkle root storage to Company contract
2. Build off-chain tree generation scripts
3. Create proof verification functions
4. Store full trees on IPFS/Arweave
5. ~1-2 weeks engineering

**Cost estimate:**
- Dev: $5-10K (1 engineer, 1-2 weeks)
- Audit: Minimal (uses OpenZeppelin library)
- Gas: ~21K per root update
- **Total: $5-10K**

---

### **Phase 2 (2026):** Evaluate Private Chain Migration

**Conditions to migrate:**
1. ✅ Private chain ecosystem proven (>$1B TVL)
2. ✅ Bridge security validated (multiple audits)
3. ✅ Regulators accept viewing key model
4. ✅ Developer tooling mature enough
5. ✅ Auditor availability (chain-specific experience)

**If conditions met:**
- Deploy contracts to private chain (Partisia/Secret/Oasis)
- Native privacy without Merkle tree complexity
- Better UX (no proof generation needed)
- True on-chain privacy with regulatory compliance

**If conditions NOT met:**
- Stay on Merkle trees (simple, battle-tested)
- Revisit in 2027

---

## Final Decision

**✅ MERKLE TREES for 2025 launch + Two-Token Lifecycle Model**

**For Private Companies (2025):**
1. **Use Merkle trees** for cap table privacy (production-ready now)
2. **Standard compliance infrastructure** (KYC/sanctions always public)
3. **Off-chain storage** (IPFS/Arweave for full cap table)
4. **Selective disclosure** (board/regulators get access)

**For Public Companies (post-IPO):**
1. **Two-token migration** (burn private → mint public)
2. **Standard ERC-20** (visible balances, SEC-compliant)
3. **Broker-dealer aggregation** (enable retail without bloat)
4. **Compliance layer unchanged** (KYC/sanctions always enforced)

**Reasoning:**
1. ✅ Production-ready technology (OpenZeppelin)
2. ✅ Extremely low implementation cost ($5-10K)
3. ✅ Minimal gas overhead (~21K per update)
4. ✅ Battle-tested and simple (Uniswap, OpenSea use it)
5. ✅ Regulatory path clear (full disclosure when needed)
6. ✅ Lifecycle model matches securities law (private → public)
7. ✅ Broker model enables scale without reinventing infrastructure

**Future options:**
- **FHE (Zama):** Monitor for production-readiness (2026+)
- **Private chains:** Evaluate if bridge security proves out (2026+)
- **Broker partnerships:** Enable Robinhood, Schwab, Coinbase integration

**Private chains and FHE are the future, but Merkle trees are pragmatic now.**

We build with Merkle trees, enable broker integration, and maintain optionality for better privacy tech when ready.

---

## Competitive Advantage

**Our Complete Privacy Strategy:**

1. **Lifecycle-Aware Privacy**
   - Carta = centralized, private cap tables ✅
   - Securitize = permissioned blockchain ⚠️
   - **Us = Privacy when needed (private), transparency when required (public)** ✅✅

2. **Scalability via Brokers**
   - Direct ownership for institutions/whales
   - Broker aggregation for retail (like traditional markets)
   - No cap table bloat (50-100 addresses vs millions)
   - User choice (self-custody OR custodial)

3. **Regulatory Alignment**
   - Private phase: Merkle privacy + regulator access
   - IPO: Two-token migration (matches securities law)
   - Public phase: Transparency + KYC (SEC-compliant)
   - Broker model: Already regulated entities (SEC/FINRA)

4. **Future-Proof Architecture**
   - Can upgrade to FHE when production-ready
   - Can migrate to private chains if beneficial
   - Broker integration enables traditional finance bridge
   - Low cost to maintain and evolve

**This is pragmatic AND scalable.**

Carta has network effects. We have **privacy + compliance + decentralization + scale**.

---

## Conclusion

**Phased rollout:**
1. **Testnet/pilots** - Ship Phase 0 features without privacy
2. **Private company launch (Q2 2025)** - Add Merkle tree privacy
3. **Public company readiness (Q3-Q4 2025)** - Build two-token migration
4. **Broker integration (2025-2026)** - Enable retail scale
5. **Future upgrades (2026+)** - Evaluate FHE/private chains

**Key principles:**
- Privacy is critical for PRIVATE companies
- Transparency is required for PUBLIC companies
- Compliance is mandatory ALWAYS
- Scalability requires broker aggregation
- Ship fast, maintain optionality

