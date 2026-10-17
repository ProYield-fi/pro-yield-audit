// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// PT sleeve — yield/principal attribution (design note §5/§9) on a REAL vault.
//
// Pins the 10 remediation tests from
// docs/SUSD3_CCTP_SLEEVE_YIELD_ATTRIBUTION_DESIGN_2026-10-05.md §9, plus the
// invariant INV-1 (`_totalAssets <= realBacking`) at every step of the round
// trip. The strategy-side F-1/F-5 pins live in PTSleeve.t.sol.
//
//   vault (HyperEVM) --allocate--> PTSleeveStrategy --CCTP--> Arb executor
//     executor unwinds --> completeInbound splits principal vs yield -->
//     pushIdle(principal) -> vault.onStrategyReturn (booked, _totalAssets flat)
//     harvest()           -> vault.harvest (fee taken, _totalAssets += net)
//
// Run: forge test --match-path 'test/forge/PTSleeveAttribution.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {PTSleeveStrategy} from "../../contracts/PTSleeveStrategy.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCctp} from "../../contracts/mocks/MockCctp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PTSleeveAttributionTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    MockCctp cctp;
    PTSleeveStrategy strat;

    address keeper = makeAddr("keeper");
    address executor = makeAddr("arbExecutor");

    uint256 constant D = 2_000e6; // deposit
    uint256 constant P = 1_800e6; // allocated principal (90% after the 10% reserve)
    uint256 constant DLT = 180e6; // realized yield on the round trip (+10%)
    uint256 constant FEE_BPS = 1000; // vault performanceFee default

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        cctp = new MockCctp(address(usdc));
        strat = new PTSleeveStrategy(address(usdc), address(this), address(cctp), address(cctp), executor, 3);

        strat.setVault(address(vault));
        strat.setKeeper(keeper);
        vault.addStrategy(address(strat));

        usdc.mint(address(this), D);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(D);
        assertEq(vault.totalAssets(), D, "booked");
    }

    // --------------------------------------------------------------- helpers

    /// allocate (ships 90% to the sole strategy) + keeper burns to the executor.
    function _ship() internal {
        vault.allocate();
        vm.prank(keeper);
        strat.deployToArb(P, 0);
        assertEq(usdc.balanceOf(address(strat)), 0, "all principal shipped");
        assertEq(strat.inFlight6(), P, "in flight at face");
    }

    /// Ack + attest the Arb value at `P + delta`, then complete the return.
    /// (Splits yield only for delta > 0; a full-principal return books delta as
    /// the realized gain.)
    function _windDown(uint256 delta) internal {
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncArbValue(P + delta);
        vm.stopPrank();
        cctp.setInboundAny(P + delta, address(strat));
        strat.completeInbound(hex"", hex"");
    }

    function _realBacking() internal view returns (uint256) {
        return usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)) + strat.inFlight6()
            + strat.arbValue6();
    }

    function _assertInv1(string memory tag) internal view {
        assertLe(vault.totalAssets(), _realBacking(), tag);
    }

    /// `_accountedBalance` has no getter; it equals balance − uncreditedArrivals.
    function _accounted() internal view returns (uint256) {
        return usdc.balanceOf(address(vault)) - vault.uncreditedArrivals();
    }

    /// Vault's own harvest: calls strategy.harvest() with msg.sender == vault,
    /// so the sleeve sweeps realized yield and the vault measures the delta.
    function _vaultHarvest() internal {
        vault.harvest();
    }

    // ---------------------------------------- 1. split at completeInbound

    function test_completeInbound_splits_principal_and_yield() public {
        _ship();
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncArbValue(P + DLT);
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
        cctp.setInboundAny(P - 100e6, address(strat)); // return < outstanding
        strat.completeInbound(hex"", hex"");

        assertEq(strat.profitRealized6(), 0, "conservative: yield deferred, not invented");
        assertEq(strat.outstandingFace6(), 100e6, "rest still out");
        assertEq(usdc.balanceOf(address(strat)), before + (P - 100e6), "whole return treated as principal");
        assertEq(strat.idlePrincipal6(), usdc.balanceOf(address(strat)), "idle == principal");
    }

    // ---------------------------------------- 3. pushIdle yield-share guard

    function test_pushIdle_reverts_on_yield_share() public {
        _ship();
        _windDown(DLT);
        uint256 ip = strat.idlePrincipal6();
        assertEq(ip, P, "principal is idle - harvestable");

        vm.prank(keeper);
        vm.expectRevert(PTSleeveStrategy.PT__ExceedsPrincipalIdle.selector);
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
        assertEq(strat.pendingRecall6(), DLT, "excess over principal is a (phantom) shortfall, not paid");
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

        _vaultHarvest();

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

        _vaultHarvest();
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
        strat.deployToArb(P, 0);
        _assertInv1("s2 deploy");
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncArbValue(P + DLT);
        vm.stopPrank();
        _assertInv1("s3 sync up (mark uncredited)");
        cctp.setInboundAny(P + DLT, address(strat));
        strat.completeInbound(hex"", hex"");
        _assertInv1("s4 return");
        vm.prank(keeper);
        strat.pushIdle(P);
        _assertInv1("s5 principal home");
        _vaultHarvest();
        _assertInv1("s6 yield harvested");
        assertLe(vault.totalAssets(), _realBacking(), "INV-1 holds after every op");
    }

    // ---------------------------------------- 8. donation/excess is yield

    function test_donation_mint_is_yield_not_principal() public {
        _ship();
        // a full principal return PLUS a 50 gift (donation) lands
        cctp.setInboundAny(P + 50e6, address(strat));
        strat.completeInbound(hex"", hex"");

        assertEq(strat.profitRealized6(), 50e6, "excess books as realized YIELD");
        assertEq(strat.idlePrincipal6(), P, "principal NOT inflated by the gift");
        assertEq(strat.harvestableProfit6(), 50e6);
    }

    // ---------------------------------------- ETH lane (destDomain 0) parity

    /// The ETH-lane instance (PTSleeveEth, destDomain 0) is the SAME source; pin
    /// that the split behaves identically there.
    function test_eth_lane_split_identical() public {
        PTSleeveStrategy eth =
            new PTSleeveStrategy(address(usdc), address(this), address(cctp), address(cctp), executor, 0);
        eth.setVault(address(vault));
        eth.setKeeper(keeper);
        usdc.mint(address(eth), P);

        vm.prank(keeper);
        eth.deployToArb(P, 0);
        cctp.setInboundAny(P + DLT, address(eth));
        eth.completeInbound(hex"", hex"");

        assertEq(eth.destDomain(), 0, "ETH lane");
        assertEq(eth.retFace6(), P, "principal retired");
        assertEq(eth.profitRealized6(), DLT, "yield booked");
        assertEq(eth.idlePrincipal6(), P, "principal = idle - harvestable");
        assertEq(eth.harvestableProfit6(), DLT);
    }

    // ---------------------------------------- 10. reconcileProfit bounds
    function test_reconcileProfit_bounds() public {
        _ship();
        _windDown(DLT);
        vm.prank(keeper);
        strat.pushIdle(P);
        _vaultHarvest(); // profitSwept6 = DLT
        uint256 swept = strat.profitSwept6();
        assertGt(swept, 0);

        vm.expectRevert(PTSleeveStrategy.PT__BelowSwept.selector);
        strat.reconcileProfit(swept - 1);

        strat.reconcileProfit(swept + 100e6); // >= swept is allowed
        assertEq(strat.profitRealized6(), swept + 100e6);

        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        strat.reconcileProfit(0);
    }

    // ---------------------------------------- 11. R-1 cap (deployToArb)

    /// R-1 (High) pin — PORTED from the pre-deploy review's repro
    /// (`test_reviewA_deployUnsweptYield_thenLoss`) and flipped to a PASS by the
    /// `deployToArb <= idlePrincipal6()` cap.
    ///
    /// The exploit it closes: after a leg unwinds with yield, `deployToArb` used
    /// to allow bridging the WHOLE balance (principal + un-swept yield), so
    /// `profitRealized6` counted yield whose cash had left the sleeve and would
    /// never return. A venue loss on that sliced-off cash then made the vault's
    /// `harvest()` sweep PRINCIPAL as yield: `vault.totalAssets()` = 2162 vs true
    /// backing 1982 → the INV-1 breach of 180. With the cap the un-swept yield
    /// can never leave, so only PRINCIPAL is ever at risk; a principal loss is
    /// then the vault's documented `reportLoss` path and INV-1 holds across it.
    function test_r1_deployToArb_principal_only_keeps_inv1_after_venue_loss() public {
        _ship();
        _windDown(DLT);
        uint256 bal = usdc.balanceOf(address(strat)); // P + DLT = 1980
        assertEq(strat.harvestableProfit6(), DLT, "180 un-swept yield sits in the sleeve");
        assertEq(strat.idlePrincipal6(), P, "1800 principal is bridgeable");
        assertEq(bal, P + DLT, "balance = principal + un-swept yield");

        // (1) THE R-1 EXPLOIT ATTEMPT: bridge principal + un-swept yield.
        // Pre-fix this SUCCEEDS (no revert) and the test fails right here;
        // post-fix the cap rejects it.
        vm.prank(keeper);
        vm.expectRevert(PTSleeveStrategy.PT__ExceedsPrincipalIdle.selector);
        strat.deployToArb(bal, 0);

        // (2) principal-only redeploy is still permitted; the yield never leaves.
        vm.prank(keeper);
        strat.deployToArb(P, 0);
        assertEq(usdc.balanceOf(address(strat)), DLT, "R-1: only the un-swept yield stays idle");
        assertEq(strat.harvestableProfit6(), DLT, "yield still waits for harvest()");

        // (3) the venue LOSES part of the redeployed principal (mirrors the 180
        // loss on the redeployed slice): only P - DLT comes home.
        vm.startPrank(keeper);
        strat.ackArrival(P);
        strat.syncArbValue(P);
        vm.stopPrank();
        cctp.setInboundAny(P - DLT, address(strat));
        strat.completeInbound(hex"", hex"");
        vm.prank(keeper);
        strat.syncArbValue(0);

        // (4) the owner recognises the venue loss (the vault's documented path),
        // then the yield is harvested: booked must never exceed real backing.
        vault.reportLoss(DLT);
        _assertInv1("after venue loss reported");
        _vaultHarvest();
        _assertInv1("after vault harvest");
        assertEq(vault.totalAssets(), _realBacking(), "INV-1 exact: booked == real backing");
    }
}
