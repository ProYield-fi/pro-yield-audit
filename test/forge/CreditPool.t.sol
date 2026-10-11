// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// CreditPoolStrategy + FrontierBase unit tests — the Frontier venue-class
// engineering (junior-tranche / first-loss credit pools). The two rules that
// make exotic venues acceptable are tested IN CODE here:
//   1. GATE: nothing supplies until the owner clears the venue after per-name
//      DD — and the gate can re-lock (incident) without ever trapping money.
//   2. CAP: the venue can never be supplied past its share of the vault book
//      (≤15% hard ceiling that even the owner cannot raise).
// Plus the first-loss accounting: losses re-baseline honestly and surface via
// LossObserved; yield above the (moved) baseline sweeps as real USDC.
//
// Run: forge test --match-path 'test/forge/CreditPool.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {CreditPoolStrategy} from "../../contracts/CreditPoolStrategy.sol";
import {FrontierBase} from "../../contracts/FrontierBase.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCreditPool} from "../../contracts/mocks/MockCreditPool.sol";

contract CreditPoolTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    MockCreditPool pool;
    CreditPoolStrategy strat;

    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    bytes4 constant E_NOTCLEARED = bytes4(keccak256("Frontier__NotCleared()"));
    bytes4 constant E_CAPEXCEEDED = bytes4(keccak256("Frontier__CapExceeded()"));
    bytes4 constant E_CAPUNVERIFIABLE = bytes4(keccak256("Frontier__CapUnverifiable()"));
    bytes4 constant E_BPSTOOHIGH = bytes4(keccak256("Frontier__BpsTooHigh()"));

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        pool = new MockCreditPool(usdc);
        strat = new CreditPoolStrategy(address(usdc), address(this), address(pool));

        strat.setVault(address(vault)); // cap denominator wired
        strat.setKeeper(keeper);
        vault.addStrategy(address(strat));

        // seed the vault's book: $2,000 (18-dec mock) so the strategy's $200
        // idle is a 10% share — inside the 15% per-name cap
        usdc.mint(address(this), 5_000e18);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(2_000e18);
        // seed the strategy's idle: $200 (as if allocate() had sent it)
        usdc.mint(address(this), 500e18);
        usdc.transfer(address(strat), 200e18);
    }

    /*//////////////////// The gate: fail-closed by default ////////////////////*/

    function test_supply_gate_default_locked() public {
        vm.prank(keeper);
        vm.expectRevert(E_NOTCLEARED);
        strat.deploy(); // $200 idle, vault wired — still locked until DD clears
        assertEq(pool.positionTokens(address(strat)), 0);
    }

    function test_clear_then_supply() public {
        vm.expectEmit(true, true, true, true, address(strat));
        emit FrontierBase.VenueCleared(true);
        strat.setVenueCleared(true);

        vm.prank(keeper);
        strat.deploy();
        assertEq(pool.positionValue(address(strat)), 200e18);
        assertEq(strat.totalAssets(), 200e18); // idle 0 + position 200
        assertEq(strat.totalSupplied(), 200e18);
        // the vault's book is untouched by the supply (moved inside the strategy)
        assertEq(vault.totalAssets(), 2_000e18);
    }

    function test_relock_never_traps_money() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deploy();
        strat.setVenueCleared(false); // incident re-lock
        // funds-out is NEVER gated — the vault can still pull everything back
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        strat.recall(200e18);
        assertEq(strat.totalAssets(), 0);
        assertEq(usdc.balanceOf(address(vault)) - before, 200e18);
    }

    /*//////////////////// The cap: ≤15% of the vault book ////////////////////*/

    function test_cap_blocks_over_15pct() public {
        strat.setVenueCleared(true);
        usdc.transfer(address(strat), 200e18); // idle 400 of 2,000 book = 20% > 15%
        vm.prank(keeper);
        vm.expectRevert(E_CAPEXCEEDED);
        strat.deploy();
        assertEq(pool.positionTokens(address(strat)), 0);
    }

    function test_cap_passes_when_within_15pct() public {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deploy(); // 200 of 2,000 book = 10% ✓
        assertEq(pool.positionValue(address(strat)), 200e18);
        assertEq(strat.projectedShareBps(), 1000); // exactly 10%
    }

    function test_cap_unverifiable_without_vault_wiring() public {
        CreditPoolStrategy orphan = new CreditPoolStrategy(address(usdc), address(this), address(pool));
        usdc.mint(address(orphan), 100e18);
        orphan.setVenueCleared(true); // clear the gate first — the CAP is what must fail
        vm.expectRevert(E_CAPUNVERIFIABLE);
        orphan.deploy(); // no vault wired → cannot verify the cap → fail closed
    }

    function test_cap_ceiling_cannot_be_raised_even_by_owner() public {
        vm.expectRevert(E_BPSTOOHIGH);
        strat.setMaxShareBps(1501); // the 15% policy ceiling is immutable
        strat.setMaxShareBps(500); // tightening is allowed (5%)
        strat.setVenueCleared(true);
        vm.prank(keeper); // 200 of 2,000 book = 10% > the new 5% cap
        vm.expectRevert(E_CAPEXCEEDED);
        strat.deploy();
    }

    /*//////////////////// First-loss accounting (the honest part) ////////////////////*/

    function _supply() internal {
        strat.setVenueCleared(true);
        vm.prank(keeper);
        strat.deploy(); // 200 in the pool (10% of the 2,000 book)
    }

    function test_loss_rebaselines_down_and_is_visible() public {
        _supply();
        uint256 debtBefore = strat.totalDebt(); // profit books on the STRATEGY
        pool.injectLossBps(2000); // junior tranche eats a 20% loss → mark 160
        assertEq(strat.totalAssets(), 160e18); // the mark is the mark — no smoothing

        vm.expectEmit(true, true, true, true, address(strat));
        emit CreditPoolStrategy.LossObserved(200e18, 160e18);
        vm.prank(address(vault));
        strat.harvest();
        assertEq(strat.totalDebt(), debtBefore, "a loss books no profit");
        assertEq(strat.lastHarvestPosition(), 160e18, "baseline moved DOWN");

        // yield AFTER the loss counts from the new, honest baseline
        pool.injectYieldBps(1250); // 160 → 180
        vm.prank(address(vault));
        strat.harvest();
        assertEq(strat.totalDebt(), debtBefore + 20e18, "only post-loss growth is profit");
    }
    function test_yield_sweeps_as_real_usdc() public {
        _supply();
        pool.injectYieldBps(1000); // 200 → 220 mark
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        strat.harvest();
        assertEq(usdc.balanceOf(address(vault)) - before, 20e18, "profit swept as USDC");
        // the baseline is the POST-REDEEM mark: sweeping the yield shrank the
        // position back to its pre-yield value (the yield left in tokens)
        assertEq(strat.lastHarvestPosition(), 200e18);
    }

    /*//////////////////// Recall edges (the money path) ////////////////////*/

    function test_recall_unwinds_partially() public {
        _supply();
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        strat.recall(60e18); // 30% of the position
        assertEq(usdc.balanceOf(address(vault)) - before, 60e18);
        assertEq(pool.positionValue(address(strat)), 140e18);
        assertEq(strat.lastHarvestPosition(), 140e18); // principal leaving ≠ yield
    }

    function test_recall_zero_and_stranger() public {
        _supply();
        vm.prank(stranger);
        vm.expectRevert(bytes("CreditPool: not vault"));
        strat.recall(1e18);
        vm.prank(address(vault));
        strat.recall(0); // silent noop
        assertEq(strat.totalAssets(), 200e18);
    }

    /*//////////////////// Admin edges ////////////////////*/

    function test_buffer_keeps_half_idle() public {
        strat.setVenueCleared(true);
        strat.setMaxShareBps(1500);
        usdc.mint(address(this), 2_000e18);
        vault.deposit(1_000e18);
        strat.setBufferBps(5000); // 50% buffer → only half supplies
        vm.prank(keeper);
        strat.deploy();
        assertEq(pool.positionValue(address(strat)), 100e18);
        assertEq(usdc.balanceOf(address(strat)), 100e18); // the cushion stays idle
    }

    function test_buffer_guard() public {
        vm.expectRevert(bytes("CreditPool: buffer too high"));
        strat.setBufferBps(5001);
    }

    function test_deploy_only_keeper_or_owner() public {
        strat.setVenueCleared(true);
        usdc.mint(address(this), 2_000e18);
        vault.deposit(1_000e18);
        vm.prank(stranger);
        vm.expectRevert(bytes("CreditPool: not keeper"));
        strat.deploy();
    }

    function test_harvest_inactive_reverts() public {
        _supply();
        strat.setActive(false);
        vm.prank(address(vault));
        vm.expectRevert(bytes("BaseStrategy: inactive")); // the base gate fires first
        strat.harvest();
    }

    function test_setters_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        strat.setVenueCleared(true);
        vm.prank(stranger);
        vm.expectRevert();
        strat.setMaxShareBps(100);
        vm.prank(stranger);
        vm.expectRevert();
        strat.setBufferBps(100);
    }

    function test_accounting_identity() public {
        _supply();
        pool.injectYieldBps(500);
        assertEq(strat.totalAssets(), usdc.balanceOf(address(strat)) + pool.positionValue(address(strat)));
    }

    /*//////////////////// Illiquidity reality (queues/lockups) ////////////////////*/

    function test_locked_pool_does_not_break_recall_or_sweep() public {
        _supply();
        pool.setBreakRedeem(true); // the venue froze redemptions
        // sweep: cannot unwind → sweeps 0, baseline unchanged, NO revert
        vm.prank(address(vault));
        strat.harvest();
        assertEq(strat.totalDebt(), 0);
        assertEq(strat.lastHarvestPosition(), 200e18); // unharvested yield stays claimable
        // recall: returns the idle it can (0 here), still NO revert
        vm.prank(address(vault));
        strat.recall(50e18);
        assertEq(pool.positionTokens(address(strat)), 200e18); // nothing burned
        // the pool unfreezes → the yield becomes reachable again
        pool.setBreakRedeem(false);
        pool.injectYieldBps(1000); // 200 → 220
        vm.prank(address(vault));
        strat.harvest();
        assertEq(strat.totalDebt(), 20e18);
    }

    function test_recall_with_zero_position_returns_only_idle() public {
        strat.setVenueCleared(true);
        // never deployed: idle 200, position 0
        vm.prank(address(vault));
        strat.recall(1_000e18); // more than everything → capped
        assertEq(usdc.balanceOf(address(strat)), 0);
        assertEq(strat.totalAssets(), 0);
    }

    function test_zero_pool_constructor_reverts_and_name_label() public {
        vm.expectRevert(bytes("CreditPool: zero pool"));
        new CreditPoolStrategy(address(usdc), address(this), address(0));
        assertEq(strat.name(), "CreditPool"); // the label the feed/monitor sees
    }
}
