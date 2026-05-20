# Contract Ownership & Control

This document defines **who controls each contract** in the obolos system.

## Quick Reference

| Contract | Owner/Admin                 | Powers | Roles | Required? |
|----------|-----------------------------|--------|-------|-----------|
| **CompanyFactory** | obolos Platform             | Deploy companies, upgrade implementations, set fees | Owner | Platform-level |
| **D01ShareToken** | Board                       | Freeze, force transfer, mint/burn (via Company) | DEFAULT_ADMIN_ROLE (Board)<br/>MINTER_ROLE (Company)<br/>BURNER_ROLE (VestingSchedule)<br/>**Custom Errors**: OnlyCompany, ZeroAddress, InvalidParameter, ExceedsAuthorizedShares | Per-company (REQUIRED) |
| **SnapshotEngine** | Board                       | Schedule record-date snapshots | DEFAULT_ADMIN_ROLE (Board)<br/>SNAPSHOOTER_ROLE (Board) | Per-company (REQUIRED) |
| **RuleEngine** | Board                       | Add/remove compliance rules | DEFAULT_ADMIN_ROLE (Board) | Per-company (REQUIRED) |
| **Company** | Board                       | Issue shares, declare dividends, manage operations | Board address | Per-company |
| **Vault** | Company Contract            | Hold treasury funds, distribute dividends | onlyCompany modifier | Per-company |
| **VestingSchedule** | Board                       | Create/revoke vesting schedules | onlyBoard modifier | Per-company |
| **OptionPool** | Board                       | Grant/exercise options, manage pool size | onlyBoard modifier | Per-company |
| **SAFE** | Board                       | Issue/cancel SAFEs; conversion driven externally by Fundraise | onlyBoard modifier<br/>onlyFundraise (for `issueSAFEFromFundraise` and privileged conversion hooks) | Per-company |
| **ConvertibleNote** | Board                       | Issue/cancel notes, repay note with ZK proof; conversion driven externally by Fundraise | onlyBoard modifier<br/>onlyFundraise (for `issueNoteFromFundraise` and privileged conversion hooks) | Per-company |
| **Fundraise** | Board                       | Create rounds, reserve spots, manage whitelist, process investments, finalize, trigger/apply/rollback joint SAFE+CN conversion | onlyBoard modifier | Per-company |
| **ShareholderRegistry** | Company Contract            | Track shareholders, register tokens | Auto-updated on transfers, token allowlist | Per-company |
| **DataRoom** | Board (via Company.board()) | Create rooms/folders, manage documents, grant/revoke access | onlyBoard modifier<br/>Operator: immutable platform key with read access to all folders | Per-company |
| **SharedHonkVerifier** + **ConversionVerifier** + **CnRepayVerifier** | obolos Platform | UltraHonk ZK proof verification for conversion and note repayment | Stateless | Platform-level (one per chain) |


## Roles & Permissions Matrix

### Board (Gnosis Safe Recommended)

| Contract | Role | Powers |
|----------|------|--------|
| **Company** | Board address | Issue shares, declare dividends, transfer board |
| **D01ShareToken** | DEFAULT_ADMIN_ROLE | Freeze, force transfer, manage roles |
| **SnapshotEngine** | SNAPSHOOTER_ROLE + DEFAULT_ADMIN_ROLE | Schedule snapshots, grant roles |
| **RuleEngine** | DEFAULT_ADMIN_ROLE | Add/remove compliance rules |
| **VestingSchedule** | onlyBoard modifier | Create/revoke vesting schedules |
| **OptionPool** | onlyBoard modifier | Manage pool size, grant/revoke options |
| **SAFE** | onlyBoard modifier | Issue SAFE directly, cancel SAFE |
| **ConvertibleNote** | onlyBoard modifier | Issue note directly, cancel note, repay note |
| **Fundraise** | onlyBoard modifier | Create rounds, manage whitelist, reservations, close/cancel/finalize rounds, trigger conversion |
| **DataRoom** | onlyBoard modifier | Create rooms/folders, manage documents, grant/revoke access, rekey |

### Operator (Platform Key)

| Contract | Role | Powers |
|----------|------|--------|
| **DataRoom** | Immutable operator address | Read all folder keys and encrypted documents. Cannot be revoked. Set once at initialization |
| **SAFE** | FHE viewing rights | Decrypt encrypted instrument terms (`inv`, `cap`, `disc`, `mfn`, `proRata`, `salt`) for off-chain conversion proving |
| **ConvertibleNote** | FHE viewing rights | Decrypt encrypted instrument terms (`principal`, `rateBps`, `cap`, `disc`, `salt`) for off-chain conversion proving |
| **Fundraise** | FHE viewing rights | Decrypt encrypted per-investor terms on reservations and investments (mirrors SAFE/CN access) |

