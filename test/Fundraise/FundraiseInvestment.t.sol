// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./FundraiseBase.t.sol";
import {ConvertibleNote} from "../../src/ConvertibleNote.sol";
import {MockSanctionsList} from "../Rules/mocks/MockSanctionsList.sol";

/// @title FundraiseInvestmentTest
contract FundraiseInvestmentTest is FundraiseBaseTest {
    function test_Invest_Success() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));

        InEuint128 memory salt = createInEuint128(0, investor1);

        vm.expectEmit(true, true, false, false);
        emit Fundraise.InvestmentReceived(0, investor1, 1e6, 0, block.timestamp);

        vm.prank(investor1);
        fundraise.invest(0, 1e6, keccak256("test:terms"), salt);

        assertEq(fundraise.getInvestorTotal(0, investor1), 1e6);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(round.totalRaised, 1e6);
        assertEq(round.investorCount, 1);

        IFundraise.Investment memory investment = fundraise.getInvestment(0, 0);
        assertEq(investment.investor, investor1);
        assertEq(investment.amount, 1e6);
        assertFalse(investment.refunded);
    }

    function test_Invest_WithReservation() public {
        _createDefaultRound();

        // Create reservation with custom terms
        vm.startPrank(board);
        fundraise.reserveSpot(
            0,
            investor1,
            5e6,
            createInEuint128(uint128(CAP_20M), board),
            createInEuint128(1500, board),
            createInEbool(true, board),
            createInEbool(false, board),
            true
        );
        vm.stopPrank();

        _mintAndApprove(investor1, 5e6, address(fundraise));
        _invest(fundraise, 0, investor1, 5e6);

        Fundraise.Reservation memory reservation = fundraise.getReservation(0, investor1);
        assertTrue(reservation.paid);

        IFundraise.Investment memory investment = fundraise.getInvestment(0, 0);
        assertHashValue(investment.valuationCap, uint128(CAP_20M)); // Custom terms used (encrypted)
        assertHashValue(investment.discountBps, uint128(1500));
    }

    function test_Invest_RejectsSystemAddresses() public {
        _createDefaultRound();

        address[7] memory systemAddrs = [
            board,
            address(company),
            address(fundraise),
            address(safeContract),
            address(company.convertibleNote()),
            address(company.vault()),
            address(shareToken)
        ];

        for (uint256 i = 0; i < systemAddrs.length; i++) {
            _mintAndApprove(systemAddrs[i], 1e6, address(fundraise));
            _investExpectRevert(fundraise, 0, systemAddrs[i], 1e6, Fundraise.InvalidInvestor.selector);
        }
    }

    function test_Invest_MultipleInvestors() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        _mintAndApprove(investor3, 3e6, address(fundraise));
        _invest(fundraise, 0, investor3, 3e6);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(round.totalRaised, 6e6);
        assertEq(round.investorCount, 3);
    }

    function test_Invest_RevertsRoundNotOpen() public {
        _createDefaultRound();

        vm.prank(board);
        fundraise.closeRound(0);

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 1e6, Fundraise.RoundNotOpen.selector);
    }

    function test_Invest_RevertsZeroAmount() public {
        _createDefaultRound();

        _investExpectRevert(fundraise, 0, investor1, 0, Fundraise.ZeroAmount.selector);
    }

    function test_Invest_RevertsBelowMinimum() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 50_000, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 50_000, Fundraise.BelowMinInvestment.selector); // Below MIN_INVESTMENT (100_000)
    }

    function test_Invest_RevertsExceedsMaximum() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 15e6, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 15e6, Fundraise.ExceedsMaxInvestment.selector); // Above MAX_INVESTMENT (10e6)
    }

    function test_Invest_RevertsExceedsHardCap() public {
        // Create round with low hard cap
        vm.prank(board);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Small Round",
                roundType: IFundraise.RoundType.SAFE,
                valuationCap: CAP_10M,
                discountBps: DISCOUNT_20PCT,
                pricePerShare: 0,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: true,
                proRata: true,
                whitelistOnly: false,
                documentRef: "ipfs://doc",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 5e6,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );

        _mintAndApprove(investor1, 10e6, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 10e6, Fundraise.ExceedsHardCap.selector);
    }

    function test_Invest_RevertsDeadlinePassed() public {
        // Create round with deadline
        vm.prank(board);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Timed Round",
                roundType: IFundraise.RoundType.SAFE,
                valuationCap: CAP_10M,
                discountBps: DISCOUNT_20PCT,
                pricePerShare: 0,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: true,
                proRata: true,
                whitelistOnly: false,
                documentRef: "ipfs://doc",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: block.timestamp + 1 days,
                targetShareClass: address(shareToken)
            })
        );

        // Warp past deadline
        vm.warp(block.timestamp + 2 days);

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 1e6, Fundraise.DeadlinePassed.selector);
    }

    function test_Invest_RevertsReservationAmountMismatch() public {
        _createDefaultRound();

        vm.startPrank(board);
        fundraise.reserveSpot(
            0,
            investor1,
            5e6,
            createInEuint128(0, board),
            createInEuint128(0, board),
            createInEbool(false, board),
            createInEbool(false, board),
            false
        );
        vm.stopPrank();

        _mintAndApprove(investor1, 3e6, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 3e6, Fundraise.ReservationAmountMismatch.selector); // Should be exactly 5e6
    }

    function test_Invest_RevertsAlreadyPaid() public {
        _createDefaultRound();

        vm.startPrank(board);
        fundraise.reserveSpot(
            0,
            investor1,
            5e6,
            createInEuint128(0, board),
            createInEuint128(0, board),
            createInEbool(false, board),
            createInEbool(false, board),
            false
        );
        vm.stopPrank();

        _mintAndApprove(investor1, 5e6, address(fundraise));
        _invest(fundraise, 0, investor1, 5e6);

        _mintAndApprove(investor1, 5e6, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 5e6, Fundraise.AlreadyPaid.selector);
    }

    function test_Invest_RevertsTooSmallForPricedRound() public {
        // Create a priced round with price per share and no min investment
        // For shares = 0: investment * 1e6 < pricePerShare
        // Using pricePerShare = 2e6 ($2/share), we need investment < 2 (less than 2 units of MUSD)
        vm.prank(board);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Expensive Round",
                roundType: IFundraise.RoundType.PRICED,
                valuationCap: 0,
                discountBps: 0,
                pricePerShare: 2e6, // $2 per share
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: false,
                whitelistOnly: false,
                documentRef: "",
                minInvestment: 0, // No minimum to test precision loss
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 100e6,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );

        // Investment of 1 unit would result in:
        // shares = (1 * 1e6) / 2e6 = 0 (rounds to 0)
        _mintAndApprove(investor1, 1, address(fundraise));
        _investExpectRevert(fundraise, 0, investor1, 1, Fundraise.InvestmentTooSmall.selector);

        // Investment of 2 units should work:
        // shares = (2 * 1e6) / 2e6 = 1 share
        _mintAndApprove(investor1, 2, address(fundraise));
        _invest(fundraise, 0, investor1, 2); // Should succeed
    }

    // ===================
    // Investment Consolidation Tests
    // ===================

    /// @notice Multiple invests from same investor produce distinct rows; totals/counts aggregate.
    function test_Invest_AggregatesMultipleInvestments() public {
        vm.prank(board);
        uint256 roundId = _createSimpleRound("Aggregation Test");

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 1e6);

        IFundraise.Round memory round = fundraise.getRound(roundId);
        assertEq(round.totalRaised, 1e6);
        assertEq(round.investorCount, 1);
        assertEq(fundraise.getInvestmentCount(roundId), 1);
        assertEq(fundraise.getInvestorTotal(roundId, investor1), 1e6);

        _mintAndApprove(investor1, 2e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 2e6);

        round = fundraise.getRound(roundId);
        assertEq(round.totalRaised, 3e6, "Total raised sums across rows");
        assertEq(round.investorCount, 1, "Distinct-investor count, not row count");
        assertEq(fundraise.getInvestmentCount(roundId), 2, "One row per invest");
        assertEq(fundraise.getInvestorTotal(roundId, investor1), 3e6);

        IFundraise.Investment memory inv0 = fundraise.getInvestment(roundId, 0);
        IFundraise.Investment memory inv1 = fundraise.getInvestment(roundId, 1);
        assertEq(inv0.amount, 1e6);
        assertEq(inv1.amount, 2e6);
        assertEq(inv0.investor, investor1);
        assertEq(inv1.investor, investor1);
    }

    /// @notice maxInvestment is enforced cumulatively across an investor's rows.
    function test_Invest_RespectsMaxInvestmentCumulatively() public {
        vm.prank(board);
        uint256 roundId = _createRound("Max Test", CAP_10M, DISCOUNT_20PCT, false);
        // maxInvestment is 10e6

        _mintAndApprove(investor1, 8e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 8e6);

        // 8 + 3 = 11 > 10 → revert
        _mintAndApprove(investor1, 3e6, address(fundraise));
        _investExpectRevert(fundraise, roundId, investor1, 3e6, Fundraise.ExceedsMaxInvestment.selector);

        // 8 + 2 = 10 → ok, second row
        _mintAndApprove(investor1, 2e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 2e6);

        assertEq(fundraise.getInvestorTotal(roundId, investor1), 10e6);
        assertEq(fundraise.getInvestmentCount(roundId), 2, "Two distinct rows");
    }

    /// @notice Each invest by the same investor must produce its own SAFE (one signed
    ///         instrument per invest — consolidation breaks the termsCommitment binding).
    function test_Invest_MultipleInvestsCreateMultipleSAFEs() public {
        vm.prank(board);
        uint256 roundId = _createSimpleRound("SAFE Test");

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 1e6);

        _mintAndApprove(investor1, 2e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 2e6);

        _mintAndApprove(investor1, 500_000, address(fundraise));
        _invest(fundraise, roundId, investor1, 500_000);

        assertEq(fundraise.getInvestmentCount(roundId), 3, "Each invest is its own row");
        assertEq(fundraise.getInvestorTotal(roundId, investor1), 3_500_000);

        IFundraise.Round memory round = fundraise.getRound(roundId);
        assertEq(round.totalRaised, 3_500_000);
        assertEq(round.investorCount, 1, "Distinct-investor count, not row count");

        IFundraise.Investment memory inv0 = fundraise.getInvestment(roundId, 0);
        IFundraise.Investment memory inv1 = fundraise.getInvestment(roundId, 1);
        IFundraise.Investment memory inv2 = fundraise.getInvestment(roundId, 2);
        assertEq(inv0.amount, 1e6);
        assertEq(inv1.amount, 2e6);
        assertEq(inv2.amount, 500_000);

        vm.startPrank(board);
        fundraise.closeRound(roundId);
        fundraise.finalizeRound(roundId);
        vm.stopPrank();

        uint256[] memory safeIds = fundraise.getRoundSAFEIds(roundId);
        assertEq(safeIds.length, 3, "One SAFE per invest");

        for (uint256 i = 0; i < safeIds.length; i++) {
            ISAFE.SAFEInstrument memory safe_ = safeContract.getSAFE(safeIds[i]);
            assertEq(safe_.investor, investor1);
            assertTrue(safe_.termsCommitment != bytes32(0));
        }
    }

    /// @notice Same rule for Convertible Note rounds: one Note per invest.
    function test_Invest_MultipleInvestsCreateMultipleNotes() public {
        vm.startPrank(board);
        IFundraise.RoundParams memory p = _defaultRoundParams();
        p.name = "Note Round";
        p.roundType = IFundraise.RoundType.CONVERTIBLE_NOTE;
        p.interestRateBps = 600;
        p.maturityDuration = 365 days;
        p.documentRef = "ipfs://note";
        uint256 roundId = fundraise.createRound(p);
        vm.stopPrank();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 1e6);

        _mintAndApprove(investor1, 2e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 2e6);

        _mintAndApprove(investor1, 500_000, address(fundraise));
        _invest(fundraise, roundId, investor1, 500_000);

        assertEq(fundraise.getInvestmentCount(roundId), 3, "Each invest is its own row");
        assertEq(fundraise.getInvestorTotal(roundId, investor1), 3_500_000);

        vm.startPrank(board);
        fundraise.closeRound(roundId);
        fundraise.finalizeRound(roundId);
        vm.stopPrank();

        uint256[] memory noteIds = fundraise.getRoundNoteIds(roundId);
        assertEq(noteIds.length, 3, "One Note per invest");

        ConvertibleNote noteContract = ConvertibleNote(address(company.convertibleNote()));
        for (uint256 i = 0; i < noteIds.length; i++) {
            IConvertibleNote.NoteInstrument memory note_ = noteContract.getNote(noteIds[i]);
            assertEq(note_.investor, investor1);
            assertTrue(note_.termsCommitment != bytes32(0));
        }
    }

    /// @notice Test that refund and re-invest creates new record
    function test_Invest_AfterRefundCreatesNewRecord() public {
        vm.prank(board);
        uint256 roundId = _createSimpleRound("Refund Test");

        // First investment
        _mintAndApprove(investor1, 2e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 2e6);

        assertEq(fundraise.getInvestmentCount(roundId), 1);

        // Refund
        vm.prank(board);
        fundraise.refundInvestment(roundId, 0);

        // Investor total should be 0 after refund
        assertEq(fundraise.getInvestorTotal(roundId, investor1), 0);

        // Invest again - should create new record since previous was refunded
        _mintAndApprove(investor1, 3e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 3e6);

        // Now should have 2 investment records (one refunded, one active)
        assertEq(fundraise.getInvestmentCount(roundId), 2, "Should have 2 records after refund and re-invest");
        assertEq(fundraise.getInvestorTotal(roundId, investor1), 3e6);

        // First record should be refunded
        IFundraise.Investment memory refundedInvestment = fundraise.getInvestment(roundId, 0);
        assertTrue(refundedInvestment.refunded);
        assertEq(refundedInvestment.amount, 2e6);

        // Second record should be active
        IFundraise.Investment memory activeInvestment = fundraise.getInvestment(roundId, 1);
        assertFalse(activeInvestment.refunded);
        assertEq(activeInvestment.amount, 3e6);
    }

    /// @notice minInvestment is enforced per invest; each invest is its own SAFE/Note,
    ///         so a sub-min follow-on must revert even after a prior valid invest.
    function test_Invest_RejectsBelowMinPerInvest() public {
        vm.prank(board);
        uint256 roundId = _createRound("Min Test", CAP_10M, DISCOUNT_20PCT, false);
        // minInvestment is 100_000 (MIN_INVESTMENT constant)

        _mintAndApprove(investor1, 500_000, address(fundraise));
        _invest(fundraise, roundId, investor1, 500_000);

        _mintAndApprove(investor1, 10_000, address(fundraise));
        _investExpectRevert(fundraise, roundId, investor1, 10_000, Fundraise.BelowMinInvestment.selector);

        assertEq(fundraise.getInvestorTotal(roundId, investor1), 500_000);
        assertEq(fundraise.getInvestmentCount(roundId), 1);
    }

    function test_Invest_RevertsWhenInvestorIsSanctioned() public {
        uint256 roundId = _createPricedRound("Priced Compliance", PRICE_PER_SHARE);
        (, MockSanctionsList sanctionsOracle) = _setupSanctionsValidationRule();

        sanctionsOracle.addToSanctionsList(investor1);

        _mintAndApprove(investor1, 200_000, address(fundraise));
        _investExpectRevert(fundraise, roundId, investor1, 200_000, Fundraise.InvestorNotCompliant.selector);
    }

    function test_Invest_SucceedsWhenInvestorIsNotSanctioned() public {
        uint256 roundId = _createPricedRound("Priced Compliance", PRICE_PER_SHARE);
        _setupSanctionsValidationRule();

        _mintAndApprove(investor1, 200_000, address(fundraise));
        _invest(fundraise, roundId, investor1, 200_000);

        assertEq(fundraise.getInvestorTotal(roundId, investor1), 200_000);
    }

    function test_FinalizePricedRound_RevertsIfInvestorBecomesSanctionedAfterInvest() public {
        uint256 roundId = _createPricedRound("Priced Compliance", PRICE_PER_SHARE);
        (, MockSanctionsList sanctionsOracle) = _setupSanctionsValidationRule();

        _mintAndApprove(investor1, 200_000, address(fundraise));
        _invest(fundraise, roundId, investor1, 200_000);

        sanctionsOracle.addToSanctionsList(investor1);

        vm.prank(board);
        fundraise.closeRound(roundId);

        vm.prank(board);
        vm.expectRevert(Fundraise.InvestorNotCompliant.selector);
        fundraise.finalizeRound(roundId);
    }
}
