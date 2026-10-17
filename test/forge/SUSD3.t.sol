// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// SUSD3 (Frontier junior-tranche sleeve) — strategy + executor, full lifecycle.
//
// Strategy (HyperEVM): the PT-sleeve mechanics (CCTP burn to an immutable
// executor, bounded attestation, async recall-with-shortfall) PLUS the
// Frontier gate (venueCleared fail-closed + ≤15% per-name cap) on the supply
// path, PLUS first-loss honesty (a downward value sync is recorded as-is and
// fires LossObserved — the venue's defining risk).
//
// Executor (Ethereum mainnet): the async exit door — enter (USDC→USD3→sUSD3),
// beginExit (venue cooldown), completeExit (cooldown-eligible shares only,
// two legs with min-out bounds), bridgeBack (immutable HyperEVM recipient),
// and the same trust model as the PT executors (ops can never redirect funds).
//
// Run: forge test --match-path 'test/forge/SUSD3.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {SUSD3Strategy} from "../../contracts/SUSD3Strategy.sol";
import {FrontierBase} from "../../contracts/FrontierBase.sol";
import {BaseStrategy} from "../../contracts/BaseStrategy.sol";
import {SUSD3Executor} from "../../contracts/ethi/SUSD3Executor.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCctp} from "../../contracts/mocks/MockCctp.sol";
import {MockUSD3} from "../../contracts/mocks/MockUSD3.sol";
import {MockSUSD3} from "../../contracts/mocks/MockSUSD3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SUSD3StrategyTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    MockCctp cctp;
    SUSD3Strategy strat;

    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");
    address executor = makeAddr("ethExecutor");

    bytes4 E_NOTCLEARED = bytes4(keccak256("Frontier__NotCleared()"));
    bytes4 E_CAPEXCEEDED = bytes4(keccak256("Frontier__CapExceeded()"));
    bytes4 E_CAPUNVERIFIABLE = bytes4(keccak256("Frontier__CapUnverifiable()"));

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        cctp = new MockCctp(address(usdc));
        strat = new SUSD3Strategy(address(usdc), address(this), address(cctp), address(cctp), executor);

        strat.setVault(address(vault));
        strat.setKeeper(keeper);
        vault.addStrategy(address(strat));

        // book $2,000 so the strategy's $200 idle is a 10% share (inside 15%)
        usdc.mint(address(this), 5_000e18);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(2_000e18);
        usdc.transfer(address(strat), 200e18);
    }

    /*//////////////////// the gate: fail-closed + cap ////////////////////*/

    function test_supply_gate_default_locked() public {
        vm.prank(keeper);
        vm.expectRevert(E_NOTCLEARED);
        strat.deployToEth(100e18, 0);
    }

    function test_deploy_burns_cctp_with_exact_args() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(100e18, 1e6);
        (uint256 amount, uint32 domain, bytes32 recipient, address burnToken, bytes32 destCaller, uint256 maxFee,) = cctp.lastBurn();
        assertEq(amount, 100e18);
        assertEq(domain, 0); // Ethereum
        assertEq(recipient, bytes32(uint256(uint160(executor))));
        assertEq(burnToken, address(usdc));
        // AUDIT F-A (deploy leg): permitted completer = the SAME immutable
        // executor used as the mint recipient, so only its `relayArrival` can
        // complete the arrival (ops, or the 2/3 Safe as recovery). Ruling:
        // docs/F_A_DEPLOY_LEG_RULING_2026-10-17.md §2/§3.1/§4 — never ship this
        // pin without `relayArrival` in the executor bytecode.
        assertEq(destCaller, bytes32(uint256(uint160(executor))), "F-A: deploy leg pinned to the executor");
        assertEq(maxFee, 1e6);
        assertEq(strat.inFlight6(), 100e18);
        assertEq(strat.totalAssets(), 200e18); // idle -> in-flight, book unchanged
    }

    /// AUDIT F-A (deploy leg): after the pin, ONLY the executor can complete the
    /// outbound arrival — a stranger's relay is refused by the transmitter. The
    /// pinned completer is the executor's `relayArrival`; the book still heals
    /// from the balance (balance-driven `ackArrival`, then an attested re-sync).
    function test_deploy_leg_arrival_only_via_the_pinned_executor() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(100e18, 1e6);
        assertEq(strat.inFlight6(), 100e18, "in flight before arrival");
        cctp.setInbound(100e18, executor); // the message THIS burn produced

        vm.prank(stranger); // the free-option relay of the old (blank) leg
        vm.expectRevert("mockcctp: destinationCaller: caller not allowed");
        cctp.receiveMessage(hex"", hex"");

        vm.prank(executor); // = exec.relayArrival(), the only legal completer
        assertTrue(cctp.receiveMessage(hex"", hex""));
        assertEq(usdc.balanceOf(executor), 100e18, "cash landed at OUR executor");
        assertEq(usdc.balanceOf(stranger), 0, "the relayer gained nothing");

        vm.prank(keeper);
        strat.ackArrival(100e18); // balance-driven: no relay needed
        assertEq(strat.inFlight6(), 0, "in-flight cleared");
        assertEq(strat.outstandingFace6(), 100e18, "face still out at the venue");

        vm.prank(keeper);
        strat.syncEthValue(100e18);
        assertEq(strat.ethValue6(), 100e18, "attested value == real executor holdings");
        assertEq(strat.totalAssets(), 200e18, "no double count");
    }

    function test_cap_blocks_over_15pct() public {
        strat.setVenueCleared(true);
        usdc.transfer(address(strat), 200e18); // idle 400 of 2,000 = 20%
        vm.prank(keeper);
        vm.expectRevert(E_CAPEXCEEDED);
        strat.deployToEth(100e18, 0);
    }

    function test_cap_unverifiable_without_vault_wiring() public {
        SUSD3Strategy orphan = new SUSD3Strategy(address(usdc), address(this), address(cctp), address(cctp), executor);
        usdc.mint(address(orphan), 100e18);
        orphan.setVenueCleared(true); // gate clear — the CAP must fail
        vm.expectRevert(E_CAPUNVERIFIABLE);
        orphan.deployToEth(100e18, 0);
    }

    function test_deployment_guards() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        vm.expectRevert(SUSD3Strategy.SUSD3__BelowMinBridge.selector);
        strat.deployToEth(4e6, 0); // below $5 min bridge (6dp-scale units)
        vm.prank(keeper);
        vm.expectRevert(SUSD3Strategy.SUSD3__MaxFeeTooHigh.selector);
        strat.deployToEth(100e18, 2e6 + 1); // maxFee cap $2
        vm.prank(keeper);
        vm.expectRevert(SUSD3Strategy.SUSD3__ExceedsIdle.selector);
        strat.deployToEth(300e18, 0); // more than idle
        vm.prank(stranger);
        vm.expectRevert(SUSD3Strategy.SUSD3__NotKeeper.selector);
        strat.deployToEth(100e18, 0); // stranger cannot deploy
    }

    function test_cap_ceiling_immutable_even_for_owner() public {
        vm.expectRevert(FrontierBase.Frontier__BpsTooHigh.selector);
        strat.setMaxShareBps(1501);
        strat.setMaxShareBps(1000); // tighten to 10%
        strat.setVenueCleared(true);
        vm.prank(keeper); // 200 of 2,000 = 10% > the new cap... equal — passes? 1000 == 1000 → allowed (≤)
        strat.deployToEth(100e18, 0);
    }

    /*//////////////////// attestation surface: bounded upside, honest downside ////////////////////*/

    function _deploy() internal {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(200e18, 0);
        vm.prank(keeper);
        strat.ackArrival(200e18); // arrived on mainnet (attested by the keeper)
    }

    function test_sync_value_bounded_upside() public {
        _deploy();
        // arrived face 200; cap = 200 × 1.20 = 240
        vm.prank(keeper);
        strat.syncEthValue(240e18); // exactly at the bound
        assertEq(strat.ethValue6(), 240e18);
        vm.prank(keeper);
        vm.expectRevert(SUSD3Strategy.SUSD3__ValueAboveBound.selector);
        strat.syncEthValue(240e18 + 1); // one wei past the clamp
    }

    function test_loss_is_honest_downward_sync() public {
        _deploy();
        vm.prank(keeper);
        strat.syncEthValue(200e18);
        // the junior tranche loses 10% — the keeper reports the true mark
        vm.expectEmit(true, true, true, true, address(strat));
        emit SUSD3Strategy.LossObserved(200e18, 180e18);
        vm.prank(keeper);
        strat.syncEthValue(180e18); // BELOW the old mark — no clamp on the downside
        assertEq(strat.ethValue6(), 180e18);
        assertEq(strat.totalAssets(), 180e18); // the book follows the mark DOWN
        // recovery yields sync back up (within the bound)
        vm.prank(keeper);
        strat.syncEthValue(190e18);
        assertEq(strat.ethValue6(), 190e18);
    }

    function test_ack_and_inbound_never_double_count() public {
        _deploy();
        vm.prank(keeper);
        strat.syncEthValue(200e18); // book back to 200 after the ack dip
        // return leg: the executor ships 100 back; the keeper completes inbound
        cctp.setInboundAny(100e18, address(strat));
        uint256 got = strat.completeInbound(hex"00", hex"00");
        assertEq(got, 100e18);
        assertEq(strat.retFace6(), 100e18);
        assertEq(strat.ethValue6(), 100e18); // the returned face dropped from the attested value
        assertEq(strat.totalAssets(), 200e18); // idle 100 + inFlight 0 + value 100 — no double-count
        // a return-false transmitter cannot be completed
        cctp.setInboundAny(50e18, address(strat));
        cctp.setInboundFail(true, false);
        vm.expectRevert(SUSD3Strategy.SUSD3__ReceiveFailed.selector);
        strat.completeInbound(hex"00", hex"00");
        cctp.setInboundFail(false, false);
    }

    /*//////////////////// recall: async by design, never gated ////////////////////*/

    function test_recall_pays_idle_and_records_shortfall() public {
        _deploy(); // 200 idle → all in flight on mainnet
        vm.prank(keeper);
        strat.syncEthValue(200e18);
        vm.prank(address(vault));
        strat.recall(50e18); // vault wants 50; idle is 0
        assertEq(strat.pendingRecall6(), 50e18);
        // the unwind lands back home
        cctp.setInboundAny(50e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        vm.prank(keeper);
        strat.pushIdle(50e18); // keeper pays the pending recall
        assertEq(strat.pendingRecall6(), 0);
        assertEq(usdc.balanceOf(address(vault)), 2_000e18 + 50e18);
    }

    function test_relock_never_traps_money() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(100e18, 0);
        strat.setVenueCleared(false); // incident re-lock
        // money-out is NEVER gated: inbound completion + push to vault still work
        cctp.setInboundAny(100e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        vm.prank(keeper);
        strat.pushIdle(100e18);
        assertEq(usdc.balanceOf(address(vault)), 2_100e18);
    }

    function test_recall_zero_and_stranger() public {
        _deploy();
        vm.prank(stranger);
        vm.expectRevert(SUSD3Strategy.SUSD3__NotVault.selector);
        strat.recall(1e18);
        vm.prank(address(vault));
        strat.recall(0); // silent noop
        assertEq(strat.pendingRecall6(), 0);
    }

    /*//////////////////// admin ////////////////////*/

    function test_setParams_bounds() public {
        vm.expectRevert(bytes("SUSD3: headroom too high"));
        strat.setParams(3001, 5e6);
        vm.expectRevert(bytes("SUSD3: min too low"));
        strat.setParams(2000, 1e6);
        strat.setParams(1000, 2e6);
        assertEq(strat.headroomBps(), 1000);
    }

    function test_zero_addr_constructor() public {
        vm.expectRevert(SUSD3Strategy.SUSD3__ZeroAddr.selector);
        new SUSD3Strategy(address(usdc), address(this), address(0), address(cctp), executor);
    }

    function test_owner_path_and_views() public {
        // the OWNER can also drive the keeper surface (onlyKeeperOrOwner)
        strat.setVenueCleared(true);
        strat.deployToEth(100e18, 0); // owner == this
        assertEq(strat.outstandingFace6(), 100e18); // sent - returned
        assertEq(strat.name(), "SUSD3"); // the feed/monitor label
        // a second ship + return flips outstanding to the residual
        cctp.setInboundAny(40e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        assertEq(strat.outstandingFace6(), 60e18);
    }

    /*//////////////////// audit remediation pins (F-1, F-6) ////////////////////*/

    /// AUDIT F-1. The LIVE phantom: entry was refused by the venue, so the
    /// outbound was never `ackArrival`ed; on the way home `completeInbound`
    /// booked the cash but left `inFlight6` set, so the sleeve reported 2x its
    /// real value. `completeInbound` must consume the in-flight slice.
    function test_phantom_never_double_counts() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(200e18, 0); // sent = 200, inFlight = 200 (NOT acked)
        assertEq(strat.inFlight6(), 200e18);
        assertEq(strat.totalAssets(), 200e18); // idle 0 + inFlight 200 + value 0

        cctp.setInboundAny(200e18, address(strat)); // the full return arrives
        uint256 got = strat.completeInbound(hex"00", hex"00");
        assertEq(got, 200e18);
        assertEq(strat.inFlight6(), 0, "F-1: inbound must clear the in-flight slice");
        assertEq(strat.totalAssets(), 200e18, "F-1: reported assets must equal real backing (was 400 = 2x)");
        assertLe(strat.totalAssets(), usdc.balanceOf(address(strat)), "F-1: totalAssets <= real idle");
        // and a sync of the now-empty mainnet remainder must not revert
        vm.prank(keeper);
        strat.syncEthValue(0);
        assertLe(strat.totalAssets(), usdc.balanceOf(address(strat)));
    }

    /// AUDIT F-6 + design-note §5.3. `retFace > sentFace` (an excess inbound
    /// gift/donation) must never underflow or revert; the excess is now booked
    /// as REALIZED YIELD (it is real money — crediting it is correct), and only
    /// the outstanding principal retires deployed face.
    function test_excess_inbound_is_a_benign_gift() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(100e18, 0); // sent = 100
        // a 150 mint lands (100 back + 50 gift)
        cctp.setInboundAny(150e18, address(strat));
        uint256 got = strat.completeInbound(hex"00", hex"00");
        assertEq(got, 150e18);
        assertEq(strat.retFace6(), 100e18, "F-6: retFace books PRINCIPAL only");
        assertEq(strat.profitRealized6(), 50e18, "the +50 excess is REALIZED YIELD");
        assertEq(strat.outstandingFace6(), 0, "F-6: outstanding floors to 0, no underflow");
        assertEq(strat.inFlight6(), 0, "F-6: in-flight floors to 0, no underflow");
        assertEq(strat.harvestableProfit6(), 50e18, "yield waits for harvest()");
        assertEq(strat.idlePrincipal6(), 200e18, "idle 250 - 50 profit");
        assertEq(strat.totalAssets(), 250e18); // 100 idle kept + 150 arrived — all real
        // the sync cap floors to 0: any positive mark is refused, 0 is fine
        vm.prank(keeper);
        strat.syncEthValue(0);
    }

    /*//////////////////// audit remediation pin (F-1 belt-and-braces) ////////////////////*/

    /// AUDIT F-1 belt-and-braces: `syncEthValue` must fail loudly if in-flight
    /// ever exceeds what is still out (sent - returned), instead of silently
    /// flooring `arrivedFace` to 0 and masking a phantom. A probe (test-only)
    /// forces the inconsistent state, because `completeInbound` now consumes
    /// in-flight so no public path can reach it.
    function test_sync_eth_value_reverts_on_accounting_invariant() public {
        SUSD3Probe probe = new SUSD3Probe(address(usdc), address(this), address(cctp), address(cctp), executor);
        probe.poke(100e18, 0, 150e18); // inFlight 150 > outstanding 100
        vm.expectRevert(SUSD3Strategy.SUSD3__AccountingInvariant.selector);
        probe.syncEthValue(0);
    }

    /*//////////// audit remediation pins (F-3/F-4): focused-allocate ////////////*/

    /// The runner's focused-allocate contract relies on three vault facts:
    ///  (1) strategies are enumerable on-chain via `strategyList(i)`;
    ///  (2) `setStrategyActive` REVERTS on an unregistered address (so a loop
    ///      must guard each call — live `0x1C77…` sorts first and killed it);
    ///  (3) the active flag round-trips, so the runner can snapshot/restore.
    function test_focused_allocate_snapshot_restore_and_unregistered_guard() public {
        // a second registered + active strategy
        SUSD3Strategy other = new SUSD3Strategy(address(usdc), address(this), address(cctp), address(cctp), executor);
        other.setVault(address(vault));
        vault.addStrategy(address(other));
        assertTrue(vault.strategyActive(address(other)));

        // on-chain enumeration: [strat, other], then the probe stops (OOB revert)
        assertEq(vault.strategyList(0), address(strat));
        assertEq(vault.strategyList(1), address(other));
        vm.expectRevert();
        vault.strategyList(2);

        // the live trap: an unregistered address must revert, never be toggled
        address unreg = address(0x1C770315D159b52a7fA892878B1F33B1A61618Bf);
        assertFalse(vault.strategies(unreg));
        vm.expectRevert(bytes("ProYieldVault: not a strategy"));
        vault.setStrategyActive(unreg, true);

        // snapshot → deactivate → allocate → restore to the SNAPSHOT
        bool snapshot = vault.strategyActive(address(other));
        assertTrue(snapshot);
        vault.setStrategyActive(address(other), false);
        vault.allocate();
        vault.setStrategyActive(address(other), snapshot); // restore, not blind `true`
        assertTrue(vault.strategyActive(address(other)));
    }

    /*//////////////////// audit remediation pin (F-5) ////////////////////*/

    /// AUDIT F-5. Returned PRINCIPAL (pushIdle) must be redeployable by the next
    /// `allocate()` WITHOUT raising the vault's totalAssets — the old path
    /// stranded it as an uncredited arrival and the only owner lever
    /// (`creditYield`) double-counted it (repro: 1,900 vs 1,000 real).
    function test_principal_return_is_redeployable_no_double_count() public {
        // book $2,000; only sUSD3 is registered+active → allocate ships 90% ($1,800)
        vault.allocate();
        uint256 deployed = usdc.balanceOf(address(strat)) - 200e18;
        assertEq(deployed, 1_800e18);
        assertEq(vault.totalAssets(), 2_000e18); // still on our books
        assertEq(vault.uncreditedArrivals(), 0);

        // the sleeve returns the principal
        vm.prank(keeper);
        strat.pushIdle(deployed);
        assertEq(usdc.balanceOf(address(vault)), 2_000e18); // cash is home
        assertEq(vault.totalAssets(), 2_000e18, "F-5: principal return must NOT raise totalAssets");
        assertEq(vault.uncreditedArrivals(), 0, "F-5: returned principal must be booked, not a phantom arrival");

        // the next allocate redeploys it (before the fix this shipped 0)
        vault.allocate();
        assertEq(vault.totalAssets(), 2_000e18);
        assertEq(usdc.balanceOf(address(strat)) - 200e18, 1_800e18, "F-5: returned principal redeployed");
        // and the book never exceeds real backing
        assertLe(vault.totalAssets(), usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)), "F-5: totalAssets <= real backing");
    }

    /// AUDIT F-5 (review round 2). The known-good path above relies on a vault
    /// that implements `onStrategyReturn`. The LIVE vault (non-upgradeable
    /// 0x8954…D1C1) does NOT, so an unconditional hook call would revert, roll
    /// the transfer back and brick `pushIdle` — the regression the reviewer
    /// caught. pin the BACKWARD-SAFE fallback: the principal still returns, the
    /// hook is best-effort, and the miss is surfaced as an event.
    function test_pushIdle_backward_safe_on_legacy_vault() public {
        LegacyVaultNoHook legacy = new LegacyVaultNoHook();
        strat.setVault(address(legacy)); // owner == this
        usdc.transfer(address(strat), 100e18); // idle USDC to return

        vm.expectEmit(true, true, true, true, address(strat));
        emit SUSD3Strategy.ReturnHookUnavailable(address(legacy), 100e18);
        vm.prank(keeper);
        strat.pushIdle(100e18);

        assertEq(usdc.balanceOf(address(legacy)), 100e18, "F-5: principal must land even when the hook is absent");
    }
}