### Company Contract

| Contract | Role | Powers |
|----------|------|--------|
| **D01ShareToken** | MINTER_ROLE | Mint shares during issuance |
| **Vault** | Only caller | Withdraw funds, pay dividends |

### VestingSchedule Contract

| Contract | Role | Powers |
|----------|------|--------|
| **D01ShareToken** | BURNER_ROLE | Burn unvested tokens when revoking schedules |

### OptionPool Contract

| Contract | Role | Powers |
|----------|------|--------|
| **Company** | Authorized caller | Issue shares when options are exercised |

### SAFE Contract

| Contract | Role | Powers |
|----------|------|--------|
| **Company** | Authorized caller | Issue shares when SAFEs convert via `_applyConversion` hook |
| **Fundraise** | Authorized caller (`onlyFundraise`) | `issueSAFEFromFundraise`, `_markPendingConversion`, `_applyConversion`, `_rollbackConversion` |

### ConvertibleNote Contract

| Contract | Role | Powers |
|----------|------|--------|
| **Company** | Authorized caller | Issue shares when notes convert via `_applyConversion` hook |
| **Fundraise** | Authorized caller (`onlyFundraise`) | `issueNoteFromFundraise`, `_markPendingConversion`, `_applyConversion`, `_rollbackConversion` |

### Fundraise Contract

| Contract | Role | Powers |
|----------|------|--------|
| **SAFE** | Authorized caller | Issue SAFEs on finalize of SAFE rounds; trigger/apply/rollback joint conversion on qualifying priced round |
| **ConvertibleNote** | Authorized caller | Issue notes on finalize of NOTE rounds; trigger/apply/rollback joint conversion on qualifying priced round |
| **Company** | Authorized caller | `issueSharesFromFundraise` for priced rounds |
| **paymentToken** (ERC-20, e.g. MUSD) | Fund holder | Investments held by Fundraise until finalize/refund (pull pattern for failed refunds) |

### Factory

| Contract | Role | Powers |
|----------|------|--------|
| **Platform** | Owner | Upgrade implementations, set fees |
| **During deployment** | Temporary admin | Transfers to board after setup |

---

## Deployment Flow

### CompanyFactory.deployCompany()

```
1. Clone Company (EIP-1167 from implementation)
2. Clone Vault (EIP-1167 from implementation)
3. Clone VestingSchedule (EIP-1167 from implementation)
4. Clone OptionPool (EIP-1167 from implementation)
5. Clone SAFE (EIP-1167 from implementation)
6. Clone Fundraise (EIP-1167 from implementation)
7. Clone ShareholderRegistry (EIP-1167 from implementation)
8. Clone ConvertibleNote (EIP-1167 from implementation)
9. Clone DataRoom (EIP-1167 from implementation)
10. Initialize all contracts (DataRoom gets company + operator address)
11. Register company in factory registry
```

**Result:** Board has full control, Factory has zero admin rights

### CompanyFactory.deployShareClass()

```solidity
1. Verify caller is registered company
2. Clone D01ShareToken (EIP-1167)
3. Deploy SnapshotEngine (fresh)
4. Deploy RuleEngine (fresh)
5. Initialize token with both engines (REQUIRED)
6. Transfer admin roles to tokenOwner (usually board)
7. Grant Company MINTER_ROLE
8. Grant VestingSchedule BURNER_ROLE (for burn-on-revoke functionality)
9. Factory renounces admin roles
10. Company registers token on ShareholderRegistry (token allowlist)
```

**Result:** New share class with separate token, snapshot engine, and rule engine

---

## Key Interactions

### Share Issuance
```
Board → Company.issueShares(className, shareholder, amount, purpose)
  → Validate shareholder is registered
  → Company.mint(shareholder, amount) [via MINTER_ROLE]
    → RuleEngine.detectTransferRestriction(0x0, shareholder, amount)
      → Check all rules (minting typically allowed)
    → If CODE_SUCCESS (0), mint succeeds
    → SnapshotEngine updates internal accounting
```

### Share Transfer
```
Shareholder → D01ShareToken.transfer(recipient, amount)
  → RuleEngine.detectTransferRestriction(sender, recipient, amount)
    → Loop through all rules (RuleLockup, RuleWhitelist, etc.)
    → Each rule returns error code (0 = success, non-zero = blocked)
  → If any rule blocks, revert with error code
  → If CODE_SUCCESS (0), execute transfer
  → SnapshotEngine updates balances
```

