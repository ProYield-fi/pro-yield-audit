// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Targeted coverage for the slither-mutate survivors that the battery's
// integration suite could not kill (vault campaign, 2026-09-23):
//   - name() never asserted                      → test_name
//   - _toShares/_toAssets zero-supply branches   → test_zero_supply_conversions
//   - _feeOn's `performanceFee == 0` branch      → test_zero_performance_fee_path
//   - harvestStrategy success path + revert MESSAGES: the integration suite
//     only asserted the call reverts, and a `require(...) ==> revert()` mutant
//     still reverts — same observable, so failure-path tests cannot kill it.
//     expectRevert("message") (different revert data) + a real success path can.
// NOTE: the 4th require in harvestStrategy (`strategy != address(0)`) is
// UNREACHABLE — for address(0) the `strategies[strategy]` check fires first —
// its campaign survivor is an equivalent mutant (documented in the triage).

import {Test} from "forge-std/Test.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {YieldStrategy} from "./Vault.invariants.t.sol";

contract VaultCoverageTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    YieldStrategy s1;

    uint256 constant ONE = 1e18;

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        s1 = new YieldStrategy(address(usdc), address(this));
        vault.addStrategy(address(s1));
        s1.setVault(address(vault));
    }

    function test_name() public view {
        assertEq(vault.name(), "ProYieldVault");
    }

    function test_zero_supply_conversions() public view {
        // Before the first deposit: conversions must not revert and must be
        // exactly 1:1 (the share offset only shifts from the first deposit on).
        assertEq(vault.convertToAssets(ONE), ONE);
        assertEq(vault.convertToShares(ONE), ONE);
    }

    function test_zero_performance_fee_path() public {
        // Kills the _feeOn `performanceFee == 0 → return 0` RR mutant: with the
        // mutant, any harvest/withdraw that computes a fee reverts at fee=0.
        vault.setPerformanceFee(0);

        // harvest with fee=0: full profit credited, nothing taken.
        s1.fund(1_000 * ONE);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vault.harvest();
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 1_000 * ONE, "full profit credited with fee=0");
        assertEq(usdc.balanceOf(address(fd)), 0, "no fee taken");

        // deposit/withdraw round-trip with fee=0: exact principal back.
        usdc.mint(address(this), 100 * ONE);
        usdc.approve(address(vault), 100 * ONE);
        vault.deposit(100 * ONE);
        uint256 before = usdc.balanceOf(address(this));
        vault.withdraw(50 * ONE);
        assertEq(usdc.balanceOf(address(this)) - before, 50 * ONE, "exact principal out, zero fee");
    }

    function test_harvestStrategy_success_and_messages() public {
        // SUCCESS path — kills every `body ==> revert()` mutant in
        // harvestStrategy (lines 240-243): each one makes this revert.
        s1.fund(1_000 * ONE);
        uint256 sBefore = usdc.balanceOf(address(s1));
        uint256 vBefore = usdc.balanceOf(address(vault));
        uint256 fdBefore = usdc.balanceOf(address(fd));
        vault.harvestStrategy(address(s1));
        uint256 swept = sBefore - usdc.balanceOf(address(s1));
        assertEq(swept, 1_000 * ONE, "strategy swept its pending");
        assertEq(usdc.balanceOf(address(vault)) - vBefore, swept, "vault received the sweep");
        // harvestStrategy is a BARE sweep: no fee split, no totalAssets credit —
        // that bookkeeping lives in vault.harvest(). Operator-only tool; the
        // keeper calls vault.harvest(), so nothing strands the yield in practice
        // (if it IS used mid-cycle, the swept profit would sit as surplus).
        assertEq(usdc.balanceOf(address(fd)) - fdBefore, 0, "no fee in harvestStrategy");
        assertEq(vault.totalAssets(), 0, "no totalAssets credit in harvestStrategy");

        // Message-asserted reverts — a require->revert() mutant produces
        // DIFFERENT revert data, so these kill those mutants.
        vm.expectRevert("ProYieldVault: not a strategy");
        vault.harvestStrategy(address(0xBEEF));

        vault.setStrategyActive(address(s1), false);
        vm.expectRevert("ProYieldVault: strategy paused");
        vault.harvestStrategy(address(s1));

        vault.setStrategyActive(address(s1), true);

        vm.expectRevert("ProYieldVault: not a strategy"); // 0x0 fails the FIRST require
        vault.harvestStrategy(address(0));
    }

    function test_recall_pulls_exactly_the_shortfall() public {
        // Kills the AOR survivor in the withdraw-recall math
        // (`missing - got` -> `missing + got`, vault line ~161): with '+' the
        // recall over-pulls and the vault keeps surplus idle after paying.
        // Assert the strategy's outflow IS the shortfall, and the post-withdraw
        // idle is (near) zero.
        usdc.mint(address(this), 100_000 * ONE);
        usdc.approve(address(vault), 100_000 * ONE);
        vault.deposit(100_000 * ONE);
        s1.fund(30_000 * ONE); // recallable yield on the strategy
        vault.allocate();      // deploys reserve-excess; vault keeps RESERVE_BPS idle

        uint256 idleBeforeW = usdc.balanceOf(address(vault));
        uint256 s1BeforeW = usdc.balanceOf(address(s1));
        uint256 want = 50_000 * ONE;
        uint256 before = usdc.balanceOf(address(this));
        vault.withdraw(want);
        assertEq(usdc.balanceOf(address(this)) - before, want, "exact payout");
        uint256 expectedShortfall = want > idleBeforeW ? want - idleBeforeW : 0;
        uint256 pulled = s1BeforeW - usdc.balanceOf(address(s1));
        assertGe(pulled, expectedShortfall, "recall covered the shortfall");
        assertLe(pulled, expectedShortfall + 1, "recall pulled no more than the shortfall (+<=1 wei buffer)");
        assertLe(usdc.balanceOf(address(vault)), 1 * ONE, "no over-pull: idle drained by the payout");
    }
}