# Decision 01 – Contract Deployment Pattern

- **Date**: 2025-10-15
- **Status**: Accepted
- **Context**: CompanyFactory bytecode exceeded the 24 KB limit (~70 KB) when instantiating child contracts with `new`.

## Options Considered

1. Use external contract references (quick fix, non-standard) ❌  
2. **Adopt EIP-1167 minimal proxies (OpenZeppelin Clones)** ✅  
3. Split functionality across multiple factories (additional complexity) ❌

## Decision

Adopt the EIP-1167 minimal proxy pattern for deploying companies, share tokens, vaults, and compliance modules via the factory.

## Rationale

- Proven pattern used by Uniswap V3, Gnosis Safe, and Compound.
- Reduces deployment gas (~45k gas per clone vs. >3M using `new`).
- Keeps factory bytecode between ~3–10 KB, well below the 24 KB limit.
- Backed by OpenZeppelin libraries and extensive audits.

## Implementation Notes

```solidity
import "@openzeppelin/contracts/proxy/Clones.sol";

contract CompanyFactory {
    address public immutable companyImplementation;
    address public immutable vaultImplementation;
    address public immutable shareTokenImplementation;
    address public immutable complianceImplementation;

    constructor(
        address _companyImpl,
        address _vaultImpl,
        address _shareTokenImpl,
        address _complianceImpl
    ) {
        companyImplementation = _companyImpl;
        vaultImplementation = _vaultImpl;
        shareTokenImplementation = _shareTokenImpl;
        complianceImplementation = _complianceImpl;
    }

    function deployCompany(...) external returns (...) {
        address company = Clones.clone(companyImplementation);
        address vault = Clones.clone(vaultImplementation);
        address token = Clones.clone(shareTokenImplementation);
        address compliance = Clones.clone(complianceImplementation);

        Company(company).initialize(...);
        // ...
    }
}
```

- All cloned contracts must expose an `initialize` function (no constructors).
- Guard clones against re-initialization with OpenZeppelin `Initializable`.
- Implementation contracts are deployed once per network; the factory stores their addresses as `immutable`.

## Implementation Status

### ✅ COMPLETED - EIP-1167 Clones Pattern

**Date**: 2025-10-15

**Changes Made**:
1. ✅ **ShareToken.sol** - Replaced constructor with `init()` function
2. ✅ **Company.sol** - Replaced constructor with `initialize()` function
3. ✅ **CompanyFactory.sol** - Replaced `new` calls with `Clones.clone()`
4. ✅ **Documentation** - Created `.claude/` directory with comprehensive guides

**Contract Changes**:
- `CompanyFactory` now stores immutable implementation addresses
- Constructor takes 3 implementation addresses: Company, ShareToken, ModularCompliance
- `deployCompany()` clones implementations instead of using `new`
- Only `CompanyVault` still uses `new` (has immutable company address)


## References

- [EIP-1167: Minimal Proxy Contract](https://eips.ethereum.org/EIPS/eip-1167)  
- [OpenZeppelin Clones Documentation](https://docs.openzeppelin.com/contracts/4.x/api/proxy#Clones)  
- [Gnosis Safe Proxy Factory](https://github.com/safe-global/safe-contracts/blob/main/contracts/proxies/GnosisSafeProxyFactory.sol)
