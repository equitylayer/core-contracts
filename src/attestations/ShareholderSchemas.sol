// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title ShareholderSchemas
/// @notice Schema definitions for D01 shareholder attestations
/// @dev Three schemas grouped by update frequency:
///      1. D01Identity - Stable (country, KYC, sanctions) - updates every 1-2 years
///      2. D01Accreditation - Expires (accreditation, QP) - updates periodically (e.g., 90 days to 1 year)
///      3. D01Tax - Annual (tax residency, forms)
///
/// All schemas include:
/// - providerId: Source identifier (e.g., "obolos:sumsub", "obolos:parallelmarkets")
/// - externalId: Optional external reference for off-chain linking
library ShareholderSchemas {
    string internal constant VERSION = "0.9.0";

    // KYC Levels
    uint8 constant KYC_NONE = 0;
    uint8 constant KYC_BASIC = 1; // ID verified
    uint8 constant KYC_ENHANCED = 2; // ID + address + source of funds

    // Investor Types
    uint8 constant INVESTOR_INDIVIDUAL = 0;
    uint8 constant INVESTOR_JOINT = 1;
    uint8 constant INVESTOR_IRA = 2;
    uint8 constant INVESTOR_TRUST = 3;
    uint8 constant INVESTOR_LLC = 4;
    uint8 constant INVESTOR_CORPORATION = 5;
    uint8 constant INVESTOR_PARTNERSHIP = 6;
    uint8 constant INVESTOR_FUND = 7;

    // Accreditation Types (US - SEC Rule 501)
    uint8 constant ACCREDITED_NONE = 0;
    uint8 constant ACCREDITED_US_INCOME = 1; // $200k/$300k income
    uint8 constant ACCREDITED_US_NET_WORTH = 2; // $1M net worth
    uint8 constant ACCREDITED_US_PROFESSIONAL = 3; // Series 7/65/82
    uint8 constant ACCREDITED_US_ENTITY = 4; // Entity $5M+
    uint8 constant ACCREDITED_US_FAMILY_OFFICE = 5;
    // UK - FCA (Financial Promotion Order)
    uint8 constant ACCREDITED_UK_CERTIFIED_HNW = 10; // Certified High Net Worth: £100k income OR £250k assets
    uint8 constant ACCREDITED_UK_SELF_CERTIFIED_SOPHISTICATED = 11; // Self-Certified Sophisticated: 2+ unlisted investments OR director of £1M+ co
    // EU - MiFID II
    uint8 constant ACCREDITED_EU_PROFESSIONAL = 20; // Professional client (per se or elective)
    uint8 constant ACCREDITED_EU_ELIGIBLE_COUNTERPARTY = 21; // Eligible counterparty (subset of professional)
    // Switzerland - FinSA
    uint8 constant ACCREDITED_CH_PROFESSIONAL = 30; // Professional client: CHF 500k + knowledge OR CHF 2M
    uint8 constant ACCREDITED_CH_INSTITUTIONAL = 31; // Institutional client: banks, insurance, regulated entities

    // Qualified Purchaser Types (US - 3(c)(7))
    uint8 constant QP_NONE = 0;
    uint8 constant QP_INDIVIDUAL = 1; // $5M+ investments
    uint8 constant QP_FAMILY_COMPANY = 2;
    uint8 constant QP_TRUST = 3;
    uint8 constant QP_ENTITY = 4; // $25M+ investments

    // Tax Form Types
    uint8 constant TAX_FORM_NONE = 0;
    uint8 constant TAX_FORM_W9 = 1; // US person
    uint8 constant TAX_FORM_W8BEN = 2; // Non-US individual
    uint8 constant TAX_FORM_W8BENE = 3; // Non-US entity

    // ============ Schema 1: D01Identity ============
    // Stable investor data - KYC, country, sanctions
    // Updates: Every 1-2 years or when status changes
    string constant IDENTITY_SCHEMA =
        "string providerId,string externalId,uint16 countryCode,bool isUSPerson,uint8 investorType,string entityName,uint8 kycLevel,bool sanctionsCleared,uint64 verifiedAt";

    struct IdentityData {
        string providerId; // e.g., "obolos:sumsub" or "obolos:selfattest"
        string externalId; // Optional off-chain reference
        uint16 countryCode; // ISO 3166-1 numeric (e.g., 840=US, 826=GB, 756=CH)
        bool isUSPerson; // For Reg S
        uint8 investorType; // Individual, trust, LLC, etc.
        string entityName; // Empty for individuals
        uint8 kycLevel; // None, Basic, Enhanced
        bool sanctionsCleared; // OFAC/sanctions passed
        uint64 verifiedAt;
    }

    function encodeIdentity(IdentityData memory d) internal pure returns (bytes memory) {
        return abi.encode(
            d.providerId,
            d.externalId,
            d.countryCode,
            d.isUSPerson,
            d.investorType,
            d.entityName,
            d.kycLevel,
            d.sanctionsCleared,
            d.verifiedAt
        );
    }

    function decodeIdentity(bytes memory data) internal pure returns (IdentityData memory d) {
        (
            d.providerId,
            d.externalId,
            d.countryCode,
            d.isUSPerson,
            d.investorType,
            d.entityName,
            d.kycLevel,
            d.sanctionsCleared,
            d.verifiedAt
        ) = abi.decode(data, (string, string, uint16, bool, uint8, string, uint8, bool, uint64));
    }

    // ============ Schema 2: D01Accreditation ============
    // Investor qualification status - expires every 90 days typically
    // Supports multiple jurisdictions (US, UK, EU, CH)

    string constant ACCREDITATION_SCHEMA =
        "string providerId,string externalId,uint8 accreditationType,uint8 qpType,uint64 verifiedAt,uint64 expiresAt";

    struct AccreditationData {
        string providerId; // e.g., "obolos:parallelmarkets"
        string externalId;
        uint8 accreditationType; // See ACCREDITED_* constants (jurisdiction-specific)
        uint8 qpType; // Qualified purchaser type (US only, 0 for others). See QP_* constants
        uint64 verifiedAt;
        uint64 expiresAt;
    }

    function encodeAccreditation(AccreditationData memory d) internal pure returns (bytes memory) {
        return abi.encode(d.providerId, d.externalId, d.accreditationType, d.qpType, d.verifiedAt, d.expiresAt);
    }

    function decodeAccreditation(bytes memory data) internal pure returns (AccreditationData memory d) {
        (d.providerId, d.externalId, d.accreditationType, d.qpType, d.verifiedAt, d.expiresAt) =
            abi.decode(data, (string, string, uint8, uint8, uint64, uint64));
    }

    // ============ Schema 3: D01Tax ============
    // Tax residency and withholding info - annual updates

    string constant TAX_SCHEMA =
        "string providerId,string externalId,uint16 taxCountry,uint8 taxFormType,uint64 verifiedAt";

    struct TaxData {
        string providerId; // e.g., "obolos:selfAttest"
        string externalId;
        uint16 taxCountry; // ISO 3166-1 numeric (e.g., 840=US, 826=GB, 756=CH)
        uint8 taxFormType; // W9, W8BEN, W8BENE, or 0
        uint64 verifiedAt;
    }

    function encodeTax(TaxData memory d) internal pure returns (bytes memory) {
        return abi.encode(d.providerId, d.externalId, d.taxCountry, d.taxFormType, d.verifiedAt);
    }

    function decodeTax(bytes memory data) internal pure returns (TaxData memory d) {
        (d.providerId, d.externalId, d.taxCountry, d.taxFormType, d.verifiedAt) =
            abi.decode(data, (string, string, uint16, uint8, uint64));
    }
}
