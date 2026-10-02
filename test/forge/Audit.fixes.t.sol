// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MorphoStrategy} from "../../contracts/MorphoStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockMorpho} from "../../contracts/mocks/MockMorpho.sol";

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
}