// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// DN A3 contract fix — regression suite for the security RE-REVIEW findings
// (card t_42954aa0, commit 05de8909 → fix on card t_b7b4a9ee).
//
// FINDING 1: `bridgeBackToEvm` bounded the outflow on the ALL-LEGS equity but
//   `_sendUsdcToEvm` sources from the Core SPOT USDC balance — an unsourceable
//   amount was admitted, the sendAsset dropped silently, and principal /
//   profitRealized were already mutated (principal booked as yield, inv1).
//   FIX: bound on `coreSpotUsdc6()` (the source of funds), like HLEarnStrategy.
//
// FINDING 2: the retained `coreEquity6 -= amount6` + the widened bound broke
//   `totalAssets()` both ways (negative-equity clamp inflates NAV; the staged
//   keeper moveUsdcToSpot→bridge double-decrements → understated NAV).
//   FIX: count Core spot USDC in `totalAssets()` and drop the manual perp-leg
//   decrement (the move is naturally NAV-neutral: spot down, idle EVM up).
//
// Acceptance criteria pinned here:
//   (a) amount6 > coreSpotUsdc6() reverts;
//   (b) totalAssets() is unchanged by a Core→EVM bridge for amount6 both ≤ and
//       > coreEquity6 (value-neutral move, no NAV jump);
//   (c) the keeper's staged moveUsdcToSpot(amt) → bridgeBackToEvm(amt) leaves
//       totalAssets() unchanged;
//   (d) coreProfitUsesAllLegs() is pinned in the same suite as the all-legs split.
//
// Run: forge test --match-path 'test/forge/DNCore*.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {DNCoreStrategy} from "../../contracts/DNCoreStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {
    MockCoreUserExists,
    MockMarginSummary,
    MockPosition2,
    MockSpotBalance,
    MockSpotPx
} from "../../contracts/mocks/MockPrecompiles.sol";
import {MockCoreWriter, MockCoreDepositWallet} from "../../contracts/mocks/MockCoreWriter.sol";

