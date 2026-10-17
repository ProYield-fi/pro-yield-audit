// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Aave v4 USDC Tokenization-Spoke sleeve (Frontier) — strategy + executor,
// full lifecycle.
//
// STRATEGY (HyperEVM, vault-facing): the PT/sUSD3-sleeve mechanics (CCTP burn
// to an immutable executor, bounded attestation, recall-with-shortfall) PLUS
// the Frontier gate (venueCleared fail-closed + ≤15% per-name cap) on the
// supply path, PLUS honest mark-downs (a lending deficit is recorded as-is and
// fires LossObserved).
//
// EXECUTOR (Ethereum mainnet): the venue door. `enter` = one ERC-4626 deposit
// into the USDC Tokenization Spoke; `exit` = a redeem CAPPED BY THE HUB'S
// AVAILABLE USDC and blocked by a spoke halt — the liquidity-conditional exit
// that AAVE_DD §5 names as the venue's defining risk. There is NO forced
// unwind: a partially-utilized position unwinds in slices and a fully-utilized
// one reverts `NoLiquidity` (explicit + retryable).
//
// Run: forge test --match-path 'test/forge/Aave.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {AaveStrategy} from "../../contracts/AaveStrategy.sol";
import {FrontierBase} from "../../contracts/FrontierBase.sol";
import {BaseStrategy} from "../../contracts/BaseStrategy.sol";
import {AaveExecutor} from "../../contracts/ethi/AaveExecutor.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCctp} from "../../contracts/mocks/MockCctp.sol";
import {MockAaveSpoke} from "../../contracts/mocks/MockAaveSpoke.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AaveStrategyTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    MockCctp cctp;
    AaveStrategy strat;

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
        strat = new AaveStrategy(address(usdc), address(this), address(cctp), address(cctp), executor);

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
        (uint256 amount, uint32 domain, bytes32 recipient, address burnToken, bytes32 destCaller, uint256 maxFee,) =
            cctp.lastBurn();
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

    function test_cap_blocks_over_15pct() public {
        strat.setVenueCleared(true);
        usdc.transfer(address(strat), 200e18); // idle 400 of 2,000 = 20%
        vm.prank(keeper);
        vm.expectRevert(E_CAPEXCEEDED);
        strat.deployToEth(100e18, 0);
    }

    function test_cap_unverifiable_without_vault_wiring() public {
        AaveStrategy orphan = new AaveStrategy(address(usdc), address(this), address(cctp), address(cctp), executor);
        usdc.mint(address(orphan), 100e18);
        orphan.setVenueCleared(true); // gate clear — the CAP must fail
        vm.expectRevert(E_CAPUNVERIFIABLE);
        orphan.deployToEth(100e18, 0);
    }

    function test_deployment_guards() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        vm.expectRevert(AaveStrategy.AAVE__BelowMinBridge.selector);
        strat.deployToEth(4e6, 0); // below the $5 min bridge
        vm.prank(keeper);
        vm.expectRevert(AaveStrategy.AAVE__MaxFeeTooHigh.selector);
        strat.deployToEth(100e18, 2e6 + 1); // maxFee cap $2
        vm.prank(keeper);
        vm.expectRevert(AaveStrategy.AAVE__ExceedsIdle.selector);
        strat.deployToEth(300e18, 0); // more than idle
        vm.prank(stranger);
        vm.expectRevert(AaveStrategy.AAVE__NotKeeper.selector);
        strat.deployToEth(100e18, 0); // stranger cannot deploy
    }

    function test_cap_ceiling_immutable_even_for_owner() public {
        vm.expectRevert(FrontierBase.Frontier__BpsTooHigh.selector);
        strat.setMaxShareBps(1501);
        strat.setMaxShareBps(1000); // tighten to 10%
        strat.setVenueCleared(true);
        vm.prank(keeper); // 200 of 2,000 = 10% == the cap → allowed (≤)
        strat.deployToEth(100e18, 0);
    }

    function test_inactive_blocks_supply() public {
        strat.setVenueCleared(true);
        strat.setActive(false);
        vm.prank(keeper);
        vm.expectRevert(AaveStrategy.AAVE__Inactive.selector);
        strat.deployToEth(100e18, 0);
    }

    /*//////////////////// attestation: bounded upside, honest downside ////////////////////*/

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
        vm.expectRevert(AaveStrategy.AAVE__ValueAboveBound.selector);
        strat.syncEthValue(240e18 + 1); // one wei past the clamp
    }

    function test_loss_is_honest_downward_sync() public {
        _deploy();
        vm.prank(keeper);
        strat.syncEthValue(200e18);
        // a Hub deficit marks the position down — the keeper reports the truth
        vm.expectEmit(true, true, true, true, address(strat));
        emit AaveStrategy.LossObserved(200e18, 180e18);
        vm.prank(keeper);
        strat.syncEthValue(180e18); // BELOW the old mark — no clamp on the downside
        assertEq(strat.ethValue6(), 180e18);
        assertEq(strat.totalAssets(), 180e18); // the book follows the mark DOWN
        vm.prank(keeper);
        strat.syncEthValue(190e18); // recovery syncs back up (within the bound)
        assertEq(strat.ethValue6(), 190e18);
    }

    function test_ack_and_inbound_never_double_count() public {
        _deploy();
        vm.prank(keeper);
        strat.syncEthValue(200e18);
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
        vm.expectRevert(AaveStrategy.AAVE__ReceiveFailed.selector);
        strat.completeInbound(hex"00", hex"00");
        cctp.setInboundFail(false, false);
    }

    /*//////////////////// recall: liquidity-conditional, never gated ////////////////////*/

    /// The venue's exit is capped by the Hub's available USDC, so a recall can
    /// legitimately find NOTHING idle. It must pay what it can, record the
    /// shortfall for the keeper to retry — never revert, never force an unwind.
    function test_recall_pays_idle_and_records_shortfall() public {
        _deploy(); // 200 idle → all in flight on mainnet
        vm.prank(keeper);
        strat.syncEthValue(200e18);
        vm.prank(address(vault));
        strat.recall(50e18); // vault wants 50; idle is 0
        assertEq(strat.pendingRecall6(), 50e18);
        // the unwind lands back home as the Hub refills
        cctp.setInboundAny(50e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        vm.prank(keeper);
        strat.pushIdle(50e18); // keeper pays the pending recall
        assertEq(strat.pendingRecall6(), 0);
        assertEq(usdc.balanceOf(address(vault)), 2_000e18 + 50e18);
    }

    /// A PARTIAL recall (illiquid slice) is the common case: pay the idle
    /// slice, defer the rest to the next keeper pass.
    function test_recall_partial_defers_the_remainder() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(100e18, 0); // idle now 100 (was 200)
        vm.prank(address(vault));
        strat.recall(150e18); // vault wants 150; only 100 is idle
        assertEq(usdc.balanceOf(address(vault)), 2_000e18 + 100e18);
        assertEq(strat.pendingRecall6(), 50e18, "the illiquid remainder is deferred, not forced");
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
        vm.expectRevert(AaveStrategy.AAVE__NotVault.selector);
        strat.recall(1e18);
        vm.prank(address(vault));
        strat.recall(0); // silent noop
        assertEq(strat.pendingRecall6(), 0);
    }

    /// AUDIT F-C (EXACT) regression — the ledger is a cumulative
    /// `recallDemand6` − `recallPaid6`, so the undecidable "did the vault
    /// re-request the deferred slice, or make a fresh demand?" split is REMOVED
    /// rather than guessed. A deferred slice is NOT silently cleared by a later
    /// fully-paid demand (the old double-credit false negative, probe
    /// `test_FC_residual_counter_zeros_while_a_real_demand_is_unpaid`); only a
    /// PAYMENT back to the vault (`recall` `sent` or `pushIdle`) settles demand.
    function test_FC_exact_ledger_unpaid_demand_survives_a_later_paid_demand() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(200e18, 0); // idle 200 -> 0

        // demand #1: 40 asked, nothing idle -> 40 deferred, nothing paid
        vm.prank(address(vault));
        strat.recall(40e18);
        assertEq(strat.pendingRecall6(), 40e18, "demand #1 fully deferred");
        assertEq(strat.recallDemand6(), 40e18, "cumulative demand 40");
        assertEq(strat.recallPaid6(), 0, "nothing paid yet");

        // money comes home; the vault's NEXT (fresh) demand is 50, paid in full
        cctp.setInboundAny(50e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        vm.prank(address(vault));
        strat.recall(50e18);

        // the 50 was paid against the NEW demand; 40 of demand #1 is STILL unpaid,
        // so the counter must NOT read 0 (the old false negative).
        assertEq(strat.recallDemand6(), 90e18, "cumulative demand 40 + 50");
        assertEq(strat.recallPaid6(), 50e18, "cumulative paid 50");
        assertEq(strat.pendingRecall6(), 40e18, "F-C exact: the unpaid 40 is not silently cleared");

        // the keeper's normal settlement path (`pushIdle`) DOES retire it
        cctp.setInboundAny(40e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        vm.prank(keeper);
        strat.pushIdle(40e18);
        assertEq(strat.pendingRecall6(), 0, "pushIdle settles outstanding demand first");
    }

    /// AUDIT F-C (EXACT), probe 2
    /// (`test_FC_residual_partial_payment_double_credit`): a PARTIAL payment on a
    /// re-requested demand used to be double-credited (the old code reported 40
    /// for 20 outstanding). The exact ledger reports the true cumulative
    /// residual — demand 150 − paid 80 = 70 — never a double count.
    function test_FC_exact_ledger_partial_payment_is_not_double_credited() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(150e18, 0); // idle 200 -> 50

        vm.prank(address(vault));
        strat.recall(100e18); // 50 paid, 50 deferred
        assertEq(strat.pendingRecall6(), 50e18, "50 deferred");

        cctp.setInboundAny(30e18, address(strat));
        strat.completeInbound(hex"00", hex"00"); // idle = 30
        vm.prank(address(vault));
        strat.recall(50e18); // pays 30, 20 short of THIS request

        assertEq(strat.recallDemand6(), 150e18, "cumulative demand 100 + 50");
        assertEq(strat.recallPaid6(), 80e18, "cumulative paid 50 + 30");
        assertEq(strat.pendingRecall6(), 70e18, "F-C exact: cumulative residual, no double-credit");
    }

    /// AUDIT F-C (Blocking 2, fix) — `test_PROBE_FC_pushIdle_credit_masks_a_later_real_shortfall`.
    /// A payment made when NOTHING is owed must not bank a credit: `recallPaid6` is
    /// capped at `recallDemand6`, so an unbacked `pushIdle` cannot silently swallow a
    /// later genuine shortfall (which would keep the monitor's pending-recall alert
    /// from firing while the vault is still owed money).
    function test_FC_unbacked_pushIdle_does_not_mask_a_later_real_shortfall() public {
        // normal ops, no error: a return lands and the keeper pushes it home; no recall ever happened
        vm.prank(keeper);
        strat.pushIdle(200e18);
        assertEq(strat.recallDemand6(), 0, "no recall was ever made");
        assertEq(strat.recallPaid6(), 0, "F-C: an unbacked payment banks NO credit");

        // the vault now makes a GENUINE recall of 50 the sleeve cannot pay
        vm.prank(address(vault));
        strat.recall(50e18);
        assertEq(strat.recallDemand6(), 50e18);
        assertEq(strat.recallPaid6(), 0);
        assertEq(strat.pendingRecall6(), 50e18, "F-C: the real 50 shortfall is reported, alert fires");
    }

    /// AUDIT F-C (Blocking 2, fix), the other door (`test_PROBE_FC_recall_path_alone_masks_it_too`):
    /// a fully-paid recall, and then a fresh shortfall, must still report the shortfall.
    function test_FC_recall_path_does_not_bank_a_surplus() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(150e18, 0); // idle 50
        vm.prank(address(vault));
        strat.recall(100e18); // demand 100, paid 50
        assertEq(strat.pendingRecall6(), 50e18);

        cctp.setInboundAny(50e18, address(strat));
        strat.completeInbound(hex"00", hex"00"); // idle 50
        vm.prank(keeper);
        strat.pushIdle(50e18); // settles the outstanding 50: demand 100, paid 100
        assertEq(strat.pendingRecall6(), 0, "settled");

        vm.prank(address(vault));
        strat.recall(10e18); // nothing idle -> a real 10 shortfall
        assertEq(strat.pendingRecall6(), 10e18, "the honest shortfall is reported");
    }

    /*//////////////////// admin ////////////////////*/

    function test_setParams_bounds() public {
        vm.expectRevert(bytes("Aave: headroom too high"));
        strat.setParams(3001, 5e6);
        vm.expectRevert(bytes("Aave: min too low"));
        strat.setParams(2000, 1e6);
        strat.setParams(1000, 2e6);
        assertEq(strat.headroomBps(), 1000);
    }

    function test_zero_addr_constructor() public {
        vm.expectRevert(AaveStrategy.AAVE__ZeroAddr.selector);
        new AaveStrategy(address(usdc), address(this), address(0), address(cctp), executor);
    }

    function test_owner_path_and_views() public {
        // the OWNER can also drive the keeper surface (onlyKeeperOrOwner)
        strat.setVenueCleared(true);
        strat.deployToEth(100e18, 0); // owner == this
        assertEq(strat.outstandingFace6(), 100e18); // sent - returned
        assertEq(strat.name(), "Aave"); // the feed/monitor label
        assertEq(strat.ethExecutor(), executor); // immutable venue binding
        // a second ship + return flips outstanding to the residual
        cctp.setInboundAny(40e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        assertEq(strat.outstandingFace6(), 60e18);
    }

    /*//////////////////// audit remediation pins (F-1, F-6) ////////////////////*/

    /// AUDIT F-1. The live phantom: entry was refused by the venue, so the
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
        assertEq(strat.totalAssets(), 200e18, "F-1: reported assets must equal real backing");
        assertLe(strat.totalAssets(), usdc.balanceOf(address(strat)), "F-1: totalAssets <= real idle");
        vm.prank(keeper);
        strat.syncEthValue(0);
        assertLe(strat.totalAssets(), usdc.balanceOf(address(strat)));
    }

    /// AUDIT F-6 + design-note §5.3. `retFace > sentFace` (an excess inbound
    /// gift/donation) must never underflow or revert; the excess books as
    /// REALIZED YIELD and only outstanding principal retires deployed face.
    function test_excess_inbound_is_a_benign_gift() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(100e18, 0); // sent = 100
        cctp.setInboundAny(150e18, address(strat)); // 100 back + 50 gift
        uint256 got = strat.completeInbound(hex"00", hex"00");
        assertEq(got, 150e18);
        assertEq(strat.retFace6(), 100e18, "F-6: retFace books PRINCIPAL only");
        assertEq(strat.profitRealized6(), 50e18, "the +50 excess is REALIZED YIELD");
        assertEq(strat.outstandingFace6(), 0, "F-6: outstanding floors to 0, no underflow");
        assertEq(strat.inFlight6(), 0, "F-6: in-flight floors to 0, no underflow");
        assertEq(strat.harvestableProfit6(), 50e18, "yield waits for harvest()");
        assertEq(strat.idlePrincipal6(), 200e18, "idle 250 - 50 profit");
        assertEq(strat.totalAssets(), 250e18);
        vm.prank(keeper);
        strat.syncEthValue(0);
    }

    /// The R-1 pin: the un-swept yield can never leave through the supply or
    /// principal doors — only `harvest()` moves it.
    function test_deployToEth_is_principal_only() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(100e18, 0); // 100 out, 100 idle
        cctp.setInboundAny(150e18, address(strat)); // 100 principal + 50 yield back
        strat.completeInbound(hex"00", hex"00");
        assertEq(strat.harvestableProfit6(), 50e18);
        assertEq(strat.idlePrincipal6(), 200e18);
        vm.prank(keeper);
        vm.expectRevert(AaveStrategy.AAVE__ExceedsPrincipalIdle.selector);
        strat.deployToEth(201e18, 0); // would ship un-swept yield
        vm.prank(keeper);
        strat.deployToEth(200e18, 0); // principal-only is fine
    }

    function test_sync_eth_value_reverts_on_accounting_invariant() public {
        AaveProbe probe = new AaveProbe(address(usdc), address(this), address(cctp), address(cctp), executor);
        probe.poke(100e18, 0, 150e18); // inFlight 150 > outstanding 100
        vm.expectRevert(AaveStrategy.AAVE__AccountingInvariant.selector);
        probe.syncEthValue(0);
    }

    function test_reconcileProfit_bounds() public {
        strat.setVenueCleared(true);
        cctp.setInboundAny(300e18, address(strat)); // 200 principal + 100 yield
        strat.completeInbound(hex"00", hex"00");
        vault.harvest(); // profitSwept6 = 100
        uint256 swept = strat.profitSwept6();
        assertGt(swept, 0);
        vm.expectRevert(AaveStrategy.AAVE__BelowSwept.selector);
        strat.reconcileProfit(swept - 1);
        strat.reconcileProfit(swept + 100e18); // >= swept is allowed
        assertEq(strat.profitRealized6(), swept + 100e18);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        strat.reconcileProfit(0);
    }

    /*//////////////////// audit F-D: exact face book on close ////////////////////*/

    /// AUDIT F-D. CCTP deducts its fee at destination minting, so the burned
    /// face exceeds the amount that comes home; a naive (sent − received) book
    /// leaves a permanent phantom `outstandingFace6`. When the keeper attests
    /// the venue EMPTY with nothing in flight (the position is closed), the
    /// residual face is retired to `feesPaid6`, so `outstandingFace6()` is exact.
    function test_FD_closed_position_retires_the_fee_residual() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(200e18, 0); // burn face 200
        vm.prank(keeper);
        strat.ackArrival(200e18); // arrived (gross ack) -> inFlight 0
        vm.prank(keeper);
        strat.syncEthValue(200e18); // open position: face 200 == executor 200
        assertEq(strat.outstandingFace6(), 200e18);
        assertEq(strat.feesPaid6(), 0, "an OPEN position is never retired");

        // the venue returns less than the burn face — the CCTP destination fee
        cctp.setInboundAny(199e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        assertEq(strat.outstandingFace6(), 1e18, "1 face left = the CCTP fee (still a phantom)");
        assertEq(strat.feesPaid6(), 0);

        // the position closes: the keeper attests the executor EMPTY, nothing in flight
        vm.prank(keeper);
        strat.syncEthValue(0);
        assertEq(strat.outstandingFace6(), 0, "F-D: the residual fee is retired, no phantom");
        assertEq(strat.feesPaid6(), 1e18, "the retired face is booked as feesPaid6");
        assertEq(strat.retFace6(), 199e18, "retFace stays a pure received-cash counter (199)");
        assertEq(strat.ethPrincipal6(), 0);
    }

    /// AUDIT F-D (Blocking 1, fix). The retire trigger is a KEEPER ATTESTATION of a
    /// genuine open→closed transition, not "any zero sync with nothing in flight".
    /// A first/never-attested zero (the ack→sync F-E window that starts every
    /// cycle, or a stale/pre-deposit read) must NOT write off face, and a truthful
    /// re-attestation must still be accepted.
    function test_FD_first_zero_attest_does_not_retire_and_real_resync_is_accepted() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(200e18, 0); // burn 200 -> inFlight 200
        vm.prank(keeper);
        strat.ackArrival(200e18); // arriving at the venue; nothing attested this cycle yet
        assertEq(strat.cyclePeak6(), 0, "no non-zero attestation yet this cycle");

        // a stale/pre-deposit read (or a failed RPC defaulting to 0) is synced
        vm.prank(keeper);
        strat.syncEthValue(0);
        assertEq(strat.outstandingFace6(), 200e18, "a never-attested zero must NOT retire face");
        assertEq(strat.feesPaid6(), 0, "nothing booked as a fee");
        assertEq(strat.cyclePeak6(), 0);

        // the honest read is accepted, and the book is intact
        vm.prank(keeper);
        strat.syncEthValue(200e18);
        assertEq(strat.ethValue6(), 200e18);
        assertEq(strat.outstandingFace6(), 200e18);
        assertEq(strat.cyclePeak6(), 200e18, "the position is now attested open");

        // and the returning principal is still booked as PRINCIPAL, never yield
        cctp.setInboundAny(199e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        assertEq(strat.profitRealized6(), 0, "returned principal is not booked as yield");
        assertEq(strat.outstandingFace6(), 1e18, "1 face left = the CCTP fee (retired on close)");
        vm.prank(keeper);
        strat.syncEthValue(0); // genuine close
        assertEq(strat.feesPaid6(), 1e18, "now (and only now) the fee is retired");
        assertEq(strat.outstandingFace6(), 0);
    }

    /// AUDIT F-D (Blocking 1, item 2/3b). After a retirement, a later real
    /// attestation is still accepted (the bound is not locked) and a later
    /// returned principal still books as PRINCIPAL (the split is not disturbed).
    function test_FD_after_retire_re_attest_accepted_and_return_stays_principal() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(200e18, 0);
        vm.prank(keeper);
        strat.ackArrival(200e18);
        vm.prank(keeper);
        strat.syncEthValue(200e18); // open
        cctp.setInboundAny(199e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        vm.prank(keeper);
        strat.syncEthValue(0); // close -> retire 1 face
        assertEq(strat.outstandingFace6(), 0);
        assertEq(strat.feesPaid6(), 1e18);

        // a truthful small re-attestation (the closure was in fact a slice; the
        // venue still holds 0.5) is ACCEPTED — the bound keys off the gross face
        vm.prank(keeper);
        strat.syncEthValue(0.5e18);
        assertEq(strat.ethValue6(), 0.5e18, "the bound is not locked by the retire");

        // a later return is still booked as principal (outstandingBefore = gross),
        // not silently as yield
        cctp.setInboundAny(0.5e18, address(strat));
        strat.completeInbound(hex"00", hex"00");
        assertEq(strat.profitRealized6(), 0, "a later return is principal, not yield");
        assertEq(strat.retFace6(), 199.5e18, "retFace books the returned principal");
    }

    /// AUDIT F-D guard. Retirement must NOT fire while money is genuinely out —
    /// only a zero attestation AND an empty in-flight is "nothing remains out".
    function test_FD_retirement_is_guarded_while_money_is_out() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deployToEth(200e18, 0); // inFlight 200 (mid-bridge)
        vm.prank(keeper);
        strat.syncEthValue(0); // a zero attest while mid-bridge must NOT retire
        assertEq(strat.outstandingFace6(), 200e18, "mid-bridge face is not retired");
        assertEq(strat.feesPaid6(), 0);

        // ack + sync to a real OPEN value: still no retirement
        vm.prank(keeper);
        strat.ackArrival(200e18);
        vm.prank(keeper);
        strat.syncEthValue(200e18);
        assertEq(strat.outstandingFace6(), 200e18, "open position face is not retired");
        assertEq(strat.feesPaid6(), 0);
    }
}

