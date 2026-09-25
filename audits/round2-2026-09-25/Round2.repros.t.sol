// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ROUND-2 EXECUTABLE REPRO SUITE — verifies (or refutes) the round-1 manual
// findings H1, H3, M1, M2, L1 from FINAL_FINDINGS.md against the byte-identical
// audit snapshot (hypervault @ 17e890df). Tests are written so that each
// assertion IS the evidence: exact-value asserts on vault/strategy/FD state.
//
// Run: forge test --match-path 'test/audit/*' -vv

import {Test} from "forge-std/Test.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {BaseStrategy} from "../../contracts/BaseStrategy.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";

/// @dev Strategy that can simulate a venue loss (funds leave for good).
/// No loss-reporting path exists in BaseStrategy — that absence IS finding H1.
contract LossStrategy is BaseStrategy {
    address public immutable sink;

    constructor(address _underlying, address initialOwner, address _sink)
        BaseStrategy(_underlying, initialOwner, "LossStrategy")
    {
        sink = _sink;
    }

    function lose(uint256 amount) external onlyOwner {
        require(underlying.transfer(sink, amount), "lose: transfer failed");
    }
}

/// @dev Strategy with the "balance vs tracked principal" sweep convention:
/// when the VAULT harvests it, everything on it above its tracked principal
/// (incl. unaccounted donations) is sent to the vault and reported as profit.
/// Used for the M2 repro (vault books any inflow during harvest as profit).
contract DonationSweepStrategy is BaseStrategy {
    uint256 public principalTracked;

    constructor(address _underlying, address initialOwner)
        BaseStrategy(_underlying, initialOwner, "DonationSweep")
    {}

    function setPrincipalTracked(uint256 p) external onlyOwner {
        principalTracked = p;
    }

    function _doHarvest() internal override returns (uint256) {
        if (msg.sender != vault) return 0; // keeper/owner only settle (no movement)
        uint256 bal = underlying.balanceOf(address(this));
        uint256 sweep = bal > principalTracked ? bal - principalTracked : 0;
        if (sweep > 0) {
            principalTracked += sweep;
            require(underlying.transfer(vault, sweep), "sweep: transfer failed");
        }
        return sweep;
    }
}

/// @dev Minimal caller that can be set as a strategy's `vault` so the
/// recall() clamp semantics can be exercised directly (M1, unit level).
contract RecallCaller {
    function callRecall(address strategy, uint256 amount) external {
        BaseStrategy(strategy).recall(amount);
    }
}

