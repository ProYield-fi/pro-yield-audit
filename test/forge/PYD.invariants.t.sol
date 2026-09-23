// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Stateful invariant + targeted suite for the PYD layer:
//   PYDStaking      — Synthetix-style reward streaming
//   PYDFeeDiscount  — tiered fee rebates (stake → tier; rebates from real fee deltas)
// Invariants: principal intact, stake bookkeeping, claims bounded by the
// funded pool, accrual bounded by the pool. Targeted: no accrual after the
// window, mid-period top-up preserves accrual, tier boundaries, budget-capped
// claims, zero-share stakers accrue nothing.

import {Test} from "forge-std/Test.sol";
import {PYDToken} from "../../contracts/PYDToken.sol";
import {PYDStaking} from "../../contracts/PYDStaking.sol";
import {PYDFeeDiscount} from "../../contracts/PYDFeeDiscount.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";

contract StakeHandler is Test {
    PYDToken public pyd;
    PYDStaking public staking;
    address[] public actors;

    constructor(PYDToken _pyd, PYDStaking _staking, address[3] memory _actors) {
        pyd = _pyd;
        staking = _staking;
        for (uint256 i; i < 3; i++) actors.push(_actors[i]);
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        amount = bound(amount, 1e15, 50_000e18);
        if (pyd.balanceOf(a) < amount) return;
        vm.prank(a);
        staking.stake(amount);
    }

    function unstake(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        uint256 staked = staking.stakeAmount(a);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);
        vm.prank(a);
        staking.withdraw(amount);
    }

    function claim(uint256 seed) external {
        address a = actors[seed % actors.length];
        vm.prank(a);
        staking.getReward();
    }

    function exit(uint256 seed) external {
        address a = actors[seed % actors.length];
        vm.prank(a);
        staking.exit();
    }

    function fundRewards(uint256 amount, uint256 duration) external {
        amount = bound(amount, 1e18, 100_000e18);
        duration = bound(duration, 1 hours, 30 days);
        if (pyd.balanceOf(address(this)) < amount) return;
        staking.fundRewards(amount, duration);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }
}

