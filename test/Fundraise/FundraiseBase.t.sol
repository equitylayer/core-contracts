// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "../helpers/BaseTest.sol";
import {Fundraise} from "../../src/Fundraise.sol";
import {SAFE} from "../../src/SAFE.sol";
import {EquityIssuance} from "../../src/EquityIssuance.sol";
import {IRuleValidation} from "RuleEngine/interfaces/IRuleValidation.sol";
import {RuleSanctionList} from "Rules/rules/validation/RuleSanctionList.sol";
import {MockSanctionsList} from "../Rules/mocks/MockSanctionsList.sol";

/// @title FundraiseBaseTest
/// @notice Base test contract with shared setup and helpers for Fundraise tests
abstract contract FundraiseBaseTest is BaseTest {
    Fundraise fundraise;
    SAFE safeContract;
    // `issuance` is inherited from BaseTest; the deploy helper populates it.

    address investor1 = address(0x1001);
    address investor2 = address(0x1002);
    address investor3 = address(0x1003);

    uint256 constant MIN_INVESTMENT = 100_000; // $0.10 (6 decimals)
    uint256 constant MAX_INVESTMENT = 10e6; // $10 (6 decimals)
    uint256 constant TARGET_RAISE = 50e6; // $50 (6 decimals)
    uint256 constant HARD_CAP = 100e6; // $100 (6 decimals)

    // Valuation caps in MUSD (6 decimals) for SAFE auto-conversion tests
    uint256 constant CAP_10M_MUSD = 10_000e6;
    uint256 constant CAP_20M_MUSD = 20_000e6;
    uint256 constant CAP_5M_MUSD = 5_000e6;

    function setUp() public virtual {
        _baseSetUp();

        ShareholderRegistry deployedRegistry;
        OptionPool optionPool;
        (company, vault, vestingSchedule, deployedRegistry, optionPool, safeContract, shareToken, fundraise) =
            _deployStandardCompany();
    }

    // ===================
    // Helper Functions
    // ===================

    /// @notice Helper to create a standard SAFE round with common parameters
    function _createRound(string memory name, uint256 valuationCap, uint256 discountBps, bool whitelistOnly)
        internal
        returns (uint256)
    {
        IFundraise.RoundParams memory p = _defaultRoundParams();
        p.name = name;
        p.valuationCap = valuationCap;
        p.discountBps = discountBps;
        p.mfn = true;
        p.proRata = true;
        p.whitelistOnly = whitelistOnly;
        p.minInvestment = MIN_INVESTMENT;
        p.maxInvestment = MAX_INVESTMENT;
        p.targetRaise = TARGET_RAISE;
        p.hardCap = HARD_CAP;
        return fundraise.createRound(p);
    }

    /// @notice Helper to create a simple SAFE round with just name
    function _createSimpleRound(string memory name) internal returns (uint256) {
        IFundraise.RoundParams memory p = _defaultRoundParams();
        p.name = name;
        p.mfn = true;
        p.proRata = true;
        return fundraise.createRound(p);
    }

    /// @notice Helper to create a default SAFE round (delegates to _createRound)
    function _createDefaultRound() internal returns (uint256) {
        vm.prank(board);
        return _createRound("Test Round", CAP_10M, DISCOUNT_20PCT, false);
    }

    /// @notice Helper to create a whitelist-only round (delegates to _createRound)
    function _createWhitelistRound() internal returns (uint256) {
        vm.prank(board);
        return _createRound("Whitelist Round", CAP_10M, DISCOUNT_20PCT, true);
    }

    /// @notice Helper to create a priced round
    function _createPricedRound(string memory name, uint256 pricePerShare) internal returns (uint256) {
        vm.prank(board);
        IFundraise.RoundParams memory p = _defaultRoundParams();
        p.name = name;
        p.roundType = IFundraise.RoundType.PRICED;
        p.valuationCap = 0;
        p.discountBps = 0;
        p.pricePerShare = pricePerShare;
        p.documentRef = "";
        p.minInvestment = MIN_INVESTMENT;
        p.maxInvestment = MAX_INVESTMENT;
        p.targetRaise = TARGET_RAISE;
        p.hardCap = HARD_CAP;
        return fundraise.createRound(p);
    }

    /// @notice Helper to create a SAFE round with specific cap (for auto-conversion tests)
    function _createSafeRoundWithCap(string memory name, uint256 cap) internal returns (uint256) {
        vm.prank(board);
        IFundraise.RoundParams memory p = _defaultRoundParams();
        p.name = name;
        p.valuationCap = cap;
        p.proRata = true;
        p.documentRef = "ipfs://safe";
        return fundraise.createRound(p);
    }

    function _reserveSpotDefault(uint256 roundId, address investor, uint256 amount) internal {
        InEuint128 memory cap = createInEuint128(0, board);
        InEuint128 memory disc = createInEuint128(0, board);
        InEbool memory mfn = createInEbool(false, board);
        InEbool memory proRata = createInEbool(false, board);
        vm.prank(board);
        fundraise.reserveSpot(roundId, investor, amount, cap, disc, mfn, proRata, false);
    }

    function _reserveSpotCustom(
        uint256 roundId,
        address investor,
        uint256 amount,
        uint128 valuationCap,
        uint128 discountBps,
        bool mfn,
        bool proRata
    ) internal {
        InEuint128 memory cap = createInEuint128(valuationCap, board);
        InEuint128 memory disc = createInEuint128(discountBps, board);
        InEbool memory eMfn = createInEbool(mfn, board);
        InEbool memory eProRata = createInEbool(proRata, board);
        vm.prank(board);
        fundraise.reserveSpot(roundId, investor, amount, cap, disc, eMfn, eProRata, true);
    }

    function _setupSanctionsValidationRule() internal returns (RuleSanctionList rule, MockSanctionsList oracle) {
        ruleEngine = RuleEngine(address(shareToken.ruleEngine()));

        oracle = new MockSanctionsList();
        rule = new RuleSanctionList(address(board), address(0), address(oracle));
        vm.prank(board);
        ruleEngine.addRuleValidation(IRuleValidation(address(rule)));
    }
}
