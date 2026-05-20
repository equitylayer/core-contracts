// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./helpers/BaseTest.sol";
import {SAFE} from "../src/SAFE.sol";
import {ShareToken} from "../src/ShareToken.sol";
import {MockZKVerifier} from "../src/mocks/MockZKVerifier.sol";

contract SAFETest is BaseTest {
    SAFE safeContract;
    Fundraise fundraise;
    OptionPool optionPool;
    // conversionVerifier inherited from BaseTest -- joint SAFE+CN conversion now lives on Fundraise.

    address investor1 = address(0x1001);
    address investor2 = address(0x1002);

    bytes32 constant TERMS_COMMITMENT = keccak256("terms:investor1:safe");
    bytes32 constant SHARES_COMMITMENT = keccak256("shares:investor1:safe");

    /// @dev Build a `TermsCiphertext` via the CoFheTest mock encryption helpers,
    ///      bound to `sender` so it matches the address that will call `issueSAFE`.
    function _termsCipher(address sender) internal returns (ISAFE.TermsCiphertext memory) {
        return ISAFE.TermsCiphertext({
            investmentAmount: createInEuint128(100_000e6, sender),
            valuationCap: createInEuint128(5_000_000e6, sender),
            discountBps: createInEuint128(2000, sender),
            mfn: createInEbool(false, sender),
            proRata: createInEbool(true, sender)
        });
    }

    function setUp() public {
        _baseSetUp();

        ShareholderRegistry deployedRegistry;
        (company, vault, vestingSchedule, deployedRegistry, optionPool, safeContract, shareToken, fundraise) =
            _deployStandardCompany();
    }

    // Conversion-flow tests (request/apply/rollback) moved to Fundraise tests after the
    // joint conversion refactor — see `Fundraise.triggerConversions` / `applyConversions` /
    // `rollbackConversions`. SAFE no longer owns conversion state or verification.

    function test_IssueSAFE_StoresCommitment() public {
        ISAFE.TermsCiphertext memory cipher = _termsCipher(board);
        InEuint128 memory salt = createInEuint128(0, board);
        vm.prank(board);
        uint256 safeId = safeContract.issueSAFE(
            investor1, TERMS_COMMITMENT, cipher, salt, address(shareToken), "ipfs://private-safe", block.timestamp, ""
        );

        ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeId);
        assertEq(safe_.investor, investor1);
        assertEq(safe_.termsCommitment, TERMS_COMMITMENT);
        assertEq(safe_.targetShareClass, address(shareToken));
        assertTrue(safe_.status == ISAFE.Status.Active);
        assertEq(safeContract.getActiveSAFECount(), 1);
    }

    function test_CancelSAFE() public {
        uint256 safeId = _issueSAFE();
        vm.prank(board);
        safeContract.cancelSAFE(safeId, "ipfs://cancellation");

        ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeId);
        assertTrue(safe_.status == ISAFE.Status.Cancelled);
        assertEq(safeContract.getActiveSAFECount(), 0);
    }

    function _issueSAFE() internal returns (uint256 safeId) {
        ISAFE.TermsCiphertext memory cipher = _termsCipher(board);
        InEuint128 memory salt = createInEuint128(0, board);
        vm.prank(board);
        return safeContract.issueSAFE(
            investor1, TERMS_COMMITMENT, cipher, salt, address(shareToken), "ipfs://private-safe", block.timestamp, ""
        );
    }

    function _finalizePricedRound() internal {
        // Founders must have minted before SAFEs can convert (CC formula needs
        // fully_diluted > 0). Mirrors real-world flow.
        vm.prank(board);
        issuance.issueGrant("Common", founder, 1_000_000e6, "founder shares", "");

        IFundraise.RoundParams memory p = _defaultRoundParams();
        p.roundType = IFundraise.RoundType.PRICED;
        p.valuationCap = 0;
        p.discountBps = 0;
        p.pricePerShare = PRICE_PER_SHARE;
        p.documentRef = "ipfs://priced-round";

        vm.prank(board);
        uint256 roundId = fundraise.createRound(p);

        _mintAndApprove(investor2, 10e6, address(fundraise));
        _invest(fundraise, roundId, investor2, 10e6);

        vm.startPrank(board);
        fundraise.closeRound(roundId);
        fundraise.finalizeRound(roundId);
        vm.stopPrank();
    }

    function _singleResult(uint256 safeId, uint256 sharesIssued)
        internal
        pure
        returns (ISAFE.ConversionResult[] memory results)
    {
        results = new ISAFE.ConversionResult[](1);
        results[0] =
            ISAFE.ConversionResult({safeId: safeId, sharesIssued: sharesIssued, sharesCommitment: SHARES_COMMITMENT});
    }

    function _singleUint(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _singleBytes32(bytes32 value) internal pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = value;
    }
}
