// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Regression for the community audit finding (2026-10-01, Firlinata, issue #2
// on the public audit repo — [Low]): DNCoreBase.hedgeTransferOut had NO
// per-action size bound, violating the written claim "worst case is bounded
// by maxActionUsd6 per action" (AUDIT_SCOPE §4 / VAULT_UNLOCK_PLAN §2).
// The fix values the send with the live spot mark and reverts DNCore__Cap
// over the policy cap — and refuses entirely through a price blackout.
//
// Run: forge test --match-path 'test/forge/DNCoreHedgeBound.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {DNCoreStrategy} from "../../contracts/DNCoreStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCoreUserExists, MockMarginSummary, MockPosition2, MockSpotPx} from "../../contracts/mocks/MockPrecompiles.sol";
import {MockCoreWriter, MockCoreDepositWallet} from "../../contracts/mocks/MockCoreWriter.sol";

contract DNCoreHedgeBoundTest is Test {
    MockUSDC usdc;
    DNCoreStrategy strat;
    address keeper = makeAddr("keeper");
    address sink = makeAddr("sink");
    address constant P_810 = 0x0000000000000000000000000000000000000810;
    address constant P_813 = 0x0000000000000000000000000000000000000813;
    address constant P_80F = 0x000000000000000000000000000000000000080F;
    address constant P_SPOT_PX = 0x0000000000000000000000000000000000000808; // HLConstants.SPOT_PX_PRECOMPILE
    address constant DEPOSIT_WALLET = 0x2222222222222222222222222222222222222222;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    // pxScale 1e4, px 10_000 raw → usd6 per 1e8 wei = 1e8 * 1e4 / 1e4 = 1e8 = $100/1e8 wei
    uint64 constant PX = 10_000;
    uint256 constant PX_SCALE = 1e4;
    uint256 constant MAX_ACTION = 25e6; // $25 per action

    function setUp() public {
        usdc = new MockUSDC();
        new MockCoreUserExists(); // etched in constructor? (etched by deploy below)
        MockCoreUserExists exists = new MockCoreUserExists();
        MockMarginSummary marg = new MockMarginSummary();
        MockPosition2 pos = new MockPosition2();
        MockSpotPx sppx = new MockSpotPx();
        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(P_810, address(exists).code);
        vm.etch(P_80F, address(marg).code);
        vm.etch(P_813, address(pos).code);
        vm.etch(P_SPOT_PX, address(sppx).code);
        vm.etch(CORE_WRITER, address(cw).code);
        vm.etch(DEPOSIT_WALLET, address(new MockCoreDepositWallet()).code);

        MockCoreUserExists(P_810).setExists(true); // storage lives at the etched address
        strat = new DNCoreStrategy(address(usdc), address(this), 159, MAX_ACTION);
        strat.setKeeper(keeper);
        strat.setSpotConfig(107, 1070, PX_SCALE);
        // point the mock at our price
        MockSpotPx(P_SPOT_PX).setPx(PX);
    }

    function test_inCap_send_ok() public {
        // $20 of hedge value — inside the $25 per-action cap
        strat.hedgeTransferOut(sink, 2e7);
    }

    function test_overCap_send_reverts() public {
        // $30 — over the $25 cap → DNCore__Cap (the finding's PoC shape)
        vm.expectRevert(bytes4(keccak256("DNCore__Cap()")));
        strat.hedgeTransferOut(sink, 3e7);
    }

    function test_price_blackout_refuses() public {
        // precompile hiccup → px 0 → the send waits (never moves hedge funds
        // blind)
        MockSpotPx(P_SPOT_PX).setPx(0);
        vm.expectRevert(bytes4(keccak256("DNCore__SpotDisabled()")));
        strat.hedgeTransferOut(sink, 1e6);
    }

    function test_nonKeeper_cannot_send() public {
        vm.prank(address(0xbeef));
        vm.expectRevert();
        strat.hedgeTransferOut(sink, 1e6);
    }
}
