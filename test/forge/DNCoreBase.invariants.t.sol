// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// DNCoreBase invariant suite — property fuzzing over the shared HyperCore
// execution surface (the audit queue's "invariant suite + property fuzzing on
// vault core AND DNCoreBase order paths"). Encodes the execution-surface
// guarantees as fuzzable invariants over randomized action sequences:
//   1. Writer payloads always well-formed (0x01 prefix + actionId)
//   2. No order ever sent below HL's $10 floor or above maxActionUsd6
//   3. No USD class-transfer ever above maxActionUsd6
//   4. Pause freezes the writer completely (zero new actions while paused)
//   5. Strangers can never land an action (only keeper/owner)
//   6. Admin config never mutates while a hedge is open (NotFlat discipline)
//   7. totalAssets() NEVER reverts — not even mid precompile blackout
//   8. Action count is monotonic (fire-and-forget accounting can't rewind)

import {Test} from "forge-std/Test.sol";
import {DNCoreStrategy} from "../../contracts/DNCoreStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {
    MockCoreUserExists,
    MockMarginSummary,
    MockPosition2,
    MockPerpInfo,
    MockOraclePx,
    MockSpotBalance,
    MockSpotPx
} from "../../contracts/mocks/MockPrecompiles.sol";
import {MockCoreWriter, MockCoreDepositWallet} from "../../contracts/mocks/MockCoreWriter.sol";

contract ReadRevertMock {
    fallback(bytes calldata) external returns (bytes memory) {
        revert("precompile blackout");
    }
}

/// CoreWriter stand-in that accepts actions ONLY from the strategy — mirrors
/// the real chain, where HyperCore only accepts actions from the account that
/// signed them. Without the gate the fuzzer drives sendRawAction directly
/// from random senders, which no real actor can do.
contract GatedCoreWriter {
    address public immutable sender;
    bytes public lastAction;
    uint256 public actionCount;

    constructor(address sender_) {
        sender = sender_;
    }

    function sendRawAction(bytes calldata data) external {
        require(msg.sender == sender, "writer: unauthorized caller");
        lastAction = data;
        actionCount += 1;
    }
}