/// Test-only probe: exposes the parent's face counters so the belt-and-braces
/// `syncEthValue` invariant can be exercised (no public path can violate it).
contract AaveProbe is AaveStrategy {
    constructor(address u, address o, address tm, address mt, address ex) AaveStrategy(u, o, tm, mt, ex) {}

    function poke(uint256 _sent, uint256 _ret, uint256 _inFlight) external {
        sentFace6 = _sent;
        retFace6 = _ret;
        inFlight6 = _inFlight;
    }
}

/*//////////////// attribution on a REAL vault (yield vs principal) ////////////////*/

// The Frontier ≤15% cap forces a minority sleeve slice, so the harness carries
// 5 filler strategies and `allocate()` splits 1,800/6 = 300 = 15.0%.
//   vault --allocate--> AaveStrategy --CCTP--> Ethereum executor
//     executor unwinds --> completeInbound splits principal vs yield -->
//     pushIdle(principal) -> vault.onStrategyReturn (booked, _totalAssets flat)
//     harvest()           -> vault.harvest (fee taken, _totalAssets += net)
contract AaveAttributionTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    MockCctp cctp;
    AaveStrategy strat;
    address[] fillers;

    address keeper = makeAddr("keeper");
    address executor = makeAddr("ethExecutor");

    uint256 constant D = 2_000e18; // deposit
    uint256 constant P = 300e18; // allocated principal to the sleeve (15%)
    uint256 constant DLT = 60e18; // realized yield on the round trip (+20%, at the headroom cap)
    uint256 constant FEE_BPS = 1000; // vault performanceFee default

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        cctp = new MockCctp(address(usdc));
        strat = new AaveStrategy(address(usdc), address(this), address(cctp), address(cctp), executor);

        strat.setVault(address(vault));
        strat.setKeeper(keeper);
        strat.setVenueCleared(true);
        vault.addStrategy(address(strat));
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

    function _ship() internal {
        vault.allocate();
        assertEq(usdc.balanceOf(address(strat)), P, "sleeve slice");
        vm.prank(keeper);
        strat.deployToEth(P, 0);
        assertEq(strat.inFlight6(), P, "in flight at face");
    }

    function _realBacking() internal view returns (uint256) {
        uint256 sum = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)) + strat.inFlight6()
            + strat.ethValue6();
        for (uint256 i = 0; i < fillers.length; i++) {
            sum += usdc.balanceOf(fillers[i]);
        }
        return sum;
    }

    function test_harvest_sweeps_yield_only() public {
        _ship();
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncEthValue(P + DLT);
        vm.stopPrank();
        cctp.setInboundAny(P + DLT, address(strat));
        strat.completeInbound(hex"", hex"");
        vm.prank(keeper);
        strat.pushIdle(P); // principal home

        uint256 taBefore = vault.totalAssets();
        vm.prank(keeper);
        strat.harvest(); // keeper settle only — never sweeps
        assertEq(strat.profitSwept6(), 0, "keeper harvest must NOT sweep");
        vault.harvest();

        uint256 fee = (DLT * FEE_BPS) / 10000;
        uint256 net = DLT - fee;
        assertEq(strat.profitSwept6(), DLT, "vault harvest swept exactly the yield");
        assertEq(vault.totalAssets(), taBefore + net, "_totalAssets rose by net yield");
        assertLe(vault.totalAssets(), _realBacking(), "INV-1 holds");
    }

    /// AUDIT F-5: returned PRINCIPAL is redeployable accounted cash and never
    /// raises the vault's totalAssets (no double count, no phantom arrival).
    function test_principal_return_is_redeployable_no_double_count() public {
        _ship();
        cctp.setInboundAny(P, address(strat)); // the executor unwinds, principal returns
        strat.completeInbound(hex"", hex"");
        vm.prank(keeper);
        strat.pushIdle(P);
        assertEq(vault.totalAssets(), D, "F-5: principal return must NOT raise totalAssets");
        assertEq(vault.uncreditedArrivals(), 0, "F-5: returned principal is booked cash");
        assertEq(usdc.balanceOf(address(strat)), 0, "sleeve emptied");
        assertLe(vault.totalAssets(), _realBacking(), "INV-1 holds");
    }

    function test_recall_capped_at_principal_leaves_yield_for_harvest() public {
        _ship();
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncEthValue(P + DLT);
        vm.stopPrank();
        cctp.setInboundAny(P + DLT, address(strat));
        strat.completeInbound(hex"", hex"");
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(address(vault));
        strat.recall(P + DLT); // ask for everything

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, P, "recall pays principal ONLY");
        assertEq(strat.harvestableProfit6(), DLT, "the yield stays for harvest()");
        assertEq(strat.pendingRecall6(), DLT, "excess over principal is a phantom shortfall, not paid");
    }
}