contract PYDInvariantsTest is Test {
    PYDToken pyd;
    PYDStaking staking;
    StakeHandler handler;
    address[3] actors;

    function setUp() public {
        pyd = new PYDToken(1_000_000); // 1M PYD to this test contract
        staking = new PYDStaking(address(pyd));
        actors = [makeAddr("dave"), makeAddr("erin"), makeAddr("frank")];
        handler = new StakeHandler(pyd, staking, actors);

        // fund actors + the handler (reward pool source)
        for (uint256 i; i < 3; i++) {
            pyd.transfer(actors[i], 100_000e18);
            vm.prank(actors[i]);
            pyd.approve(address(staking), type(uint256).max);
        }
        pyd.transfer(address(handler), 500_000e18);
        vm.prank(address(handler));
        pyd.approve(address(staking), type(uint256).max);

        // handler owns staking so it can fund reward windows
        staking.transferOwnership(address(handler));

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// Staked principal is always fully backed.
    function invariant_principal_intact() public view {
        assertGe(pyd.balanceOf(address(staking)), staking.totalSupply(), "principal not backed");
    }

    /// Stake bookkeeping: per-user stakes sum exactly to totalSupply.
    function invariant_stake_sum_to_total() public view {
        uint256 sum;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            sum += staking.stakeAmount(handler.actors(i));
        }
        assertEq(sum, staking.totalSupply(), "stake sum mismatch");
    }

    /// Claims can never exceed the funded pool (balance - principal).
    function invariant_claims_bounded_by_pool() public view {
        uint256 banked;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            banked += staking.rewards(handler.actors(i));
        }
        assertLe(banked, pyd.balanceOf(address(staking)) - staking.totalSupply(), "claims > pool");
    }

    /// Accrual (banked + unbanked) can never exceed the funded pool either —
    /// the stream pays only what was actually funded.
    function invariant_accrual_bounded_by_pool() public view {
        uint256 claimable;
        uint256 n = handler.actorsLength();
        for (uint256 i; i < n; i++) {
            claimable += staking.earned(handler.actors(i));
        }
        assertLe(claimable, pyd.balanceOf(address(staking)) - staking.totalSupply(), "accrual > pool");
    }

    /*//////////////////////////////////////////////////////////////
                         TARGETED / EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_no_accrual_after_period_finish() public {
        address a = actors[0];
        vm.prank(a);
        staking.stake(1000e18);
        vm.prank(address(handler));
        staking.fundRewards(1000e18, 7 days);

        vm.warp(block.timestamp + 7 days); // exactly at periodFinish
        uint256 earnedAtFinish = staking.earned(a);
        assertGt(earnedAtFinish, 0, "must have accrued during the window");

        vm.warp(block.timestamp + 30 days); // way past periodFinish
        assertEq(staking.earned(a), earnedAtFinish, "accrual continued past the funded window");
    }

    /// REGRESSION (found by the invariant suite): a window that fully lapsed
    /// with NO user interaction, followed by a keeper top-up, used to
    /// double-bank the tail — claims could exceed the funded pool and eat
    /// staked principal.
    function test_rollover_without_interaction_no_double_accrual() public {
        address a = actors[0];
        vm.prank(a);
        staking.stake(1000e18);
        vm.prank(address(handler));
        staking.fundRewards(1000e18, 7 days);

        // window fully lapses, no user interaction at all
        vm.warp(block.timestamp + 7 days);
        // keeper top-up (this used to double-bank the tail)
        vm.prank(address(handler));
        staking.fundRewards(1000e18, 7 days);
        vm.warp(block.timestamp + 7 days);

        uint256 before = pyd.balanceOf(a);
        vm.prank(a);
        staking.getReward();
        uint256 paid = pyd.balanceOf(a) - before;

        assertLe(paid, 2000e18, "paid more than funded (double-bank)");
        assertGt(paid, 1990e18, "must still pay the funded rewards");
        assertGe(pyd.balanceOf(address(staking)), staking.totalSupply(), "principal shortfall");
    }

    function test_mid_period_topup_preserves_accrual() public {
        address a = actors[0];
        vm.prank(a);
        staking.stake(1000e18);
        vm.prank(address(handler));
        staking.fundRewards(1000e18, 10 days);

        vm.warp(block.timestamp + 5 days);
        uint256 earnedMid = staking.earned(a);
        assertGt(earnedMid, 0, "must accrue mid-window");

        // top-up must not erase the first window's accrual
        vm.prank(address(handler));
        staking.fundRewards(1000e18, 10 days);
        assertGe(staking.earned(a), earnedMid, "top-up erased accrual");

        vm.warp(block.timestamp + 10 days);
        assertGt(staking.earned(a), earnedMid, "second window must accrue");
    }

    function test_claims_never_exceed_funded_pool() public {
        address a = actors[0];
        vm.prank(a);
        staking.stake(10_000e18);
        vm.prank(address(handler));
        staking.fundRewards(1000e18, 1 days);

        vm.warp(block.timestamp + 2 days);
        uint256 before = pyd.balanceOf(a);
        vm.prank(a);
        staking.getReward();
        uint256 paid = pyd.balanceOf(a) - before;
        assertGt(paid, 0, "must pay rewards");
        assertLe(paid, 1000e18, "paid more than the funded window");
        // principal intact after the payout
        assertGe(pyd.balanceOf(address(staking)), staking.totalSupply(), "principal not intact");
    }

    function test_exit_returns_principal_and_rewards() public {
        address a = actors[0];
        vm.prank(a);
        staking.stake(5000e18);
        vm.prank(address(handler));
        staking.fundRewards(1000e18, 2 days);
        vm.warp(block.timestamp + 3 days);

        uint256 before = pyd.balanceOf(a);
        vm.prank(a);
        staking.exit();
        uint256 out = pyd.balanceOf(a) - before;
        assertGe(out, 5000e18, "principal must be returned");
        assertEq(staking.stakeAmount(a), 0, "stake must be zeroed");
        assertEq(staking.rewards(a), 0, "rewards must be zeroed");
    }

    /*//////////////////////////////////////////////////////////////
                       PYDFeeDiscount (targeted)
    //////////////////////////////////////////////////////////////*/

    /// Fresh PYD + USDC + vault + discount for the discount tests: a fresh
    /// token avoids cross-test tier/balance coupling, and every actor is
    /// funded + approved against the discount (stake pulls PYD via
    /// safeTransferFrom).
    function _discountSetup()
        internal
        returns (PYDFeeDiscount discount, ProYieldVault vault, MockUSDC usdc, FeeDistributor fd)
    {
        PYDToken dPyd = new PYDToken(10_000_000);
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        discount = new PYDFeeDiscount(address(dPyd), address(usdc), address(fd), address(vault), address(this));
        for (uint256 i; i < 3; i++) {
            dPyd.transfer(actors[i], 2_000_000e18);
            vm.prank(actors[i]);
            dPyd.approve(address(discount), type(uint256).max);
        }
    }

    function test_discount_tier_boundaries() public {
        (PYDFeeDiscount discount,,,) = _discountSetup();
        address a = actors[0];

        vm.startPrank(a);
        discount.stake(999e18);
        assertEq(discount.tierBpsOf(a), 0, "999 must be below first tier");
        discount.stake(1e18); // now 1000
        assertEq(discount.tierBpsOf(a), 500, "1000 must hit 5%");
        discount.stake(9_000e18); // 10_000
        assertEq(discount.tierBpsOf(a), 1000, "10K must hit 10%");
        discount.stake(90_000e18); // 100_000
        assertEq(discount.tierBpsOf(a), 1500, "100K must hit 15%");
        discount.stake(900_000e18); // 1_000_000
        assertEq(discount.tierBpsOf(a), 2000, "1M must hit 20%");
        vm.stopPrank();
    }

    function test_discount_set_tiers_validation() public {
        (PYDFeeDiscount discount,,,) = _discountSetup();

        uint256[][] memory bad = new uint256[][](2);
        bad[0] = _pair(1000e18, 500);
        bad[1] = _pair(999e18, 600); // descending → revert
        vm.expectRevert(PYDFeeDiscount.PYDFee__BadTier.selector);
        discount.setTiers(bad);

        uint256[][] memory overCap = new uint256[][](1);
        overCap[0] = _pair(1000e18, 4001); // > MAX_TIER_BPS
        vm.expectRevert(PYDFeeDiscount.PYDFee__BadTier.selector);
        discount.setTiers(overCap);

        uint256[][] memory empty = new uint256[][](0);
        vm.expectRevert(PYDFeeDiscount.PYDFee__BadTier.selector);
        discount.setTiers(empty);
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = a;
        p[1] = b;
    }

    function test_discount_snapshot_math_and_budget_cap() public {
        (PYDFeeDiscount discount, ProYieldVault vault, MockUSDC usdc, FeeDistributor fd) = _discountSetup();
        address staker = actors[0];

        // staker is also the only vault depositor (shares = 100% of totalShares)
        vm.startPrank(staker);
        usdc.mint(staker, 1000e18);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1000e18);
        discount.stake(10_000e18); // tier 1000 = 10%
        vm.stopPrank();

        // real fee delta lands in the FD
        usdc.mint(address(fd), 1000e18);
        discount.snapshotHarvest();

        // rebate = shares/totalShares * delta * tier/10000 = 1000e18 * 10% = 100e18
        assertEq(discount.rebateOf(staker), 100e18, "rebate math wrong");

        // budget cap: only 30e18 routed in → partial claim, remainder stays accrued
        usdc.mint(address(discount), 30e18);
        vm.prank(staker);
        discount.claimRebate();
        assertEq(usdc.balanceOf(staker), 30e18, "claim must pay exactly the budget");
        assertEq(discount.rebateOf(staker), 70e18, "remainder must stay accrued");

        // rest of the budget arrives → full claim
        usdc.mint(address(discount), 100e18);
        vm.prank(staker);
        discount.claimRebate();
        assertEq(usdc.balanceOf(staker), 100e18, "second claim wrong");
        assertEq(discount.rebateOf(staker), 0, "nothing left to claim");
    }

    function test_discount_zero_share_and_below_tier_stakers_accrue_nothing() public {
        (PYDFeeDiscount discount, ProYieldVault vault, MockUSDC usdc, FeeDistributor fd) = _discountSetup();

        // a vault depositor WITH shares but below the first tier
        address belowTier = actors[1];
        vm.startPrank(belowTier);
        usdc.mint(belowTier, 1000e18);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1000e18);
        discount.stake(999e18); // tier 0
        vm.stopPrank();

        // a staker ABOVE tier but with zero vault shares
        address noShares = actors[2];
        vm.prank(noShares);
        discount.stake(100_000e18);

        usdc.mint(address(fd), 1000e18);
        discount.snapshotHarvest();

        assertEq(discount.rebateOf(belowTier), 0, "below-tier must accrue nothing");
        assertEq(discount.rebateOf(noShares), 0, "zero-share staker must accrue nothing");
    }

    function test_discount_exit_keeps_accrued_rebate_claimable() public {
        (PYDFeeDiscount discount, ProYieldVault vault, MockUSDC usdc, FeeDistributor fd) = _discountSetup();
        address staker = actors[0];

        vm.startPrank(staker);
        usdc.mint(staker, 1000e18);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1000e18);
        discount.stake(10_000e18);
        vm.stopPrank();

        usdc.mint(address(fd), 1000e18);
        discount.snapshotHarvest();
        uint256 accrued = discount.rebateOf(staker);
        assertGt(accrued, 0, "must accrue first");

        vm.prank(staker);
        discount.exit(); // full unstake
        assertEq(discount.rebateOf(staker), accrued, "exit must not erase rebates");

        usdc.mint(address(discount), accrued);
        vm.prank(staker);
        discount.claimRebate();
        assertEq(usdc.balanceOf(staker), accrued, "claim after exit failed");
    }
}