contract Round2ReprosTest is Test {
    MockUSDC usdc;          // 18-decimals mock (repo's own test token)
    FeeDistributor fd;
    ProYieldVault vault;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    uint256 constant U = 1e18;

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        vault.deposit(amount);
    }

    /*//////////////////////////////////////////////////////////////
        H1 — no strategy-loss accounting: phantom totalAssets()
    //////////////////////////////////////////////////////////////*/

    function test_H1_strategyLoss_phantomTotalAssets_withdrawReverts() public {
        LossStrategy strat = new LossStrategy(address(usdc), address(this), address(0x000000000000000000000000000000000000dEaD));
        _deposit(alice, 1000 * U);
        _deposit(bob, 1000 * U);

        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vault.allocate(); // 2000 total → 200 reserve (10%), 1800 deployed

        assertEq(usdc.balanceOf(address(strat)), 1800 * U, "precondition: 1800 deployed to strategy");
        assertEq(usdc.balanceOf(address(vault)), 200 * U, "precondition: 200 idle reserve");

        strat.lose(1800 * U); // venue loss / hack — funds gone, no reporting path
        assertEq(usdc.balanceOf(address(strat)), 0, "strategy lost everything");

        // Vault accounting still claims the full amount: NO loss write-down exists
        // (ProYieldVault._totalAssets is only decremented by withdraw/emergency).
        assertEq(vault.totalAssets(), 2000 * U, "H1: totalAssets() still claims 2000");
        uint256 backing = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat));
        assertEq(backing, 200 * U, "H1: real backing is only 200");
        assertGt(vault.totalAssets(), backing, "H1: accounting > real backing");

        // Full withdrawal passes the phantom `amount <= totalAssets()` check but
        // reverts at the transfer (recall cannot conjure the lost 1800).
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1000 * U);

        // Bank-run: first user salvages the idle scrap...
        vm.prank(alice);
        vault.withdraw(200 * U);
        assertEq(usdc.balanceOf(alice), 200 * U, "alice salvaged the idle scrap");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault idle drained");

        // ...everyone after is trapped while accounting still claims 1800.
        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(100 * U);
        assertEq(vault.totalAssets(), 1800 * U, "H1: phantom claim persists for the trapped user");
        assertEq(strat.totalDebt(), 0, "no deployed-debt/loss ledger on the strategy either");
    }

    /*//////////////////////////////////////////////////////////////
        H3 — creditYield cannot distinguish idle from new arrivals
    //////////////////////////////////////////////////////////////*/

    function test_H3_creditYield_doubleCountsPreExistingIdle() public {
        _deposit(alice, 1000 * U);
        _deposit(bob, 1000 * U);
        assertEq(vault.totalAssets(), 2000 * U, "precondition: 2000 accounted");

        // Credit idle assets that are ALREADY inside _totalAssets — single call.
        vault.creditYield(2000 * U);

        assertEq(vault.totalAssets(), 4000 * U, "H3: totalAssets doubled with no new assets");
        assertEq(usdc.balanceOf(address(vault)), 2000 * U, "H3: real backing unchanged at 2000");
        assertGt(vault.totalAssets(), usdc.balanceOf(address(vault)), "H3: accounting > backing");

        // Bob extracts phantom value: withdraws ~2x his deposit off the inflated price.
        uint256 bobOut = vault.maxWithdraw(bob);
        emit log_named_uint("H3: bob maxWithdraw (phantom payout, wei)", bobOut);
        assertGt(bobOut, 1000 * U, "H3: phantom price pays bob more than his deposit");
        vm.prank(bob);
        vault.withdraw(bobOut);
        assertEq(usdc.balanceOf(bob), bobOut, "bob got the phantom payout");

        // Alice's remaining claim is unbacked — trapped, first-come-first-served.
        assertLe(usdc.balanceOf(address(vault)), 1e6, "vault drained to dust");
        assertGt(vault.totalAssets(), 0, "H3: alice's claim still shows on the books");
        uint256 aliceOut = vault.maxWithdraw(alice); // hoisted: expectRevert must arm the withdraw only
        assertGt(aliceOut, 0, "alice still has a phantom claim");
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(aliceOut);
    }

    function test_H3b_repeatedCreditYield_sameIdle_inflates() public {
        usdc.mint(address(vault), 1000 * U); // unaccounted idle sitting in the vault
        vault.creditYield(1000 * U);         // credit #1 — matches real backing (OK)
        assertEq(vault.totalAssets(), 1000 * U, "credit #1 equals backing");

        vault.creditYield(1000 * U);         // credit #2 — SAME idle re-credited
        assertEq(vault.totalAssets(), 2000 * U, "H3: re-credit inflates totalAssets");
        assertEq(usdc.balanceOf(address(vault)), 1000 * U, "backing still 1000");

        vault.creditYield(1000 * U);         // credit #3 — unbounded repetition
        assertEq(vault.totalAssets(), 3000 * U, "H3: no guard stops further re-credits");
    }

    /*//////////////////////////////////////////////////////////////
        M1 — recall() clamps at balance, no deployed-debt accounting
    //////////////////////////////////////////////////////////////*/

    function test_M1_unit_recall_capsAtBalance_notDeployedDebt() public {
        LossStrategy strat = new LossStrategy(address(usdc), address(this), address(0x000000000000000000000000000000000000dEaD));
        RecallCaller caller = new RecallCaller();
        strat.setVault(address(caller));

        usdc.mint(address(strat), 500 * U); // unaccounted funds (donation); zero deployed debt
        assertEq(strat.totalDebt(), 0, "no deployed-debt ledger exists");

        caller.callRecall(address(strat), 1000 * U); // request 2x its balance
        // Silent clamp to balance — no revert, nothing tracks what was requested.
        assertEq(usdc.balanceOf(address(strat)), 0, "M1: drained to zero");
        assertEq(usdc.balanceOf(address(caller)), 500 * U, "M1: delivered = balance, not request");
        assertEq(strat.totalDebt(), 0, "M1: no debt value to compare against");
    }

    function test_M1_integration_recallDrainsStrategy_toZero_inclDonation() public {
        LossStrategy strat = new LossStrategy(address(usdc), address(this), address(0x000000000000000000000000000000000000dEaD));
        _deposit(alice, 10000 * U);
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vault.allocate(); // 1000 reserve, 9000 deployed

        strat.lose(8800 * U);                // venue loss: only 200 of vault funds remain
        usdc.mint(address(strat), 300 * U);  // unswept donation (not vault-owned)

        assertEq(usdc.balanceOf(address(strat)), 500 * U, "strategy holds 500 = 200 vault funds + 300 donation");
        assertEq(vault.totalAssets(), 10000 * U, "loss of 8800 NOT written down anywhere");

        // Full withdrawal: recall(9001) is silently clamped to the 500 balance →
        // whole strategy drained (donation included), still short → revert.
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(10000 * U);

        // A withdrawal sized to what recall can actually deliver SUCCEEDS and
        // drains the strategy to zero in ONE recall (incl. the unaccounted 300).
        vm.prank(alice);
        vault.withdraw(1500 * U);
        emit log_named_uint("M1: strategy remaining balance after 1 withdrawal (wei)", usdc.balanceOf(address(strat)));
        emit log_named_uint("M1: vault totalAssets after (phantom, wei)", vault.totalAssets());
        assertEq(usdc.balanceOf(address(strat)), 0, "M1: one vault withdrawal drained the strategy to zero");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault empty");
        assertEq(vault.totalAssets(), 8500 * U, "M1: 8500 of phantom claims remain on the books");

        // Remaining accounting has no real backing left — trapped.
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1000 * U);
    }

    /*//////////////////////////////////////////////////////////////
        M2 — donation → harvest = attributed profit + FD fee
    //////////////////////////////////////////////////////////////*/

    function test_M2a_donationToVault_notCountedAtHarvest() public {
        _deposit(alice, 1000 * U);
        usdc.mint(address(vault), 500 * U); // direct USDC donation to the vault, no accounting

        vault.harvest();

        // idleBefore already includes the donation → it is NOT counted as profit.
        assertEq(vault.totalAssets(), 1000 * U, "M2a: vault-held donation NOT converted to profit");
        assertEq(usdc.balanceOf(address(fd)), 0, "M2a: no fee fabricated");
        assertEq(usdc.balanceOf(address(vault)), 1500 * U, "donation sits unaccounted");
        // It also never reaches depositors on its own: alice's claim is still 1000.
        assertEq(vault.maxWithdraw(alice), 1000 * U, "donation value not attributed to alice");
    }

    function test_M2b_donationToStrategy_sweptAsProfit_withFDFee() public {
        DonationSweepStrategy strat = new DonationSweepStrategy(address(usdc), address(this));
        _deposit(alice, 1000 * U);
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vault.allocate();                       // 100 reserve, 900 deployed
        strat.setPrincipalTracked(900 * U);     // strategy's own ledger of vault principal
        usdc.mint(address(strat), 100 * U);     // unaccounted donation lands on the strategy

        vault.harvest(); // strategy sweeps the donation to the vault mid-harvest

        // Vault books the inflow as profit, skims 10% for the FD, credits the net
        // to _totalAssets (share price) — provenance of the inflow is never checked.
        assertEq(usdc.balanceOf(address(fd)), 10 * U, "M2b: 10% fee taken out of the donation");
        assertEq(vault.totalAssets(), 1090 * U, "M2b: donation converted into attributed profit (net)");
        assertEq(usdc.balanceOf(address(strat)), 900 * U, "M2b: donation swept off the strategy");
        assertEq(strat.principalTracked(), 1000 * U, "M2b: strategy now counts the donation as profit");
    }

    /*//////////////////////////////////////////////////////////////
        L1 — FeeDistributor.route() silently clamps; routed > received
    //////////////////////////////////////////////////////////////*/

    function test_L1_route_silentlyClamps_routedExceedsReceived() public {
        usdc.mint(address(fd), 100 * U); // fees landed; receiveFees() NOT yet called
        assertEq(fd.totalFeesReceived(), 0, "receiveFees not synced yet");

        fd.route(treasury, 999 * U); // router typo: over-routes everything
        assertEq(usdc.balanceOf(treasury), 100 * U, "L1: silently clamped to balance, no revert");
        assertEq(fd.totalFeesRouted(), 100 * U, "L1: routed recorded");
        assertEq(fd.totalFeesReceived(), 0, "L1: received never incremented");
        assertGt(fd.totalFeesRouted(), fd.totalFeesReceived(), "L1: routed > received (invariant drift)");

        // receiveFees() cannot retroactively repair the drift — no balance left.
        fd.receiveFees();
        assertEq(fd.totalFeesReceived(), 0, "nothing left to re-sync from");
        int256 drift = int256(fd.totalFeesReceived()) - int256(fd.totalFeesRouted());
        assertEq(drift, -100 * int256(U), "L1: bookkeeping identity (received - routed) is -100");

        // New fees arrive + re-sync: drift persists (received 50 < routed 100).
        usdc.mint(address(fd), 50 * U);
        fd.receiveFees();
        assertEq(fd.totalFeesReceived(), 50 * U, "re-synced to new balance");
        int256 drift2 = int256(fd.totalFeesReceived()) - int256(fd.totalFeesRouted());
        assertEq(drift2, -50 * int256(U), "L1: drift still negative after re-sync");

        // Clamp-to-zero path: route() of anything when empty reverts.
        uint256 rem = usdc.balanceOf(address(fd));
        fd.route(treasury, rem); // drain everything (clamp sends full balance)
        assertEq(usdc.balanceOf(address(fd)), 0, "FD empty");
        vm.expectRevert(bytes("FeeDistributor: nothing to route"));
        fd.route(treasury, 1 * U);
    }
}
