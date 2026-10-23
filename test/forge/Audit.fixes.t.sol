// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {BaseStrategy} from "../../contracts/BaseStrategy.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MorphoStrategy} from "../../contracts/MorphoStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockMorpho} from "../../contracts/mocks/MockMorpho.sol";

/// Strategy that can DESTROY real cash, i.e. reproduce a venue loss: the USDC
/// is gone, not merely re-valued. Required by the F-4 residual tests — a
/// write-down on a strategy that still holds the cash proves nothing.
contract LossyStrategy is BaseStrategy {
    constructor(address _underlying, address owner_) BaseStrategy(_underlying, owner_, "LossyStrategy") {}

    function name() external pure override returns (string memory) {
        return "LossyStrategy";
    }

    /// @notice Venue loss: `amount` of USDC leaves the system for good.
    function lose(uint256 amount) external {
        require(underlying.transfer(address(0xdead), amount), "lose: transfer failed");
    }
}

/// Round-2 regression suite for the audit fixes that landed in the contracts the
/// audit session owns. Each test pins a specific finding from AUDIT_ROUND1.
contract AuditFixesTest is Test {
    MockUSDC usdc;
    ProYieldVault vault;
    FeeDistributor fd;
    address owner = address(0xA11CE);
    address alice = address(0xB0B);
    address bob = address(0xB0B2);
    address treasury = address(0x7EA5);
    address insurance = address(0xCEE5);

    function setUp() public {
        usdc = new MockUSDC();
        vault = new ProYieldVault(address(usdc), owner, address(0xFEE));
        fd = new FeeDistributor(address(usdc));
        usdc.mint(alice, 1000e18);
        usdc.mint(bob, 1000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ─────────────────────────── F-4 · creditYield phantom assets ───────────

    function test_F4_idleFloatCannotBeRecredited() public {
        vm.prank(alice);
        vault.deposit(100e18);
        assertEq(vault.uncreditedArrivals(), 0, "a deposit is not an arrival");

        vm.prank(owner);
        vm.expectRevert("ProYieldVault: exceeds uncredited arrivals");
        vault.creditYield(100e18);

        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)), "books still == reality");
    }

    function test_F4_realArrivalCreditsExactlyOnce() public {
        vm.prank(alice);
        vault.deposit(100e18);
        usdc.mint(address(this), 50e18);
        usdc.transfer(address(vault), 50e18);
        assertEq(vault.uncreditedArrivals(), 50e18);

        vm.prank(owner);
        vault.creditYield(50e18);
        assertEq(vault.totalAssets(), 150e18, "arrival credited");
        assertEq(vault.uncreditedArrivals(), 0, "consumed");

        vm.prank(owner);
        vm.expectRevert("ProYieldVault: exceeds uncredited arrivals");
        vault.creditYield(50e18);
    }

    /// A donation is an arrival but must not be creditable as yield — it would
    /// be a gift, not income. (Arrivals are creditable by design; this test
    /// documents the boundary: the vault books exactly what arrived, so books
    /// and reality stay equal either way.)
    function test_F4_booksNeverExceedReality() public {
        vm.prank(alice);
        vault.deposit(100e18);
        usdc.mint(address(this), 10e18);
        usdc.transfer(address(vault), 10e18);

        assertEq(vault.totalAssets(), 100e18, "donation is NOT booked as yield");
        assertEq(vault.uncreditedArrivals(), 10e18, "but it IS visible as an arrival");
        assertLe(vault.totalAssets(), usdc.balanceOf(address(vault)), "books <= reality always");
    }

    // ─────────────────────── F-5 · emergencyWithdraw hardening ──────────────

    function test_F5_emergencyWithdrawEmitsEvent() public {
        vm.prank(alice);
        vault.deposit(50e18);

        vm.recordLogs();
        vm.prank(owner);
        vault.emergencyWithdraw();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 want = keccak256("EmergencyWithdraw(uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == want) found = true;
        }
        assertTrue(found, "EmergencyWithdraw must be observable in the logs");
    }

    /// The 1-wei donation used to underflow `_totalAssets -= balance` and brick
    /// the crisis lever for ANYONE.
    function test_F5_oneWeiDonationNoLongerBricksEmergencyExit() public {
        vm.prank(alice);
        vault.deposit(100e18);
        usdc.mint(address(this), 1);
        usdc.transfer(address(vault), 1);

        vm.prank(owner);
        vault.emergencyWithdraw(); // must NOT revert

        assertEq(usdc.balanceOf(address(vault)), 0, "vault emptied");
        assertEq(vault.totalAssets(), 0, "books written down, no underflow");
    }

    /// PY-EMERG-01 (yossweh 2026-10-22): the docstring claimed "uncredited
    /// arrivals are left in place"; the code sweeps the FULL balance. This pins
    /// what the code actually does, so any future behavior flip (booked-only)
    /// fails loudly and has to be a deliberate owner decision.
    /// See docs/EXTERNAL_FINDINGS_2026-10-22_YOSSWEH.md §PY-EMERG-01.
    function test_PY_EMERG_01_fullBalanceSweptIncludingUncreditedArrivals() public {
        vm.prank(alice);
        vault.deposit(100e18);
        usdc.mint(address(vault), 5e18); // a routed fee awaiting creditYield
        assertEq(vault.uncreditedArrivals(), 5e18, "setup: uncredited arrival exists");
        assertEq(vault.totalAssets(), 100e18, "setup: books do not count it");

        vm.expectEmit(true, true, true, true, address(vault));
        emit ProYieldVault.EmergencyWithdraw(105e18, 0);
        vm.prank(owner);
        vault.emergencyWithdraw();

        assertEq(usdc.balanceOf(address(vault)), 0, "whole balance swept (docs now say so)");
        assertEq(vault.uncreditedArrivals(), 0, "no orphaned cash left behind");
        assertEq(vault.totalAssets(), 0, "books written down to the booked part only");
    }

    // ────────────────────────── F-13 · FeeDistributor cumulative ────────────

    function test_F13_feesReceivedIsCumulativeNotHighWaterMark() public {
        // round 1: 100 USDC arrives
        usdc.mint(address(this), 100e18);
        usdc.transfer(address(fd), 100e18);
        fd.receiveFees();
        assertEq(fd.totalFeesReceived(), 100e18, "first fee counted");

        // route it all out — the old high-water-mark froze here forever
        fd.route(treasury, 100e18);
        assertEq(usdc.balanceOf(address(fd)), 0, "drained");

        // round 2: a SMALLER fee arrives. The old code ignored this entirely.
        usdc.mint(address(this), 40e18);
        usdc.transfer(address(fd), 40e18);
        fd.receiveFees();
        assertEq(fd.totalFeesReceived(), 140e18, "cumulative across both rounds");

        // idempotent
        fd.receiveFees();
        assertEq(fd.totalFeesReceived(), 140e18, "repeat call does not double count");
    }

    function test_F13_peakBalanceTracked() public {
        usdc.mint(address(this), 100e18);
        usdc.transfer(address(fd), 100e18);
        fd.receiveFees();
        assertEq(fd.peakBalance(), 100e18);

        fd.route(treasury, 100e18);
        fd.receiveFees();
        assertEq(fd.peakBalance(), 100e18, "peak is a high-water mark by design");
    }

    // ─────────────────────────── F-15 · addStrategy guards ──────────────────

    function test_F15_addStrategyRejectsCodelessAddress() public {
        vm.prank(owner);
        vm.expectRevert("ProYieldVault: strategy has no code");
        vault.addStrategy(address(0xDEAD)); // an EOA — used to burn real USDC
    }

    function test_F15_addStrategyRejectsDuplicates() public {
        vm.prank(owner);
        vault.addStrategy(address(vault)); // has code
        vm.prank(owner);
        vm.expectRevert("ProYieldVault: already added");
        vault.addStrategy(address(vault));
        assertEq(vault.strategyList(0), address(vault), "listed once");
    }

    // ────────── F-4 RESIDUAL · reportLoss must not debit the CASH ledger ────
    // t_b0874348: reportLoss debited `_accountedBalance` by the FULL loss even
    // when the loss was a VALUATION loss (no USDC left the vault). The old code
    // then left `uncreditedArrivals()` = the untouched idle reserve, so
    // `creditYield(reserve)` booked depositor principal as yield. Live on the
    // boost book 0xdeD29C…5d3e: an 11.992945 write-down zeroed the ledger while
    // balanceOf stayed 5.000000 -> creditYield(5_000_000) succeeded.

    /// DEPOSIT 100 -> allocate (10% reserve = 10 idle, 90 deployed) -> the venue
    /// BURNS 30 of real cash -> reportLoss(30). The vault's own cash must be
    /// untouched, the cash ledger must stay at 10, and the reserve must NOT
    /// become a creditable arrival.
    function test_F4_residual_reportLossBeyondIdleMustNotStrandCash() public {
        LossyStrategy strat = new LossyStrategy(address(usdc), owner);
        vm.startPrank(owner);
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(owner);
        vault.allocate();
        assertEq(usdc.balanceOf(address(vault)), 10e18, "setup: 10% reserve idle");
        assertEq(usdc.balanceOf(address(strat)), 90e18, "setup: 90 deployed");
        assertEq(vault.accountedBalance(), 10e18, "setup: cash ledger == idle cash");

        // The venue loses 30: real cash destroyed, nothing leaves the VAULT.
        strat.lose(30e18);
        assertEq(usdc.balanceOf(address(vault)), 10e18, "setup: vault cash untouched by the venue loss");

        vm.prank(owner);
        vault.reportLoss(30e18); // 1-arg selector = valuation loss, fromIdle = 0

        assertEq(vault.totalAssets(), 70e18, "claims written down to real backing");
        assertEq(usdc.balanceOf(address(vault)), 10e18, "vault cash untouched");
        assertEq(vault.accountedBalance(), 10e18, "THE FIX: cash ledger not debited by a valuation loss");
        assertEq(vault.uncreditedArrivals(), 0, "reserve must never read as creditable yield");

        // The live exploit: credit the stranded reserve as if it were income.
        vm.prank(owner);
        vm.expectRevert("ProYieldVault: exceeds uncredited arrivals");
        vault.creditYield(10e18);

        // Post-fix allocation still works off the intact ledger: reserve for
        // 70 of assets is 7, the ledger says 10 idle, so 3 is redeployable.
        vm.prank(owner);
        vault.allocate();
        assertEq(usdc.balanceOf(address(vault)), 7e18, "reserve rebased on the written-down total");
        assertEq(usdc.balanceOf(address(strat)), 63e18, "excess reserve redeployed (60 + 3)");
        assertEq(vault.accountedBalance(), 7e18, "redeploy debited only what actually shipped");
    }

    /// Two-arg path: `fromIdle` is bounded by BOTH the loss and the cash ledger.
    function test_F4_residual_twoArgSplitIsBounded() public {
        vm.prank(alice);
        vault.deposit(100e18); // no allocate: 100 idle, ledger = 100

        vm.prank(owner);
        vm.expectRevert("ProYieldVault: bad split");
        vault.reportLoss(5e18, 6e18); // fromIdle > amount

        vm.prank(owner);
        vm.expectRevert("ProYieldVault: bad split");
        vault.reportLoss(100e18, 101e18); // fromIdle > _accountedBalance

        // Nothing moved.
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.accountedBalance(), 100e18);
    }

    /// F-4R-1: `fromIdle` must be EVIDENCED by a real cash shortfall. A venue
    /// valuation loss leaves the vault's own cash at 10, so a report of
    /// `reportLoss(20, fromIdle=10)` is a lie and must revert; before the guard
    /// it left arrivals = 10 and creditYield(10) inflated NAV against 80 real.
    function test_F4_residual_falseSplitIsRefused() public {
        LossyStrategy strat = new LossyStrategy(address(usdc), owner);
        vm.startPrank(owner);
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(owner);
        vault.allocate();
        assertEq(usdc.balanceOf(address(vault)), 10e18, "setup: 10% reserve idle");
        strat.lose(20e18); // real loss is in the strategy; vault cash is untouched

        vm.prank(owner);
        vm.expectRevert("ProYieldVault: bad split");
        vault.reportLoss(20e18, 10e18);

        // Even a 1-wei false claim of a cash loss is refused.
        vm.prank(owner);
        vm.expectRevert("ProYieldVault: bad split");
        vault.reportLoss(20e18, 1);

        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.accountedBalance(), 10e18);
        assertEq(vault.uncreditedArrivals(), 0);
    }

    /// Two-arg path, CASH case: when cash really left the vault, the ledger is
    /// debited by exactly the cash part and no arrival appears.
    function test_F4_residual_twoArgDebitsLedgerForTheCashPart() public {
        vm.prank(alice);
        vault.deposit(100e18); // 100 idle, ledger = 100

        // 10 of the vault's own cash vanishes (the vault's balance drops without
        // the books being told — a lost transfer / seized float).
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), 10e18);
        assertEq(vault.uncreditedArrivals(), 0, "a shortfall is not an arrival");

        vm.prank(owner);
        vault.reportLoss(10e18, 10e18); // whole loss was idle CASH

        assertEq(vault.totalAssets(), 90e18, "claims written down");
        assertEq(vault.accountedBalance(), 90e18, "ledger debited by the cash part");
        assertEq(usdc.balanceOf(address(vault)), 90e18, "books == reality again");
        assertEq(vault.uncreditedArrivals(), 0, "still no phantom arrival");
    }

    /// Fail-closed PROPERTY (reworked for F-4R-2, t_27c2410c): if cash really
    /// vanishes and the owner reports it with the 1-arg (valuation) selector,
    /// the vault must NOT turn the shortfall into creditable capacity.
    ///
    /// This test used to assert the IMPLEMENTATION — "the cash ledger is still
    /// 100e18" — which is the assertion the F-4R-2 cap breaks, and which was
    /// the wrong thing to pin anyway (the ledger is a book value; a write-down
    /// is entitled to move it DOWN). What protects depositors is the property:
    /// no arrival appears, claims never exceed backing, and the ledger never
    /// claims more than the claims themselves.
    function test_F4_residual_oneArgIsFailClosedWhenCashVanishes() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), 40e18); // 40 gone, books still say 100

        vm.prank(owner);
        vault.reportLoss(40e18); // under-stated split: fromIdle = 0

        assertEq(vault.totalAssets(), 60e18, "claims written down to real backing");

        // THE PROPERTY (implementation-independent), not "ledger == 100":
        // 1. a vanished shortfall never becomes creditable capacity,
        assertEq(vault.uncreditedArrivals(), 0, "a shortfall is not an arrival");
        // 2. the cash ledger never claims more than the claim total,
        assertLe(vault.accountedBalance(), vault.totalAssets(), "ledger <= claims");
        // 3. everything the vault could still credit is covered by real assets,
        assertLe(
            vault.totalAssets() + vault.uncreditedArrivals(),
            usdc.balanceOf(address(vault)),
            "claims + creditable <= backing"
        );

        vm.prank(owner);
        vm.expectRevert("ProYieldVault: exceeds uncredited arrivals");
        vault.creditYield(1e18);
    }

    /// F-4R-2 (t_27c2410c) — the unreported-split PoC, end to end, plus the
    /// reason the cap is SAFE rather than a second F-4.
    ///
    /// deposit 100 (all idle) -> reportLoss(60) claims a VALUATION loss while
    /// nothing is deployed. Before the cap that left totalAssets 40 with the
    /// cash ledger still at 100, and `allocate()` shipped 96 (its reserve is
    /// 10% of 40) — cash the books no longer owned. With the cap the ledger is
    /// pinned to the claim total, so deployment is bounded by what the books
    /// own, and the 60 residue is REAL unclaimed USDC that can be re-credited
    /// without ever exceeding backing (the F-4 defect was the opposite: it made
    /// already-booked cash creditable, so a credit pushed claims ABOVE reality).
    function test_F4R2_writeDownCapsLedgerAtClaimsAndBoundsDeployment() public {
        LossyStrategy strat = new LossyStrategy(address(usdc), owner);
        vm.startPrank(owner);
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(100e18);
        assertEq(vault.accountedBalance(), 100e18, "setup: all cash booked and idle");

        // The cap is a book correction, so it must be OBSERVABLE (audit F-5).
        vm.recordLogs();
        vm.prank(owner);
        vault.reportLoss(60e18); // 1-arg = "valuation loss", but nothing is deployed
        bytes32 want = keccak256("LossLedgerCappedToClaims(uint256,uint256,uint256,uint256)");
        bool capped;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == want) capped = true;
        }
        assertTrue(capped, "a binding cap must emit LossLedgerCappedToClaims");

        assertEq(vault.totalAssets(), 40e18, "claims written down");
        // THE CAP: the cash ledger can never exceed the claim total.
        assertEq(vault.accountedBalance(), 40e18, "cash ledger capped at totalAssets");
        // The mislabelled 60 is real, unclaimed USDC — an arrival, never a claim.
        assertEq(vault.uncreditedArrivals(), 60e18, "residue is a real surplus");
        assertLe(
            vault.totalAssets() + vault.uncreditedArrivals(),
            usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)),
            "claims + creditable <= backing"
        );

        // Pre-cap this shipped 96 of the 100. Deployment is now bounded by the
        // book: reserve = 10% of 40 = 4, deployable = 36.
        vm.prank(owner);
        vault.allocate();
        assertEq(usdc.balanceOf(address(strat)), 36e18, "deployment bounded by the claim total");
        assertEq(usdc.balanceOf(address(vault)), 64e18, "36 deployed + 4 reserve + 60 surplus idle");
        assertEq(vault.accountedBalance(), 4e18, "only the reserve is booked idle cash");
        assertLe(
            vault.totalAssets() + vault.uncreditedArrivals(),
            usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)),
            "claims + creditable <= backing after allocate"
        );

        // Crediting the surplus restores the books to reality and stays solvent:
        // that is precisely what distinguishes this cap from the F-4 phantom.
        vm.prank(owner);
        vault.creditYield(60e18);
        assertEq(vault.totalAssets(), 100e18, "books back to real backing");
        assertEq(vault.accountedBalance(), 64e18, "all idle cash booked");
        assertEq(vault.uncreditedArrivals(), 0, "surplus consumed");
        assertLe(
            vault.totalAssets(),
            usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat)),
            "solvent after the credit"
        );
    }

    /// `deployable <= balance` in allocate(): when cash has really left the
    /// vault and the split under-stated it, the ledger (capped at the claim
    /// total 95) is still far above the 5 of real cash, so the vault must not
    /// try to ship money it does not have.
    function test_F4_residual_allocateRefusesCashTheVaultLacks() public {
        LossyStrategy strat = new LossyStrategy(address(usdc), owner);
        vm.startPrank(owner);
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vm.stopPrank();

        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), 95e18); // 5 real cash, books still 100

        vm.prank(owner);
        vault.reportLoss(5e18); // fromIdle = 0 -> ledger capped at 95, cash 5

        vm.prank(owner);
        vault.allocate(); // deployable (85.5) > balance (5) -> no-op, must not revert
        assertEq(usdc.balanceOf(address(vault)), 5e18, "cash was not shipped");
        assertEq(usdc.balanceOf(address(strat)), 0, "strategy got nothing");
        assertEq(vault.uncreditedArrivals(), 0, "no arrival manufactured by the shortfall");
    }

    // ────────── Auto-earn / permit sweep · depositFor ─────────────────────────
    function test_depositFor_keeperSweepsUserAllowanceAndBlocksStrangerGriefing() public {
        address keeperAddr = address(0xBEEF);
        address stranger = address(0xCAFE);
        vm.startPrank(owner);
        vault.setKeeper(keeperAddr);
        vault.setCaps(500e18, 250e18);
        vm.stopPrank();

        // Stranger cannot force-sweep alice's open allowance.
        vm.prank(stranger);
        vm.expectRevert("ProYieldVault: not keeper");
        vault.depositFor(alice, 100e18);

        // Zero user is refused even from owner.
        vm.prank(owner);
        vm.expectRevert("ProYieldVault: zero user");
        vault.depositFor(address(0), 100e18);

        // Keeper pulls from alice -> vault and mints shares to alice (keeper holds 0).
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(keeperAddr);
        vault.depositFor(alice, 150e18);

        assertEq(usdc.balanceOf(alice), aliceBefore - 150e18, "pulled from alice");
        assertEq(usdc.balanceOf(keeperAddr), 0, "keeper never touches funds");
        assertEq(vault.shares(alice), 150e18, "shares minted to alice");
        assertEq(vault.shares(keeperAddr), 0, "keeper gets no shares");
        assertEq(vault.totalAssets(), 150e18, "totalAssets updated");
        assertEq(vault.accountedBalance(), 150e18, "cash ledger updated");

        // Per-user cap still binds on depositFor.
        vm.prank(keeperAddr);
        vm.expectRevert("ProYieldVault: per-user cap reached");
        vault.depositFor(alice, 101e18);

        // Self-call depositFor works identically to deposit.
        vm.prank(alice);
        vault.depositFor(alice, 100e18);
        assertEq(vault.shares(alice), 250e18);
    }
}