# Shorthand Reference

This reference collects the abbreviations and short names used across the obolos documentation so that readers can quickly translate each shorthand into the underlying concept.

## Platform & Roles

| Short | Full Term | Context |
|-------|-----------|---------|
| obolos | Platform operator account | Deployer/governance entity that controls platform-level infrastructure. |
| Board | Company board multisig | Per-company governance address that owns ShareToken and compliance contracts. |
| Operator | Platform operator key | Immutable address set at DataRoom initialization. Has read access to all FHE-encrypted folder keys. Cannot be revoked. |
| EOA | Externally Owned Account | Standard wallet (not a contract); several docs require new board addresses to be EOAs. |

## Contract Suite

| Short | Full Term | Context |
|-------|-----------|---------|
| CMTAT | Capital Markets and Technology Association Token | Swiss CMTA standard for security tokens (MPL-2.0 licensed). |
| RE | RuleEngine | Modular compliance engine for transfer validation (per token). |
| SE | SnapshotEngine | Point-in-time balance recording for dividends (per token). |
| SR | ShareholderRegistry | Tracks all shareholders per token for enumeration. |
| VS | VestingSchedule | Time-based vesting with cliff support (per company). |
| OP | OptionPool | Equity compensation with 409A valuation tracking (per company). |
| SAFE | SAFE | SAFE instrument management (per company). |
| CN | ConvertibleNote | Debt-to-equity convertible instruments with interest accrual (per company). |
| FR | Fundraise | Fundraising rounds with whitelist and investment management (per company). |
| DR | DataRoom | FHE-encrypted document storage with per-folder access control (per company). |

## Standards & Architecture

| Short | Full Term | Context |
|-------|-----------|---------|
| ERC | Ethereum Request for Comments | Specification prefix for Ethereum standards (e.g., ERC-20, ERC-3643). |
| EIP | Ethereum Improvement Proposal | Process document describing proposed protocol or contract standards. |
| UUPS | Universal Upgradeable Proxy Standard | Upgrade pattern used by CompanyFactory and other upgradeable contracts. |
| IPFS | InterPlanetary File System | Content-addressed storage used for company metadata URIs. |
| RPC | Remote Procedure Call | Endpoint used by tooling (Forge, scripts) to talk to an Ethereum node. |
| URI | Uniform Resource Identifier | Generic string reference (used for metadata pointers). |

## Encryption & Privacy

| Short | Full Term | Context |
|-------|-----------|---------|
| FHE | Fully Homomorphic Encryption | Encryption scheme allowing computation on ciphertexts. Used in DataRoom for access-controlled key storage. |
| CoFHE | Coprocessor FHE | Fhenix's coprocessor-based FHE model — offloads FHE operations from the EVM. |
| Fhenix | Fhenix Protocol | FHE provider used for DataRoom encryption (see [ADR-05](decisions/05_2026-03-21_fhenix_fhe_provider.md)). |
| CEK | Content Encryption Key | Symmetric key that encrypts a document's content. Wrapped (encrypted) with the folder's FHE room key. |
| CID | Content Identifier | Content-addressed hash used by Storacha/IPFS to locate document data. |
| Storacha | Storacha | Decentralized storage layer where encrypted document blobs are stored. Documents referenced by CID on-chain. |

## Financial Instruments

| Short | Full Term | Context |
|-------|-----------|---------|
| SAFE | Simple Agreement for Future Equity | Convertible instrument with valuation cap and/or discount rate. |
| SAFT | Simple Agreement for Future Tokens | Convertible instrument for token projects (similar to SAFE). |
| CN | Convertible Note | Debt instrument that converts to equity on a qualifying event, with principal + accrued interest. |
| CC | Company Capitalization | Total shares (including all converting instruments) used as denominator in YC post-money SAFE conversion. Solved via `CC = (FD + knownShares) / (1 - Σ(inv_i / cap_i))`. |
| FD | Fully Diluted (shares) | Total shares outstanding before conversion — the base input to the CC formula. |
| QFT | Qualified Financing Threshold | Minimum round size that triggers automatic SAFE/Note conversion. If 0, any priced round triggers conversion. |
| MFN | Most Favored Nation | SAFE clause where conversion terms match the best terms given to any subsequent SAFE investor. |
| PPS | Price Per Share | Price at which new shares are sold in a priced round; used to compute discount-path conversion. |
| 409A | IRS Section 409A Valuation | Fair market value determination required for stock options (tax compliance). |
| ISO | Incentive Stock Option | Tax-advantaged employee stock options (US tax code). |
| NSO | Non-Qualified Stock Option | Standard stock options without special tax treatment. |
| FMV | Fair Market Value | Current market value used for option pricing (from 409A valuation). |
| BPS | Basis Points | 1/100th of a percent (e.g., 2000 bps = 20%). Used for discount rates and interest rates. |

## Compliance & Regulation

| Short | Full Term | Context |
|-------|-----------|---------|
| KYC | Know Your Customer | Regulatory requirement to verify investor identity. |
| AML | Anti-Money Laundering | Compliance checks against illicit finance. |
| SEC | U.S. Securities and Exchange Commission | Regulator referenced for U.S. securities compliance (Reg D, Rule 144). |
| MiFID II | Markets in Financial Instruments Directive II | EU regulatory framework referenced in compliance notes. |
| ESMA | European Securities and Markets Authority | EU regulator enforcing MiFID II. |
| FINMA | Swiss Financial Market Supervisory Authority | Swiss regulator referenced in compliance proposals. |
| LEI | Legal Entity Identifier | Global identifier sometimes required for institutional investors. |
| SSN | Social Security Number | U.S. identifier referenced in onboarding requirements. |

## Product & Development

| Short | Full Term | Context |
|-------|-----------|---------|
| DApp | Decentralized Application | Frontend that interacts with the smart contracts. |
| API | Application Programming Interface | Backend endpoint layer (e.g., deployment relayer). |
| SDK | Software Development Kit | Helper libraries referenced for integration. |
| UI | User Interface | Visual layer presented to end users. |
| UX | User Experience | Overall flow/interaction quality referenced in workflow docs. |
| MVP | Minimum Viable Product | Early product milestone referenced in deployment guides. |
| ETH | Ether | Native currency used for paying deployment fees. |
