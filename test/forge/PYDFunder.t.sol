// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// PYDFunder unit tests — the 0.0% coverage gap flagged in
// INTERNAL_TOOLS_ROUND §3 ("dormant but funds-touching — unit-test before any
// activation"). Covers every guard, the F-8 rate-freeze fix, the balance-delta
// conversion accounting, the allowance-revocation discipline, and the
// reentrancy surface via a re-entering swapper.
//
// Run: forge test --match-path 'test/forge/PYDFunder.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {PYDFunder} from "../../contracts/PYDFunder.sol";
import {PYDToken} from "../../contracts/PYDToken.sol";
import {PYDStaking} from "../../contracts/PYDStaking.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockSwapper} from "../../contracts/mocks/MockSwapper.sol";

/// Swapper with exact output control (for the NoOutput / ZeroRate paths) plus
/// a reentrancy probe: every swap tries to re-enter funder.topUp and records
/// whether the guard reverted the inner call.
contract ConfigurableSwapper {
    MockUSDC public immutable usdcIn;
    PYDToken public immutable pyd;
    PYDFunder public immutable funder;
    uint256 public nextOut;
    bool public reentryBlocked;

    constructor(address pyd_, address usdc_, address funder_) {
        pyd = PYDToken(pyd_);
        usdcIn = MockUSDC(usdc_);
        funder = PYDFunder(funder_);
    }

    function setNextOut(uint256 out) external {
        nextOut = out;
    }

    function swap(address, address, uint256 amountIn, uint256) external returns (uint256) {
        usdcIn.transferFrom(msg.sender, address(this), amountIn);
        try funder.topUp(amountIn, 1 days) {
            revert("reentrancy guard DID NOT fire");
        } catch {
            reentryBlocked = true; // nonReentrant reverted the inner call
        }
        uint256 out = nextOut;
        if (out > 0) pyd.transfer(msg.sender, out);
        return out;
    }
}