/// A legacy vault: a real contract (code present) that does NOT implement
/// `onStrategyReturn` — mirrors the live non-upgradeable vault so the
/// backward-safe fallback can be pinned.
contract LegacyVaultNoHook {
    // holds whatever it is transferred; has no matching function and no fallback
}

/// Test-only probe: exposes the parent's face counters so the belt-and-braces
/// `syncEthValue` invariant can be exercised (no public path can violate it).
contract SUSD3Probe is SUSD3Strategy {
    constructor(address u, address o, address tm, address mt, address ex) SUSD3Strategy(u, o, tm, mt, ex) {}

    function poke(uint256 _sent, uint256 _ret, uint256 _inFlight) external {
        sentFace6 = _sent;
        retFace6 = _ret;
        inFlight6 = _inFlight;
    }
}

/// A minimal hook-bearing vault recorder (F-5 happy path).
contract SUSD3HookVault {
    uint256 public booked;

    function onStrategyReturn(uint256 amount) external {
        booked += amount;
    }
}

/*/////////////// ATTRIBUTION: yield/principal split (design note §5/§9) ///////////////*/

// SUSD3 sleeve — yield/principal attribution on a REAL vault.
//
// Pins the design note §9 list plus INV-1 (`_totalAssets <= realBacking`) at
// every step of the round trip. The Frontier ≤15% cap means the sleeve must sit
// at a minority share of the book, so the vault carries 5 filler strategies and
// `allocate()` splits 1,800/6 = 300 = 15.0% to the sUSD3 sleeve.
//
//   vault (HyperEVM) --allocate--> SUSD3Strategy --CCTP--> Ethereum executor
//     executor unwinds --> completeInbound splits principal vs yield -->
//     pushIdle(principal) -> vault.onStrategyReturn (booked, _totalAssets flat)
//     harvest()           -> vault.harvest (fee taken, _totalAssets += net)
contract SUSD3AttributionTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    MockCctp cctp;
    SUSD3Strategy strat;
    address[] fillers;

    address keeper = makeAddr("keeper");
    address executor = makeAddr("ethExecutor");

    uint256 constant D = 2_000e18; // deposit
    uint256 constant P = 300e18; // allocated principal to the sleeve (15% of D)
    uint256 constant DLT = 60e18; // realized yield on the round trip (+20%, at the headroom cap)
    uint256 constant FEE_BPS = 1000; // vault performanceFee default

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        cctp = new MockCctp(address(usdc));
        strat = new SUSD3Strategy(address(usdc), address(this), address(cctp), address(cctp), executor);

        strat.setVault(address(vault));
        strat.setKeeper(keeper);
        strat.setVenueCleared(true); // DD gate open for the supply path
        vault.addStrategy(address(strat));
        // 5 fillers so allocate() splits to a ≤15% sleeve slice (1800/6 = 300).
        for (uint256 i = 0; i < 5; i++) {
            address f = address(new BaseStrategy(address(usdc), address(this), "fill"));
            vault.addStrategy(f);
            fillers.push(f);
        }

        usdc.mint(address(this), D);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(D);
        assertEq(vault.totalAssets(), D, "booked");
    }

    // --------------------------------------------------------------- helpers

    /// allocate (ships 15% to the sleeve) + keeper burns to the executor.
    function _ship() internal {
        vault.allocate();
        assertEq(usdc.balanceOf(address(strat)), P, "sleeve slice");
        vm.prank(keeper);
        strat.deployToEth(P, 0);
        assertEq(usdc.balanceOf(address(strat)), 0, "all principal shipped");
        assertEq(strat.inFlight6(), P, "in flight at face");
    }

    /// Ack + attest the mainnet value at `P + delta`, then complete the return.
    function _windDown(uint256 delta) internal {
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncEthValue(P + delta);
        vm.stopPrank();
        cctp.setInboundAny(P + delta, address(strat));
        strat.completeInbound(hex"", hex"");
    }

    /// totalAssets <= realBacking, where realBacking sums EVERY sleeve the vault
    /// can reach (the design-note INV-1).
    function _realBacking() internal view returns (uint256) {
        uint256 sum = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)) + strat.inFlight6()
            + strat.ethValue6();
        for (uint256 i = 0; i < fillers.length; i++) {
            sum += usdc.balanceOf(fillers[i]);
        }
        return sum;
    }

    function _assertInv1(string memory tag) internal view {
        assertLe(vault.totalAssets(), _realBacking(), tag);
    }

    /// `_accountedBalance` has no getter; it equals balance − uncreditedArrivals.
    function _accounted() internal view returns (uint256) {
        return usdc.balanceOf(address(vault)) - vault.uncreditedArrivals();
    }

    // ---------------------------------------- 1. split at completeInbound

    function test_completeInbound_splits_principal_and_yield() public {
        _ship();
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncEthValue(P + DLT);
        vm.stopPrank();

        cctp.setInboundAny(P + DLT, address(strat));
        strat.completeInbound(hex"", hex"");

        assertEq(strat.profitRealized6(), DLT, "the excess is realized yield");
        assertEq(strat.retFace6(), P, "retFace books PRINCIPAL only");
        assertEq(strat.outstandingFace6(), 0, "principal fully retired");
        assertEq(strat.harvestableProfit6(), DLT, "yield ready to harvest");
        assertEq(strat.idlePrincipal6(), P, "principal = idle - harvestable");
    }

    // ---------------------------------------- 2. partial unwind defers yield

    function test_partial_unwind_defers_yield() public {
        _ship();
        uint256 before = usdc.balanceOf(address(strat)); // 0
        cctp.setInboundAny(P - 100e18, address(strat)); // return < outstanding
        strat.completeInbound(hex"", hex"");

        assertEq(strat.profitRealized6(), 0, "conservative: yield deferred, not invented");
        assertEq(strat.outstandingFace6(), 100e18, "rest still out");
        assertEq(usdc.balanceOf(address(strat)), before + (P - 100e18), "whole return treated as principal");
        assertEq(strat.idlePrincipal6(), usdc.balanceOf(address(strat)), "idle == principal");
    }

    // ---------------------------------------- 3. pushIdle yield-share guard

    function test_pushIdle_reverts_on_yield_share() public {
        _ship();
        _windDown(DLT);
        uint256 ip = strat.idlePrincipal6();
        assertEq(ip, P, "principal is idle - harvestable");

        vm.prank(keeper);
        vm.expectRevert(SUSD3Strategy.SUSD3__ExceedsPrincipalIdle.selector);
        strat.pushIdle(ip + 1);

        vm.prank(keeper);
        strat.pushIdle(ip); // the whole principal is fine
        assertEq(strat.harvestableProfit6(), DLT, "yield untouched by the principal door");
    }

    // ---------------------------------------- 4. recall capped at principal

    function test_recall_capped_at_principal() public {
        _ship();
        _windDown(DLT);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        strat.recall(P + DLT); // ask for everything

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, P, "recall pays principal ONLY");
        assertEq(strat.harvestableProfit6(), DLT, "the yield stays for harvest()");
        assertEq(strat.pendingRecall6(), DLT, "excess over principal is a phantom shortfall, not paid");
    }

    // ---------------------------------------- 5. harvest sweeps yield only

    function test_harvest_sweeps_yield_only() public {
        _ship();
        _windDown(DLT);
        // push principal home so the vault's harvest measures only the yield
        vm.prank(keeper);
        strat.pushIdle(P);

        uint256 taBefore = vault.totalAssets();
        uint256 acctBefore = _accounted();

        // keeper-called harvest settles only (never sweeps to the vault)
        vm.prank(keeper);
        strat.harvest();
        assertEq(strat.profitSwept6(), 0, "keeper harvest must NOT sweep");
        assertEq(strat.harvestableProfit6(), DLT);

        vault.harvest();

        uint256 fee = (DLT * FEE_BPS) / 10000;
        uint256 net = DLT - fee;
        assertEq(strat.profitSwept6(), DLT, "vault harvest swept exactly the yield");
        assertEq(strat.harvestableProfit6(), 0);
        assertEq(vault.totalAssets(), taBefore + net, "_totalAssets rose by net yield");
        assertEq(_accounted(), acctBefore + net, "_accountedBalance rose by net yield");
    }

    // ---------------------------------------- 6. end-to-end, no double count

    function test_no_double_count_end_to_end() public {
        _assertInv1("fresh deposit");
        _ship(); // NOTE: no ackArrival — exercises F-1
        _assertInv1("shipped");
        assertEq(strat.inFlight6(), P, "unacked in flight");

        cctp.setInboundAny(P + DLT, address(strat));
        strat.completeInbound(hex"", hex"");
        _assertInv1("returned");
        assertEq(strat.inFlight6(), 0, "F-1: completion consumed the in-flight slice");

        vm.prank(keeper);
        strat.pushIdle(P); // principal home
        _assertInv1("principal pushed");
        assertEq(vault.totalAssets(), D, "F-5: principal return must NOT raise _totalAssets");
        assertEq(vault.uncreditedArrivals(), 0, "F-5: principal booked, not a phantom arrival");

        vault.harvest();
        _assertInv1("harvested");

        uint256 fee = (DLT * FEE_BPS) / 10000;
        uint256 net = DLT - fee;
        assertEq(vault.totalAssets(), D + net, "booked == D + delta - fee");
        assertEq(strat.totalAssets(), 0, "sleeve emptied");
        assertEq(usdc.balanceOf(address(strat)), 0, "no cash stranded in the sleeve");
    }

    // ---------------------------------------- 7. INV-1 invariant (stepped)

    function test_invariant_totalAssets_le_realBacking() public {
        _assertInv1("s0");
        vault.allocate();
        _assertInv1("s1 allocate");
        vm.prank(keeper);
        strat.deployToEth(P, 0);
        _assertInv1("s2 deploy");
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncEthValue(P + DLT);
        vm.stopPrank();
        _assertInv1("s3 sync up (mark uncredited)");
        cctp.setInboundAny(P + DLT, address(strat));
        strat.completeInbound(hex"", hex"");
        _assertInv1("s4 return");
        vm.prank(keeper);
        strat.pushIdle(P);
        _assertInv1("s5 principal home");
        vault.harvest();
        _assertInv1("s6 yield harvested");
        assertLe(vault.totalAssets(), _realBacking(), "INV-1 holds after every op");
    }

    // ---------------------------------------- 8. donation/excess is yield

    function test_donation_mint_is_yield_not_principal() public {
        _ship();
        // a full principal return PLUS a 50 gift (donation) lands
        cctp.setInboundAny(P + 50e18, address(strat));
        strat.completeInbound(hex"", hex"");

        assertEq(strat.profitRealized6(), 50e18, "excess books as realized YIELD");
        assertEq(strat.idlePrincipal6(), P, "principal NOT inflated by the gift");
        assertEq(strat.harvestableProfit6(), 50e18);
    }

    // ---------------------------------------- 10. reconcileProfit bounds

    function test_reconcileProfit_bounds() public {
        _ship();
        _windDown(DLT);
        vm.prank(keeper);
        strat.pushIdle(P);
        vault.harvest(); // profitSwept6 = DLT
        uint256 swept = strat.profitSwept6();
        assertGt(swept, 0);

        vm.expectRevert(SUSD3Strategy.SUSD3__BelowSwept.selector);
        strat.reconcileProfit(swept - 1);

        strat.reconcileProfit(swept + 100e18); // >= swept is allowed
        assertEq(strat.profitRealized6(), swept + 100e18);

        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        strat.reconcileProfit(0);
    }

    // ---------------------------------------- F-5 hook happy path

    /// AUDIT F-5. `pushIdle` must notify the vault so returned PRINCIPAL is
    /// booked as redeployable accounted cash (never as a phantom arrival).
    function test_pushIdle_notifies_hook_vault() public {
        SUSD3HookVault hv = new SUSD3HookVault();
        strat.setVault(address(hv)); // owner == this
        usdc.mint(address(strat), 100e18); // idle principal to return
        vm.prank(keeper);
        strat.pushIdle(100e18);
        assertEq(hv.booked(), 100e18, "vault notified with the principal amount");
    }
}

