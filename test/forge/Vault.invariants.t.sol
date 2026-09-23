// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Stateful invariant suite for the vault money path (item 3 of the testing
// hardening round). Encodes AUDIT_SCOPE.md §3 invariants as fuzzable
// properties over randomized action sequences:
//   1. Solvency — real backing (idle + strategies) >= accounted totalAssets
//   2. Price floor — totalAssets >= totalShares (share price never < 1)
//   3. Share bookkeeping — user shares sum exactly to totalShares
//   4. No zero-valued depositor
//   5. FeeDistributor bookkeeping — balance == received - routed
// Plus adversarial targeted tests: donation attack, emergency semantics,
// dust guard, recall path, paused-strategy containment, broken-strategy
// harvest resilience, and the fee-recycling (route->creditYield) pairing.

import {Test} from "forge-std/Test.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {BaseStrategy} from "../../contracts/BaseStrategy.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";

/// Honest yielding strategy: venue payout mints USDC to the strategy
/// (fund()), the vault's harvest sweeps it (same direction as
/// DeltaNeutralStrategy: sweep only when the VAULT calls).
contract YieldStrategy is BaseStrategy {
    uint256 public pendingYield;
    bool public boom; // when true, harvest reverts — vault must stay resilient

    constructor(address _underlying, address owner_)
        BaseStrategy(_underlying, owner_, "YieldStrategy")
    {}

    function name() external view override returns (string memory) {
        return "YieldStrategy";
    }

    function setBoom(bool b) external {
        boom = b;
    }

    function fund(uint256 amount) external {
        MockUSDC(address(underlying)).mint(address(this), amount);
        pendingYield += amount;
    }

    function _doHarvest() internal override returns (uint256) {
        if (boom) revert("YieldStrategy: boom");
        if (msg.sender != vault) return 0; // keeper/owner settle only; vault sweeps
        uint256 bal = underlying.balanceOf(address(this));
        uint256 sweep = pendingYield < bal ? pendingYield : bal;
        if (sweep == 0) return 0;
        pendingYield -= sweep;
        require(underlying.transfer(vault, sweep), "transfer failed");
        return sweep;
    }
}

contract VaultHandler is Test {
    ProYieldVault public vault;
    MockUSDC public usdc;
    FeeDistributor public fd;
    YieldStrategy public s1;
    YieldStrategy public s2;
    address public treasury = makeAddr("treasury");
    address[] public actors;

    uint256 public totalFeesToFD;
    uint256 public totalRoutedOut;
    uint256 public totalCredited;

    constructor(
        ProYieldVault _v,
        MockUSDC _u,
        FeeDistributor _f,
        YieldStrategy _s1,
        YieldStrategy _s2,
        address[3] memory _actors
    ) {
        vault = _v;
        usdc = _u;
        fd = _f;
        s1 = _s1;
        s2 = _s2;
        for (uint256 i; i < 3; i++) actors.push(_actors[i]);
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _strat(uint256 seed) internal view returns (YieldStrategy) {
        return seed % 2 == 0 ? s1 : s2;
    }

    // ── user actions ────────────────────────────────────────────────
    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 1e27);
        usdc.mint(a, amount);
        vm.prank(a);
        vault.deposit(amount);
        require(vault.shares(a) > 0, "deposit minted no shares");
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        uint256 before = usdc.balanceOf(a);
        vm.prank(a);
        vault.withdraw(amount);
        require(usdc.balanceOf(a) == before + amount, "withdraw paid wrong amount");
    }

    // ── owner/keeper actions ────────────────────────────────────────
    function allocate() external {
        vault.allocate();
    }

    function harvest() external {
        uint256 fdBefore = usdc.balanceOf(address(fd));
        vault.harvest();
        totalFeesToFD += usdc.balanceOf(address(fd)) - fdBefore;
    }

    function fundStrategy(uint256 stratSeed, uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        _strat(stratSeed).fund(amount);
    }

    function toggleStrategy(uint256 stratSeed, bool active) external {
        vault.setStrategyActive(address(_strat(stratSeed)), active);
    }

    /// Paired recycle flow: FD routes USDC to the vault, then creditYield.
    function creditYield(uint256 amount) external {
        uint256 bal = usdc.balanceOf(address(fd));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        fd.route(address(vault), amount);
        vault.creditYield(amount);
        totalRoutedOut += amount;
        totalCredited += amount;
    }

    function routeOut(uint256 amount) external {
        uint256 bal = usdc.balanceOf(address(fd));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        fd.route(treasury, amount);
        totalRoutedOut += amount;
    }

    // ── adversarial ─────────────────────────────────────────────────
    /// Direct USDC donation to the vault — no accounting. Must never break
    /// solvency or share-price invariants (offset neutralizes inflation).
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        usdc.mint(address(vault), amount);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 30 days));
    }
}

