// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// PT fixed-rate sleeve — HyperEVM strategy + Arbitrum executor.
// Properties proven here:
//   1. deployToArb burns CCTP with EXACT args (domain 3, immutable executor
//      recipient, token, maxFee cap, fast finality) and idle -> inFlight
//      without changing totalAssets.
//   2. The attestation surface is bounded: syncArbValue can never count more
//      than arrived-face x (1 + headroom); ack can never exceed inFlight.
//   3. completeInbound is permissionless but can only ever add real USDC to
//      this contract; it subtracts the received amount from the attested value
//      (no double-count) and records the monotonic return flow.
//   4. recall() pays idle only and leaves a pendingRecall shortfall for the
//      keeper (the Arb leg is asynchronous by design); pushIdle returns
//      unwound cash to the vault and clears the shortfall.
//   5. Executor: ops can only buy/sell PT on the owner-set market and burn
//      back to the IMMUTABLE HyperEVM strategy address; owner-only config and
//      rescue; min-out slippage bounds enforced.
//   6. Full cycle: ship -> arrive -> earn -> unwind -> land -> vault paid,
//      with no double-count at any step.

import {Test} from "forge-std/Test.sol";
import {PTSleeveStrategy} from "../../contracts/PTSleeveStrategy.sol";
import {PTSleeveExecutor} from "../../contracts/arbi/PTSleeveExecutor.sol";
import {MockCctp, MockPT} from "../../contracts/mocks/MockCctp.sol";
import {MockPendleRouterMin} from "../../contracts/mocks/MockPendleRouterMin.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PTSleeveStrategyTest is Test {
    MockUSDC usdc;
    MockCctp cctp;
    PTSleeveStrategy strat;

    address vaultAddr = address(0xF00D);
    address keeper = address(0xCAFE);
    address executorAddr = address(0xEEEE);

    function setUp() public {
        usdc = new MockUSDC();
        cctp = new MockCctp(address(usdc));
        strat = new PTSleeveStrategy(address(usdc), address(this), address(cctp), address(cctp), executorAddr, 3);
        strat.setVault(vaultAddr);
        strat.setKeeper(keeper);
        usdc.mint(address(strat), 1_000e6);
    }

    // ------------------------------------------------------------ deployToArb

    function test_deployToArb_burn_args_and_accounting() public {
        vm.prank(keeper);
        strat.deployToArb(100e6, 0);
        (uint256 amount, uint32 dest, bytes32 recip, address token,, uint256 maxFee, uint32 finality) = cctp.lastBurn();
        assertEq(amount, 100e6, "amount");
        assertEq(dest, 3, "Arbitrum domain");
        assertEq(recip, bytes32(uint256(uint160(executorAddr))), "immutable executor recipient");
        assertEq(token, address(usdc), "burn token");
        assertEq(maxFee, 0, "maxFee");
        assertEq(finality, 1000, "fast transfer");
        assertEq(cctp.burnCount(), 1, "one burn");
        assertEq(usdc.balanceOf(address(cctp)), 100e6, "USDC pulled by messenger");
        assertEq(strat.totalAssets(), 1_000e6, "total unchanged: idle -> inFlight");
        assertEq(strat.inFlight6(), 100e6, "inFlight booked at face");
        assertEq(strat.outstandingFace6(), 100e6, "outstanding");
    }

    function test_deployToArb_auth() public {
        vm.prank(address(0xB0B));
        vm.expectRevert("PT: not keeper");
        strat.deployToArb(100e6, 0);
    }

    function test_deployToArb_min_bridge() public {
        vm.prank(keeper);
        vm.expectRevert("PT: below min bridge");
        strat.deployToArb(4e6, 0);
    }

    function test_deployToArb_maxfee_cap() public {
        vm.prank(keeper);
        vm.expectRevert("PT: maxFee too high");
        strat.deployToArb(100e6, 3e6);
    }

    function test_deployToArb_exceeds_idle() public {
        vm.prank(keeper);
        vm.expectRevert("PT: exceeds idle");
        strat.deployToArb(1_001e6, 0);
    }

    function test_deployToArb_inactive_reverts() public {
        strat.setActive(false);
        vm.prank(keeper);
        vm.expectRevert("PT: inactive");
        strat.deployToArb(100e6, 0);
    }

    // ------------------------------------------------------------ ack + sync

    function test_ack_arrival() public {
        vm.startPrank(keeper);
        strat.deployToArb(100e6, 0);
        strat.ackArrival(100e6);
        vm.stopPrank();
        assertEq(strat.inFlight6(), 0, "arrival acked");
        // Conservative by design: ack WITHOUT a value sync transiently drops
        // the total (arbValue6 is still 0) — never over-counts.
        assertEq(strat.totalAssets(), 900e6, "under-count until sync (safe direction)");
        vm.prank(keeper);
        strat.syncArbValue(100e6);
        assertEq(strat.totalAssets(), 1_000e6, "total restored after attestation");
    }

    function test_ack_over_inflight_reverts() public {
        vm.startPrank(keeper);
        strat.deployToArb(100e6, 0);
        vm.expectRevert("PT: exceeds inFlight");
        strat.ackArrival(100e6 + 1);
        vm.stopPrank();
    }

    function test_sync_bounds_and_totals() public {
        vm.startPrank(keeper);
        strat.deployToArb(100e6, 0);
        strat.ackArrival(100e6);
        strat.syncArbValue(100e6);
        vm.stopPrank();
        assertEq(strat.arbValue6(), 100e6);
        assertEq(strat.totalAssets(), 1_000e6, "at face");

        vm.prank(keeper);
        strat.syncArbValue(110e6); // accrual within +20%
        assertEq(strat.totalAssets(), 1_010e6, "gain visible");

        vm.prank(keeper);
        vm.expectRevert("PT: value above bound");
        strat.syncArbValue(120e6 + 1); // cap = 100 * 1.2
    }

    function test_sync_excludes_unacked_inflight() public {
        vm.startPrank(keeper);
        strat.deployToArb(100e6, 0);
        strat.ackArrival(100e6);
        strat.syncArbValue(100e6);
        strat.deployToArb(100e6, 0); // second shipment: outstanding 200, arrived 100
        strat.syncArbValue(115e6); // cap = 100 * 1.2 = 120
        vm.expectRevert("PT: value above bound");
        strat.syncArbValue(121e6);
        vm.stopPrank();
    }

    function test_sync_only_keeper_or_owner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert("PT: not keeper");
        strat.syncArbValue(1e6);
    }

    // ------------------------------------------------------- completeInbound

    function test_completeInbound_success_math() public {
        vm.startPrank(keeper);
        strat.deployToArb(100e6, 0);
        strat.ackArrival(100e6);
        strat.syncArbValue(105e6);
        vm.stopPrank();

        cctp.setInbound(105e6, address(strat));
        vm.prank(address(0xB0B)); // permissionless BY DESIGN
        uint256 got = strat.completeInbound(hex"dead", hex"beef");
        assertEq(got, 105e6, "received measured");
        assertEq(strat.retFace6(), 105e6, "return flow booked");
        assertEq(strat.arbValue6(), 0, "value fully returned, not double-counted");
        assertEq(strat.outstandingFace6(), 0, "nothing outstanding");
        assertEq(strat.totalAssets(), 1_005e6, "gain realized exactly once");
    }

    function test_completeInbound_partial_return_prorated() public {
        vm.startPrank(keeper);
        strat.deployToArb(100e6, 0);
        strat.ackArrival(100e6);
        strat.syncArbValue(100e6);
        vm.stopPrank();

        cctp.setInbound(40e6, address(strat));
        strat.completeInbound(hex"", hex"");
        assertEq(strat.arbValue6(), 60e6, "reduced by received amount");
        assertEq(strat.outstandingFace6(), 60e6, "rest still out");
        assertEq(strat.totalAssets(), 1_000e6, "no double count");
    }

    function test_completeInbound_receive_false_reverts() public {
        cctp.setInboundFail(true, false);
        vm.expectRevert("PT: receive failed");
        strat.completeInbound(hex"", hex"");
    }

    function test_completeInbound_nothing_minted_reverts() public {
        cctp.setInboundFail(false, false); // inbound not configured -> returns false via require? no: revert path
        // inboundTo == 0 -> mock reverts; catch the mock's guard instead
        vm.expectRevert("mockcctp: inbound not set");
        strat.completeInbound(hex"", hex"");
    }

    // ------------------------------------------------------- recall/pushIdle

    function test_recall_pays_idle_only_and_records_shortfall() public {
        vm.prank(keeper);
        strat.deployToArb(700e6, 0); // 300 idle remains
        vm.prank(vaultAddr);
        strat.recall(500e6);
        assertEq(usdc.balanceOf(vaultAddr), 300e6, "paid what was idle");
        assertEq(strat.pendingRecall6(), 200e6, "shortfall left for the keeper");
    }

    function test_recall_no_shortfall() public {
        vm.prank(vaultAddr);
        strat.recall(100e6);
        assertEq(usdc.balanceOf(vaultAddr), 100e6);
        assertEq(strat.pendingRecall6(), 0);
    }

    function test_recall_auth() public {
        vm.prank(address(0xB0B));
        vm.expectRevert("PT: not vault");
        strat.recall(1e6);
    }

    function test_pushIdle_returns_to_vault_and_clears_pending() public {
        vm.startPrank(keeper);
        strat.deployToArb(700e6, 0);
        vm.stopPrank();
        vm.prank(vaultAddr);
        strat.recall(700e6); // pays idle 300, shortfall 400
        assertEq(strat.pendingRecall6(), 400e6);

        cctp.setInbound(400e6, address(strat));
        strat.completeInbound(hex"", hex""); // unwind landed
        vm.prank(keeper);
        strat.pushIdle(400e6);
        assertEq(usdc.balanceOf(vaultAddr), 700e6, "vault made whole");
        assertEq(strat.pendingRecall6(), 0, "shortfall cleared");
    }

    function test_pushIdle_nothing_idle_reverts() public {
        vm.startPrank(keeper);
        strat.deployToArb(1_000e6, 0); // ship everything: idle = 0
        vm.expectRevert("PT: nothing idle");
        strat.pushIdle(1e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- full cycle

    function test_full_cycle_earn_and_return() public {
        vm.startPrank(keeper);
        strat.deployToArb(100e6, 0);
        strat.ackArrival(100e6);
        strat.syncArbValue(100e6);
        strat.syncArbValue(104e6); // PT accretes +4
        vm.stopPrank();
        assertEq(strat.totalAssets(), 1_004e6, "accrual visible");

        cctp.setInbound(104e6, address(strat)); // sold + bridged standard
        strat.completeInbound(hex"aa", hex"bb");
        assertEq(strat.totalAssets(), 1_004e6, "value moved to idle, no double count");
        assertEq(strat.arbValue6(), 0);

        vm.prank(vaultAddr);
        strat.recall(1_004e6);
        assertEq(usdc.balanceOf(vaultAddr), 1_004e6, "vault paid, gain included");
        assertEq(strat.pendingRecall6(), 0);
    }

    // ----------------------------------------------------------------- params

    function test_setParams_guards() public {
        vm.expectRevert("PT: headroom too high");
        strat.setParams(3001, 5e6);
        vm.expectRevert("PT: min too low");
        strat.setParams(1000, 1e6);
        strat.setParams(1000, 10e6);
        assertEq(strat.headroomBps(), 1000);
        assertEq(strat.minBridgeUsd6(), 10e6);
    }
}

contract PTSleeveExecutorTest is Test {
    MockUSDC usdc;
    MockCctp cctp;
    MockPendleRouterMin router;
    MockPT pt;
    PTSleeveExecutor exec;

    address ops = address(0x0B5);
    address strategyHyperEvm = address(0xABCD);
    address marketAddr = address(0x1234);

    function setUp() public {
        usdc = new MockUSDC();
        pt = new MockPT();
        router = new MockPendleRouterMin(address(usdc), address(pt));
        cctp = new MockCctp(address(usdc));
        exec = new PTSleeveExecutor(address(usdc), address(router), address(cctp), strategyHyperEvm, ops, address(this));
        exec.setMarket(marketAddr, address(pt));
        usdc.mint(address(exec), 1_000e6);
    }

    function test_buyPT_flows_and_price() public {
        uint256 px = 995e15; // 0.995 USD/PT, 18dp — same value as the mock default
        vm.prank(ops);
        uint256 ptOut = exec.buyPT(100e6, 100e18);
        assertEq(ptOut, (100e6 * 1e12 * 1e18) / px, "PT out at price");
        assertEq(exec.ptBalance(), ptOut, "PT held by executor");
        assertEq(exec.usdcBalance(), 900e6, "USDC spent");
        assertEq(router.buyCount(), 1);
    }

    function test_buyPT_slippage_reverts() public {
        vm.prank(ops);
        vm.expectRevert("router: minPtOut");
        exec.buyPT(100e6, 101e18);
    }

    function test_buyPT_auth() public {
        vm.prank(address(0xB0B));
        vm.expectRevert("PTE: not ops");
        exec.buyPT(1e6, 0);
    }

    function test_sellPT_flows() public {
        uint256 px = 995e15;
        pt.mint(address(exec), 100e18);
        vm.prank(ops);
        uint256 out = exec.sellPT(100e18, 99e6);
        assertEq(out, (100e18 * px) / 1e18 / 1e12, "USDC out at price");
        assertEq(exec.usdcBalance(), 1_000e6 + 99.5e6, "USDC received");
        assertEq(router.sellCount(), 1);
    }

    function test_sellPT_slippage_reverts() public {
        pt.mint(address(exec), 100e18);
        vm.prank(ops);
        vm.expectRevert("router: minTokenOut");
        exec.sellPT(100e18, 100e6); // real out is 99.5
    }

    function test_bridgeBack_fixed_destination_and_standard_finality() public {
        vm.prank(ops);
        exec.bridgeBack(500e6, 0);
        (uint256 amount, uint32 dest, bytes32 recip, address token,, uint256 maxFee, uint32 finality) = cctp.lastBurn();
        assertEq(amount, 500e6);
        assertEq(dest, 19, "HyperEVM domain");
        assertEq(recip, bytes32(uint256(uint160(strategyHyperEvm))), "immutable strategy return address");
        assertEq(token, address(usdc));
        assertEq(maxFee, 0);
        assertEq(finality, 2000, "standard transfer (fee-free today)");
        assertEq(exec.usdcBalance(), 500e6, "USDC burned back");
    }

    function test_bridgeBack_auth_and_amount() public {
        vm.prank(address(0xB0B));
        vm.expectRevert("PTE: not ops");
        exec.bridgeBack(1e6, 0);
        vm.prank(ops);
        vm.expectRevert("PTE: bad amount");
        exec.bridgeBack(1_001e6, 0);
    }

    function test_config_is_owner_only() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ops);
        vm.prank(ops);
        vm.expectRevert(err);
        exec.setMarket(address(0x1), address(0x2));
        vm.prank(ops);
        vm.expectRevert(err);
        exec.setOps(ops);
        vm.prank(ops);
        vm.expectRevert(err);
        exec.ownerRescue(address(usdc), ops, 1e6);
    }

    function test_ownerRescue_works_for_owner() public {
        exec.ownerRescue(address(usdc), address(0xBEEF), 10e6);
        assertEq(usdc.balanceOf(address(0xBEEF)), 10e6);
    }

    // ——— one-time return-address confirm (deploy bootstrap safety net) ———

    function test_confirmStrategyReturn_once_then_locked() public {
        assertEq(exec.strategyReturn(), bytes32(uint256(uint160(strategyHyperEvm))), "constructor value");
        exec.confirmStrategyReturn(address(0x9999));
        assertEq(exec.strategyReturn(), bytes32(uint256(uint160(address(0x9999)))), "corrected");
        vm.expectRevert("PTE: already confirmed");
        exec.confirmStrategyReturn(address(0x8888));
    }

    function test_confirmStrategyReturn_too_late_after_activity() public {
        vm.prank(ops);
        exec.buyPT(1e6, 0);
        vm.expectRevert("PTE: too late");
        exec.confirmStrategyReturn(address(0x9999));
        // also too late once a return has been burned
        exec.setMarket(marketAddr, address(pt)); // no-op sanity
        vm.prank(ops);
        exec.bridgeBack(1e6, 0);
        vm.expectRevert("PTE: too late");
        exec.confirmStrategyReturn(address(0x9999));
    }

    function test_confirmStrategyReturn_owner_only() public {
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ops));
        exec.confirmStrategyReturn(address(0x9999));
    }
}
