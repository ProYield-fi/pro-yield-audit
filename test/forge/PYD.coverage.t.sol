// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Targeted coverage for the PYD campaign survivors (slither-mutate, 2026-09-23).
// Classified buckets → kills:
//   - PYDStaking.withdraw() path entirely untested  → test_withdraw_path
//   - rollover math (remaining*rate leftover)       → test_rollover_math_exact
//   - reward accumulator `+=` (claimed between)     → test_accrual_accumulates
//   - constructor zero guards, setTiers boundaries,
//     unstake boundaries, metadata/views            → the *_boundary tests
//   - tx.origin-vs-msg.sender mutants (EOA-only
//     test method artifact)                         → test_contract_callers
// Equivalent/boundary-only survivors are documented in AUDIT_SCOPE §5.

import {Test} from "forge-std/Test.sol";
import {PYDToken} from "../../contracts/PYDToken.sol";
import {PYDStaking} from "../../contracts/PYDStaking.sol";
import {PYDFeeDiscount} from "../../contracts/PYDFeeDiscount.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";

contract PYDCoverageTest is Test {
    PYDToken pyd;
    PYDStaking staking;
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    PYDFeeDiscount discount;
    uint256 constant ONE = 1e18;

    function setUp() public {
        pyd = new PYDToken(1_000_000);
        staking = new PYDStaking(address(pyd));
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        discount = new PYDFeeDiscount(address(pyd), address(usdc), address(fd), address(vault), address(this));
        pyd.approve(address(staking), type(uint256).max);
        pyd.approve(address(discount), type(uint256).max);
    }

    // ── staking.withdraw() path (kills RR 91-98: entire path untested) ──
    function test_withdraw_path() public {
        staking.stake(1_000 * ONE);
        uint256 balBefore = pyd.balanceOf(address(this));
        staking.withdraw(400 * ONE); // partial
        assertEq(staking.stakeAmount(address(this)), 600 * ONE, "partial decrements");
        assertEq(pyd.balanceOf(address(this)) - balBefore, 400 * ONE, "principal returned");
        vm.expectRevert("PYDStaking: insufficient stake");
        staking.withdraw(601 * ONE);
        staking.withdraw(600 * ONE); // exact-full (kills the >= → > boundary)
        assertEq(staking.stakeAmount(address(this)), 0, "full withdraw zeroes");
        assertEq(staking.totalSupply(), 0, "totalSupply zeroes");
        vm.expectRevert("PYDStaking: amount is 0");
        staking.withdraw(0);
    }

    function test_withdraw_then_claim_keeps_accrual() public {
        staking.stake(2_000 * ONE);
        staking.fundRewards(10_000 * ONE, 10 days);
        vm.warp(block.timestamp + 5 days);
        staking.withdraw(1_000 * ONE);
        uint256 b = pyd.balanceOf(address(this));
        staking.getReward();
        assertGt(pyd.balanceOf(address(this)) - b, 0, "rewards claimable after withdraw");
        assertEq(staking.rewards(address(this)), 0, "rewards ledger cleared on claim");
    }

    // ── rollover math exactness (kills AOR 68-70, LOR 47) ──
    function test_rollover_math_exact() public {
        uint256 A1 = 10_000 * ONE;
        uint256 D1 = 10 days;
        staking.fundRewards(A1, D1);
        assertEq(staking.rewardRate(), A1 / D1, "initial rate = amount/duration");
        vm.warp(block.timestamp + 4 days);
        uint256 remaining = staking.periodFinish() - block.timestamp;
        uint256 rate1 = staking.rewardRate();
        uint256 A2 = 6_000 * ONE;
        uint256 D2 = 12 days;
        staking.fundRewards(A2, D2);
        assertEq(staking.rewardRate(), (A2 + remaining * rate1) / D2, "rate = (new + leftover)/duration");
        assertEq(staking.periodFinish(), block.timestamp + D2, "window restarts");
        vm.expectRevert("PYDStaking: zero");
        staking.fundRewards(1_000 * ONE, 0);
    }

    // ── reward accumulator adds (kills ASOR 164 = / |= / ^=) ──
    function test_accrual_accumulates_across_touches() public {
        staking.stake(1_000 * ONE);
        staking.fundRewards(10_000 * ONE, 10 days);
        vm.warp(block.timestamp + 3 days);
        staking.stake(1_000 * ONE); // touch #1 → accrual
        uint256 r1 = staking.rewards(address(this));
        uint256 u1 = staking.userRewardPerTokenPaid(address(this));
        assertGt(r1, 0, "first accrual nonzero");
        vm.warp(block.timestamp + 3 days);
        uint256 sPre = staking.stakeAmount(address(this));
        staking.stake(1_000 * ONE); // touch #2 → accrual ON TOP
        uint256 r2 = staking.rewards(address(this));
        uint256 u2 = staking.userRewardPerTokenPaid(address(this));
        assertEq(r2, r1 + (sPre * (u2 - u1)) / ONE, "second accrual ADDS to the first");
    }

    function _pair(uint256 threshold, uint256 bps) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = threshold;
        p[1] = bps;
    }

    // ── constructor zero guards (kills LOR 73) ──
    function test_discount_constructor_zero_guards() public {
        vm.expectRevert();
        new PYDFeeDiscount(address(0), address(usdc), address(fd), address(vault), address(this));
        vm.expectRevert();
        new PYDFeeDiscount(address(pyd), address(0), address(fd), address(vault), address(this));
        vm.expectRevert();
        new PYDFeeDiscount(address(pyd), address(usdc), address(0), address(vault), address(this));
        vm.expectRevert();
        new PYDFeeDiscount(address(pyd), address(usdc), address(fd), address(0), address(this));
    }

    // ── setTiers boundaries: equal thresholds revert; exactly-MAX bps allowed
    //    (kills ROR 103 `<= → <` and ROR 104 `> → >=`) ──
    function test_settiers_boundaries() public {
        uint256[][] memory eq = new uint256[][](2);
        eq[0] = _pair(1_000e18, 500);
        eq[1] = _pair(1_000e18, 500); // EQUAL threshold → must revert
        vm.expectRevert(PYDFeeDiscount.PYDFee__BadTier.selector);
        discount.setTiers(eq);
        uint256[][] memory cap = new uint256[][](1);
        cap[0] = _pair(1_000e18, 4000); // exactly MAX_TIER_BPS → allowed
        discount.setTiers(cap);
        assertEq(discount.tiers(0, 1), 4000, "cap tier accepted");
    }

    // ── snapshot below lastFeeSnapshot is a clean no-op (kills ROR 171 `<`);
    //    also exercises the totalShares==0 emit path (kills RR 183) and both
    //    lastSnapshotAt update sites (kills SBR 174/179) ──
    function test_snapshot_noop_paths() public {
        usdc.mint(address(fd), 1_000e18);
        discount.snapshotHarvest(); // vault has 0 shares → emit + return
        uint256 snap = discount.lastFeeSnapshot();
        assertEq(snap, 1_000e18, "snapshot took the balance");
        assertEq(discount.lastSnapshotAt(), block.timestamp, "empty-vault snapshot timestamp recorded");
        fd.route(address(vault), 400e18); // fees routed out → balance < snapshot
        assertLt(usdc.balanceOf(address(fd)), snap);
        discount.snapshotHarvest(); // must NOT underflow: <= guard no-ops
        assertEq(discount.lastFeeSnapshot(), snap, "no snapshot below the balance");
        // main accrual path: deposit shares + stake, new fees, snapshot again
        usdc.mint(address(this), 10_000e18);
        usdc.approve(address(vault), 10_000e18);
        vault.deposit(10_000e18);
        discount.stake(1_000 * ONE);
        usdc.mint(address(fd), 500e18);
        vm.warp(block.timestamp + 1 hours);
        discount.snapshotHarvest();
        assertEq(discount.lastSnapshotAt(), block.timestamp, "main-path snapshot timestamp recorded");
        assertGt(discount.rebateOf(address(this)), 0, "staker accrued from the delta");
    }

    // ── metadata + views (kills RR 42 name, RR 248 stakerCount, RR 225) ──
    function test_name_counts_budget() public {
        assertEq(staking.name(), "PYDStaking");
        assertEq(discount.stakerCount(), 0, "no discount stakers yet");
        discount.stake(1_000 * ONE);
        assertEq(discount.stakerCount(), 1, "discount staker counted");
        usdc.mint(address(discount), 1_000e18);
        discount.receiveBudget(); // budget path (emit not reverted)
    }

    // ── contract callers: msg.sender semantics (kills the ~15 tx.origin SBR
    //    mutants across staking stake/withdraw/getReward and discount
    //    stake/unstake/exit/claim) ──
    function test_contract_callers() public {
        CallingContract c = new CallingContract(pyd, staking, discount, usdc, vault);
        pyd.transfer(address(c), 100_000 * ONE);

        // staking side
        c.stakeS(2_000 * ONE);
        assertEq(staking.stakeAmount(address(c)), 2_000 * ONE, "stake credited to caller");
        c.withdrawS(500 * ONE);
        assertEq(staking.stakeAmount(address(c)), 1_500 * ONE, "withdraw debits the caller");
        staking.fundRewards(10_000 * ONE, 10 days);
        vm.warp(block.timestamp + 5 days);
        uint256 cBal = pyd.balanceOf(address(c));
        c.claimS();
        assertGt(pyd.balanceOf(address(c)) - cBal, 0, "rewards paid to the caller");

        // discount side
        c.depositV(20_000e18); // vault shares so the caller accrues rebates
        c.stakeD(2_000 * ONE);
        assertEq(discount.stakedBy(address(c)), 2_000 * ONE, "discount stake debited to caller");
        c.unstakeD(500 * ONE);
        assertEq(discount.stakedBy(address(c)), 1_500 * ONE, "discount unstake debits the caller");
        usdc.mint(address(fd), 3_000_000e18);
        discount.snapshotHarvest();
        usdc.mint(address(discount), discount.rebateOf(address(c))); // budget cover
        uint256 cUsdc = usdc.balanceOf(address(c));
        c.claimD();
        assertGt(usdc.balanceOf(address(c)) - cUsdc, 0, "rebate paid to the caller");
        c.exitD();
        assertEq(discount.stakedBy(address(c)), 0, "exit zeroes the caller");
    }

    // ⟪TESTS-APPEND-HERE⟫
}

/// Calls the contracts from a CONTRACT (msg.sender != tx.origin) so the
/// `msg.sender → tx.origin` mutants cannot hide behind EOA-only tests.
contract CallingContract {
    PYDToken private immutable p;
    PYDStaking private immutable s;
    PYDFeeDiscount private immutable d;
    MockUSDC private immutable u;
    ProYieldVault private immutable v;

    constructor(PYDToken p_, PYDStaking s_, PYDFeeDiscount d_, MockUSDC u_, ProYieldVault v_) {
        p = p_;
        s = s_;
        d = d_;
        u = u_;
        v = v_;
        p_.approve(address(s_), type(uint256).max);
        p_.approve(address(d_), type(uint256).max);
        u_.approve(address(v_), type(uint256).max);
    }

    function stakeS(uint256 a) external { s.stake(a); }
    function withdrawS(uint256 a) external { s.withdraw(a); }
    function claimS() external { s.getReward(); }
    function stakeD(uint256 a) external { d.stake(a); }
    function unstakeD(uint256 a) external { d.unstake(a); }
    function exitD() external { d.exit(); }
    function claimD() external { d.claimRebate(); }
    function depositV(uint256 a) external { u.mint(address(this), a); v.deposit(a); }
}