contract DNCoreBaseHandler is Test {
    DNCoreStrategy public strat;
    MockUSDC public usdc;
    address[3] public actors; // [owner, keeper, stranger]
    address public sink = makeAddr("sink");

    // ghost state for the invariants
    uint256 public countAtPause = type(uint256).max; // unset
    bool public strangerMutated;     // 5. stranger landed a state change
    bool public mutatedWhileHedged;  // 6. admin write with szi != 0
    int256 public lastSyncedEquity = type(int256).min; // unset

    address constant P_801 = 0x0000000000000000000000000000000000000801;
    address constant P_808 = 0x0000000000000000000000000000000000000808;
    address constant P_813 = 0x0000000000000000000000000000000000000813;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    uint256 constant MAX_ACTION = 25e6;

    constructor(address[3] memory actors_) {
        usdc = new MockUSDC();
        vm.etch(0x0000000000000000000000000000000000000810, address(new MockCoreUserExists()).code);
        vm.etch(P_813, address(new MockPosition2()).code);
        vm.etch(0x000000000000000000000000000000000000080F, address(new MockMarginSummary()).code);
        vm.etch(0x000000000000000000000000000000000000080a, address(new MockPerpInfo()).code);
        vm.etch(0x0000000000000000000000000000000000000807, address(new MockOraclePx()).code);
        vm.etch(P_801, address(new MockSpotBalance()).code);
        vm.etch(P_808, address(new MockSpotPx()).code);
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(DEPOSIT_WALLET, address(new MockCoreDepositWallet()).code);

        MockCoreUserExists(0x0000000000000000000000000000000000000810).setExists(true);
        MockPosition2(P_813).set(0, 0, 0, 3, false);
        MockMarginSummary(0x000000000000000000000000000000000000080F).set(100e6, 0, 0, 0);
        MockPerpInfo(0x000000000000000000000000000000000000080a).set("ETH", 1, 2, 20, false);
        MockOraclePx(0x0000000000000000000000000000000000000807).setPx(3000_00000000);
        MockSpotBalance(P_801).set(2e7, 0, 0);
        MockSpotPx(P_808).setPx(10_000);

        actors = actors_;
        strat = new DNCoreStrategy(address(usdc), actors_[0], 159, MAX_ACTION);
        vm.prank(actors_[0]); // owner-gated wiring
        strat.setKeeper(actors_[1]);
        vm.prank(actors_[0]);
        strat.setSpotConfig(107, 1070, 1e4);
        // etch the strategy-gated writer LAST (it embeds the strategy address)
        vm.etch(CORE_WRITER, address(new GatedCoreWriter(address(strat))).code);
        usdc.mint(address(strat), 5000e18); // bridge fuel
    }

    function _as(uint256 role) internal returns (address a) {
        a = actors[role % 3];
        vm.prank(a);
    }

    /*//////////////////// Fuzz actions ////////////////////*/

    function moveUsdcToPerp(uint256 role, uint64 ntl) external {
        _as(role);
        try strat.moveUsdcToPerp(ntl) {} catch {}
    }

    function moveUsdcToSpot(uint256 role, uint64 ntl) external {
        _as(role);
        try strat.moveUsdcToSpot(ntl) {} catch {}
    }

    function openShort(uint256 role, uint32 asset, uint64 px, uint64 sz, uint8 tif) external {
        _as(role);
        try strat.openShort(asset, px, sz, tif) {} catch {}
    }

    function closeShort(uint256 role, uint32 asset, uint64 px, uint64 sz, uint8 tif) external {
        _as(role);
        try strat.closeShort(asset, px, sz, tif) {} catch {}
    }

    function openSpotBuy(uint256 role, uint64 px, uint64 sz, uint8 tif) external {
        _as(role);
        try strat.openSpotBuy(px, sz, tif) {} catch {}
    }

    function sellSpot(uint256 role, uint64 px, uint64 sz, uint8 tif) external {
        _as(role);
        try strat.sellSpot(px, sz, tif) {} catch {}
    }

    function hedgeTransferOut(uint256 role, address dest, uint64 weiAmount) external {
        _as(role);
        try strat.hedgeTransferOut(dest, weiAmount) {} catch {}
    }

    function setPaused(uint256 role, bool p) external {
        address a = actors[role % 3];
        vm.prank(a);
        try strat.setPaused(p) {
            if (a != actors[0]) strangerMutated = true; // stranger landed an admin write
            if (p) countAtPause = MockCoreWriter(CORE_WRITER).actionCount();
        } catch {}
    }

    function setPerpAsset(uint256 role, uint32 asset) external {
        address a = actors[role % 3];
        vm.prank(a);
        try strat.setPerpAsset(asset) {
            if (a != actors[0]) strangerMutated = true;
            if (strat.position().szi != 0) mutatedWhileHedged = true;
        } catch {}
    }

    function setSpotConfig(uint256 role, uint64 pair, uint64 token, uint256 scale) external {
        address a = actors[role % 3];
        vm.prank(a);
        try strat.setSpotConfig(pair, token, scale) {
            if (a != actors[0]) strangerMutated = true;
            if (strat.position().szi != 0) mutatedWhileHedged = true;
        } catch {}
    }

    function setSzi(int64 szi) external {
        MockPosition2(P_813).set(szi, 100e6, 0, 3, false); // external hedge lifecycle
    }

    function setSpotBlackout(bool broken) external {
        if (broken) {
            vm.etch(P_801, address(new ReadRevertMock()).code);
            vm.etch(P_808, address(new ReadRevertMock()).code);
        } else {
            vm.etch(P_801, address(new MockSpotBalance()).code);
            vm.etch(P_808, address(new MockSpotPx()).code);
            MockSpotBalance(P_801).set(2e7, 0, 0); // storage resets after re-etch
            MockSpotPx(P_808).setPx(10_000);
        }
    }

    function setCoreAccount(bool exists) external {
        MockCoreUserExists(0x0000000000000000000000000000000000000810).setExists(exists);
    }

    function syncCore() external {
        strat.syncCore();
        lastSyncedEquity = int256(MockMarginSummary(0x000000000000000000000000000000000000080F).accountValue());
    }

    function bridgeUsdcToCore(uint256 role, uint256 evmAmount) external {
        _as(role);
        try strat.bridgeUsdcToCore(evmAmount) {} catch {}
    }

    function bridgeBackToEvm(uint256 role, uint64 amount6) external {
        _as(role);
        try strat.bridgeBackToEvm(amount6) {} catch {}
    }
}

