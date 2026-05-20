// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import "./FundraiseBase.t.sol";

/// @title FundraiseWhitelistTest
/// @notice Tests for whitelist functionality
contract FundraiseWhitelistTest is FundraiseBaseTest {
    // ===================
    // Whitelist Tests
    // ===================

    function test_CreateRound_WithWhitelist() public {
        vm.prank(board);
        uint256 roundId = fundraise.createRound(
            IFundraise.RoundParams({
                name: "Whitelist Round",
                roundType: IFundraise.RoundType.SAFE,
                valuationCap: CAP_10M,
                discountBps: DISCOUNT_20PCT,
                pricePerShare: 0,
                interestRateBps: 0,
                maturityDuration: 0,
                allowEarlyRepayment: false,
                mfn: true,
                proRata: true,
                whitelistOnly: true,
                documentRef: "ipfs://doc",
                minInvestment: MIN_INVESTMENT,
                maxInvestment: MAX_INVESTMENT,
                targetRaise: TARGET_RAISE,
                hardCap: HARD_CAP,
                deadline: 0,
                targetShareClass: address(shareToken)
            })
        );

        IFundraise.Round memory round = fundraise.getRound(roundId);
        assertTrue(round.whitelistOnly);
    }

    function test_AddToWhitelist_Success() public {
        uint256 roundId = _createWhitelistRound();

        vm.expectEmit(true, true, false, true);
        emit Fundraise.WhitelistUpdated(roundId, investor1, true);

        address[] memory toAdd = new address[](1);
        toAdd[0] = investor1;
        vm.prank(board);
        fundraise.addToWhitelist(roundId, toAdd);

        assertTrue(fundraise.isWhitelisted(roundId, investor1));
    }

    function test_Whitelist_OnlyBoard() public {
        uint256 roundId = _createWhitelistRound();

        address[] memory addrs = new address[](1);
        addrs[0] = investor1;

        // addToWhitelist requires board
        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.addToWhitelist(roundId, addrs);

        // Add to whitelist first (as board)
        vm.prank(board);
        fundraise.addToWhitelist(roundId, addrs);

        // removeFromWhitelist requires board
        vm.prank(investor1);
        vm.expectRevert(Fundraise.OnlyBoard.selector);
        fundraise.removeFromWhitelist(roundId, addrs);
    }

    function test_AddToWhitelist_SkipsZeroAddresses() public {
        uint256 roundId = _createWhitelistRound();

        address[] memory investors = new address[](3);
        investors[0] = investor1;
        investors[1] = address(0); // Should be skipped
        investors[2] = investor3;

        vm.prank(board);
        fundraise.addToWhitelist(roundId, investors);

        assertTrue(fundraise.isWhitelisted(roundId, investor1));
        assertFalse(fundraise.isWhitelisted(roundId, address(0)));
        assertTrue(fundraise.isWhitelisted(roundId, investor3));
    }

    function test_AddToWhitelist_RevertsRoundNotOpen() public {
        uint256 roundId = _createWhitelistRound();

        vm.prank(board);
        fundraise.closeRound(roundId);

        address[] memory toAdd = new address[](1);
        toAdd[0] = investor1;
        vm.prank(board);
        vm.expectRevert(Fundraise.RoundNotOpen.selector);
        fundraise.addToWhitelist(roundId, toAdd);
    }

    function test_RemoveFromWhitelist_Success() public {
        uint256 roundId = _createWhitelistRound();

        address[] memory toAdd = new address[](1);
        toAdd[0] = investor1;
        vm.prank(board);
        fundraise.addToWhitelist(roundId, toAdd);

        vm.expectEmit(true, true, false, true);
        emit Fundraise.WhitelistUpdated(roundId, investor1, false);

        address[] memory toRemove = new address[](1);
        toRemove[0] = investor1;
        vm.prank(board);
        fundraise.removeFromWhitelist(roundId, toRemove);

        assertFalse(fundraise.isWhitelisted(roundId, investor1));
    }

    function test_AddToWhitelist_MultipleInvestors() public {
        uint256 roundId = _createWhitelistRound();

        address[] memory investors = new address[](3);
        investors[0] = investor1;
        investors[1] = investor2;
        investors[2] = investor3;

        vm.prank(board);
        fundraise.addToWhitelist(roundId, investors);

        assertTrue(fundraise.isWhitelisted(roundId, investor1));
        assertTrue(fundraise.isWhitelisted(roundId, investor2));
        assertTrue(fundraise.isWhitelisted(roundId, investor3));
    }

    function test_RemoveFromWhitelist_MultipleInvestors() public {
        uint256 roundId = _createWhitelistRound();

        address[] memory investors = new address[](3);
        investors[0] = investor1;
        investors[1] = investor2;
        investors[2] = investor3;

        vm.prank(board);
        fundraise.addToWhitelist(roundId, investors);

        vm.prank(board);
        fundraise.removeFromWhitelist(roundId, investors);

        assertFalse(fundraise.isWhitelisted(roundId, investor1));
        assertFalse(fundraise.isWhitelisted(roundId, investor2));
        assertFalse(fundraise.isWhitelisted(roundId, investor3));
    }

    function test_Invest_WhitelistRound_Success() public {
        uint256 roundId = _createWhitelistRound();

        // Add investor to whitelist
        address[] memory toAdd = new address[](1);
        toAdd[0] = investor1;
        vm.prank(board);
        fundraise.addToWhitelist(roundId, toAdd);

        // Whitelisted investor can invest
        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 1e6);

        assertEq(fundraise.getInvestorTotal(roundId, investor1), 1e6);
    }

    function test_Invest_WhitelistRound_RevertsNotWhitelisted() public {
        uint256 roundId = _createWhitelistRound();

        // Non-whitelisted investor cannot invest
        _mintAndApprove(investor1, 1e6, address(fundraise));
        _investExpectRevert(fundraise, roundId, investor1, 1e6, Fundraise.NotWhitelisted.selector);
    }

    function test_Invest_WhitelistRound_ReservationBypassesWhitelist() public {
        uint256 roundId = _createWhitelistRound();

        // Create reservation (investor is NOT whitelisted)
        vm.startPrank(board);
        fundraise.reserveSpot(
            roundId,
            investor1,
            5e6,
            createInEuint128(0, board),
            createInEuint128(0, board),
            createInEbool(false, board),
            createInEbool(false, board),
            false
        );
        vm.stopPrank();

        assertFalse(fundraise.isWhitelisted(roundId, investor1));

        // Investor with reservation can invest even without being whitelisted
        _mintAndApprove(investor1, 5e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 5e6);

        assertEq(fundraise.getInvestorTotal(roundId, investor1), 5e6);
    }

    function test_Invest_NonWhitelistRound_AnyoneCanInvest() public {
        uint256 roundId = _createDefaultRound();

        // Non-whitelist round allows anyone
        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, roundId, investor2, 2e6);

        assertEq(fundraise.getInvestorTotal(roundId, investor1), 1e6);
        assertEq(fundraise.getInvestorTotal(roundId, investor2), 2e6);
    }

    function test_CanInvest_ChecksWhitelistStatus() public {
        uint256 roundId = _createWhitelistRound();

        // Not whitelisted - cannot invest
        assertFalse(fundraise.canInvest(roundId, investor1));

        // Add to whitelist - can invest
        address[] memory toAdd = new address[](1);
        toAdd[0] = investor1;
        vm.prank(board);
        fundraise.addToWhitelist(roundId, toAdd);
        assertTrue(fundraise.canInvest(roundId, investor1));

        // Remove from whitelist - cannot invest
        address[] memory toRemove = new address[](1);
        toRemove[0] = investor1;
        vm.prank(board);
        fundraise.removeFromWhitelist(roundId, toRemove);
        assertFalse(fundraise.canInvest(roundId, investor1));
    }

    function test_CanInvest_ReservationAllowsInvest() public {
        uint256 roundId = _createWhitelistRound();

        assertFalse(fundraise.canInvest(roundId, investor1));

        // Create reservation
        vm.startPrank(board);
        fundraise.reserveSpot(
            roundId,
            investor1,
            5e6,
            createInEuint128(0, board),
            createInEuint128(0, board),
            createInEbool(false, board),
            createInEbool(false, board),
            false
        );
        vm.stopPrank();

        // Reservation allows invest
        assertTrue(fundraise.canInvest(roundId, investor1));
    }

    function test_CanInvest_NonWhitelistRound_AlwaysTrue() public {
        uint256 roundId = _createDefaultRound();

        assertTrue(fundraise.canInvest(roundId, investor1));
        assertTrue(fundraise.canInvest(roundId, investor2));
        assertTrue(fundraise.canInvest(roundId, investor3));
    }

    function test_CanInvest_ClosedRound_ReturnsFalse() public {
        uint256 roundId = _createDefaultRound();

        vm.prank(board);
        fundraise.closeRound(roundId);

        assertFalse(fundraise.canInvest(roundId, investor1));
    }

    function test_CanInvest_DeadlinePassed_ReturnsFalse() public {
        vm.prank(board);
        uint256 roundId = fundraise.createRound(
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

        assertTrue(fundraise.canInvest(roundId, investor1));

        vm.warp(block.timestamp + 2 days);

        assertFalse(fundraise.canInvest(roundId, investor1));
    }

    function test_WhitelistRound_FullLifecycle() public {
        // 1. Create whitelist-only round
        uint256 roundId = _createWhitelistRound();

        // 2. Whitelist investors
        address[] memory investors = new address[](2);
        investors[0] = investor1;
        investors[1] = investor2;
        vm.prank(board);
        fundraise.addToWhitelist(roundId, investors);

        // 3. Non-whitelisted investor cannot invest
        _mintAndApprove(investor3, 1e6, address(fundraise));
        _investExpectRevert(fundraise, roundId, investor3, 1e6, Fundraise.NotWhitelisted.selector);

        // 4. Whitelisted investors can invest
        _mintAndApprove(investor1, 1e6, address(fundraise));
        _invest(fundraise, roundId, investor1, 1e6);

        _mintAndApprove(investor2, 2e6, address(fundraise));
        _invest(fundraise, roundId, investor2, 2e6);

        // 5. Verify investments
        IFundraise.Round memory round = fundraise.getRound(roundId);
        assertEq(round.totalRaised, 3e6);
        assertEq(round.investorCount, 2);

        // 6. Close and finalize
        vm.prank(board);
        fundraise.closeRound(roundId);

        vm.prank(board);
        fundraise.finalizeRound(roundId);

        // 7. Verify SAFEs issued
        assertEq(safeContract.safeCount(), 2);
    }
}
