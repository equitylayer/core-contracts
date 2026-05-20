// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./FundraiseBase.t.sol";

/// @title FundraiseRoundsTest
/// @notice Tests for round creation, lifecycle (close, finalize, cancel), reservations, and refunds
contract FundraiseRoundsTest is FundraiseBaseTest {
    // ===================
    // Initialization Tests
    // ===================

    function test_Initialize() public view {
        assertEq(address(fundraise.company()), address(company));
        assertEq(fundraise.roundCount(), 0);
    }

    function test_Initialize_RevertsZeroAddress() public {
        Fundraise newFundraise = new Fundraise();

        vm.expectRevert(Fundraise.ZeroAddress.selector);
        newFundraise.initialize(address(0));
    }

    function test_Initialize_CannotInitializeTwice() public {
        vm.expectRevert();
        fundraise.initialize(address(company));
    }

    // ===================
    // Round Creation Tests
    // ===================

    function test_CreateRound_Success() public {
        vm.expectEmit(true, false, false, true);
        emit Fundraise.RoundCreated(
            0, "Seed Round", CAP_10M, DISCOUNT_20PCT, HARD_CAP, address(shareToken), "ipfs://safe-doc"
        );

        vm.prank(board);
        uint256 roundId = _createRound("Seed Round", CAP_10M, DISCOUNT_20PCT, false);

        assertEq(roundId, 0);
        assertEq(fundraise.roundCount(), 1);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(round.name, "Seed Round");
        assertEq(round.valuationCap, CAP_10M);
        assertEq(round.discountBps, DISCOUNT_20PCT);
        assertTrue(round.mfn);
        assertTrue(round.proRata);
        assertFalse(round.whitelistOnly);
        assertEq(round.minInvestment, MIN_INVESTMENT);
        assertEq(round.maxInvestment, MAX_INVESTMENT);
        assertEq(round.hardCap, HARD_CAP);
        assertEq(uint256(round.status), uint256(IFundraise.RoundStatus.OPEN));
    }

    function test_CreateRound_OnlyBoard() public {
        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Seed Round",
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
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
    }

    function test_CreateRound_RevertsZeroShareClass() public {
        vm.prank(board);
        vm.expectRevert(Fundraise.ZeroAddress.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Seed Round",
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
                deadline: 0,
                targetShareClass: address(0)
            })
        );
    }

    function test_CreateRound_RevertsInvalidDiscount() public {
        vm.prank(board);
        vm.expectRevert(Fundraise.InvalidDiscountRate.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Seed Round",
                roundType: IFundraise.RoundType.SAFE,
                valuationCap: CAP_10M,
                discountBps: 10000, // 100% discount invalid
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
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
    }

    function test_CreateRound_RevertsInterestRateAboveMax() public {
        vm.prank(board);
        vm.expectRevert(Fundraise.InvalidInterestRate.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "CN Round",
                roundType: IFundraise.RoundType.CONVERTIBLE_NOTE,
                valuationCap: CAP_10M,
                discountBps: DISCOUNT_20PCT,
                pricePerShare: 0,
                interestRateBps: 5001, // just above MAX_INTEREST_RATE_BPS (5000)
                maturityDuration: 365 days,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: false,
                whitelistOnly: false,
                documentRef: "ipfs://doc",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
    }

    function test_CreateRound_RevertsMinGreaterThanMax() public {
        vm.prank(board);
        vm.expectRevert(Fundraise.InvalidStatus.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Seed Round",
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
                minInvestment: 10e6, // min > max
                maxInvestment: 5e6, // max < min
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
    }

    function test_CreateRound_PricedRoundRejectsDiscountBps() public {
        vm.prank(board);
        vm.expectRevert(Fundraise.NoOp.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Series A",
                roundType: IFundraise.RoundType.PRICED,
                valuationCap: 0,
                discountBps: 2000, // Not allowed for PRICED rounds
                pricePerShare: 1e6,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: false,
                whitelistOnly: false,
                documentRef: "",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
    }

    function test_CreateRound_PricedRoundRejectsValuationCap() public {
        vm.prank(board);
        vm.expectRevert(Fundraise.NoOp.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Series A",
                roundType: IFundraise.RoundType.PRICED,
                valuationCap: CAP_10M, // Not allowed for PRICED rounds
                discountBps: 0,
                pricePerShare: 1e6,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: false,
                proRata: false,
                whitelistOnly: false,
                documentRef: "",
                minInvestment: 0,
                maxInvestment: 0,
                targetRaise: 0,
                hardCap: 0,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
    }

    function test_CreateRound_SafeRoundRejectsPricePerShare() public {
        vm.prank(board);
        vm.expectRevert(Fundraise.NoOp.selector);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "SAFE Round",
                roundType: IFundraise.RoundType.SAFE,
                valuationCap: CAP_10M,
                discountBps: DISCOUNT_20PCT,
                pricePerShare: 1e6, // Not allowed for SAFE rounds
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
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );
    }

    // ===================
    // Reservation Tests
    // ===================

    function test_ReserveSpot_Success() public {
        _createDefaultRound();

        InEuint128 memory zero128 = createInEuint128(0, board);
        InEuint128 memory zero128b = createInEuint128(0, board);
        InEbool memory falseBool = createInEbool(false, board);
        InEbool memory falseBool2 = createInEbool(false, board);

        vm.expectEmit(true, true, false, true);
        emit Fundraise.ReservationCreated(0, investor1, 5e6, false);

        vm.prank(board);
        fundraise.reserveSpot(0, investor1, 5e6, zero128, zero128b, falseBool, falseBool2, false);

        Fundraise.Reservation memory reservation = fundraise.getReservation(0, investor1);
        assertEq(reservation.investor, investor1);
        assertEq(reservation.amount, 5e6);
        assertFalse(reservation.useCustomTerms);
        assertFalse(reservation.paid);
    }

    function test_ReserveSpot_WithCustomTerms() public {
        _createDefaultRound();

        _reserveSpotCustom(0, investor1, 5e6, uint128(CAP_20M), 1500, true, false);

        Fundraise.Reservation memory reservation = fundraise.getReservation(0, investor1);
        assertHashValue(reservation.valuationCap, uint128(CAP_20M));
        assertHashValue(reservation.discountBps, 1500);
        assertHashValue(reservation.mfn, true);
        assertHashValue(reservation.proRata, false);
        assertTrue(reservation.useCustomTerms);
    }

    function _emptyReservationTerms()
        internal
        returns (InEuint128 memory cap, InEuint128 memory disc, InEbool memory mfn, InEbool memory proRata)
    {
        cap = createInEuint128(0, board);
        disc = createInEuint128(0, board);
        mfn = createInEbool(false, board);
        proRata = createInEbool(false, board);
    }

    function test_ReserveSpot_OnlyBoard() public {
        _createDefaultRound();
        (InEuint128 memory cap, InEuint128 memory disc, InEbool memory mfn, InEbool memory proRata) =
            _emptyReservationTerms();

        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.reserveSpot(0, investor1, 5e6, cap, disc, mfn, proRata, false);
    }

    function test_ReserveSpot_RevertsInvalidRound() public {
        (InEuint128 memory cap, InEuint128 memory disc, InEbool memory mfn, InEbool memory proRata) =
            _emptyReservationTerms();
        vm.prank(board);
        vm.expectRevert(Fundraise.InvalidRoundId.selector);
        fundraise.reserveSpot(999, investor1, 5e6, cap, disc, mfn, proRata, false);
    }

    function test_ReserveSpot_RevertsZeroInvestor() public {
        _createDefaultRound();
        (InEuint128 memory cap, InEuint128 memory disc, InEbool memory mfn, InEbool memory proRata) =
            _emptyReservationTerms();
        vm.prank(board);
        vm.expectRevert(Fundraise.ZeroAddress.selector);
        fundraise.reserveSpot(0, address(0), 5e6, cap, disc, mfn, proRata, false);
    }

    function test_ReserveSpot_RevertsZeroAmount() public {
        _createDefaultRound();
        (InEuint128 memory cap, InEuint128 memory disc, InEbool memory mfn, InEbool memory proRata) =
            _emptyReservationTerms();
        vm.prank(board);
        vm.expectRevert(Fundraise.ZeroAmount.selector);
        fundraise.reserveSpot(0, investor1, 0, cap, disc, mfn, proRata, false);
    }

    // ===================
    // Close Round Tests
    // ===================

    function test_CloseRound_Success() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.expectEmit(true, false, false, true);
        emit Fundraise.RoundClosed(0, 1e6, 1, "ipfs://safe-doc");

        vm.prank(board);
        fundraise.closeRound(0);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(uint256(round.status), uint256(IFundraise.RoundStatus.CLOSED));
    }

    function test_CloseRound_OnlyBoard() public {
        _createDefaultRound();

        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.closeRound(0);
    }

    function test_CloseRound_RevertsNotOpen() public {
        _createDefaultRound();

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(board);
        vm.expectRevert(Fundraise.RoundNotOpen.selector);
        fundraise.closeRound(0);
    }

    // ===================
    // Refund Tests
    // ===================

    function test_RefundInvestment_Success() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        uint256 investorBalanceBefore = musd.balanceOf(investor1);

        vm.expectEmit(true, true, false, true);
        emit Fundraise.InvestmentRefunded(0, investor1, 1e6, 0);

        vm.prank(board);
        fundraise.refundInvestment(0, 0);

        IFundraise.Investment memory investment = fundraise.getInvestment(0, 0);
        assertTrue(investment.refunded);

        assertEq(musd.balanceOf(investor1), investorBalanceBefore + 1e6);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(round.totalRaised, 0);
        assertEq(round.investorCount, 0);
    }

    function test_RefundInvestment_ResetsReservation() public {
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

        vm.prank(board);
        fundraise.refundInvestment(0, 0);

        Fundraise.Reservation memory reservation = fundraise.getReservation(0, investor1);
        assertFalse(reservation.paid);
    }

    function test_RefundInvestment_OnlyBoard() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.refundInvestment(0, 0);
    }

    function test_RefundInvestment_RevertsAlreadyRefunded() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.prank(board);
        fundraise.refundInvestment(0, 0);

        vm.prank(board);
        vm.expectRevert(Fundraise.AlreadyRefunded.selector);
        fundraise.refundInvestment(0, 0);
    }

    function test_RefundInvestment_RevertsAfterFinalization() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(board);
        fundraise.finalizeRound(0);

        vm.prank(board);
        vm.expectRevert(Fundraise.InvalidStatus.selector);
        fundraise.refundInvestment(0, 0);
    }

    // ===================
    // Finalization Tests
    // ===================

    function test_FinalizeRound_Success() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.expectEmit(true, false, false, true);
        emit Fundraise.RoundFinalized(0, 3e6, 2, 2, "ipfs://safe-doc");

        vm.prank(board);
        fundraise.finalizeRound(0);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(uint256(round.status), uint256(IFundraise.RoundStatus.FINALIZED));

        // Verify SAFEs were issued
        assertEq(safeContract.safeCount(), 2);
    }

    function test_FinalizeRound_SkipsRefundedInvestments() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        // Refund investor1
        vm.prank(board);
        fundraise.refundInvestment(0, 0);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(board);
        fundraise.finalizeRound(0);

        // Only 1 SAFE issued (investor2)
        assertEq(safeContract.safeCount(), 1);
    }

    function test_FinalizeRound_OnlyBoard() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.finalizeRound(0);
    }

    function test_FinalizeRound_RevertsNotClosed() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.prank(board);
        vm.expectRevert(Fundraise.RoundNotClosed.selector);
        fundraise.finalizeRound(0);
    }

    // ===================
    // Cancellation Tests
    // ===================

    function test_CancelRound_RefundsAll() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        uint256 investor1BalanceBefore = musd.balanceOf(investor1);
        uint256 investor2BalanceBefore = musd.balanceOf(investor2);

        vm.expectEmit(true, false, false, true);
        emit Fundraise.RoundCancelled(0, 3e6, "ipfs://safe-doc");

        vm.prank(board);
        fundraise.cancelRound(0);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(uint256(round.status), uint256(IFundraise.RoundStatus.CANCELLED));

        assertEq(musd.balanceOf(investor1), investor1BalanceBefore + 1e6);
        assertEq(musd.balanceOf(investor2), investor2BalanceBefore + 2e6);
    }

    function test_CancelRound_SkipsAlreadyRefunded() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        // Refund investor1 first
        vm.prank(board);
        fundraise.refundInvestment(0, 0);

        uint256 investor1BalanceBefore = musd.balanceOf(investor1);
        uint256 investor2BalanceBefore = musd.balanceOf(investor2);

        vm.prank(board);
        fundraise.cancelRound(0);

        // investor1 should not get double refund
        assertEq(musd.balanceOf(investor1), investor1BalanceBefore);
        // investor2 should get refund
        assertEq(musd.balanceOf(investor2), investor2BalanceBefore + 2e6);

        IFundraise.Round memory round = fundraise.getRound(0);
        assertEq(uint256(round.status), uint256(IFundraise.RoundStatus.CANCELLED));
        assertEq(round.totalRaised, 0, "cancel should clear remaining raised amount");
        assertEq(round.investorCount, 0, "cancel should clear remaining active investors");
    }

    function test_CancelRound_OnlyBoard() public {
        _createDefaultRound();

        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.cancelRound(0);
    }

    function test_CancelRound_RevertsAfterFinalization() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(board);
        fundraise.finalizeRound(0);

        vm.prank(board);
        vm.expectRevert(Fundraise.InvalidStatus.selector);
        fundraise.cancelRound(0);
    }

    // ===================
    // Claim Refund Tests
    // ===================

    function test_ClaimRefund_Success() public {
        _createDefaultRound();

        // Deploy a contract that rejects ETH
        RejectEther rejecter = new RejectEther();
        address rejecterAddr = address(rejecter);

        // Rejecter invests with MUSD
        _mintAndApprove(rejecterAddr, 1e6, address(fundraise));
        _invest(fundraise, 0, rejecterAddr, 1e6);

        // Normal investor also invests
        _mintAndApprove(investor1, 2e6, address(fundraise));
        _invest(fundraise, 0, investor1, 2e6);

        // Cancel round - MUSD refunds should work for both
        vm.prank(board);
        fundraise.cancelRound(0);

        // With ERC20 refunds, both should succeed (no ETH rejection issue)
        // Verify balances
        assertEq(musd.balanceOf(rejecterAddr), 1e6, "Rejecter should have MUSD refund");
        assertEq(musd.balanceOf(investor1), 2e6, "investor1 should have MUSD refund");
    }

    function test_ClaimRefund_RevertsNoPendingRefund() public {
        vm.prank(investor1);
        vm.expectRevert(Fundraise.NoPendingRefund.selector);
        fundraise.claimRefund();
    }

    event RefundClaimed(address indexed investor, uint256 amount);

    // ===================
    // View Function Tests
    // ===================

    function test_GetInvestments() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        IFundraise.Investment[] memory investments = fundraise.getInvestments(0);
        assertEq(investments.length, 2);
        assertEq(investments[0].investor, investor1);
        assertEq(investments[1].investor, investor2);
    }

    function test_GetInvestmentCount() public {
        _createDefaultRound();

        assertEq(fundraise.getInvestmentCount(0), 0);

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        assertEq(fundraise.getInvestmentCount(0), 1);
    }

    function test_GetRoundNoteIds_EmptyBeforeFinalization() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        // Before finalization, noteIds should be empty
        uint256[] memory noteIds = fundraise.getRoundSAFEIds(0);
        assertEq(noteIds.length, 0);
    }

    function test_GetRoundNoteIds_PopulatedAfterFinalization() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(board);
        fundraise.finalizeRound(0);

        // After finalization, should have 2 noteIds
        uint256[] memory noteIds = fundraise.getRoundSAFEIds(0);
        assertEq(noteIds.length, 2);

        // Verify noteIds match SAFE contract
        assertEq(noteIds[0], 0); // First SAFE noteId
        assertEq(noteIds[1], 1); // Second SAFE noteId
    }

    function test_GetRoundNoteIds_SkipsRefundedInvestments() public {
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 0, investor2, 2e6);

        _mintAndApprove(investor3, 3e6, address(fundraise));
        _invest(fundraise, 0, investor3, 3e6);

        // Refund investor2
        vm.prank(board);
        fundraise.refundInvestment(0, 1);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(board);
        fundraise.finalizeRound(0);

        // Should only have 2 noteIds (investor1 and investor3)
        uint256[] memory noteIds = fundraise.getRoundSAFEIds(0);
        assertEq(noteIds.length, 2);

        // Verify SAFE contract has 2 SAFEs
        assertEq(safeContract.safeCount(), 2);
    }

    function test_GetRoundNoteIds_MultipleRounds() public {
        // Create and finalize round 0
        _createDefaultRound();

        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, 0, investor1, 1e6);

        vm.prank(board);
        fundraise.closeRound(0);

        vm.prank(board);
        fundraise.finalizeRound(0);

        // Create and finalize round 1
        vm.prank(board);
        fundraise.createRound(
            IFundraise.RoundParams({
                name: "Round 2",
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
                minInvestment: MIN_INVESTMENT,
                maxInvestment: MAX_INVESTMENT,
                targetRaise: TARGET_RAISE,
                hardCap: HARD_CAP,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, 1, investor2, 2e6);

        _mintAndApprove(investor3, 3e6, address(fundraise));
        _invest(fundraise, 1, investor3, 3e6);

        vm.prank(board);
        fundraise.closeRound(1);

        vm.prank(board);
        fundraise.finalizeRound(1);

        // Verify noteIds per round
        uint256[] memory round0Notes = fundraise.getRoundSAFEIds(0);
        uint256[] memory round1Notes = fundraise.getRoundSAFEIds(1);

        assertEq(round0Notes.length, 1);
        assertEq(round1Notes.length, 2);

        // Round 0 has noteId 0
        assertEq(round0Notes[0], 0);

        // Round 1 has noteIds 1 and 2
        assertEq(round1Notes[0], 1);
        assertEq(round1Notes[1], 2);

        // Total SAFEs in SAFE contract
        assertEq(safeContract.safeCount(), 3);
    }

    function test_SetDocumentRef() public {
        uint256 roundId = _createDefaultRound();
        assertEq(fundraise.getRound(roundId).documentRef, "ipfs://safe-doc");

        vm.prank(board);
        fundraise.setDocumentRef(roundId, "ipfs://updated");
        assertEq(fundraise.getRound(roundId).documentRef, "ipfs://updated");

        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.setDocumentRef(roundId, "ipfs://nope");

        vm.prank(board);
        vm.expectRevert(Fundraise.InvalidRoundId.selector);
        fundraise.setDocumentRef(99, "ipfs://nope");
    }
}