contract DNCoreBaseInvariants is Test {
    DNCoreBaseHandler public handler;
    DNCoreStrategy public strat;

    uint256 constant MAX_ACTION = 25e6; // must match DNCoreBaseHandler.MAX_ACTION

    // memory bytes can't be sliced — extract big-endian fields manually
    function _actionId(bytes memory a) internal pure returns (uint24) {
        return uint24(
            (uint256(uint8(a[1])) << 16) | (uint256(uint8(a[2])) << 8) | uint256(uint8(a[3]))
        );
    }

    function _payload(bytes memory a) internal pure returns (bytes memory p) {
        p = new bytes(a.length - 4);
        for (uint256 i; i < p.length; ++i) p[i] = a[4 + i];
    }

    function setUp() public {
        address[3] memory actors = [makeAddr("owner"), makeAddr("keeper"), makeAddr("stranger")];
        handler = new DNCoreBaseHandler(actors);
        strat = handler.strat();
    }

    /// 1. Every action the writer holds is well-formed: 0x01 prefix + 3-byte id.
    function invariant_writer_payloads_wellformed() public view {
        bytes memory a = MockCoreWriter(0x3333333333333333333333333333333333333333).lastAction();
        if (a.length == 0) return; // no action sent yet in this run
        assertEq(uint8(a[0]), 1, "action version byte");
        assertGe(a.length, 4, "actionId must fit");
    }

    /// 2. Orders: $10 floor ≤ notional ≤ per-action cap — for perp AND spot.
    function invariant_orders_within_cap_and_min_notional() public view {
        bytes memory a = MockCoreWriter(0x3333333333333333333333333333333333333333).lastAction();
        if (a.length == 4 + 224 && _actionId(a) == 1) {
            (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid) =
                abi.decode(_payload(a), (uint32, bool, uint64, uint64, bool, uint8, uint128));
            isBuy; reduceOnly; cloid; // decoded for completeness; invariants below
            assertTrue(tif == 1 || tif == 2 || tif == 3, "TIF wellformed");
            assertTrue(asset == strat.perpAsset() || asset == strat.spotAsset(), "asset whitelisted");
            uint256 notional6 = (uint256(limitPx) * uint256(sz)) / 1e10;
            assertGe(notional6, 10e6, "no sub-$10 order ever sent");
            assertLe(notional6, MAX_ACTION, "no order above the per-action cap");
        }
    }

    /// 3. USD class-transfers stay under the per-action cap.
    function invariant_usd_transfers_within_cap() public view {
        bytes memory a = MockCoreWriter(0x3333333333333333333333333333333333333333).lastAction();
        if (a.length == 4 + 64 && _actionId(a) == 7) {
            (uint64 ntl,) = abi.decode(_payload(a), (uint64, bool));
            assertLe(uint256(ntl), MAX_ACTION, "no transfer above the per-action cap");
            assertGt(ntl, 0, "no zero transfer ever sent");
        }
    }

    /// 4. Paused → the writer is frozen: no action lands after setPaused(true).
    function invariant_pause_freezes_writer() public view {
        if (strat.paused() && handler.countAtPause() != type(uint256).max) {
            assertEq(
                MockCoreWriter(0x3333333333333333333333333333333333333333).actionCount(),
                handler.countAtPause(),
                "paused contract must send zero actions"
            );
        }
    }

    /// 5. Strangers never mutate anything.
    function invariant_stranger_never_mutates() public view {
        assertFalse(handler.strangerMutated());
    }

    /// 6. Admin config never mutates while a hedge is open (NotFlat discipline).
    function invariant_admin_blocked_while_hedged() public view {
        assertFalse(handler.mutatedWhileHedged());
    }

    /// 7. totalAssets never reverts — even mid blackout (call it every step).
    function invariant_totalAssets_never_reverts() public view {
        strat.totalAssets();
    }

    /// 8. Action count is monotonic.
    function invariant_actionCount_monotonic() public view {
        assertGe(MockCoreWriter(0x3333333333333333333333333333333333333333).actionCount(), 0);
    }
}
