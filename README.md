# obolos - Decentralized Incorporation & Ownership of the full lifecyle of a company's equity journey

[![CI](https://github.com/equitylayer/contracts/workflows/CI/badge.svg)](https://github.com/equitylayer/contracts/actions)
[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.35-blue.svg)](https://docs.soliditylang.org)

A protocol for incorporating companies on-chain using CMTAT security tokens with built-in compliance, shareholder management, vesting schedules, option pools, and SAFE instruments.

[Deployed on Arbitrum sepolia](./421614.contracts.json).

## Quick Links

**Get Started**
- **[Coding Standards](docs/CODING_STANDARDS.md)** - What to keep in mind when developing
- **[Terminology](./docs/OBOLOS_TERMINOLOGY.md)** - Shorthand terms and what they mean
- **[Decision Records](./docs/decisions)** - All important ADRs (Architecture)

**Engineering & Design**
- **[Ownership & Control](./docs/OWNERSHIP.md)** - Who controls each contract
- **[Contract Relations](docs/SC_RELATIONS.md)** - Diagram of contract ownership & calls

**Business / Product Documentation**

Lives in [equitylayer/documentation](https://github.com/equitylayer/documentation):
- [Whitepaper](https://github.com/equitylayer/documentation/blob/main/WHITEPAPER.md), [Equity 101](https://github.com/equitylayer/documentation/blob/main/EQUITY_101.md), [Compliance & KYC](https://github.com/equitylayer/documentation/blob/main/COMPLIANCE.md)
- [Security audits](https://github.com/equitylayer/documentation/tree/main/audits), [feature proposals](https://github.com/equitylayer/documentation/tree/main/proposals), [migration plans](https://github.com/equitylayer/documentation/tree/main/migrations)
- [Strategic positioning & market analysis](https://github.com/equitylayer/documentation/tree/main/business_planning), [sample legal docs](https://github.com/equitylayer/documentation/tree/main/samples)


**External**
- **[Foundry Book](https://book.getfoundry.sh/)** - Foundry documentation
- **[CMTAT](https://github.com/CMTA/CMTAT)** - CMTAT standard
- **[Y Combinator SAFE](https://www.ycombinator.com/documents)** - Post-money SAFE primer

---

## Development

### Prerequisites

**Foundry** (required):

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup # to update
```

Optional developer tooling:
- **[Python](https://www.python.org/downloads/)** - needed for Python-based security tools such as Slither and Mythril
- **[nvm](https://github.com/nvm-sh/nvm)** - recommended Node.js version manager for JavaScript dependencies
- **[Rust / Cargo](https://rustup.rs/)** - needed for Rust-based tools such as Aderyn

**Noir + Barretenberg** (required for ZK SAFE / ConvertibleNote circuits):

```bash
# noirup (official. same pattern as rustup)
curl -L https://raw.githubusercontent.com/noir-lang/noirup/main/install | bash
source ~/.zshrc                # or restart terminal
noirup                         # installs latest stable nargo to ~/.nargo/bin

# Barretenberg (verifier codegen + proof generation).
mkdir -p ~/.bb
ARCH=$(uname -m); case "$ARCH" in arm64|aarch64) BB_ARCH="arm64-darwin";; x86_64) BB_ARCH="amd64-darwin";; esac
LATEST=$(curl -s https://api.github.com/repos/AztecProtocol/aztec-packages/releases?per_page=20 | grep '"tag_name"' | grep -v nightly | grep -v commit | head -1 | awk -F'"' '{print $4}')
curl -sL "https://github.com/AztecProtocol/aztec-packages/releases/download/${LATEST}/barretenberg-${BB_ARCH}.tar.gz" | tar -xz -C ~/.bb

# Persist PATH:
echo 'export PATH="$HOME/.nargo/bin:$HOME/.bb:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify:

```bash
nargo --version    # e.g. nargo 0.36.0
bb --version       # e.g. 0.x
```

### Build & Test

```bash
yarn install
forge build [--sizes]                    
forge test  [--match-test NAME] [--gas-report]                
forge fmt                      
```

## Security Scanning

### Install Tools

```bash
pip install slither-analyzer mythril
cargo install aderyn
```

### Run

```bash
./security-scan.sh              # Run all (Slither + Aderyn + Mythril)
./security-scan.sh slither      # Slither only
./security-scan.sh aderyn       # Aderyn only
./security-scan.sh mythril      # Mythril only (slow)
./security-scan.sh --skip-compile slither  # Skip forge build
```

Reports are saved to `security-reports/`.

### Deploy Locally

```bash
# Terminal 1: Start Anvil
anvil

```

**Configure Factory Settings** (optional): create `config/factory-config.json`:
```json
{
  "treasury": "0xYourTreasuryAddress",
  "deploymentFee": "100000000000000000",
  "shareClassFee": "10000000000000000",
  "owner": "0xYourOwnerAddress"
}
```

Defaults: Treasury = deployer, Deployment Fee = 0.1 ETH, Share Class Fee = 0.01 ETH

```bash
# Terminal 2: Deploy everything
./deploy.sh

# Or manually:
# 1. Deploy mocks (EAS, Chainalysis)
forge script script/DeployDevelopment.s.sol --rpc-url http://localhost:8545 --broadcast

# 2. Deploy platform (attestation + factory)
forge script script/DeployFactories.s.sol --rpc-url http://localhost:8545 --broadcast
```

**Output files:**
- `config/mocks.31337.json` - Mock contract addresses
- `config/deployments.31337.json` - Platform addresses + schemas

### Technology Stack

- **Solidity 0.8.35** / **Foundry** - Language & framework
- **CMTAT 2.x** - Swiss CMTA security token standard (MPL-2.0)
- **OpenZeppelin 5.x** - Audited contract libraries
- **ERC-20 / ERC-1404 / ERC-1643 / EIP-2771** - Token, compliance, docs, meta-tx standards
- **Chainalysis Oracle** - OFAC sanctions screening
- **EIP-1167 Minimal Proxies** - Gas-efficient factory deployments

---

## Architecture

### Deployment Structure

```
Platform (obolos) - Deploys Once per Chain
├── CompanyFactory (deploys companies)
├── RuleFactory (creates compliance rules)
├── ProviderRegistry (attestation providers)
├── AttestationProvider (KYC/accreditation)
└── Platform Shared Rules (OFAC sanctions, etc.)

Per-Company Deployment
├── Company Contract (governance + operations)
├── CompanyVault (treasury)
├── ShareholderRegistry (tracks all shareholders)
├── ShareToken (CMTAT-based share class tokens)
├── VestingSchedule (founder/employee vesting)
├── OptionPool (equity compensation with 409A tracking)
├── SAFE (SAFE instruments)
├── Fundraise (fundraising rounds with whitelist)
├── DataRoom (FHE-encrypted document storage)
└── Custom Compliance Rules (lockup, trading control)
```

### Core Components

#### Platform Infrastructure (Deployed Once)

| Contract | Purpose |
|----------|---------|
| **CompanyFactory** | Permissionless company deployments with fee management |
| **RuleFactory** | Creates platform-approved compliance rules |
| **ProviderRegistry** | Registry of approved attestation providers (UUPS upgradeable) |
| **AttestationProvider** | obolos's KYC/accreditation attestation service |
| **Platform OFAC Rule** | Shared sanctions screening (Chainalysis oracle) |

#### Company Governance & Treasury

| Contract | Purpose |
|----------|---------|
| **Company** | Central governance (board control, share issuance, dividends) |
| **CompanyVault** | Treasury for ETH/token holdings (isolated from governance) |

#### Share Management

| Contract | Purpose |
|----------|---------|
| **ShareToken** | CMTAT-based security token with compliance, snapshots, ERC-1643 docs, partial freezing, gasless tx (EIP-2771) |
| **ShareholderRegistry** | Enumerates all shareholders per share class (enables dividend distribution) |

#### Equity Instruments

| Contract | Purpose |
|----------|---------|
| **VestingSchedule** | Time-based vesting with cliff, revocation, multiple schedules per beneficiary |
| **OptionPool** | 409A tracking, pool management, grants with vesting, exercise/revocation |
| **SAFE** | Valuation cap + discount, capacity reservation, automatic conversion |
| **Fundraise** | SAFE/equity rounds, whitelist, investment limits, consolidation |
| **DataRoom** | FHE-encrypted document rooms with per-folder keys, operator escrow |

#### Compliance Rules

| Contract | Purpose |
|----------|---------|
| **RuleLockup** | Time-based transfer restrictions (vesting integration) |
| **RuleTradingControl** | Enable/disable trading (board controlled) |
| **RuleSanctionList** | OFAC sanctions screening (shared platform instance) |

---

## Ownership Model

See **[docs/OWNERSHIP.md](./docs/OWNERSHIP.md)** for full details.

**Platform-Level (obolos Controls):**
- CompanyFactory, RuleFactory, ProviderRegistry, AttestationProvider, Platform OFAC Rule

**Company-Level (Board Controls):**
- Company, ShareToken, SnapshotEngine, RuleEngine, Vault, VestingSchedule, OptionPool, SAFE, ShareholderRegistry

**Key Patterns:**
- **Board** = Ultimate authority (Gnosis Safe multisig recommended)
- **Company Contract** = Executes board decisions via MINTER_ROLE
- **Vault** = Treasury (isolated, only Company can access)
- **Capacity Protection** = minted + options + SAFEs <= authorized
- **Automatic Role Management** = Factory grants roles during deployment, then renounces
- **7-Day Timelock** = Board transfer requires 7-day wait

---

## Features

### Share Token Management
- Multiple share classes (Common, Preferred, etc.)
- Authorized shares cap enforced on all mint paths
- Capacity protection for options and SAFEs
- Auto-tracked shareholder registry per class
- Snapshot support for dividends

### Vesting & Lock-ups
- Linear vesting after cliff (Founder 4yr/1yr, Employee 4yr/1yr, Advisor 2yr/6mo)
- Revocable schedules with sanctioned-beneficiary handling
- Lock-up enforcement via RuleLockup
- Multiple schedules per beneficiary, discrete vesting (whole shares only)

### Option Pool Management
- Board-controlled pool size (reserved from authorized shares)
- 409A valuation tracking (IRS requirement)
- Grant management with custom vesting/cliff
- Exercise tracking, revocation with 90-day exercise window

### SAFE Instruments
- Valuation cap + discount rate, best-price guarantee
- Worst-case capacity reservation from authorized shares
- Automatic conversion on priced round (post-money Y Combinator formula)
- Cancel erroneously issued SAFEs

### Fundraising Rounds
- SAFE or equity rounds with whitelist and investment limits
- Investment consolidation (multiple investments per investor)
- Round lifecycle (open, close, cancel)

### Dividends
- ETH and ERC20 token dividends, snapshot-based distribution
- Reservation system prevents spending dividend funds
- Auto-iterate shareholders, vault/vesting excluded

### Compliance & Rules
- OFAC sanctions (Chainalysis oracle), lock-up periods, trading control
- Modular rule engine, ERC-1404 error codes
- Dynamic rule management without redeployment

### Governance
- Board-controlled with multi-sig support
- 7-day timelock on board transfers
- Vault isolation from governance

---

## Key Concepts

### Capacity Model

The system enforces a single invariant across all share issuance paths:

```
totalSupply + poolSize + outstandingOptions <= authorizedShares
 (minted)    (reserved    (granted, not
              for NEW       yet exercised)
              grants)
```

Enforced at: `OptionPool.increasePoolSize()`, `CompanyIssuance._checkOptionPoolCapacity()`, and `ShareToken._update()` (hard ceiling on all mints).

#### Issuance Paths

All share issuance flows through `CompanyIssuance._issueShares()`, but with different callers and capacity behavior:

| Path | Caller | Capacity Check | Why |
|------|--------|----------------|-----|
| `issueShares()` | Board | Yes | Direct issuance must not eat into option pool |
| `issueSharesFromOptionPool()` | OptionPool | **No** | Exercise reduces `outstanding` by same amount, invariant stays balanced |
| `issueSharesFromSAFE()` | SAFE | Yes | SAFEs don't pre-reserve; checked at mint time |
| `issueSharesFromConvertibleNote()` | ConvertibleNote | Yes | Same as SAFE — debt converts to equity |
| `issueSharesFromFundraise()` | Fundraise | Yes | Priced round investor buys shares |
| `issueSharesWithVesting()` | Board | Yes | Shares minted to VestingSchedule, released over time |

```
Start: 10M authorized, 0 issued, 0 pool, 0 outstanding

1. Board creates 3M option pool        → 0 + 3M + 0 = 3M  <= 10M ✓
2. Board issues 5M to founders         → 5M + 3M + 0 = 8M  <= 10M ✓
3. Board grants 2M options to employees → 5M + 1M + 2M = 8M  <= 10M ✓
   (pool shrinks by 2M, outstanding grows by 2M)
4. Board tries to issue 3M to investor → 5M + 3M + 1M + 2M = 11M > 10M ✗
   → reverts WouldConsumeOptionPoolCapacity
5. Board increases authorized to 15M, then issues 3M
                                        → 8M + 1M + 2M = 11M <= 15M ✓
6. Employee exercises 1M options        → 9M + 1M + 1M = 11M <= 15M ✓
   (totalSupply +1M, outstanding -1M — net zero)
```

---

## License

BUSL-1.1. See [LICENSE](LICENSE).
