# Decision 02 – Migration from T-REX to CMTAT

- **Date**: 2025-10-23
- **Status**: Accepted
- **Context**: T-REX compliance modules use dual licensing (GPL-3.0 + CC-BY-NC-4.0) creating legal ambiguity for commercial use. Additionally, T-REX requires complex identity infrastructure (OnchainID, IdentityRegistry) that adds significant deployment costs and complexity.

## Options Considered

1. **Continue with T-REX and accept licensing risk** ❌
2. **Migrate to CMTAT (MPL-2.0 licensed, simpler architecture)** ✅
3. **Build custom compliance system from scratch** ❌

## Decision

Migrate from Tokeny's T-REX (ERC-3643) to CMTA's CMTAT framework using a minimal implementation approach.

## Rationale

### Legal Clarity
- **T-REX Problem**: Dual licensing (GPL-3.0 + CC-BY-NC-4.0) creates contradictory terms
  - GPL-3.0 allows commercial use
  - CC-BY-NC-4.0 prohibits commercial use
  - Creates legal uncertainty for VC-backed companies
- **CMTAT Solution**: MPL-2.0 (Mozilla Public License) provides clear commercial use rights
  - Weak copyleft (file-level, not project-level)
  - Only requires open-sourcing changes to CMTAT files themselves
  - Custom contracts can remain closed-source
  - VC/investor friendly

### Technical Superiority
- **Simpler Architecture**: CMTAT has NO identity registry requirements
  - T-REX: 9 contracts per company (IdentityRegistry, TrustedIssuersRegistry, ClaimTopicsRegistry, ModularCompliance, Token, 4+ compliance modules)
  - CMTAT: 1 contract per company (CMTATShareToken with built-in compliance)
  - 80% reduction in contracts
- **Built-in Features**: CMTAT includes features T-REX lacks
  - ✅ Snapshot module (for dividends) - we can delete our custom 130-line implementation
  - ✅ Partial freezing (freeze subset of tokens, not just full address)
  - ✅ Document management (ERC-1643)
  - ✅ Gasless transactions (EIP-2771)
  - ✅ Better error messages (ERC-1404 standard error codes)
- **Flexible Compliance**: RuleEngine pattern is more extensible than T-REX's module array
  - Single RuleEngine can serve multiple tokens (shared infrastructure)
  - Rules are stateless and reusable
  - Better error reporting with specific error codes

### Cost Savings
- **Per Company Deployment**:
  - T-REX: ~2,980k gas (~$223 @ 30 gwei, $2500 ETH)
  - CMTAT Minimal: ~1,210k gas (~$91)
  - **Savings: 59% ($132 per company)**
- **Per Investor Onboarding**:
  - T-REX: ~200k gas (OnchainID deployment)
  - CMTAT: ~50k gas (simple mapping)
  - **Savings: 75% ($11 per investor)**

### Ecosystem & Governance
- **T-REX**: Controlled by single for-profit company (Tokeny sàrl)
- **CMTAT**: Governed by Swiss non-profit consortium (CMTA)
  - Members: Deutsche Bank, Taurus, Swiss banks, legal firms
  - Industry standard in Swiss financial sector
  - Multi-stakeholder governance
  - Active development and audits

### Risk Mitigation
- **Current State**: No freeze/unfreeze calls in codebase (clean migration)
- **Snapshot Compatibility**: CMTAT has built-in snapshots matching our API
- **Test Scope**: Only 9 test files to update
- **Rollback Plan**: Easy rollback until production deployment

## Implementation Notes

### Phase 1: Minimal Migration (4 Weeks)

**Week 1: Create CMTATShareToken**
```solidity
import "lib/CMTAT/contracts/modules/1_CMTATBaseRuleEngine.sol";

contract CMTATShareToken is CMTATBaseRuleEngine {
    uint256 public authorizedShares;
    address public companyAddress;

    function initialize(
        address _companyAddress,
        string memory _name,
        string memory _symbol,
        uint256 _initialAuthorizedShares,
        address _snapshotEngine
    ) external initializer {
        __CMTAT_init(
            _companyAddress,
            ICMTATConstructor.ERC20Attributes({
                name: _name,
                symbol: _symbol,
                decimals: 6,
                decimalsIrrevocable: true
            }),
            ICMTATConstructor.ExtraInformationAttributes({
                tokenId: "",
                terms: "",
                information: ""
            }),
            ICMTATConstructor.Engine({
                ruleEngine: IRuleEngine(address(0)),  // No rules initially
                snapshotEngine: ISnapshotEngine(_snapshotEngine),
                documentEngine: IERC1643(address(0))
            })
        );

        authorizedShares = _initialAuthorizedShares;
        companyAddress = _companyAddress;
        _tokenPaused = true;  // Start paused
    }

    function issueShares(address _to, uint256 _amount) external onlyCompany {
        require(totalSupply() + _amount <= authorizedShares, "Cannot mint more shares auth.");
        mint(_to, _amount);
    }

    // DELETE custom snapshot code (lines 20-210 in ShareToken.sol)
    // CMTAT has it built-in via SnapshotEngineModule
}
```