### Dividend Declaration & Distribution
```
1. Board → Company.declareDividend(amount, recordDate, paymentDate)
   → SnapshotEngine.scheduleSnapshot(recordDate)
   → Store dividend details
   → Emit DividendDeclared event

2. Board → Company.distributeDividend(dividendId)
   → Verify current time >= paymentDate
   → For each shareholder:
      → balance = SnapshotEngine.snapshotBalanceOf(recordDate, shareholder)
      → proRataShare = (balance / totalSupply) * dividendAmount
      → Vault.payDividend(shareholder, proRataShare)
```

### Adding Compliance Rule
```
Board → RuleEngine.addRuleValidation(ruleAddress) [via DEFAULT_ADMIN_ROLE]
  → Rule contract added to rules array
  → All future transfers now check this rule
  → Existing holdings unaffected (only transfers checked)
```

### Option Pool Management
```
1. Board → OptionPool.setPoolSize(token, poolSize)
   → Explicitly designate pool capacity (e.g., 5M shares for employee options)
   → Validates: issued + poolSize <= authorized
   → Pool is now protected when issuing shares

2. Board → Company.issueShares(className, shareholder, amount, purpose)
   → Checks that issuing won't consume pool: currentSupply + amount + poolSize <= authorized
   → If valid, issues shares
   → Pool remains fully protected (Option B approach)

3. Board → OptionPool.grantOptions(employee, token, amount, strikePrice, isISO, vestingScheduleId)
   → Validates against pool capacity: outstandingOptions + newGrant <= poolSize
   → Creates grant with vesting schedule
   → Tracks ISO vs NSO for tax treatment

4. Employee → OptionPool.exerciseOptions(grantId, amount) [+ strikePrice payment]
   → Validates grant is vested and not expired
   → Employee pays strike price in ETH to company vault
   → OptionPool calls Company.issueSharesFromOptionPool(token, employee, amount)
   → Employee receives shares

5. Board → OptionPool.revokeGrant(grantId) [on termination]
   → Vested options get 90-day exercise window
   → Unvested options are revoked immediately
   → Capacity remains reserved until grant expires or is cleaned up

6. Board → OptionPool.cleanupExpiredGrant(grantId)
   → Releases reserved capacity from expired grants
   → Frees up pool for new grants
```

---


## Ownership Transfer Pattern

### Automatic Transfer (CompanyFactory)

When deploying via `CompanyFactory.deployCompany()`, ownership transfers automatically:

```solidity
// 1. Factory deploys and initializes all contracts
// 2. Factory sets up roles
// 3. Factory transfers admin to board:

// Token admin
D01ShareToken(token).grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
D01ShareToken(token).renounceRole(DEFAULT_ADMIN_ROLE, address(this));

// SnapshotEngine admin
snapshotEngine.grantRole(SNAPSHOOTER_ROLE, msg.sender);
snapshotEngine.grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
snapshotEngine.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

// RuleEngine admin
ruleEngine.grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
ruleEngine.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

// 4. Caller (msg.sender) is now the board with full control
```

**Security Principle:**
- Factory = temporary deployer (setup only)
- Board (msg.sender) = permanent admin (governance)
- Factory renounces all admin roles immediately

---

## Recommended Production Setup

### Board Multisig Structure

Use **Gnosis Safe** with appropriate threshold:

```
Board Multisig (3-of-5 Safe)
|
+-- Board Member 1 (CEO)
+-- Board Member 2 (CFO)
+-- Board Member 3 (Independent Director)
+-- Board Member 4 (Investor Representative)
+-- Board Member 5 (Legal Counsel)
```

**Deployment Flow:**
1. Deploy Gnosis Safe with 3-of-5 threshold
2. Call `CompanyFactory.deployCompany()` from Safe
3. All board actions require 3/5 signatures
4. Monitor `BoardTransferProposed` events for hostile takeover attempts

---

## Security Considerations

### 1. Board Security
- ✅ **Use multisig (3-of-5 or higher)** - No single point of failure
- ✅ **Monitor board transfer events** - 7-day timelock provides response window
- ✅ **Rotate keys periodically** - Reduce compromise risk
- ⚠️ **Board has immense power** - Can freeze, force transfer, drain vault

### 2. RuleEngine Security
- ✅ **Rules are modular** - Board can add/remove as needed
- ✅ **CMTAT rules are audited** - RuleWhitelist, RuleBlacklist, RuleSanctionList
- ⚠️ **Custom rules not audited** - RuleLockup, RuleTradingControl (to be built)
- ⚠️ **Board can change rules** - Can disable all compliance by calling `clearRulesValidation()`