contract PYDFunderTest is Test {
    PYDToken pyd;
    MockUSDC usdc;
    PYDStaking staking;
    PYDFunder funder;
    MockSwapper swapper;
    ConfigurableSwapper cfgSwapper;

    address stranger = makeAddr("stranger");

    uint256 constant DUST = 10e6; // minConvertUsd6 default
    uint256 constant DAY = 1 days;

    bytes4 constant E_ZEROADDR = bytes4(keccak256("PYDFunder__ZeroAddresses()"));
    bytes4 constant E_ZEROSWAP = bytes4(keccak256("PYDFunder__ZeroSwapper()"));
    bytes4 constant E_ZEROAMT = bytes4(keccak256("PYDFunder__ZeroAmount()"));
    bytes4 constant E_DUST = bytes4(keccak256("PYDFunder__BelowDust()"));
    bytes4 constant E_PAUSED = bytes4(keccak256("PYDFunder__Paused()"));
    bytes4 constant E_NOOUT = bytes4(keccak256("PYDFunder__NoOutput()"));
    bytes4 constant E_SHORT = bytes4(keccak256("PYDFunder__DurationTooShort()"));
    bytes4 constant E_LONG = bytes4(keccak256("PYDFunder__DurationTooLong()"));
    bytes4 constant E_ZERORATE = bytes4(keccak256("PYDFunder__ZeroRate()"));

    function setUp() public {
        pyd = new PYDToken(1_000_000); // 1M PYD here (constructor scales 1e18)
        staking = new PYDStaking(address(pyd));
        usdc = new MockUSDC();
        funder = new PYDFunder(address(usdc), address(staking), address(this));
        swapper = new MockSwapper(address(pyd), address(usdc));
        cfgSwapper = new ConfigurableSwapper(address(pyd), address(usdc), address(funder));

        // the funder must own staking to call fundRewards (one-step OZ v5)
        staking.transferOwnership(address(funder));
        // stock both swappers with PYD to hand out
        pyd.transfer(address(swapper), 500_000e18);
        pyd.transfer(address(cfgSwapper), 500_000e18);

        funder.setSwapper(address(swapper));
        usdc.mint(address(funder), 1000e6); // conversion fuel
    }

    /*//////////////////// Constructor + admin ////////////////////*/

    function test_constructor_zero_addresses_revert() public {
        vm.expectRevert(E_ZEROADDR);
        new PYDFunder(address(0), address(staking), address(this));
        vm.expectRevert(E_ZEROADDR);
        new PYDFunder(address(usdc), address(0), address(this));
    }

    function test_constructor_sets_immutables() public {
        assertEq(address(funder.usdc()), address(usdc));
        assertEq(address(funder.staking()), address(staking));
        assertEq(funder.maxConvertUsd6(), 1000e6);
        assertEq(funder.minConvertUsd6(), 10e6);
        assertFalse(funder.paused());
    }

    function test_setSwapper_zero_reverts() public {
        vm.expectRevert(E_ZEROSWAP);
        funder.setSwapper(address(0));
    }

    function test_setSwapper_onlyOwner_and_event() public {
        vm.prank(stranger);
        vm.expectRevert();
        funder.setSwapper(address(cfgSwapper));

        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.SwapperSet(address(cfgSwapper));
        funder.setSwapper(address(cfgSwapper));
        assertEq(address(funder.swapper()), address(cfgSwapper));
    }

    function test_setMaxConvertUsd6_onlyOwner_and_event() public {
        vm.prank(stranger);
        vm.expectRevert();
        funder.setMaxConvertUsd6(1);

        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.MaxConvertSet(50e6);
        funder.setMaxConvertUsd6(50e6);
        assertEq(funder.maxConvertUsd6(), 50e6);
    }

    function test_setPaused_gates_topUp_and_emits() public {
        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.PausedSet(true);
        funder.setPaused(true);
        vm.expectRevert(E_PAUSED);
        funder.topUp(100e6, 7 * DAY);
        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.PausedSet(false);
        funder.setPaused(false);
    }

    /*//////////////////// Reconciliation reads ////////////////////*/

    function test_receiveUsdc_emits_only_when_funded() public {
        // zero balance → succeeds with NO event at all
        PYDFunder fresh = new PYDFunder(address(usdc), address(staking), address(this));
        vm.recordLogs();
        fresh.receiveUsdc();
        assertEq(vm.getRecordedLogs().length, 0);
        // funded → emits the CURRENT balance (mirrors FD.receiveFees semantics)
        usdc.mint(address(funder), 5e6); // funder already holds 1000e6
        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.UsdcReceived(1005e6);
        funder.receiveUsdc();
    }

    function test_pendingUsdc_tracks_balance() public {
        assertEq(funder.pendingUsdc(), 1000e6);
        usdc.mint(address(funder), 1);
        assertEq(funder.pendingUsdc(), 1000e6 + 1);
    }

    /*//////////////////// topUp: guard ladder ////////////////////*/

    function test_topUp_guards_in_order() public {
        // no swapper configured (fresh funder)
        PYDFunder fresh = new PYDFunder(address(usdc), address(staking), address(this));
        usdc.mint(address(fresh), 100e6);
        vm.expectRevert(E_ZEROSWAP);
        fresh.topUp(100e6, 7 * DAY);

        // amount guards
        vm.expectRevert(E_ZEROAMT);
        funder.topUp(0, 7 * DAY);
        vm.expectRevert(E_DUST);
        funder.topUp(DUST - 1, 7 * DAY);

        // duration bounds (F-8 family)
        vm.expectRevert(E_SHORT);
        funder.topUp(100e6, DAY - 1);
        vm.expectRevert(E_LONG);
        funder.topUp(100e6, 365 * DAY + 1);
    }

    /*//////////////////// topUp: capping + balance limits ////////////////////*/

    function test_topUp_caps_at_maxConvert() public {
        funder.setMaxConvertUsd6(50e6);
        _expectHappy(50e6, 7 * DAY); // requests 100e6 → converts the 50e6 cap
        funder.topUp(100e6, 7 * DAY);
        assertEq(usdc.balanceOf(address(funder)), 1000e6 - 50e6);
    }

    function test_topUp_balance_below_dust_reverts() public {
        // balance 8e6 < dust 10e6 → the balance-clamped cap reverts BEFORE any
        // swap or stream interaction (no staking wiring needed)
        PYDFunder poor = new PYDFunder(address(usdc), address(staking), address(this));
        usdc.mint(address(poor), 8e6);
        poor.setSwapper(address(swapper));
        vm.expectRevert(E_DUST);
        poor.topUp(100e6, 7 * DAY);
    }

    function test_topUp_converts_only_what_balance_allows() public {
        funder.setMaxConvertUsd6(5000e6); // lift the cap so the BALANCE clamps
        usdc.mint(address(funder), 30e6); // balance now 1030e6; request 2_000e6
        _expectHappy(1030e6, 7 * DAY);
        funder.topUp(2_000e6, 7 * DAY);
        assertEq(usdc.balanceOf(address(funder)), 0); // everything converted
    }

    /*//////////////////// topUp: F-8 rate-freeze family ////////////////////*/

    function test_topUp_no_output_reverts() public {
        funder.setSwapper(address(cfgSwapper));
        cfgSwapper.setNextOut(0);
        vm.expectRevert(E_NOOUT);
        funder.topUp(100e6, 7 * DAY);
    }

    function test_topUp_rate_floored_to_zero_reverts() public {
        funder.setSwapper(address(cfgSwapper));
        // pydOut = duration - 1 → pydOut / duration == 0 → permanent-freeze shape
        cfgSwapper.setNextOut(7 * DAY - 1);
        vm.expectRevert(E_ZERORATE);
        funder.topUp(100e6, 7 * DAY);
    }

    /*//////////////////// topUp: happy paths ////////////////////*/

    function _expectHappy(uint256 cap, uint256 duration) internal {
        uint256 pydOut = cap * 1e12; // MockSwapper: 6dp in → 18dec out, ×1e12
        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.Converted(address(swapper), cap, 0); // pre-call emit
        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.Converted(address(swapper), cap, pydOut); // measured emit
        vm.expectEmit(true, true, true, true, address(funder));
        emit PYDFunder.StreamFunded(pydOut, duration);
    }

    function test_topUp_happy_path_full_accounting() public {
        _expectHappy(100e6, 7 * DAY);
        funder.topUp(100e6, 7 * DAY);

        assertEq(usdc.balanceOf(address(funder)), 900e6); // 100e6 drained
        assertEq(usdc.balanceOf(address(swapper)), 100e6); // swapper holds it
        assertEq(pyd.balanceOf(address(staking)), 100e6 * 1e12); // stream funded
        assertEq(pyd.balanceOf(address(funder)), 0); // nothing stranded
        // allowance discipline: the swapper must NEVER keep a live approval
        assertEq(usdc.allowance(address(funder), address(swapper)), 0);
        assertEq(pyd.allowance(address(funder), address(staking)), 0);
    }

    function test_topUp_is_permissionless() public {
        _expectHappy(100e6, 7 * DAY);
        vm.prank(stranger); // no trust needed — caps + swapper hold policy
        funder.topUp(100e6, 7 * DAY);
        assertEq(pyd.balanceOf(address(staking)), 100e6 * 1e12);
    }

    function test_topUp_exact_duration_bounds_pass() public {
        _expectHappy(100e6, DAY);
        funder.topUp(100e6, DAY); // exactly 1 day
        usdc.mint(address(funder), 100e6);
        _expectHappy(100e6, 365 * DAY);
        funder.topUp(100e6, 365 * DAY); // exactly 1 year
    }

    /*//////////////////// Reentrancy ////////////////////*/

    function test_topUp_reentrancy_guard_blocks_inner_call() public {
        funder.setSwapper(address(cfgSwapper));
        cfgSwapper.setNextOut(100e6 * 1e12);
        funder.topUp(100e6, 7 * DAY);
        assertTrue(cfgSwapper.reentryBlocked(), "inner topUp must revert");
        // exactly ONE stream funded — the reentered call never ran
        assertEq(pyd.balanceOf(address(staking)), 100e6 * 1e12);
    }
}