**Week 2: Update CompanyFactory**
- Remove ModularCompliance deployment
- Remove compliance modules deployment (CountryRestrict, TimeTransfers, etc.)
- Add SnapshotEngine deployment (one-time, shared)
- Update to deploy CMTATShareToken instead of ShareToken
- KEEP IdentityRegistry deployment (for minimal migration)

**Week 3: Update Company.sol**
- Remove `IModularCompliance` parameter from `initialize()`
- Update `ShareToken` → `CMTATShareToken` types
- Remove compliance storage variable

**Week 4: Integration Testing**
- Update 9 test files
- Remove compliance module tests
- Deploy to testnet
- Verify gas savings

### Phase 2: Full Migration (Optional, Month 2+)

**Optional future enhancements:**
- Replace IdentityRegistry with D01KYCRegistry (centralized KYC)
- Add InvestorCountryRegistry for jurisdiction controls (simpler than OnchainID)
- Implement custom rules via RuleEngine (if needed)
- Full gas savings: 76% vs current 59%

### Key Changes

**What Changes:**
- ShareToken.sol → CMTATShareToken.sol (delete 130 lines of snapshot code)
- CompanyFactory.sol (remove ModularCompliance deployment)
- Company.sol (remove IModularCompliance parameter)
- 9 test files (update token type, remove compliance setup)

**What Stays the Same:**
- ERC-20 interface (transfer, mint, burn, etc.)
- Company governance structure
- Vault functionality
- Share class pattern (separate tokens per class)
- Investor onboarding flow (keeping IdentityRegistry initially)

**Breaking Changes:**
- None for minimal migration (API-compatible)
- Future: `.freeze()` → `.setAddressFrozen()` (if we add freezing)

## Implementation Status

### 🔄 IN PROGRESS - CMTAT Migration

**Phase**: Research & Planning Complete

**Next Steps**:
1. Create `src/tokens/CMTATShareToken.sol`
2. Test snapshot functionality works with CMTAT built-in
3. Update CompanyFactory deployment logic
4. Update test suite

## References

### CMTAT Resources
- [CMTAT Repository](https://github.com/CMTA/CMTAT)
- [CMTA Organization](https://cmta.ch/)
- [CMTAT Specification](https://github.com/CMTA/CMTAT/blob/master/doc/general/CMTAT_SPECIFICATION.md)
- [Security Audit (Halborn)](https://github.com/CMTA/CMTAT/tree/master/doc/audits)

### Licensing
- [MPL-2.0 License](https://www.mozilla.org/en-US/MPL/2.0/)
- [MPL-2.0 FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)
- [GPL-3.0 License](https://www.gnu.org/licenses/gpl-3.0.en.html)
- [CC-BY-NC-4.0 License](https://creativecommons.org/licenses/by-nc/4.0/)

### Comparison Articles
- [CMTAT vs ERC-3643 vs ERC-1400](https://www.taurushq.com/blog/security-token-standards-compared-cmtat-solidity-code-vs-erc-1400-vs-erc-3643/)
- [CMTAT in Swiss Finance](https://www.taurushq.com/blog/security-token-standards-a-closer-look-at-cmtat/)

### Internal Documentation
- [Proposal 05: CMTAT Migration](../proposals/05_CMTAT_MIGRATION/05_CMTAT_MIGRATION.md)
- [CMTAT Concepts Parallel](../proposals/05_CMTAT_MIGRATION/05_CMTAT_CONCEPTS_PARALLEL.md)
- [CMTAT D1 Implementation](../proposals/05_CMTAT_MIGRATION/05_01_CMTAT_D1_IMPLEMENTATION.md)