/*/////////////////// R-1: deployToEth is PRINCIPAL-ONLY (review t_1ecae5f9) ///////////////////*/

// R-1 (High) pin — PORTED from the pre-deploy review's repro
// (`susd3_review_t_1ecae5f9_exploit.t.sol::test_reviewA_deployUnsweptYield_thenLoss`)
// and flipped to a PASS by the `deployToEth <= idlePrincipal6()` cap.
//
// The exploit it closed: after a leg unwinds with yield, `deployToEth` used to
// allow bridging the WHOLE balance (principal + un-swept yield), so
// `profitRealized6` counted yield whose cash had left the sleeve and would never
// return. A venue loss on that sliced-off cash then made the vault's `harvest()`
// sweep PRINCIPAL as yield: `vault.totalAssets()` inflated above true backing ->
// INV-1 breach (reviewer repro: booked 2040.5e18 vs real 1995.5e18). With the cap
// the un-swept yield can never leave, so only PRINCIPAL is ever at risk; a
// principal loss is then the vault's documented `reportLoss` path and INV-1 holds
// across it.
//
// The Frontier <=15% cap forces a minority sleeve slice, so this harness uses 8
// strategies (sUSD3 + 7 fillers) and `allocate()` splits 1,800/8 = 225 = 11.25%,
// leaving the yield-bearing re-deploy at 270/2,000 = 13.5% (<= 15%).
contract SUSD3R1CapTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    MockCctp cctp;
    SUSD3Strategy strat;
    address[] fillers;

    address keeper = makeAddr("keeper");
    address executor = makeAddr("ethExecutor");

    uint256 constant D = 2_000e18;
    uint256 constant P = 225e18; // sleeve slice (1800/8)
    uint256 constant DLT = 45e18; // realized yield (20% of P, at the headroom cap)

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        cctp = new MockCctp(address(usdc));
        strat = new SUSD3Strategy(address(usdc), address(this), address(cctp), address(cctp), executor);

        strat.setVault(address(vault));
        strat.setKeeper(keeper);
        strat.setVenueCleared(true); // DD gate open for the supply path
        vault.addStrategy(address(strat));
        for (uint256 i = 0; i < 7; i++) {
            address f = address(new BaseStrategy(address(usdc), address(this), "fill"));
            vault.addStrategy(f);
            fillers.push(f);
        }
        usdc.mint(address(this), D);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(D);
    }

    function _realBacking() internal view returns (uint256) {
        uint256 sum = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)) + strat.inFlight6()
            + strat.ethValue6();
        for (uint256 i = 0; i < fillers.length; i++) {
            sum += usdc.balanceOf(fillers[i]);
        }
        return sum;
    }

    function _assertInv1(string memory tag) internal view {
        assertLe(vault.totalAssets(), _realBacking(), tag);
    }

    function test_r1_deployToEth_principal_only_keeps_inv1_after_venue_loss() public {
        // allocate ships 11.25% (225) to the sleeve; keeper burns it to the
        // executor, acks, attests +20% (270), and the return lands.
        vault.allocate();
        assertEq(usdc.balanceOf(address(strat)), P, "sleeve slice");
        vm.prank(keeper);
        strat.deployToEth(P, 0);
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncEthValue(P + DLT);
        vm.stopPrank();
        cctp.setInboundAny(P + DLT, address(strat));
        strat.completeInbound(hex"", hex"");

        uint256 bal = usdc.balanceOf(address(strat)); // P + DLT = 270
        assertEq(strat.profitRealized6(), DLT, "45 realized yield booked");
        assertEq(strat.harvestableProfit6(), DLT, "45 un-swept yield sits in the sleeve");
        assertEq(strat.idlePrincipal6(), P, "225 principal is bridgeable");
        assertEq(bal, P + DLT, "balance = principal + un-swept yield");

        // (1) THE R-1 EXPLOIT ATTEMPT: bridge principal + un-swept yield.
        // Pre-fix this SUCCEEDS (no revert) and the test fails right here;
        // post-fix the cap rejects it. (The Frontier gate passes: 270/2000 =
        // 13.5% <= 15%.)
        vm.prank(keeper);
        vm.expectRevert(SUSD3Strategy.SUSD3__ExceedsPrincipalIdle.selector);
        strat.deployToEth(bal, 0);

        // (2) principal-only re-deploy is still permitted; the yield never leaves.
        vm.prank(keeper);
        strat.deployToEth(P, 0);
        assertEq(usdc.balanceOf(address(strat)), DLT, "R-1: only the un-swept yield stays idle");
        assertEq(strat.harvestableProfit6(), DLT, "yield still waits for harvest()");

        // (3) the venue LOSES part of the re-deployed principal (mirrors the
        // repro's 45 loss on the redeployed slice): only P - DLT comes home.
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncEthValue(P);
        vm.stopPrank();
        cctp.setInboundAny(P - DLT, address(strat));
        strat.completeInbound(hex"", hex"");
        vm.prank(keeper);
        strat.syncEthValue(0);
        assertEq(strat.profitRealized6(), DLT, "loss books NO new profit (stays 45)");
        assertEq(strat.harvestableProfit6(), DLT, "the pre-existing yield is unchanged");
        assertEq(strat.idlePrincipal6(), P - DLT, "principal shrank by the venue loss");

        // (4) the owner recognises the venue loss (the vault's documented path),
        // then the yield is harvested: booked must never exceed real backing.
        vault.reportLoss(DLT);
        _assertInv1("after venue loss reported");
        vault.harvest();
        _assertInv1("after vault harvest");
        assertEq(vault.totalAssets(), _realBacking(), "INV-1 exact: booked == real backing");
    }
}

