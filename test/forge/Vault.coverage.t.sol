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
import {Vm} from "forge-std/Vm.sol";
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

    // ── Round-2 killers: survivors of the FULL vault campaign (61 tweak
    // mutants). Earlier passes ran with a single strategy and only EOA
    // callers, which left whole condition families alive. ──

    /// Kills `strategies[s] && strategyActive[s]` → `||` (line 193) and the
    /// block-level rewrite of the same `if`: with `||` a REGISTERED-but-PAUSED
    /// strategy is still swept, defeating the per-strategy circuit breaker.
    function test_harvest_skips_paused_strategy() public {
        YieldStrategy s2 = new YieldStrategy(address(usdc), address(this));
        vault.addStrategy(address(s2));
        s2.setVault(address(vault));
        s1.fund(500 * ONE);
        s2.fund(700 * ONE);
        vault.setStrategyActive(address(s2), false); // paused

        uint256 s2Before = usdc.balanceOf(address(s2));
        uint256 vBefore = usdc.balanceOf(address(vault));
        vault.harvest();
        assertEq(usdc.balanceOf(address(s2)), s2Before, "paused strategy must not be swept");
        // Only s1's 500 arrives, net of the performance fee the vault routes out.
        uint256 grossProfit = 500 * ONE;
        uint256 fee = (grossProfit * vault.performanceFee()) / 10000;
        assertEq(
            usdc.balanceOf(address(vault)) - vBefore,
            grossProfit - fee,
            "only the active strategy's profit, net of fee"
        );
    }

    /// Kills the recall loop `missing > 0` → `>= 0` (line 155): with `>= 0` the
    /// loop keeps recalling from LATER strategies after the shortfall is covered.
    function test_recall_never_over_pulls_past_the_shortfall() public {
        YieldStrategy s2 = new YieldStrategy(address(usdc), address(this));
        YieldStrategy s3 = new YieldStrategy(address(usdc), address(this));
        vault.addStrategy(address(s2));
        vault.addStrategy(address(s3));
        s2.setVault(address(vault));
        s3.setVault(address(vault));

        usdc.mint(address(this), 100_000 * ONE);
        usdc.approve(address(vault), 100_000 * ONE);
        vault.deposit(100_000 * ONE);
        vault.allocate(); // 10% reserve stays idle → all three strategies funded
        usdc.mint(address(s1), 30_000 * ONE); // recall depth
        usdc.mint(address(s2), 30_000 * ONE);
        usdc.mint(address(s3), 30_000 * ONE);

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 want = idle + 3; // a 3-wei shortfall
        uint256 b1 = usdc.balanceOf(address(s1));
        uint256 b2 = usdc.balanceOf(address(s2));
        uint256 b3 = usdc.balanceOf(address(s3));
        vault.withdraw(want);
        uint256 pulled = (b1 - usdc.balanceOf(address(s1)))
            + (b2 - usdc.balanceOf(address(s2)))
            + (b3 - usdc.balanceOf(address(s3)));
        assertGe(pulled, 3, "shortfall covered");
        assertLe(pulled, 4, "never pulls beyond the shortfall (+<=1 wei round-up)");
    }

    /// Kills `lastHarvest = block.timestamp` → `= 0` (line 214).
    function test_harvest_stamps_lastHarvest() public {
        vm.warp(1_800_000_000);
        s1.fund(100 * ONE);
        vault.harvest();
        assertEq(vault.lastHarvest(), 1_800_000_000, "lastHarvest must stamp the current block time");
    }

    /// Kills `if (fee > 0)` → `>= 0` (line 207): a harvest whose fee floors to
    /// zero must move nothing — the mutant emits a 0-value Transfer to the FD.
    function test_harvest_takes_no_zero_value_fee_transfer() public {
        vault.setPerformanceFee(1000); // 10% → fee = 9*1000/10000 = 0
        s1.fund(9);
        vm.recordLogs();
        vault.harvest();
        assertEq(_transfersTo(vm.getRecordedLogs(), address(fd)), 0, "no zero-value fee transfer");
    }

    /// Kills `perStrategy > 0` → `>= 0` (line 132): with `>= 0` the vault makes a
    /// 0-value transfer to EVERY active strategy when the slice floors to zero.
    function test_allocate_no_zero_value_transfers() public {
        YieldStrategy s2 = new YieldStrategy(address(usdc), address(this));
        YieldStrategy s3 = new YieldStrategy(address(usdc), address(this));
        vault.addStrategy(address(s2));
        vault.addStrategy(address(s3));
        s2.setVault(address(vault));
        s3.setVault(address(vault));

        usdc.mint(address(this), 2); // deployable 2 wei across 3 strategies → 0 each
        usdc.approve(address(vault), 2);
        vault.deposit(2);

        vm.recordLogs();
        vault.allocate();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_transfersTo(logs, address(s1)), 0, "no zero-value transfer to s1");
        assertEq(_transfersTo(logs, address(s2)), 0, "no zero-value transfer to s2");
        assertEq(_transfersTo(logs, address(s3)), 0, "no zero-value transfer to s3");
    }

    /// Kills the msg.sender→tx.origin family (line 97 Deposit emit, line 109
    /// emergencyWithdraw transfer, line 183 Withdraw emit): with a CONTRACT
    /// caller msg.sender != tx.origin, so each mutant names or pays the wrong party.
    function test_contract_callers_use_msg_sender_not_tx_origin() public {
        VaultActor actor = new VaultActor();
        ProYieldVault v2 = new ProYieldVault(address(usdc), address(actor), address(fd));
        usdc.mint(address(actor), 1_000 * ONE);
        address origin = tx.origin;

        vm.recordLogs();
        actor.depositInto(v2, usdc, 100 * ONE);
        assertTrue(
            _eventNames(vm.getRecordedLogs(), DEPOSIT_TOPIC, address(actor)),
            "Deposit must name the calling contract"
        );

        vm.recordLogs();
        actor.withdrawFrom(v2, 50 * ONE);
        assertTrue(
            _eventNames(vm.getRecordedLogs(), WITHDRAW_TOPIC, address(actor)),
            "Withdraw must name the calling contract"
        );

        uint256 actorBefore = usdc.balanceOf(address(actor));
        uint256 originBefore = usdc.balanceOf(origin);
        actor.emergency(v2);
        assertGt(usdc.balanceOf(address(actor)), actorBefore, "caller contract got the emergency payout");
        assertEq(usdc.balanceOf(origin), originBefore, "tx.origin must receive nothing");
    }

    // ── log helpers (only observable difference for zero-value-transfer mutants) ──
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 constant DEPOSIT_TOPIC = keccak256("Deposit(address,uint256)");
    bytes32 constant WITHDRAW_TOPIC = keccak256("Withdraw(address,uint256)");

    function _transfersTo(Vm.Log[] memory logs, address to) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER_TOPIC
                && address(uint160(uint256(logs[i].topics[2]))) == to) n++;
        }
    }

    function _eventNames(Vm.Log[] memory logs, bytes32 topic, address who) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic
                && address(uint160(uint256(logs[i].topics[1]))) == who) return true;
        }
        return false;
    }
}

/// Minimal contract caller: every vault interaction is made BY a contract, so
/// msg.sender != tx.origin on every path — the blind spot of the tx.origin family.
contract VaultActor {
    function depositInto(ProYieldVault v, MockUSDC u, uint256 amt) external {
        u.approve(address(v), amt);
        v.deposit(amt);
    }

    function withdrawFrom(ProYieldVault v, uint256 amt) external {
        v.withdraw(amt);
    }

    function emergency(ProYieldVault v) external {
        v.emergencyWithdraw();
    }
}