/*/////////////////////////// EXECUTOR (Ethereum side) ////////////////////////////*/

contract AaveExecutorTest is Test {
    MockUSDC usdc;
    MockAaveSpoke spoke;
    MockCctp cctp;
    AaveExecutor exec;

    address ops = makeAddr("opsKey");
    address stranger = makeAddr("stranger");
    address safe = makeAddr("safeOwner");
    address strategyOnHyperEvm = makeAddr("strategyHypeEVM");

    uint256 constant PRIME_ASSET_ID = 4;

    function setUp() public {
        usdc = new MockUSDC();
        spoke = new MockAaveSpoke(IERC20(address(usdc)), PRIME_ASSET_ID);
        cctp = new MockCctp(address(usdc));
        exec = new AaveExecutor(address(usdc), address(spoke), address(cctp), strategyOnHyperEvm, ops, safe);
        usdc.mint(address(this), 1_000e18);
        usdc.transfer(address(exec), 1_000e18); // funding that "arrived via CCTP"
    }

    function test_constructor_shape_guard() public {
        // a spoke whose asset is NOT the configured USDC must be refused
        MockUSDC other = new MockUSDC();
        MockAaveSpoke wrongSpoke = new MockAaveSpoke(IERC20(address(other)), PRIME_ASSET_ID);
        vm.expectRevert(AaveExecutor.AAVE_E__Shape.selector);
        new AaveExecutor(address(usdc), address(wrongSpoke), address(cctp), strategyOnHyperEvm, ops, safe);
        // zero addresses refused (checked before any external call)
        vm.expectRevert(AaveExecutor.AAVE_E__ZeroAddr.selector);
        new AaveExecutor(address(0), address(spoke), address(cctp), strategyOnHyperEvm, ops, safe);
        vm.expectRevert(AaveExecutor.AAVE_E__ZeroAddr.selector);
        new AaveExecutor(address(usdc), address(0), address(cctp), strategyOnHyperEvm, ops, safe);
        vm.expectRevert(AaveExecutor.AAVE_E__ZeroAddr.selector);
        new AaveExecutor(address(usdc), address(spoke), address(0), strategyOnHyperEvm, ops, safe);
        vm.expectRevert(AaveExecutor.AAVE_E__ZeroAddr.selector);
        new AaveExecutor(address(usdc), address(spoke), address(cctp), address(0), ops, safe);
        vm.expectRevert(AaveExecutor.AAVE_E__ZeroAddr.selector);
        new AaveExecutor(address(usdc), address(spoke), address(cctp), strategyOnHyperEvm, address(0), safe);
    }

    function test_enter_deposits_into_spoke() public {
        vm.prank(ops);
        uint256 shares = exec.enter(400e18, 399e18);
        assertEq(shares, 400e18); // 1:1 at genesis
        assertEq(exec.sharesBalance(), 400e18);
        assertEq(exec.usdcBalance(), 600e18);
        assertEq(exec.positionValueUsd6(), 1_000e18); // idle 600 + mark 400
        assertEq(exec.enterCount(), 1);
        // slippage + guards
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__Slippage.selector);
        exec.enter(100e18, 101e18); // impossible minShares
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__BadAmount.selector);
        exec.enter(0, 0);
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__BadAmount.selector);
        exec.enter(1_000_000e18, 0); // more than the balance
        vm.prank(stranger);
        vm.expectRevert(AaveExecutor.AAVE_E__NotOps.selector);
        exec.enter(100e18, 0);
    }

    /// THE defining venue property (AAVE_DD §5): a redeem is capped by the
    /// Hub's available USDC. The adapter unwinds in slices — no forced unwind.
    function test_exit_is_capped_by_hub_liquidity() public {
        vm.prank(ops);
        exec.enter(400e18, 0);
        // the Hub only has 100 USDC un-borrowed right now (~75% utilized)
        spoke.setLiquidity(100e18);
        assertEq(exec.redeemableShares(), 100e18);
        assertEq(exec.redeemableUsd6(), 100e18);
        vm.prank(ops);
        (uint256 sharesOut, uint256 usdcOut) = exec.exit(400e18, 99e18);
        assertEq(sharesOut, 100e18, "only the liquid slice unwinds");
        assertEq(usdcOut, 100e18);
        assertEq(exec.sharesBalance(), 300e18, "the rest stays supplied");
        assertEq(exec.usdcBalance(), 700e18);
        // the Hub refills (a borrow repays) — the remainder unwinds on retry
        spoke.setLiquidity(type(uint256).max);
        vm.prank(ops);
        (uint256 sharesOut2, uint256 usdcOut2) = exec.exit(400e18, 299e18);
        assertEq(sharesOut2, 300e18);
        assertEq(usdcOut2, 300e18);
        assertEq(exec.sharesBalance(), 0);
        assertEq(exec.usdcBalance(), 1_000e18);
        assertEq(exec.exitCount(), 2);
    }

    /// Fully-utilized capital is TEMPORARILY ILLIQUID: the exit door reports it
    /// explicitly (retry later) — it never reverts silently and never forces a
    /// venue action.
    function test_exit_reverts_no_liquidity_when_fully_utilized() public {
        vm.prank(ops);
        exec.enter(400e18, 0);
        spoke.setLiquidity(0); // ~100% utilization
        assertEq(exec.redeemableShares(), 0);
        assertEq(exec.redeemableUsd6(), 0);
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__NoLiquidity.selector);
        exec.exit(400e18, 0);
        assertEq(exec.sharesBalance(), 400e18, "position intact - nothing was forced");
    }

    /// A spoke halt blocks BOTH doors (maxDeposit/maxRedeem go to 0).
    function test_halted_spoke_blocks_both_doors() public {
        vm.prank(ops);
        exec.enter(100e18, 0);
        assertEq(exec.depositHeadroomUsd6(), type(uint256).max - 100e18); // uncapped mock, minus what is supplied
        spoke.setHalted(true);
        assertEq(exec.depositHeadroomUsd6(), 0);
        assertEq(exec.redeemableShares(), 0);
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__AddCap.selector);
        exec.enter(10e18, 0);
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__NoLiquidity.selector);
        exec.exit(100e18, 0);
        // un-halted: both doors re-open
        spoke.setHalted(false);
        vm.prank(ops);
        uint256 more = exec.enter(10e18, 0);
        assertGt(more, 0);
        vm.prank(ops);
        (uint256 sh, uint256 out) = exec.exit(110e18, 0);
        assertEq(sh, 110e18);
        assertEq(out, 110e18);
    }

    /// The per-spoke ADD CAP is enforced with an explicit, retryable error.
    function test_add_cap_blocks_enter() public {
        usdc.mint(address(exec), 100e18);
        spoke.setAddCap(50e18); // only $50 of room
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__AddCap.selector);
        exec.enter(60e18, 0);
        vm.prank(ops);
        exec.enter(50e18, 49e18); // exactly the headroom is fine
        assertEq(exec.redeemableShares(), 50e18);
    }

    /// PPS / deficit honesty: the mark is what the venue says it is; a real
    /// backing withdrawal marks the position DOWN (never smoothed here).
    function test_pps_moves_with_real_backing() public {
        vm.prank(ops);
        exec.enter(400e18, 0);
        spoke.injectBackingUsdc(40e18); // +10% real interest
        assertEq(exec.positionValueUsd6(), 1_040e18);
        spoke.removeBackingUsdc(44e18); // a Hub deficit
        assertLt(exec.positionValueUsd6(), 1_000e18);
    }

    function test_bridgeback_destination_and_trust_model() public {
        // AUDIT F-B: the return leg is UNUSABLE until the owner blesses the
        // destination — a routine first unwind can no longer lock in a wrong,
        // unconfirmed address (the one-time correction stays open).
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__NotConfirmed.selector);
        exec.bridgeBack(10e18, 0);
        vm.prank(stranger);
        vm.expectRevert(AaveExecutor.AAVE_E__NotOps.selector);
        exec.bridgeBack(1e18, 0);
        vm.prank(safe);
        exec.confirmStrategyReturn(strategyOnHyperEvm);
        assertTrue(exec.returnConfirmed());

        vm.prank(ops);
        exec.bridgeBack(10e18, 0);
        (uint256 amount, uint32 domain, bytes32 recipient,, bytes32 destCaller, uint256 maxFee,) = cctp.lastBurn();
        assertEq(amount, 10e18);
        assertEq(domain, 19); // HyperEVM
        assertEq(recipient, bytes32(uint256(uint160(strategyOnHyperEvm))), "immutable destination");
        // AUDIT F-A: the return leg pins `destinationCaller` to the strategy, so
        // ONLY the strategy (via completeInbound) may complete the inbound mint.
        assertEq(destCaller, bytes32(uint256(uint160(strategyOnHyperEvm))), "F-A: return leg pinned");
        assertEq(maxFee, 0);
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__BadAmount.selector);
        exec.bridgeBack(1_000_000e18, 0); // more than the balance
        // config is owner-only; the return destination locks after any activity
        vm.prank(stranger);
        vm.expectRevert();
        exec.setOps(stranger);
        // the one-time correction door is shut: the executor is confirmed AND
        // `bridgeBackCount != 0`, so either guard refuses. (The `TooLate` guard
        // specifically is pinned in test_enter_activity_also_closes_the_confirm_window.)
        vm.prank(safe);
        vm.expectRevert(AaveExecutor.AAVE_E__AlreadyConfirmed.selector);
        exec.confirmStrategyReturn(stranger);
        // rescue hatch is owner-only and works
        vm.prank(stranger);
        vm.expectRevert();
        exec.ownerRescue(address(usdc), stranger, 1e18);
        vm.prank(safe);
        exec.ownerRescue(address(usdc), safe, 5e18);
        assertEq(usdc.balanceOf(safe), 5e18);
    }

    /// AUDIT F-A regression: the return leg's `destinationCaller` pin is
    /// ENFORCED by the CCTP message transmitter, not merely recorded. A third
    /// party can no longer complete the inbound mint directly (which would
    /// consume the single-use nonce and permanently desync the book), and the
    /// message can only be completed once.
    function test_return_leg_pin_is_enforced_by_the_transmitter() public {
        vm.prank(safe);
        exec.confirmStrategyReturn(strategyOnHyperEvm);
        vm.prank(ops);
        exec.bridgeBack(10e18, 0); // pins destinationCaller = strategy

        cctp.setInbound(10e18, strategyOnHyperEvm);
        // an unprivileged front-runner is rejected by the transmitter itself
        vm.prank(stranger);
        vm.expectRevert("mockcctp: destinationCaller: caller not allowed");
        cctp.receiveMessage(hex"", hex"");
        // the pinned caller (the strategy) may complete it — once
        vm.prank(strategyOnHyperEvm);
        assertTrue(cctp.receiveMessage(hex"", hex""));
        assertEq(usdc.balanceOf(strategyOnHyperEvm), 10e18);
        vm.prank(strategyOnHyperEvm);
        vm.expectRevert("mockcctp: message already used"); // CCTP messages are single-use
        cctp.receiveMessage(hex"", hex"");
    }

    /// AUDIT F-A (deploy leg): the Aave deploy leg is pinned to THIS executor, so
    /// the arrival can only be completed through `relayArrival` — by ops, or by the
    /// 2/3 Safe (the recovery path after a keeper-key rotation; a CCTP message has
    /// no expiry, so the recovery path must be a contract, not a key). A message
    /// that pays the executor nothing is refused, not silently consumed.
    function test_relayArrival_entry_point_and_recovery_path() public {
        uint256 start = exec.usdcBalance(); // 1_000e18, pre-funded in setUp
        cctp.setInboundPinnedFor(250e6, address(exec), address(exec));
        vm.prank(stranger);
        vm.expectRevert(AaveExecutor.AAVE_E__NotOpsOrOwner.selector);
        exec.relayArrival(hex"", hex"");

        vm.prank(ops);
        assertEq(exec.relayArrival(hex"", hex""), 250e6, "relayed amount reported");
        assertEq(exec.usdcBalance(), start + 250e6, "mint landed in the executor");

        vm.prank(ops);
        vm.expectRevert("mockcctp: message already used");
        exec.relayArrival(hex"", hex"");

        cctp.setInboundPinnedFor(100e6, address(exec), address(exec));
        vm.prank(safe);
        exec.relayArrival(hex"", hex""); // owner == the 2/3 Safe recovery path
        assertEq(exec.usdcBalance(), start + 350e6, "recovery relay from the owner works");

        cctp.setInboundPinnedFor(50e6, address(0xB0B), address(exec));
        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__NothingMinted.selector);
        exec.relayArrival(hex"", hex"");
    }

    /// AUDIT F-B regression: `confirmStrategyReturn` still works after a FAILED
    /// bridgeBack attempt (the window is not closed by a revert), but is refused
    /// forever once a real `bridgeBack` has happened.
    function test_confirm_window_closes_only_on_a_real_bridgeback() public {
        AaveExecutor fresh =
            new AaveExecutor(address(usdc), address(spoke), address(cctp), strategyOnHyperEvm, ops, safe);
        usdc.mint(address(fresh), 100e18);

        vm.prank(ops);
        vm.expectRevert(AaveExecutor.AAVE_E__NotConfirmed.selector);
        fresh.bridgeBack(10e18, 0); // failed attempt must NOT count as activity
        assertEq(fresh.bridgeBackCount(), 0);

        vm.prank(safe);
        fresh.confirmStrategyReturn(strategyOnHyperEvm); // correction still available
        assertTrue(fresh.returnConfirmed());

        vm.prank(ops);
        fresh.bridgeBack(10e18, 0); // the one routine unwind that closes the door
        assertEq(fresh.bridgeBackCount(), 1);
        vm.prank(safe);
        vm.expectRevert(AaveExecutor.AAVE_E__AlreadyConfirmed.selector);
        fresh.confirmStrategyReturn(stranger); // refused (both guards shut it)
    }

    /// AUDIT F-B: `enter` (venue supply) is not gated on the return confirmation,
    /// so it can still close the one-time window through the `TooLate` guard —
    /// pinned so that guard cannot be silently dropped.
    function test_enter_activity_also_closes_the_confirm_window() public {
        AaveExecutor fresh =
            new AaveExecutor(address(usdc), address(spoke), address(cctp), strategyOnHyperEvm, ops, safe);
        usdc.mint(address(fresh), 100e18);
        vm.prank(ops);
        fresh.enter(50e18, 0);
        vm.prank(safe);
        vm.expectRevert(AaveExecutor.AAVE_E__TooLate.selector);
        fresh.confirmStrategyReturn(strategyOnHyperEvm);
    }

    function test_ops_rotation_and_bootstrap_confirm() public {
        AaveExecutor fresh =
            new AaveExecutor(address(usdc), address(spoke), address(cctp), strategyOnHyperEvm, ops, safe);
        vm.prank(safe);
        vm.expectRevert(AaveExecutor.AAVE_E__ZeroAddr.selector);
        fresh.setOps(address(0));
        vm.prank(safe);
        fresh.setOps(stranger); // rotation works
        assertEq(fresh.ops(), stranger);
        vm.prank(safe);
        fresh.confirmStrategyReturn(makeAddr("realStrategy"));
        assertTrue(fresh.returnConfirmed());
        vm.prank(safe);
        vm.expectRevert(AaveExecutor.AAVE_E__AlreadyConfirmed.selector);
        fresh.confirmStrategyReturn(stranger); // second confirm refused
        AaveExecutor fresh2 =
            new AaveExecutor(address(usdc), address(spoke), address(cctp), strategyOnHyperEvm, ops, safe);
        vm.prank(safe);
        vm.expectRevert(AaveExecutor.AAVE_E__ZeroAddr.selector);
        fresh2.confirmStrategyReturn(address(0));
    }

    function test_venue_readout() public {
        (address s, address h, uint256 assetId, uint256 hubLiq, uint256 pps) = exec.venueReadout();
        assertEq(s, address(spoke));
        assertEq(assetId, PRIME_ASSET_ID);
        assertEq(h, address(0)); // the mock has no wired Hub
        assertEq(hubLiq, 0);
        assertEq(pps, 1e6); // empty wrapper: 1:1
    }
}