/*/////////////////////////// EXECUTOR (Ethereum side) ////////////////////////////*/

contract SUSD3ExecutorTest is Test {
    MockUSDC usdc;
    MockUSD3 usd3;
    MockSUSD3 susd3;
    MockCctp cctp;
    SUSD3Executor exec;

    address ops = makeAddr("opsKey");
    address stranger = makeAddr("stranger");
    address owner_ = makeAddr("safeOwner");
    address strategyOnHyperEvm = makeAddr("strategyHypeEVM");
    address safe = makeAddr("safe");

    function setUp() public {
        usdc = new MockUSDC();
        usd3 = new MockUSD3(usdc);
        susd3 = new MockSUSD3(usd3);
        cctp = new MockCctp(address(usdc));
        exec = new SUSD3Executor(address(usdc), address(usd3), address(susd3), address(cctp), strategyOnHyperEvm, ops, safe);
        usdc.mint(address(this), 1_000e18);
        usdc.transfer(address(exec), 1_000e18); // funding that "arrived via CCTP"
        // AUDIT F-B: the return destination must be owner-confirmed before any
        // burn; these tests run on an armed pair.
        vm.prank(safe);
        exec.confirmStrategyReturn(strategyOnHyperEvm);
    }

    function test_constructor_shape_guard() public {
        // the junior vault's underlying MUST be the senior vault
        MockSUSD3 wrong = new MockSUSD3(usd3); // fine — but pair it with a DIFFERENT usd3:
        MockUSD3 otherUsd3 = new MockUSD3(usdc);
        vm.expectRevert(SUSD3Executor.SUSD3E__ZeroAddr.selector);
        new SUSD3Executor(address(usdc), address(otherUsd3), address(wrong), address(cctp), strategyOnHyperEvm, ops, safe);
    }

    function test_enter_wraps_two_layers() public {
        vm.prank(ops);
        (uint256 usd3Out, uint256 susd3Out) = exec.enter(100e18, 90e18, 80e18);
        assertEq(usd3Out, 100e18); // 1:1 at genesis
        assertEq(susd3Out, 100e18); // 1:1 at genesis
        assertEq(exec.usd3Balance(), 0); // fully staked down
        assertEq(exec.susd3Balance(), 100e18);
        assertEq(exec.usdcBalance(), 900e18);
        assertEq(exec.positionValueUsd6(), 1_000e18); // idle 900 + mark 100
        // slippage bounds are enforced per leg
        vm.prank(ops);
        vm.expectRevert(SUSD3Executor.SUSD3E__Slippage.selector);
        exec.enter(100e18, 101e18, 0); // impossible minUsd3Out
        vm.prank(ops);
        vm.expectRevert(SUSD3Executor.SUSD3E__BadAmount.selector);
        exec.enter(0, 0, 0);
        vm.prank(stranger);
        vm.expectRevert(SUSD3Executor.SUSD3E__NotOps.selector);
        exec.enter(100e18, 0, 0);
    }

    function test_full_lifecycle_with_the_30d_door() public {
        // in
        vm.startPrank(ops);
        exec.enter(1_000e18, 900e18, 800e18);
        // the junior share is levered: +10% junior yield, paid in REAL USD3
        // tokens backed by real USDC at the senior layer (tranche-split income)
        susd3.injectRealJuniorYieldUsd3(100e18);
        // out: the exit door — start the venue's cooldown on everything
        exec.beginExit(exec.susd3Balance());
        vm.stopPrank();
        (uint256 cdEnd, , uint256 cdShares) = exec.cooldownStatus();
        assertEq(cdEnd, block.timestamp + 30 days);
        assertEq(cdShares, 1_000e18);
        assertEq(exec.exitableShares(), 0); // door locked during cooldown

        // attempting an early exit finds nothing eligible
        vm.prank(ops);
        vm.expectRevert(SUSD3Executor.SUSD3E__BadAmount.selector);
        exec.completeExit(1_000e18, 1, 1);

        // 30 days later the door opens. The junior mark grew +10% (levered
        // share) in REAL USD3 tokens backed by real USDC — the exit pays it.
        vm.warp(block.timestamp + 30 days + 1);
        assertEq(exec.exitableShares(), 1_000e18);
        vm.prank(ops);
        (uint256 usd3Out, uint256 usdcOut) = exec.completeExit(1_000e18, 900e18, 900e18);
        assertEq(usd3Out, 1_100e18); // the levered junior share, in real USD3
        assertEq(usdcOut, 1_100e18); // real backing all the way to USDC
        assertEq(exec.susd3Balance(), 0);
        assertEq(exec.usdcBalance(), 1_100e18);
        // back home via CCTP to the IMMUTABLE strategy address
        vm.prank(ops);
        exec.bridgeBack(1_100e18, 0);
        (, uint32 domain, bytes32 recipient,, bytes32 destCaller,,) = cctp.lastBurn();
        assertEq(domain, 19); // HyperEVM
        assertEq(recipient, bytes32(uint256(uint160(strategyOnHyperEvm))));
        // AUDIT F-A: only the strategy may complete this arrival.
        assertEq(destCaller, bytes32(uint256(uint160(strategyOnHyperEvm))), "F-A: return leg pinned");
        assertEq(exec.usdcBalance(), 0);
    }

    function test_exit_partial_and_cancel() public {
        vm.startPrank(ops);
        exec.enter(500e18, 0, 0);
        exec.beginExit(200e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days + 1);
        assertEq(exec.exitableShares(), 200e18);
        vm.startPrank(ops);
        exec.completeExit(100e18, 90e18, 90e18); // half of the cooldown tranche
        assertEq(exec.exitableShares(), 100e18); // the rest stays eligible
        // a plan change: cancel what remains
        exec.cancelExit();
        vm.stopPrank();
        assertEq(exec.exitableShares(), 0);
        (, , uint256 remaining) = exec.cooldownStatus();
        assertEq(remaining, 0);
    }

    function test_usd3_liquidity_cap_limits_the_usdc_leg() public {
        vm.startPrank(ops);
        exec.enter(400e18, 0, 0);
        exec.beginExit(400e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days + 1);
        // drain USD3's USDC liquidity (the senior's cash buffer is gone)
        usd3.drainUsdc(usdc.balanceOf(address(usd3)), address(0x1234));
        // completeExit still works: the USD3→USDC leg pays what it can (0)
        vm.prank(ops);
        (uint256 usd3Out, uint256 usdcOut) = exec.completeExit(400e18, 300e18, 0);
        assertEq(usd3Out, 400e18); // shares still came down
        assertEq(usdcOut, 0); // no USDC liquidity — partial by design
        assertEq(exec.usd3Balance(), 400e18); // the USD3 waits for liquidity
        assertEq(exec.exitableShares(), 0); // the cooldown book is spent
        // liquidity returns (amortizing receivables refill the buffer)
        usdc.mint(address(usd3), 400e18);
        // the senior leg unwinds on its own ops path — no cooldown needed
        vm.prank(ops);
        uint256 usdcOut2 = exec.unwindUsd3(300e18);
        assertEq(usdcOut2, 400e18);
        assertEq(exec.usd3Balance(), 0);
    }

    function test_bridgeback_and_trust_model() public {
        vm.prank(stranger);
        vm.expectRevert(SUSD3Executor.SUSD3E__NotOps.selector);
        exec.bridgeBack(1e18, 0);
        vm.prank(ops);
        exec.bridgeBack(10e18, 0);
        (, , bytes32 recipient,, bytes32 destCaller,,) = cctp.lastBurn();
        assertEq(recipient, bytes32(uint256(uint160(strategyOnHyperEvm))));
        // AUDIT F-A: destinationCaller pinned to the strategy (was bytes32(0)).
        assertEq(destCaller, bytes32(uint256(uint160(strategyOnHyperEvm))), "F-A: return leg pinned");
        vm.prank(ops);
        vm.expectRevert(SUSD3Executor.SUSD3E__BadAmount.selector);
        exec.bridgeBack(1_000_000e18, 0); // more than the balance
        // config is owner-only; the return destination locks after use
        vm.prank(stranger);
        vm.expectRevert();
        exec.setOps(stranger);
        vm.prank(safe);
        vm.expectRevert(SUSD3Executor.SUSD3E__AlreadyConfirmed.selector);
        exec.confirmStrategyReturn(stranger); // activity already happened (bridgeBack)
        // rescue hatch is owner-only and works
        vm.prank(stranger);
        vm.expectRevert();
        exec.ownerRescue(address(usdc), stranger, 1e18);
        vm.prank(safe);
        exec.ownerRescue(address(usdc), safe, 5e18);
        assertEq(usdc.balanceOf(safe), 5e18);
    }

    /// AUDIT F-A regression (return leg): the pin is ENFORCED by the CCTP
    /// transmitter, not merely recorded. Before the pin, a public
    /// `(message, attestation)` let anyone complete our arrival first and consume
    /// the single-use nonce — after which the strategy's `completeInbound` (the
    /// only writer of `retFace6`) could never book it, permanently.
    function test_return_leg_pin_is_enforced_by_the_transmitter() public {
        vm.prank(ops);
        exec.bridgeBack(10e18, 0); // pins destinationCaller = strategyOnHyperEvm
        cctp.setInbound(10e18, strategyOnHyperEvm);

        vm.prank(stranger);
        vm.expectRevert("mockcctp: destinationCaller: caller not allowed");
        cctp.receiveMessage(hex"", hex"");

        vm.prank(strategyOnHyperEvm); // the pinned caller may complete it — once
        assertTrue(cctp.receiveMessage(hex"", hex""));
        assertEq(usdc.balanceOf(strategyOnHyperEvm), 10e18);
        vm.prank(strategyOnHyperEvm);
        vm.expectRevert("mockcctp: message already used");
        cctp.receiveMessage(hex"", hex"");
    }

    /// AUDIT F-A (deploy leg): the relay entry point on the sUSD3 executor. The
    /// strategy's outbound burn pins `destinationCaller = this executor`, so the
    /// arrival can only be completed here — by `ops` (keeper) or `owner` (Safe).
    function test_relayArrival_entry_point_and_recovery_path() public {
        cctp.setInboundPinnedFor(250e18, address(exec), address(exec));
        vm.prank(stranger);
        vm.expectRevert(SUSD3Executor.SUSD3E__NotOpsOrOwner.selector);
        exec.relayArrival(hex"", hex"");

        vm.prank(ops);
        uint256 got = exec.relayArrival(hex"", hex"");
        assertEq(got, 250e18, "relayed amount reported");
        assertEq(exec.usdcBalance(), 1_250e18, "mint landed in the executor");

        vm.prank(ops);
        vm.expectRevert("mockcctp: message already used");
        exec.relayArrival(hex"", hex"");

        cctp.setInboundPinnedFor(100e18, address(exec), address(exec));
        vm.prank(safe);
        exec.relayArrival(hex"", hex""); // the 2/3 Safe recovery path
        assertEq(exec.usdcBalance(), 1_350e18, "recovery relay from the Safe works");

        cctp.setInboundPinnedFor(50e18, address(stranger), address(exec));
        vm.prank(ops);
        vm.expectRevert(SUSD3Executor.SUSD3E__NothingMinted.selector);
        exec.relayArrival(hex"", hex"");
    }

    function test_ops_rotation_and_bootstrap_confirm() public {
        // fresh executor: the one-time return correction WORKS before activity
        SUSD3Executor fresh = new SUSD3Executor(
            address(usdc), address(usd3), address(susd3), address(cctp), strategyOnHyperEvm, ops, safe
        );
        vm.prank(safe);
        vm.expectRevert(SUSD3Executor.SUSD3E__ZeroAddr.selector);
        fresh.setOps(address(0)); // zero-ops refused
        vm.prank(safe);
        fresh.setOps(stranger); // rotation works
        assertEq(fresh.ops(), stranger);
        vm.prank(safe);
        fresh.confirmStrategyReturn(makeAddr("realStrategy"));
        assertTrue(fresh.returnConfirmed());
        vm.prank(safe);
        vm.expectRevert(SUSD3Executor.SUSD3E__AlreadyConfirmed.selector);
        fresh.confirmStrategyReturn(stranger); // second confirm refused
        // zero-strategy confirm also refused
        SUSD3Executor fresh2 = new SUSD3Executor(
            address(usdc), address(usd3), address(susd3), address(cctp), strategyOnHyperEvm, ops, safe
        );
        vm.prank(safe);
        vm.expectRevert(SUSD3Executor.SUSD3E__ZeroAddr.selector);
        fresh2.confirmStrategyReturn(address(0));
    }
}