contract DNCoreA3Test is Test {
    // Precompile + system addresses — MUST match HLConstants exactly.
    address constant P_801 = 0x0000000000000000000000000000000000000801; // SPOT_BALANCE
    address constant P_808 = 0x0000000000000000000000000000000000000808; // SPOT_PX
    address constant P_80F = 0x000000000000000000000000000000000000080F; // ACCOUNT_MARGIN_SUMMARY
    address constant P_810 = 0x0000000000000000000000000000000000000810; // CORE_USER_EXISTS
    address constant P_813 = 0x0000000000000000000000000000000000000813; // POSITION2
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    // Exact custom-error selectors (4-byte, EIP-170 discipline).
    bytes4 constant E_EXCEEDSSPOT = bytes4(keccak256("DNCore__ExceedsSpot()"));
    bytes4 constant E_EXCEEDSEQUITY = bytes4(keccak256("DNCore__ExceedsEquity()"));

    MockUSDC usdc;
    DNCoreStrategy strat;
    address keeper = makeAddr("keeper");
    address sink = makeAddr("sink");

    uint64 constant TOKEN_IDX = 1070; // hedge token (pair 107)
    uint64 constant PX = 10_000;
    uint256 constant PX_SCALE = 1e4;
    uint256 constant MAX_ACTION = 25e6;
    // underlying = MockUSDC (18 dec) → 1 USDC (6dp) = 1e12 underlying units.
    uint256 constant SCALE = 1e12;

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(P_810, address(new MockCoreUserExists()).code);
        vm.etch(P_813, address(new MockPosition2()).code);
        vm.etch(P_80F, address(new MockMarginSummary()).code);
        vm.etch(P_801, address(new MockSpotBalance()).code);
        vm.etch(P_808, address(new MockSpotPx()).code);
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(DEPOSIT_WALLET, address(new MockCoreDepositWallet()).code);

        MockCoreUserExists(P_810).setExists(true);
        MockPosition2(P_813).set(0, 0, 0, 3, false); // flat
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0); // perp $20 default
        MockSpotPx(P_808).setPx(PX);

        strat = new DNCoreStrategy(address(usdc), address(this), 159, MAX_ACTION);
        strat.setKeeper(keeper);
        strat.setSpotConfig(107, TOKEN_IDX, PX_SCALE); // flat → allowed

        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));
    }

    /// @dev Simulate the Core→EVM sendAsset landing: spot USDC drops by amount6
    /// (6dp → raw = amount6*100 in 1e8 spot-wei) and the idle EVM balance rises
    /// by the same value. Net value between legs is unchanged.
    function _landEvmCredit(uint64 amount6, uint64 spotRawBefore) internal {
        MockSpotBalance(P_801).setToken(0, uint64(uint256(spotRawBefore) - uint256(amount6) * 100), 0, 0);
        usdc.mint(address(strat), uint256(amount6) * SCALE);
    }

    function _bridgeIn(uint256 usd6) internal {
        usdc.mint(address(strat), usd6 * SCALE);
        vm.prank(keeper);
        strat.bridgeUsdcToCore(usd6 * SCALE);
    }

    /*//////////////////// (a) FINDING 1 — source-of-funds bound ////////////////////*/

    /// The exact Finding-1 PoC shape: an amount that IS within the all-legs equity
    /// but EXCEEDS the Core spot USDC balance (spot = 0) must revert and mutate
    /// nothing (pre-fix it booked phantom profit and the send dropped silently).
    function test_unsourceable_amount_reverts_exceeds_spot_no_mutation() public {
        _bridgeIn(25e6); // principal 25e6
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0);              // perp $20
        MockSpotBalance(P_801).setToken(TOKEN_IDX, 10e6, 0, 0);   // hedge $10
        MockSpotBalance(P_801).setToken(0, 0, 0, 0);              // Core spot USDC $0
        strat.syncCore();
        // all-legs = 20 + 0 + 10 = 30e6 > principal 25e6 → old bound admitted 5e6
        assertEq(strat.coreAllLegsEquity6(), int256(30e6));

        vm.prank(keeper);
        vm.expectRevert(E_EXCEEDSSPOT);
        strat.bridgeBackToEvm(5e6);

        // No phantom mutation of the ledgers.
        (int256 eq, uint256 prin, , uint256 realized, , ) = strat.coreState();
        assertEq(eq, 20e6);
        assertEq(prin, 25e6);
        assertEq(realized, 0);

        // At the actual spot balance it succeeds (5e6 == spot).
        MockSpotBalance(P_801).setToken(0, 500_000_000, 0, 0); // $5
        vm.prank(keeper);
        strat.bridgeBackToEvm(5e6);
        (, , , realized, , ) = strat.coreState();
        assertEq(realized, 5e6 * SCALE);
    }

    /// amount6 > coreSpotUsdc6() reverts even when spot is non-zero.
    function test_amount_above_spot_reverts() public {
        _bridgeIn(25e6);
        MockSpotBalance(P_801).setToken(0, 500_000_000, 0, 0); // spot $5
        strat.syncCore();
        vm.prank(keeper);
        vm.expectRevert(E_EXCEEDSSPOT);
        strat.bridgeBackToEvm(5_000_001); // 1 unit over spot
    }

    /// `amount <= spot` but `amount > all-legs` (deep perp loss) is caught by the
    /// trailing total-value guard so the principal ledger cannot underflow.
    function test_amount_above_all_legs_reverts_exceeds_equity() public {
        _bridgeIn(25e6);
        MockMarginSummary(P_80F).set(-5_000_000, 0, 0, 0);        // perp -$5
        MockSpotBalance(P_801).setToken(0, 3_000_000_000, 0, 0); // spot $30
        strat.syncCore();
        // all-legs = -5 + 30 = 25e6; 27e6 ≤ spot $30 but > all-legs 25e6
        vm.prank(keeper);
        vm.expectRevert(E_EXCEEDSEQUITY);
        strat.bridgeBackToEvm(27e6);
    }

    /*//////////////////// (b) FINDING 2 — NAV neutral ////////////////////*/

    function test_nav_neutral_amount_below_perp_equity() public {
        _bridgeIn(25e6);
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0);             // perp $20
        MockSpotBalance(P_801).setToken(0, 3_000_000_000, 0, 0); // spot $30
        strat.syncCore();
        uint256 ta0 = strat.totalAssets(); // 20 + 30 = 50e6

        uint64 amount6 = 5e6; // ≤ perp equity (coreEquity6 = 20e6)
        vm.prank(keeper);
        strat.bridgeBackToEvm(amount6);
        _landEvmCredit(amount6, 3_000_000_000);

        assertEq(strat.totalAssets(), ta0, "Core->EVM bridge must be NAV-neutral");
    }

    function test_nav_neutral_amount_above_perp_equity() public {
        _bridgeIn(25e6);
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0);
        MockSpotBalance(P_801).setToken(0, 3_000_000_000, 0, 0); // spot $30
        strat.syncCore();
        uint256 ta0 = strat.totalAssets();

        uint64 amount6 = 25e6; // > perp equity (20e6) — the negative-clamp PoC shape
        vm.prank(keeper);
        strat.bridgeBackToEvm(amount6);
        _landEvmCredit(amount6, 3_000_000_000);

        assertEq(strat.totalAssets(), ta0, "no NAV jump from amount > coreEquity6");
    }

    /*//////////////////// (c) keeper staged path ////////////////////*/

    /// The keeper's real BRIDGE_PROFIT sequence: class-transfer perp→spot
    /// (`moveUsdcToSpot`) then `bridgeBackToEvm` — NAV-neutral at every step.
    function test_nav_neutral_on_keeper_staged_move_then_bridge() public {
        _bridgeIn(25e6); // principal 25e6
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0); // perp $20
        MockSpotBalance(P_801).setToken(0, 0, 0, 0); // spot $0
        strat.syncCore();
        uint256 ta0 = strat.totalAssets(); // 20e6

        uint64 amount6 = 5e6;

        // STAGE 1 — keeper's moveUsdcToSpot(amount): perp margin → spot. The mock
        // CoreWriter action is a no-op, so drive the class transfer directly.
        vm.prank(keeper);
        strat.moveUsdcToSpot(amount6);
        MockMarginSummary(P_80F).set(15e6, 0, 0, 0);                    // perp 20 → 15
        MockSpotBalance(P_801).setToken(0, uint64(uint256(amount6) * 100), 0, 0); // spot 0 → 5
        strat.syncCore();
        assertEq(strat.totalAssets(), ta0, "staged class-transfer is NAV-neutral");

        // STAGE 2 — keeper's bridgeBackToEvm(amount). Pre-fix the manual
        // `coreEquity6 -= amount6` subtracted the already-reflected transfer a
        // SECOND time (inv3 break). Post-fix: NAV-neutral.
        vm.prank(keeper);
        strat.bridgeBackToEvm(amount6);
        assertEq(strat.totalAssets(), ta0, "bridge call is NAV-neutral (no double-decrement)");

        // STAGE 3 — the sendAsset lands Core→EVM.
        MockSpotBalance(P_801).setToken(0, 0, 0, 0);
        usdc.mint(address(strat), uint256(amount6) * SCALE);
        assertEq(strat.totalAssets(), ta0, "arrival is NAV-neutral (spot down, idle up)");
    }

    /*//////////////////// (d) marker pinned with the all-legs split ////////////////////*/

    function test_marker_pinned_with_all_legs_split() public {
        assertTrue(strat.coreProfitUsesAllLegs(), "marker must advertise the all-legs split");

        _bridgeIn(25e6); // principal 25e6
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0);              // perp $20 < principal
        MockSpotBalance(P_801).setToken(TOKEN_IDX, 10e6, 0, 0);   // hedge $10
        MockSpotBalance(P_801).setToken(0, 500_000_000, 0, 0);    // spot USDC $5
        strat.syncCore();
        assertLt(strat.coreEquity6(), int256(25e6));           // perp-only < principal
        assertGt(strat.coreAllLegsEquity6(), int256(25e6));    // 20 + 5 + 10 = 35e6

        uint256 prinBefore = strat.corePrincipal6();
        vm.prank(keeper);
        strat.bridgeBackToEvm(3e6);
        (, uint256 prin, , uint256 realized, , ) = strat.coreState();
        assertEq(prin, prinBefore, "hedged outflow realizes PROFIT; principal untouched");
        assertEq(realized, 3e6 * SCALE);
    }

    /*//////////////////// (e) RESIDUAL — negative perp equity must reduce NAV ////////////////////*/

    /// Pre-existing residual from the t_281b833e re-review: `totalAssets()`
    /// clamped ONLY the perp term (`coreEquity6 > 0 ? … : 0`), so a genuine
    /// unrealized perp LOSS went uncounted while the offsetting Core spot USDC /
    /// spot-hedge legs were still added in full → NAV OVERSTATED by |perp equity|.
    /// Fixed by summing the three Core legs SIGNED and clamping the TOTAL.
    /// Mutation check: revert the fix → this assertion reads 10e6 (loss dropped).
    function test_totalAssets_subtracts_negative_perp_equity() public {
        MockMarginSummary(P_80F).set(-5_000_000, 0, 0, 0);        // perp −$5 (real unrealized loss)
        MockSpotBalance(P_801).setToken(TOKEN_IDX, 0, 0, 0);     // no hedge
        MockSpotBalance(P_801).setToken(0, 1_000_000_000, 0, 0); // Core spot USDC $10
        strat.syncCore();

        assertEq(strat.coreEquity6(), int256(-5e6));
        assertEq(strat.coreAllLegsEquity6(), int256(5e6)); // −5 + 10
        // Old per-term clamp reported 10e6 (the −$5 loss vanished); honest NAV is $5.
        assertEq(strat.totalAssets(), 5e6 * SCALE, "negative perp equity must reduce NAV");
    }

    /// When the SIGNED Core legs net to ≤ 0 the whole Core side is worth 0 (NAV
    /// cannot go negative); only idle EVM counts. Pre-fix this reported the
    /// positive spot leg as if the perp loss did not exist.
    function test_totalAssets_net_negative_core_legs_clamp_to_zero() public {
        MockMarginSummary(P_80F).set(-5_000_000, 0, 0, 0);        // perp −$5
        MockSpotBalance(P_801).setToken(TOKEN_IDX, 0, 0, 0);
        MockSpotBalance(P_801).setToken(0, 200_000_000, 0, 0);   // Core spot USDC $2
        strat.syncCore();
        assertEq(strat.coreAllLegsEquity6(), int256(-3e6)); // −5 + 2
        assertEq(strat.totalAssets(), 0, "net-negative Core legs clamp to 0");
    }

    /// Normal-case invariant: with non-negative perp equity the signed-sum result
    /// is byte-identical to the old formula (no behaviour change off the edge).
    function test_totalAssets_unchanged_when_equity_positive() public {
        MockMarginSummary(P_80F).set(20e6, 0, 0, 0);             // perp $20
        MockSpotBalance(P_801).setToken(TOKEN_IDX, 10e6, 0, 0);  // hedge $10
        MockSpotBalance(P_801).setToken(0, 300_000_000, 0, 0);   // Core spot USDC $3
        strat.syncCore();
        assertEq(strat.totalAssets(), (20e6 + 3e6 + 10e6) * SCALE, "positive case: 33e6");
    }
}
