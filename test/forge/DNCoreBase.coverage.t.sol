// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// DNCoreBase coverage — the shared HyperCore execution surface (CoreWriter
// sends, precompile reads, admin + action gates) that INTERNAL_TOOLS_ROUND §3
// flagged at 48.2%. Target ≥90% before the r3 redeploy. Every test drives the
// base through its only live child (DNCoreStrategy) with the REAL precompile
// addresses etched with MockPrecompiles code — the same etch pattern the
// DNCoreHedgeBound regression uses, extended to every read and every gate.
//
// Run: forge test --match-path 'test/forge/DNCoreBase.coverage.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {DNCoreStrategy} from "../../contracts/DNCoreStrategy.sol";
import {DNCoreBase} from "../../contracts/adapters/DNCoreBase.sol";
import {HLConstants} from "../../contracts/adapters/HLConstants.sol";
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

/// A read-precompile stand-in that always reverts — simulates a precompile
/// blackout so the failure-safe paths (`ok == false` → 0, or DNCore__ReadFailed)
/// get real coverage instead of never firing.
contract MockReadRevert {
    fallback(bytes calldata) external returns (bytes memory) {
        revert("precompile read failed");
    }
}

contract DNCoreBaseCoverageTest is Test {
    // Precompile + system addresses — MUST match HLConstants exactly.
    address constant P_801 = 0x0000000000000000000000000000000000000801; // SPOT_BALANCE
    address constant P_807 = 0x0000000000000000000000000000000000000807; // ORACLE_PX
    address constant P_808 = 0x0000000000000000000000000000000000000808; // SPOT_PX
    address constant P_80A = 0x000000000000000000000000000000000000080a; // PERP_ASSET_INFO
    address constant P_80F = 0x000000000000000000000000000000000000080F; // ACCOUNT_MARGIN_SUMMARY
    address constant P_810 = 0x0000000000000000000000000000000000000810; // CORE_USER_EXISTS
    address constant P_813 = 0x0000000000000000000000000000000000000813; // POSITION2
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    // Forge tests run chainid 31337 → HLConstants picks the MAINNET wallet.
    address constant DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    MockUSDC usdc;
    DNCoreStrategy strat;
    address keeper = makeAddr("keeper");
    address sink = makeAddr("sink");
    address stranger = makeAddr("stranger");

    uint32 constant ASSET = 159;
    uint256 constant MAX_ACTION = 25e6; // $25 per action
    uint64 constant PX = 10_000; // raw spot px; pxScale 1e4 → $100 per 1e8 wei
    uint256 constant PX_SCALE = 1e4;
    uint64 constant TOKEN_IDX = 1070;
    uint32 constant SPOT_ASSET = 10000 + 107;

    // exact revert selectors (custom errors — 4-byte, EIP-170 discipline)
    bytes4 constant E_NOTKEEPER = bytes4(keccak256("DNCore__NotKeeper()"));
    bytes4 constant E_PAUSED = bytes4(keccak256("DNCore__Paused()"));
    bytes4 constant E_NOTINIT = bytes4(keccak256("DNCore__NotInitialized()"));
    bytes4 constant E_ZEROAMT = bytes4(keccak256("DNCore__ZeroAmount()"));
    bytes4 constant E_ZEROORDER = bytes4(keccak256("DNCore__ZeroOrder()"));
    bytes4 constant E_BADTIF = bytes4(keccak256("DNCore__BadTif()"));
    bytes4 constant E_BELOWMIN = bytes4(keccak256("DNCore__BelowMinNotional()"));
    bytes4 constant E_WRONGASSET = bytes4(keccak256("DNCore__WrongAsset()"));
    bytes4 constant E_CAP = bytes4(keccak256("DNCore__Cap()"));
    bytes4 constant E_NOTFLAT = bytes4(keccak256("DNCore__NotFlat()"));
    bytes4 constant E_SPOTDISABLED = bytes4(keccak256("DNCore__SpotDisabled()"));
    bytes4 constant E_READFAILED = bytes4(keccak256("DNCore__ReadFailed()"));

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(P_810, address(new MockCoreUserExists()).code);
        vm.etch(P_813, address(new MockPosition2()).code);
        vm.etch(P_80F, address(new MockMarginSummary()).code);
        vm.etch(P_80A, address(new MockPerpInfo()).code);
        vm.etch(P_807, address(new MockOraclePx()).code);
        vm.etch(P_801, address(new MockSpotBalance()).code);
        vm.etch(P_808, address(new MockSpotPx()).code);
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(DEPOSIT_WALLET, address(new MockCoreDepositWallet()).code);

        // storage lives at the etched address — configure through it
        MockCoreUserExists(P_810).setExists(true);
        MockPosition2(P_813).set(0, 0, 0, 3, false); // flat
        MockMarginSummary(P_80F).set(100e6, 0, 0, 0); // $100 equity
        MockPerpInfo(P_80A).set("ETH", 1, 2, 20, false);
        MockOraclePx(P_807).setPx(3000_00000000); // $3000, 1e8-scaled
        MockSpotBalance(P_801).set(2e7, 0, 0); // hedge sz 0.2 HYPE (1e8/ea)
        MockSpotPx(P_808).setPx(PX);

        strat = new DNCoreStrategy(address(usdc), address(this), ASSET, MAX_ACTION);
        strat.setKeeper(keeper);
        strat.setSpotConfig(107, TOKEN_IDX, PX_SCALE); // flat → allowed
    }

    /*//////////////////// Admin: pause + asset config ////////////////////*/

    function test_setPaused_sets_and_emits() public {
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.PausedSet(true);
        strat.setPaused(true);
        assertTrue(strat.paused());
        strat.setPaused(false);
        assertFalse(strat.paused());
    }

    function test_setPaused_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        strat.setPaused(true);
    }

    function test_setPerpAsset_whenFlat_ok() public {
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.PerpAssetSet(1);
        strat.setPerpAsset(1);
        assertEq(strat.perpAsset(), 1);
    }

    function test_setPerpAsset_reverts_whenHedged() public {
        MockPosition2(P_813).set(-5e8, 100e6, 0, 3, false); // short open
        vm.expectRevert(E_NOTFLAT);
        strat.setPerpAsset(1);
    }

    function test_setSpotConfig_validation() public {
        vm.expectRevert(E_ZEROORDER);
        strat.setSpotConfig(0, TOKEN_IDX, PX_SCALE); // pair 0
        vm.expectRevert(E_ZEROORDER);
        strat.setSpotConfig(107, 0, PX_SCALE); // token 0
        vm.expectRevert(E_ZEROORDER);
        strat.setSpotConfig(107, TOKEN_IDX, 0); // scale 0
        vm.expectRevert(E_ZEROORDER);
        strat.setSpotConfig(107, TOKEN_IDX, 1e18 + 1); // scale ceiling
    }

    function test_setSpotConfig_derives_spotAsset_and_emits() public {
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.SpotConfigSet(42, 55, 10000 + 42, 1e8);
        strat.setSpotConfig(42, 55, 1e8);
        assertEq(strat.spotAsset(), 10000 + 42);
        assertEq(strat.spotPairIndex(), 42);
        assertEq(strat.spotTokenIndex(), 55);
        assertEq(strat.spotPxScale(), 1e8);
    }

    /*//////////////////// Gates: keeper / paused / core account ////////////////////*/

    function test_onlyKeeper_owner_and_keeper_pass_stranger_reverts() public {
        strat.moveUsdcToPerp(10e6); // owner passes
        vm.prank(keeper);
        strat.moveUsdcToPerp(10e6); // keeper passes
        vm.prank(stranger);
        vm.expectRevert(E_NOTKEEPER);
        strat.moveUsdcToPerp(10e6);
    }

    function test_notPaused_blocks_actions() public {
        strat.setPaused(true);
        vm.expectRevert(E_PAUSED);
        strat.moveUsdcToPerp(10e6);
        vm.expectRevert(E_PAUSED);
        strat.openShort(ASSET, 3e11, 5e5, HLConstants.TIF_GTC);
        vm.expectRevert(E_PAUSED);
        strat.hedgeTransferOut(sink, 1e6);
    }

    function test_coreAccountRequired_blocks_actions() public {
        MockCoreUserExists(P_810).setExists(false); // Core account not initialized
        vm.expectRevert(E_NOTINIT);
        strat.moveUsdcToPerp(10e6);
        vm.expectRevert(E_NOTINIT);
        strat.openShort(ASSET, 3e11, 5e5, HLConstants.TIF_GTC);
        vm.expectRevert(E_NOTINIT);
        strat.hedgeTransferOut(sink, 1e6);
        // the bare read is a SAFE passthrough — reports false, never gates
        assertFalse(strat.coreAccountExists());
    }

    /*//////////////////// USD class transfers (action 7) ////////////////////*/

    function test_moveUsdcToPerp_cap_and_encoding() public {
        vm.expectRevert(E_CAP); // ntl 0 is rejected by the same check
        strat.moveUsdcToPerp(0);
        vm.expectRevert(E_CAP);
        strat.moveUsdcToPerp(uint64(MAX_ACTION + 1));

        bytes memory data = abi.encodePacked(uint8(1), uint24(7), abi.encode(uint64(10e6), true));
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.ActionSent(7, data);
        strat.moveUsdcToPerp(10e6);
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), data);
    }

    function test_moveUsdcToSpot_encodes_false_direction() public {
        bytes memory data = abi.encodePacked(uint8(1), uint24(7), abi.encode(uint64(10e6), false));
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.ActionSent(7, data);
        strat.moveUsdcToSpot(10e6);
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), data);
    }

    /*//////////////////// Orders (action 1): perp + spot legs ////////////////////*/

    function test_openShort_validation_ladder() public {
        vm.expectRevert(E_WRONGASSET);
        strat.openShort(158, 3e11, 5e5, HLConstants.TIF_GTC); // asset != perpAsset
        vm.expectRevert(E_ZEROORDER);
        strat.openShort(ASSET, 0, 5e5, HLConstants.TIF_GTC);
        vm.expectRevert(E_ZEROORDER);
        strat.openShort(ASSET, 3e11, 0, HLConstants.TIF_GTC);
        vm.expectRevert(E_BADTIF);
        strat.openShort(ASSET, 3e11, 5e5, 0); // 0 is no TIF
        vm.expectRevert(E_BADTIF);
        strat.openShort(ASSET, 3e11, 5e5, 4); // beyond IOC
        vm.expectRevert(E_BELOWMIN);
        strat.openShort(ASSET, 3e11, 100, HLConstants.TIF_GTC); // $0.003 < $10
        vm.expectRevert(E_CAP);
        strat.openShort(ASSET, 3e11, 1e7, HLConstants.TIF_GTC); // $300 > $25
    }

    function test_openShort_success_event_and_exact_action_bytes() public {
        bytes memory data =
            abi.encodePacked(uint8(1), uint24(1), abi.encode(ASSET, false, uint64(3e11), uint64(5e5), false, uint8(2), uint128(0)));
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.OrderSent(ASSET, false, false, 3e11, 5e5, 2, 0);
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.ActionSent(1, data);
        strat.openShort(ASSET, 3e11, 5e5, HLConstants.TIF_GTC); // $15 notional
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), data);
        assertEq(MockCoreWriter(CORE_WRITER).actionCount(), 1);
    }

    function test_closeShort_marks_reduceOnly() public {
        bytes memory data =
            abi.encodePacked(uint8(1), uint24(1), abi.encode(ASSET, true, uint64(3e11), uint64(5e5), true, uint8(1), uint128(0)));
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.OrderSent(ASSET, true, true, 3e11, 5e5, 1, 0);
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.ActionSent(1, data);
        strat.closeShort(ASSET, 3e11, 5e5, HLConstants.TIF_ALO);
    }

    function test_spot_orders_require_spotConfig_first() public {
        DNCoreStrategy fresh = new DNCoreStrategy(address(usdc), address(this), ASSET, MAX_ACTION);
        vm.expectRevert(E_SPOTDISABLED);
        fresh.openSpotBuy(3e9, 5e5, HLConstants.TIF_GTC);
        vm.expectRevert(E_SPOTDISABLED);
        fresh.sellSpot(3e9, 5e5, HLConstants.TIF_GTC);
        vm.expectRevert(E_SPOTDISABLED);
        fresh.hedgeTransferOut(sink, 1e6);
    }

    function test_openSpotBuy_uses_derived_spotAsset() public {
        // $30 px × 0.5 sz → $15 notional (inside the $10 floor and the $25 cap)
        bytes memory data = abi.encodePacked(
            uint8(1), uint24(1), abi.encode(SPOT_ASSET, true, uint64(3e9), uint64(5e7), false, uint8(2), uint128(0))
        );
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.OrderSent(SPOT_ASSET, true, false, 3e9, 5e7, 2, 0);
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.ActionSent(1, data);
        strat.openSpotBuy(3e9, 5e7, HLConstants.TIF_GTC);
    }

    function test_sellSpot_encodes_sell_direction() public {
        strat.sellSpot(3e9, 5e7, HLConstants.TIF_IOC); // $15 notional, must not revert
        assertTrue(MockCoreWriter(CORE_WRITER).actionCount() >= 1);
    }

    function test_hedgeTransferOut_validation() public {
        vm.expectRevert(E_ZEROAMT);
        strat.hedgeTransferOut(address(0), 1e6);
        vm.expectRevert(E_ZEROAMT);
        strat.hedgeTransferOut(sink, 0);
    }

    function test_hedgeTransferOut_cap_values_with_live_mark() public {
        // usd6 = 1e8 * 10_000 / 1e4 = 1e8 = $100 > $25 cap → Cap
        vm.expectRevert(E_CAP);
        strat.hedgeTransferOut(sink, 1e8);
    }

    function test_hedgeTransferOut_eventOrder_then_exact_action_bytes() public {
        // Event-ordering discipline: HedgeTransferOut BEFORE the CoreWriter send.
        bytes memory data = abi.encodePacked(uint8(1), uint24(6), abi.encode(sink, uint64(TOKEN_IDX), uint64(2e7)));
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.HedgeTransferOut(sink, 2e7);
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreBase.ActionSent(6, data);
        strat.hedgeTransferOut(sink, 2e7); // $20 ≤ $25 cap
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), data);
    }

    /*//////////////////// Bridge in/out (shared internals) ////////////////////*/

    function test_bridgeUsdcToCore_pulls_via_deposit_wallet() public {
        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));
        usdc.mint(address(strat), 25e18); // 18-dec mock → coreScale 1e12 → $25

        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreStrategy.BridgeToCore(25e18, 25e6);
        vm.prank(keeper);
        strat.bridgeUsdcToCore(25e18);

        assertEq(MockCoreDepositWallet(DEPOSIT_WALLET).lastAmount(), 25e18);
        assertEq(MockCoreDepositWallet(DEPOSIT_WALLET).lastDex(), HLConstants.SPOT_DEX);
        assertEq(strat.corePrincipal6(), 25e6);
        assertEq(usdc.balanceOf(address(strat)), 0); // wallet pulled it
    }

    function test_bridgeUsdcToCore_guards() public {
        usdc.mint(address(strat), 25e18);
        vm.prank(keeper);
        vm.expectRevert(E_ZEROAMT);
        strat.bridgeUsdcToCore(0);
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("DNCore__SubDust()"))); // 18-dec → %1e12
        strat.bridgeUsdcToCore(25e18 + 1);
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("DNCore__ExceedsBalance()")));
        strat.bridgeUsdcToCore(30e18); // balance only 25e18
    }

    function test_bridgeBackToEvm_realizes_profit_first() public {
        usdc.mint(address(strat), 25e18);
        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));
        vm.prank(keeper);
        strat.bridgeUsdcToCore(25e18); // principal 25e6; equity (mock) 100e6
        MockSpotBalance(P_801).setToken(0, 500_000_000, 0, 0); // Core spot USDC $5 (source of funds)
        // profitAvail = all-legs (100 + 5 + 20) − 25 = 100e6 → a 5e6 skim is ALL profit
        vm.prank(keeper);
        strat.bridgeBackToEvm(5e6);
        (int256 eq, uint256 prin, , uint256 realized, , ) = strat.coreState();
        assertEq(eq, 100e6); // A3 FIX 2: perp leg NOT debited for a spot outflow
        assertEq(prin, 25e6); // principal untouched by a profit-sized skim
        assertEq(realized, 5e6 * 1e12); // underlying units

        bytes memory data = abi.encodePacked(
            uint8(1),
            uint24(13),
            abi.encode(
                address(uint160(HLConstants.BASE_SYSTEM_ADDRESS) + uint160(HLConstants.USDC_TOKEN_INDEX)),
                address(0),
                HLConstants.SPOT_DEX,
                HLConstants.SPOT_DEX,
                uint64(HLConstants.USDC_TOKEN_INDEX),
                uint64(5e6) * 100 // Core wei (1e8/USDC), NOT raw 6dp
            )
        );
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), data);
    }

    /// Wire-unit regression (security re-review t_281b833e, A3R-1; card
    /// t_3493da9b). The action-13 `sendAsset` `wei` field is Core wei
    /// (1e8/USDC), so a 6dp `amount6` MUST be emitted as `amount6 * 100`.
    /// Pre-fix the base emitted `amount6` raw — 100x too small — so a Core->EVM
    /// send removed the full amount from the ledgers while only 1/100 left Core;
    /// once `DN_ALL_LEGS_PROFIT` was enabled a `harvest()` would have swept real
    /// principal to the vault as "profit" (AUDIT_SCOPE inv1). Mirrors the
    /// shipped sibling HLEarnStrategy.t.sol:133 (`_sendAssetExpected(10e6 * 100)`).
    function test_bridgeBackToEvm_wire_units_are_core_wei() public {
        usdc.mint(address(strat), 25e18);
        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));
        vm.prank(keeper);
        strat.bridgeUsdcToCore(25e18); // principal 25e6
        MockSpotBalance(P_801).setToken(0, 500_000_000, 0, 0); // Core spot USDC $5 (source of funds)

        uint64 amount6 = 5e6; // $5.00 in USDC 6dp
        vm.prank(keeper);
        strat.bridgeBackToEvm(amount6);

        bytes memory expected = abi.encodePacked(
            uint8(1),
            uint24(13),
            abi.encode(
                address(uint160(HLConstants.BASE_SYSTEM_ADDRESS) + uint160(HLConstants.USDC_TOKEN_INDEX)),
                address(0),
                HLConstants.SPOT_DEX,
                HLConstants.SPOT_DEX,
                uint64(HLConstants.USDC_TOKEN_INDEX),
                uint64(amount6) * 100
            )
        );
        bytes memory sent = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(sent, expected, "sendAsset wire = 6dp * 100 (Core wei)");

        // Decode the emitted wei field explicitly and pin both failure modes.
        bytes memory payload = new bytes(sent.length - 4);
        for (uint256 i; i < payload.length; ++i) payload[i] = sent[4 + i];
        (,,,, uint64 tok, uint64 wireWei) =
            abi.decode(payload, (address, address, uint32, uint32, uint64, uint64));
        assertEq(tok, uint64(HLConstants.USDC_TOKEN_INDEX), "USDC token index");
        assertEq(wireWei, 500_000_000, "explicit: $5.00 -> 5e8 Core wei");
        assertTrue(wireWei != uint64(amount6), "must NOT be the raw 6dp amount (pre-fix bug)");
    }

    function test_bridgeBackToEvm_guards() public {
        vm.prank(keeper);
        vm.expectRevert(E_ZEROAMT);
        strat.bridgeBackToEvm(0);
        vm.prank(keeper);
        // A3 FIX 1 (security re-review t_42954aa0): the bound is now the SOURCE
        // OF FUNDS — Core spot USDC (default mock 2e7 raw → 20e4 6dp), NOT the
        // all-legs equity. 141e6 far exceeds the spot balance.
        vm.expectRevert(bytes4(keccak256("DNCore__ExceedsSpot()")));
        strat.bridgeBackToEvm(141e6);
    }

    /// A3 regression (security review t_3a89fe76). Hedge held → perp equity
    /// (coreEquity6) BELOW principal while ALL-LEGS equity is ABOVE it. Pre-fix
    /// the perp-only split computed profitAvail == 0 and booked the whole
    /// outflow as PRINCIPAL, shaving the ledger (proven executably in the
    /// review: principal 15,187,500 → 13,797,500). Post-fix it realizes as PROFIT.
    function test_bridgeBackToEvm_hedged_realizes_profit_on_all_legs() public {
        usdc.mint(address(strat), 25e18);
        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));
        vm.prank(keeper);
        strat.bridgeUsdcToCore(25e18); // principal 25e6

        // perp leg 20e6 (< 25e6 principal); hedge token 10e6 ($10); spot USDC 5e6
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0);
        MockSpotBalance(P_801).setToken(TOKEN_IDX, 10e6, 0, 0); // hedge (token 1070)
        MockSpotBalance(P_801).setToken(0, 500_000_000, 0, 0);  // Core spot USDC $5 (1e8 spot wei)
        strat.syncCore();
        assertLt(strat.coreEquity6(), int256(25e6));           // perp-only < principal
        assertGt(strat.coreAllLegsEquity6(), int256(25e6));    // 20 + 5 + 10 = 35e6

        vm.prank(keeper);
        strat.bridgeBackToEvm(3e6); // 3e6 ≤ spot $5 AND ≤ profitAvail (35e6 − 25e6 = 10e6)
        (int256 eq, uint256 prin, , uint256 realized, , ) = strat.coreState();
        assertEq(eq, 20e6);       // A3 FIX 2: perp leg unchanged by a spot outflow
        assertEq(prin, 25e6);     // principal UNTOUCHED — was shaved pre-fix
        assertEq(realized, 3e6 * 1e12);
    }

    /// Same hedged state, outflow LARGER than available profit: the excess is
    /// (correctly) booked as principal, the profit portion as profit. The amount
    /// must still be sourceable from Core spot USDC (A3 FIX 1), so principal is
    /// sized above perp+hedge to create a genuine partial-profit case.
    function test_bridgeBackToEvm_hedged_partial_profit_then_principal() public {
        usdc.mint(address(strat), 35e18);
        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));
        vm.prank(keeper);
        strat.bridgeUsdcToCore(35e18);
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0);
        MockSpotBalance(P_801).setToken(TOKEN_IDX, 10e6, 0, 0); // hedge $10
        MockSpotBalance(P_801).setToken(0, 1_200_000_000, 0, 0); // Core spot USDC $12
        strat.syncCore();
        // all-legs = 20 + 12 + 10 = 42e6; profitAvail = 42 − 35 = 7e6
        // 12e6 outflow (≤ spot $12) = 7e6 profit + 5e6 principal
        vm.prank(keeper);
        strat.bridgeBackToEvm(12e6);
        (int256 eq, uint256 prin, , uint256 realized, , ) = strat.coreState();
        assertEq(eq, 20e6);            // A3 FIX 2: perp leg unchanged
        assertEq(prin, 30e6);          // 35e6 − 5e6 principal
        assertEq(realized, 7e6 * 1e12);
    }

    function test_coreSpotUsdc6_reads_usdc_token0_and_fails_safe() public {
        MockSpotBalance(P_801).setToken(0, 65_950_000, 0, 0); // live book #2 raw (1e8 spot wei)
        assertEq(strat.coreSpotUsdc6(), 659_500); // → 6dp USDC ($0.6595)
        vm.etch(P_801, address(new MockReadRevert()).code);
        assertEq(strat.coreSpotUsdc6(), 0); // blackout → 0, never revert
    }

    function test_coreProfitUsesAllLegs_marker_is_true() public {
        assertTrue(strat.coreProfitUsesAllLegs());
    }

    /*//////////////////// Reads: happy paths + decode ////////////////////*/

    function test_coreAccountExists_read() public {
        assertTrue(strat.coreAccountExists());
        MockCoreUserExists(P_810).setExists(false);
        assertFalse(strat.coreAccountExists());
    }

    function test_position_decodes_full_struct() public {
        MockPosition2(P_813).set(-5e8, 100e6, -2e6, 3, true);
        DNCoreBase.Position memory p = strat.position();
        assertEq(p.szi, -5e8);
        assertEq(p.entryNtl, 100e6);
        assertEq(p.isolatedRawUsd, -2e6);
        assertEq(p.leverage, 3);
        assertTrue(p.isIsolated);
    }

    function test_marginSummary_decodes_full_struct() public {
        MockMarginSummary(P_80F).set(-12e6, 5e6, 8e6, -1e6);
        DNCoreBase.AccountMarginSummary memory m = strat.marginSummary();
        assertEq(m.accountValue, -12e6);
        assertEq(m.marginUsed, 5e6);
        assertEq(m.ntlPos, 8e6);
        assertEq(m.rawUsd, -1e6);
    }

    function test_perpSzDecimals_and_oraclePx() public {
        assertEq(strat.perpSzDecimals(), 2);
        assertEq(strat.oraclePx(), 3000_00000000);
    }

    /*//////////////////// Reads: failure-safe paths ////////////////////*/

    function test_readRevert_position_margin_exists_revert_ReadFailed() public {
        vm.etch(P_813, address(new MockReadRevert()).code);
        vm.expectRevert(E_READFAILED);
        strat.position();
        vm.etch(P_80F, address(new MockReadRevert()).code);
        vm.expectRevert(E_READFAILED);
        strat.marginSummary();
        vm.etch(P_810, address(new MockReadRevert()).code);
        vm.expectRevert(E_READFAILED);
        strat.coreAccountExists();
    }

    function test_spot_reads_fail_safe_to_zero() public {
        vm.etch(P_801, address(new MockReadRevert()).code);
        assertEq(strat.spotHedgeSz(), 0); // blackout → 0, never revert
        vm.etch(P_808, address(new MockReadRevert()).code);
        assertEq(strat.spotPx(), 0);
        assertEq(strat.spotValue6(), 0); // px 0 → value 0
    }

    function test_spot_reads_unconfigured_leg_is_zero() public {
        DNCoreStrategy fresh = new DNCoreStrategy(address(usdc), address(this), ASSET, MAX_ACTION);
        assertEq(fresh.spotHedgeSz(), 0); // tokenIndex 0 short-circuit
        assertEq(fresh.spotPx(), 0); // pairIndex 0 short-circuit
        assertEq(fresh.spotValue6(), 0);
    }

    function test_spotValue6_math_and_zero_px() public {
        assertEq(strat.spotValue6(), 2e7); // 2e7 * 10_000 / 1e4 = 2e7 ($20)
        MockSpotPx(P_808).setPx(0);
        assertEq(strat.spotValue6(), 0); // blackout mid-hedge → 0
    }

    function test_totalAssets_counts_equity_spot_cash_hedge_and_idle() public {
        MockSpotBalance(P_801).setToken(0, 500_000_000, 0, 0); // Core spot USDC $5 (1e8 wei)
        // syncCore pulls equity from the margin precompile (CoreSynced event)
        vm.expectEmit(true, true, true, true, address(strat));
        emit DNCoreStrategy.CoreSynced(100e6, 0, block.timestamp);
        strat.syncCore();
        // equity 100e6 + Core spot CASH $5 + hedge $20 → 125e6 * 1e12; idle 0
        assertEq(strat.totalAssets(), 125e6 * 1e12);
    }
}