#### Protocol RuleRegistry vs per-company RuleEngine

There are **two** distinct rule mechanisms; conflating them leads to wrong assumptions about who controls compliance.

| | RuleRegistry | RuleEngine |
|---|---|---|
| **Scope** | Global (one per chain) | Per-share-class |
| **Owner** | Protocol admin (factory owner) | Board (DEFAULT_ADMIN_ROLE) |
| **Job** | Approve which rule impls are allowed in which (countryCode, entityType) | Enforce attached rules on every transfer |
| **Read at** | Attach time only (`Company.deployAndAttachRule`) | Every transfer |

**Key consequence:** if the protocol admin removes a rule impl from `RuleRegistry`, it has **no effect on already-attached rule clones in existing companies**. Their per-share-class `RuleEngine` keeps enforcing the rule on every transfer until the **board** calls `Company.detachRule(className, impl)`.

This is intentional: the protocol admin cannot unilaterally weaken a company's compliance posture. Detachment is a board-only action. As a side effect, the registry's "approved-for-jurisdiction" set can drift from the actually-attached set across companies, and that drift is normal — boards must opt into compliance changes.

### 3. Vault Security
- ⚠️ **Board can drain vault** - via `withdrawETH()` / `withdrawToken()`
- ⚠️ **Vault can be changed** - via `Company.setVault()` - old funds locked
- ✅ **Mitigations**: Multisig board, legal fiduciary duties, on-chain transparency

### 4. Snapshot Security
- ✅ **Tamper-proof record dates** - Once scheduled, cannot be changed
- ✅ **Historical balances preserved** - Dividends use snapshot, not current balance
- ⚠️ **Board can schedule snapshots** - Could manipulate record dates

---

## Access Control Summary

### D01 Platform Actions
- Deploy new companies (via CompanyFactory)
- Upgrade factory implementation (UUPS)
- Set deployment fees
- Control factory settings

### Board Actions (per company)
- Issue/burn shares (via Company contract with MINTER_ROLE)
- Increase authorized shares
- Declare and distribute dividends
- Schedule snapshots (for record dates)
- Add/remove compliance rules
- Freeze addresses or force transfers
- Transfer board control (7-day timelock)
- Withdraw from vault (via Company contract)
- Manage option pool (set pool size, grant/revoke options)
- Manage data rooms (create rooms/folders, add documents, grant/revoke access, rekey)

### Operator Actions (Platform Key)
- Read all DataRoom folder keys and encrypted documents
- Cannot be revoked or changed (immutable, set at deployment)

### Company Contract Actions
- Mint shares (delegated by board via `issueShares()`)
- Call vault functions (withdraw, pay dividends)

### Shareholder Actions
- Transfer shares (if compliant with RuleEngine rules)
- View balances and transaction history

### Option Holder Actions
- Exercise vested options (pay strike price, receive shares)
- View grant details and vested amounts

---

## Upgrade Path

### Platform Upgrades (D01)
```solidity
// D01 upgrades CompanyFactory (UUPS)
companyFactory.upgradeTo(newImplementation);
// Factory can now deploy with new logic
// Existing companies NOT affected
```

### Company Upgrades (Board)
- **Cannot upgrade token/company logic** - EIP-1167 clones are not upgradeable
- **CAN change engines**: `setRuleEngine()`, `setSnapshotEngine()`
- **CAN change rules**: Add/remove compliance rules in RuleEngine
- **Migrate if needed**: Deploy new company, transfer state manually

---

## FAQ

### Ownership & Control

**Q: Who owns the RuleEngine and SnapshotEngine?**
A: Board has DEFAULT_ADMIN_ROLE on both. They can grant/revoke roles, transfer admin, etc.

**Q: Can D01 freeze a company's tokens?**
A: No. D01 controls the factory, not individual companies. Only the board can freeze via D01ShareToken admin role.

**Q: Can board disable all compliance?**
A: Yes. Board can call `ruleEngine.clearRulesValidation()` to remove all rules. Transfers would then have no restrictions (except built-in CMTAT validations like frozen addresses).

**Q: What happens if board loses their keys?**
A: If using multisig (recommended), operations continue with remaining signers. If using single key (not recommended), control is lost. No recovery mechanism exists.

**Q: Can multiple companies share the same RuleEngine?**
A: No. Each token has its own RuleEngine instance. This allows per-company customization of compliance rules.

### Deployment

