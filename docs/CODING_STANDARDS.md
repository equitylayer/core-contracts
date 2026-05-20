# Coding Standards & Architecture Decisions

**Project**: obolos smart contracts

**Created**: 2025-10-15

**Updated**: 2026-03-21

**Purpose**: Permanent reference for architectural decisions and coding standards

---

## Core Principle

**Always use industry-standard solutions over custom implementations.**

When faced with architectural decisions:
1. ✅ Research how established protocols solve it (Uniswap, Aave, Compound, OpenZeppelin)
2. ✅ Use battle-tested patterns and libraries
3. ✅ Prioritize security and gas efficiency
4. ❌ Avoid "clever" custom solutions
5. ❌ Don't reinvent the wheel

---

## Architecture Decisions Log

- [Decision 01 – Contract Deployment Pattern (2025-10-15)](./01_2025-10-15_contract_deployment_pattern.md)

---

## Design Patterns to Follow

### 1. **Factory Pattern with Clones**
- ✅ Use `Clones.clone()` for deploying multiple instances
- ✅ Store implementation addresses as `immutable`
- ✅ Use `initialize()` instead of `constructor()` for cloned contracts
- ❌ Never use `new ContractName()` in factories (bloats bytecode)

### 2. **Upgradeability**
- ✅ Use UUPS (UUPSUpgradeable) for upgradeable contracts
- ✅ Use `Initializable` to prevent re-initialization
- ✅ Follow OpenZeppelin upgrade patterns
- ❌ Don't use transparent proxies (gas overhead)
- ❌ Don't mix constructor logic with initialize() logic

### 3. **Access Control**
- ✅ Use OpenZeppelin's `Ownable` / `AccessControl`
- ✅ Add timelocks for critical operations (transfers, upgrades)
- ✅ Emit events for all privileged actions
- ❌ Don't implement custom access control (security risk)

### 4. **Security**
- ✅ Use OpenZeppelin's `ReentrancyGuard`
- ✅ Use `SafeERC20` for token operations
- ✅ Add `Pausable` for emergency stops
- ✅ Follow Checks-Effects-Interactions pattern
- ❌ Never bypass SafeMath (even in Solidity 0.8+, use checked math)

### 5. **Gas Optimization**
- ✅ Use `immutable` for deployment-time constants
- ✅ Use `calldata` instead of `memory` for external function parameters
- ✅ Pack storage variables (uint256 is often overkill)
- ✅ Use events instead of storage when data doesn't need on-chain queries
- ❌ Don't prematurely optimize (readability > gas until proven bottleneck)

### 6. **Testing**
- ✅ Aim for >85% coverage
- ✅ Test access control on every privileged function
- ✅ Test edge cases (zero values, maximum values, empty arrays)
- ✅ Test reentrancy scenarios
- ✅ Use fuzz testing for complex logic
- ❌ Don't skip integration tests

---

## Libraries to Use (Industry Standard)

### Core (OpenZeppelin Contracts)
- `@openzeppelin/contracts/proxy/Clones.sol` - Minimal proxies
- `@openzeppelin/contracts/proxy/utils/Initializable.sol` - Initialization
- `@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol` - Upgrades
- `@openzeppelin/contracts/access/Ownable.sol` - Ownership
- `@openzeppelin/contracts/access/AccessControl.sol` - Role-based access
- `@openzeppelin/contracts/security/ReentrancyGuard.sol` - Reentrancy protection
- `@openzeppelin/contracts/security/Pausable.sol` - Emergency pause
- `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol` - Safe transfers

### Specialized
- CMTAT - Security token standard
- Gnosis Safe - Multi-sig wallets (not yet maybe on the frontend)
- Fhenix - FHE confidentiality

---

## Code Review Checklist

Before committing code, verify:

- [ ] **Simple code**: Is the code as simple as possible?
- [ ] **Industry Standard**: Is this how Uniswap/Aave/OpenZeppelin would do it?
- [ ] **Contract Size**: Does `forge build --sizes` show all contracts under 24KB?
- [ ] **Access Control**: Are privileged functions protected with modifiers?
- [ ] **Reentrancy**: Are external calls protected with `nonReentrant`?
- [ ] **Events**: Do state changes emit events?
- [ ] **Tests**: Do tests cover happy path + edge cases + access control?
- [ ] **Gas**: Did I use `immutable`, `calldata`, and avoid unnecessary storage?
- [ ] **Documentation**: Are functions documented with NatSpec comments?
- [ ] **Security**: Would this pass a professional audit?

---

## Resources

### Essential Reading
- [OpenZeppelin Contracts Documentation](https://docs.openzeppelin.com/contracts/4.x/)
- [Solidity Security Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [EIP-1167: Minimal Proxy Contract](https://eips.ethereum.org/EIPS/eip-1167)
- [Gnosis Safe Contracts](https://github.com/safe-global/safe-contracts)

### Reference Implementations
- [Uniswap V3 Factory](https://github.com/Uniswap/v3-core/blob/main/contracts/UniswapV3Factory.sol)
- [Aave Protocol](https://github.com/aave/aave-v3-core)
- [Compound Protocol](https://github.com/compound-finance/compound-protocol)

### Audit Reports (Study These)
- [Trail of Bits Audit Reports](https://github.com/trailofbits/publications)
- [OpenZeppelin Audit Reports](https://blog.openzeppelin.com/security-audits)
- [Consensys Diligence Reports](https://consensys.net/diligence/audits/)

---

**Remember**: When in doubt, check how OpenZeppelin, Uniswap, or Aave solved it. Don't innovate on security or architecture - innovate on product features.