contract VaultInvariantsTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    YieldStrategy s1;
    YieldStrategy s2;
    VaultHandler handler;
    address[3] actors;

    function setUp() public {
        usdc = new MockUSDC();
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        s1 = new YieldStrategy(address(usdc), address(this));
        s2 = new YieldStrategy(address(usdc), address(this));
        handler = new VaultHandler(vault, usdc, fd, s1, s2, actors);

        vault.addStrategy(address(s1));
        vault.addStrategy(address(s2));
        s1.setVault(address(vault));
        s2.setVault(address(vault));

        // Hand owner-gated calls to the handler (it fuzzes allocate/harvest/etc.)
        vault.transferOwnership(address(handler));
        fd.transferOwnership(address(handler));

        for (uint256 i; i < 3; i++) {
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// §3.6 — vault withdrawals are honored by real assets: the sum of all
    /// real USDC held by the vault + its strategies never falls below the
    /// accounted totalAssets.
    function invariant_solvency() public view {
        uint256 backing = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(s1))
            + usdc.balanceOf(address(s2));
        assertGe(backing, vault.totalAssets(), "backing < totalAssets");
    }

    /// §3.2 — the share-price floor: totalAssets >= totalShares at all times
    /// (price never below 1; donation/harvest/withdraw flooring cannot break it).
    function invariant_price_never_below_one() public view {
        assertGe(vault.totalAssets(), vault.totalShares(), "price < 1");
    }

    /// §3.3 — liabilities stay in sync: user shares sum exactly to totalShares.
    function invariant_user_shares_sum_to_total() public view {
        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            sum += vault.shares(handler.actors(i));
        }
        assertEq(sum, vault.totalShares(), "shares sum mismatch");
    }

    /// No depositor is ever left with a zero-valued position while holding shares.
    function invariant_no_zero_valued_depositor() public view {
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            address a = handler.actors(i);
            if (vault.shares(a) > 0) {
                assertGt(vault.maxWithdraw(a), 0, "zero-valued depositor");
            }
        }
    }

    /// Fee accounting: FD balance equals what harvests actually sent minus
    /// what was routed out (recycle to vault counts as routed out too).
    function invariant_fd_bookkeeping() public view {
        assertEq(
            usdc.balanceOf(address(fd)),
            handler.totalFeesToFD() - handler.totalRoutedOut(),
            "fd balance != received - routed"
        );
    }

    /// The recycle pairing never credits more than was routed in.
    function invariant_credited_leq_routed() public view {
        assertLe(handler.totalCredited(), handler.totalRoutedOut(), "credited > routed");
    }

    /*//////////////////////////////////////////////////////////////
                         TARGETED / ADVERSARIAL
    //////////////////////////////////////////////////////////////*/

    /// Classic donation/first-depositor inflation attack — neutralized by the
    /// SHARE_OFFSET: the attacker recovers only ~1/(offset) of the donation,
    /// the victim's loss is bounded by one share's mint-flooring (<0.1% here).
    function test_donation_attack_neutralized() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(victim);
        usdc.approve(address(vault), type(uint256).max);

        uint256 donation = 1e24; // 1,000,000e18
        uint256 victimDeposit = 1e24;

        // attacker: 1 wei deposit, then donate directly to the vault
        usdc.mint(attacker, 1);
        vm.prank(attacker);
        vault.deposit(1);
        usdc.mint(address(vault), donation);

        // victim deposits into the inflated vault
        usdc.mint(victim, victimDeposit);
        vm.prank(victim);
        vault.deposit(victimDeposit);

        // both exit fully
        uint256 victimOut = vault.maxWithdraw(victim);
        vm.prank(victim);
        vault.withdraw(victimOut);
        uint256 attackerOut = vault.maxWithdraw(attacker);
        vm.prank(attacker);
        vault.withdraw(attackerOut);

        // victim must not be robbed beyond mint-flooring dust
        assertGe(victimOut, (victimDeposit * 999) / 1000, "victim robbed");
        // attacker recovers only a sliver of the donation — attack unprofitable
        assertLt(attackerOut, donation / 500, "attacker recovered too much");
    }

    /// emergencyWithdraw is a crisis lever: it drains backing while shares
    /// keep their claims (price < 1 afterwards) — documented dilution semantics.
    function test_emergency_withdraw_dilutes_share_price() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        vm.stopPrank();
        assertEq(vault.totalAssets(), vault.totalShares(), "precondition");

        vm.prank(address(handler));
        vault.emergencyWithdraw();

        assertEq(vault.totalAssets(), 0, "assets drained");
        assertEq(vault.totalShares(), 1000e18, "shares untouched");
        assertLt(vault.totalAssets(), vault.totalShares(), "price must be < 1 after emergency");
        // NOTE: invariant_price_never_below_one intentionally does NOT run
        // emergencyWithdraw in the handler — crisis semantics are tested here.
    }

    /// Dust guard: once the price exceeds 1, sub-share deposits revert.
    function test_dust_deposit_reverts_below_price() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        vm.stopPrank();
        // inflate price 2x via paired recycle
        vm.prank(address(handler));
        usdc.mint(address(fd), 1000e18);
        vm.prank(address(handler));
        fd.route(address(vault), 1000e18);
        vm.prank(address(handler));
        vault.creditYield(1000e18);

        vm.startPrank(actors[1]);
        usdc.mint(actors[1], 1);
        vm.expectRevert("ProYieldVault: zero shares");
        vault.deposit(1);
        vm.stopPrank();
    }

    /// Withdrawals beyond idle recall from strategies (RESERVE_BPS kept liquid).
    function test_withdraw_recalls_from_strategies() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        vm.stopPrank();
        vm.prank(address(handler));
        vault.allocate();
        // 10% reserve => ~900e18 deployed, ~100e18 idle
        assertLt(usdc.balanceOf(address(vault)), 950e18, "reserve not kept");

        uint256 before = usdc.balanceOf(actors[0]);
        vm.prank(actors[0]);
        vault.withdraw(950e18);
        assertEq(usdc.balanceOf(actors[0]) - before, 950e18, "recall withdraw failed");
    }

    /// Paused strategy: allocate skips it, direct harvest reverts for it,
    /// and its funds are NOT recallable while paused (containment trade-off:
    /// a withdrawal larger than idle + active-strategy funds reverts until
    /// the strategy is unpaused).
    function test_paused_strategy_locks_its_funds_for_withdrawals() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        vm.stopPrank();
        vm.prank(address(handler));
        vault.allocate(); // 100e18 idle, 450e18 per strategy
        assertEq(usdc.balanceOf(address(s1)), 450e18, "precondition: s1 allocated");

        vm.prank(address(handler));
        vault.setStrategyActive(address(s1), false);

        // 600e18 > idle(100) + active s2(450): cannot be honored while s1 is paused
        vm.prank(actors[0]);
        vm.expectRevert();
        vault.withdraw(600e18);
        assertEq(usdc.balanceOf(address(s1)), 450e18, "paused strategy must not be recalled");

        // direct harvest of a paused strategy reverts
        vm.prank(address(handler));
        vm.expectRevert("ProYieldVault: strategy paused");
        vault.harvestStrategy(address(s1));

        // unpausing restores the withdrawal (recall now comes from s1 too)
        vm.prank(address(handler));
        vault.setStrategyActive(address(s1), true);
        vm.prank(actors[0]);
        vault.withdraw(600e18);
        assertLt(usdc.balanceOf(address(s1)), 450e18, "recall must come from s1 after unpause");
    }

    /// One broken strategy must never brick the whole vault's harvest.
    function test_broken_strategy_does_not_brick_harvest() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        vm.stopPrank();
        vm.prank(address(handler));
        vault.allocate();

        s1.setBoom(true); // s1's harvest reverts now
        s2.fund(100e18); // s2 has real profit

        vm.prank(address(handler));
        vault.harvest(); // must NOT revert — s1 is skipped via try/catch

        assertGt(vault.totalAssets(), 1000e18, "s2 profit must be harvested");
    }

    /// Harvest fee split: 10% of profit to the FeeDistributor, 90% credited
    /// to depositors via the share price.
    function test_harvest_fee_split() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        vm.stopPrank();
        vm.prank(address(handler));
        vault.allocate();
        s1.fund(100e18);

        uint256 fdBefore = usdc.balanceOf(address(fd));
        vm.prank(address(handler));
        vault.harvest();

        assertEq(usdc.balanceOf(address(fd)) - fdBefore, 10e18, "fee != 10% of profit");
        assertEq(vault.totalAssets(), 1090e18, "net profit attribution wrong");
    }

    /// creditYield cannot credit more than actually sits in the vault.
    function test_credit_yield_requires_backing() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        vm.stopPrank();
        vm.prank(address(handler));
        vm.expectRevert("ProYieldVault: exceeds balance");
        vault.creditYield(2000e18);
    }

    /// First depositor gets 1:1; a later depositor into an appreciated vault
    /// gets fewer shares (earnings claims hold).
    function test_first_depositor_one_to_one_then_price_appreciation() public {
        vm.startPrank(actors[0]);
        usdc.mint(actors[0], 1000e18);
        vault.deposit(1000e18);
        assertEq(vault.shares(actors[0]), 1000e18, "first depositor must be 1:1");
        vm.stopPrank();

        // +10% profit
        vm.prank(address(handler));
        vault.allocate();
        s1.fund(100e18);
        vm.prank(address(handler));
        vault.harvest();

        vm.startPrank(actors[1]);
        usdc.mint(actors[1], 1100e18);
        vault.deposit(1100e18);
        assertLt(vault.shares(actors[1]), 1100e18, "late depositor must get fewer shares");
        vm.stopPrank();

        // early depositor redeems above 1:1
        assertGt(vault.maxWithdraw(actors[0]), 1000e18, "early depositor must redeem > deposit");
    }
}