**Q: Who can deploy companies?**
A: Anyone who pays the deployment fee. CompanyFactory is permissionless - the caller automatically becomes the board.

**Q: What happens if deployment fails?**
A: Entire transaction reverts atomically - nothing gets deployed. All contracts are deployed in a single transaction.

**Q: Can I deploy without RuleEngine?**
A: No. RuleEngine is REQUIRED (production style). Initialization will revert if `address(0)` is passed.

### Compliance

**Q: Can investors transfer shares freely?**
A: Only if they pass all RuleEngine checks. Board configures which rules apply (whitelist, lockup, trading control, etc.).

**Q: Can different share classes have different compliance rules?**
A: Yes! Each share class has its own D01ShareToken + RuleEngine. Board can configure different rules per class.

**Q: Can board change compliance rules after shares are issued?**
A: Yes. Board can add/remove rules at any time via `addRuleValidation()` / `removeRuleValidation()`. Changes take effect immediately.

### Dividends

**Q: Who can withdraw from vault?**
A: Only board, via Company contract functions. Vault has `onlyCompany` modifier.

**Q: Can board steal dividend funds?**
A: Technically yes - board can call `Company.withdrawFromVault()` to withdraw all funds. Mitigations: multisig, legal duties, transparency.

**Q: What if dividend distribution runs out of gas?**
A: Transaction reverts. Board should distribute in batches or implement claim-based system for large shareholder counts.

### Security

**Q: Are the contracts audited?**
A: Base CMTAT contracts are audited. Our custom contracts (CompanyFactory, Company, Vault) are tested but not professionally audited.

**Q: What are the biggest security risks?**
A: Board key compromise, vault drainage, board transfer attacks. Use multisig + monitor events + legal accountability.

---

---

## Complete Role Matrix (OpenZeppelin AccessControl)

### D01ShareToken Roles

| Role | Holder | Purpose | Key Functions |
|------|--------|---------|---------------|
| **DEFAULT_ADMIN_ROLE** (`0x00`) | Board | Master admin | Grant/revoke all roles, freeze, force transfer |
| **MINTER_ROLE** (`keccak256("MINTER_ROLE")`) | Company contract | Mint new shares | `mint(to, amount)`, `issueShares(to, amount)` |
| **BURNER_ROLE** (`keccak256("BURNER_ROLE")`) | VestingSchedule contract | Burn tokens | `burn(from, amount)` - used when revoking vesting |

### SnapshotEngine Roles

| Role | Holder | Purpose | Key Functions |
|------|--------|---------|---------------|
| **DEFAULT_ADMIN_ROLE** (`0x00`) | Board | Master admin | Grant/revoke SNAPSHOOTER_ROLE |
| **SNAPSHOOTER_ROLE** (`keccak256("SNAPSHOOTER_ROLE")`) | Board | Schedule snapshots | `scheduleSnapshot(timestamp)`, `unscheduleSnapshot(timestamp)` |

### RuleEngine Roles

| Role | Holder | Purpose | Key Functions |
|------|--------|---------|---------------|
| **DEFAULT_ADMIN_ROLE** (`0x00`) | Board | Master admin | `addRuleValidation(rule)`, `removeRuleValidation(rule)`, `clearRulesValidation()` |

### Custom Access Patterns (Not AccessControl-based)

| Contract | Pattern | Holder | Check Method |
|----------|---------|--------|--------------|
| **Company** | `board` address field | Board | `require(msg.sender == board)` |
| **Vault** | `onlyCompany` modifier | Company contract | `require(msg.sender == company)` |
| **VestingSchedule** | `onlyBoard` modifier | Board (via Company) | `require(msg.sender == company.board())` |
| **OptionPool** | `onlyBoard` modifier | Board (via Company) | `require(msg.sender == company.board())` |
| **DataRoom** | `onlyBoard` modifier | Board (via Company) | `require(msg.sender == company.board())` |
| **DataRoom** | `operator` address | Platform operator | Immutable, set in `initialize()`. Read access to all keys/docs |
| **SAFE / ConvertibleNote** | `onlyFundraise` modifier | Fundraise contract | `require(msg.sender == address(fundraise))` (Fundraise→instrument issuance + conversion requests) |
| **SAFE / ConvertibleNote** | `FHE.allow` viewing rights | Investor, board, operator | Granted at issuance time; operator decrypts ciphertexts off-chain to drive the ZK conversion prover |

---

**Last Updated**: 2026-05-13 (Added ConvertibleNote + ZK verifiers + operator FHE-key role; clarified Fundraise auth boundary)
