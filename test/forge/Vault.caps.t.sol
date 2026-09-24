// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// S2 beta safety rails — deposit caps + pause (unlock plan rev 2, §2).
// Every rail is asserted at its BOUNDARY (exact-cap deposit passes; one unit
// over reverts with the message), with the exit path held open throughout:
//   - TVL cap: totalAssets-based, re-opens when funds leave
//   - per-user cap: VALUE-based (earned profit counts toward the cap)
//   - pause: blocks deposits only — withdrawals always stay open
//   - setters are owner-only; events asserted so emit-removal mutants die

import {Test} from "forge-std/Test.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {YieldStrategy} from "./Vault.invariants.t.sol";

contract VaultCapsTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    YieldStrategy s1;

    uint256 constant ONE = 1e18;
    address user1 = address(0xA11CE);
    address user2 = address(0xB0B);

    event CapsSet(uint256 tvlCap, uint256 perUserCap);
    event DepositsPausedSet(bool paused);

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        s1 = new YieldStrategy(address(usdc), address(this));
        vault.addStrategy(address(s1));
        s1.setVault(address(vault));
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
    }

    function test_defaults_uncapped_and_unpaused() public view {
        assertEq(vault.tvlCap(), 0, "tvlCap default");
        assertEq(vault.perUserCap(), 0, "perUserCap default");
        assertFalse(vault.depositsPaused(), "pause default");
    }

    function test_tvl_cap_boundary_and_reopen() public {
        vault.setCaps(1_000 * ONE, 0);
        _fund(user1, 2_000 * ONE);

        vm.prank(user1);
        vault.deposit(1_000 * ONE); // exactly at cap — passes
        assertEq(vault.totalAssets(), 1_000 * ONE);

        vm.prank(user1);
        vm.expectRevert("ProYieldVault: TVL cap reached");
        vault.deposit(1); // one wei over — reverts

        // withdrawals are unaffected by the cap, and re-open headroom
        vm.prank(user1);
        vault.withdraw(100 * ONE);
        assertEq(vault.totalAssets(), 900 * ONE);

        vm.prank(user1);
        vault.deposit(50 * ONE);
        assertEq(vault.totalAssets(), 950 * ONE);
    }

    function test_per_user_cap_boundary() public {
        vault.setCaps(0, 600 * ONE);
        _fund(user1, 2_000 * ONE);
        _fund(user2, 2_000 * ONE);

        vm.prank(user1);
        vault.deposit(600 * ONE); // exactly at per-user cap

        vm.prank(user1);
        vm.expectRevert("ProYieldVault: per-user cap reached");
        vault.deposit(1); // one wei over — reverts

        vm.prank(user2);
        vault.deposit(600 * ONE); // cap is per-user, not global

        assertEq(vault.totalAssets(), 1_200 * ONE);
    }

    function test_per_user_cap_counts_earned_value() public {
        _fund(user1, 1_000 * ONE);
        vm.prank(user1);
        vault.deposit(400 * ONE);

        // Vault earns: strategy pays 100, harvest credits net profit to the price.
        s1.fund(100 * ONE);
        vault.harvest();

        uint256 value = vault.convertToAssets(vault.shares(user1));
        assertGt(value, 400 * ONE, "profit raised the user's value");

        // Headroom set to exactly 10 — the boundary is derived at runtime.
        vault.setCaps(0, value + 10 * ONE);
        _fund(user1, 100 * ONE);

        vm.prank(user1);
        vault.deposit(10 * ONE); // fits exactly

        vm.prank(user1);
        vm.expectRevert("ProYieldVault: per-user cap reached");
        vault.deposit(1); // one wei over the value cap

        vm.prank(user1);
        vault.withdraw(100 * ONE); // exits stay open above the cap
    }

    function test_pause_blocks_deposits_not_withdrawals() public {
        _fund(user1, 1_000 * ONE);
        vm.prank(user1);
        vault.deposit(100 * ONE);

        vault.setDepositsPaused(true);

        _fund(user2, 100 * ONE);
        vm.prank(user2);
        vm.expectRevert("ProYieldVault: deposits paused");
        vault.deposit(1);

        vm.prank(user1);
        vault.withdraw(50 * ONE); // users are never trapped by a pause

        vault.setDepositsPaused(false);
        vm.prank(user2);
        vault.deposit(1 * ONE); // reopened

        assertEq(vault.totalAssets(), 51 * ONE);
    }

    function test_setters_owner_only() public {
        vm.startPrank(user1);
        vm.expectRevert();
        vault.setCaps(1, 1);
        vm.expectRevert();
        vault.setDepositsPaused(true);
        vm.stopPrank();
    }

    function test_events_emitted() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit CapsSet(10, 20);
        vault.setCaps(10, 20);

        vm.expectEmit(false, false, false, true, address(vault));
        emit DepositsPausedSet(true);
        vault.setDepositsPaused(true);
    }
}
