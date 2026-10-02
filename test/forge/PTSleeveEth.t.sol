// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// PT fixed-rate sleeve — ETH lane (Ethereum-side executor).
//
// Part 1 (mocked): mirrors the Arb executor suite — hop math, CCTP burn args,
// slippage bounds, auth, one-time return confirm, full cycle.
// Part 2 (fork): runs only when ETH_RPC_URL is set — executes a REAL
// buy/sell round trip against live Ethereum mainnet (Pendle + Curve) and a
// real CCTP bridgeBack burn, logging measured friction for the record.
// Route under test: USDC -> Curve (apxUSD-USDC v3) -> apxUSD ->
// Pendle router -> PT-apxUSD-5NOV2026, and back. (The apyUSD-5NOV2026
// market accepts apxUSD on entry but returns apyUSD on exit — asymmetric;
// see contracts/ethi/PTSleeveEthExecutor.sol deploy constraint.)

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PTSleeveEthExecutor} from "../../contracts/ethi/PTSleeveEthExecutor.sol";
import {MockCctp, MockPT} from "../../contracts/mocks/MockCctp.sol";
import {MockPendleRouterMin} from "../../contracts/mocks/MockPendleRouterMin.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCurve} from "../../contracts/mocks/MockCurve.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PTSleeveEthExecutorTest is Test {
    MockUSDC usdc;
    MockUSDC apx;
    MockCctp cctp;
    MockCurve curve;
    MockPendleRouterMin router;
    MockPT pt;
    PTSleeveEthExecutor exec;

    address ops = address(0x0B5);
    address strategyHyperEvm = address(0xABCD);
    address marketAddr = address(0x1234);

    function setUp() public {
        usdc = new MockUSDC();
        apx = new MockUSDC();
        pt = new MockPT();
        curve = new MockCurve(address(usdc), address(apx)); // idx1 = USDC, idx0 = apx (live layout)
        router = new MockPendleRouterMin(address(apx), address(pt));
        cctp = new MockCctp(address(usdc));
        exec = new PTSleeveEthExecutor(
            address(usdc), address(router), address(cctp), strategyHyperEvm, ops, address(this),
            address(apx), address(curve), 1, 0
        );
        exec.setMarket(marketAddr, address(pt));
        usdc.mint(address(exec), 1_000e6);
    }

    // ------------------------------------------------------------ guards

    function test_constructor_guards() public {
        vm.expectRevert("PTE: zero addr");
        new PTSleeveEthExecutor(
            address(0), address(router), address(cctp), strategyHyperEvm, ops, address(this),
            address(apx), address(curve), 1, 0
        );
        vm.expectRevert("PTE: same indices");
        new PTSleeveEthExecutor(
            address(usdc), address(router), address(cctp), strategyHyperEvm, ops, address(this),
            address(apx), address(curve), 1, 1
        );
    }

    function test_buyPT_no_market_reverts() public {
        PTSleeveEthExecutor fresh = new PTSleeveEthExecutor(
            address(usdc), address(router), address(cctp), strategyHyperEvm, ops, address(this),
            address(apx), address(curve), 1, 0
        );
        usdc.mint(address(fresh), 10e6);
        vm.prank(ops);
        vm.expectRevert("PTE: no market");
        fresh.buyPT(10e6, 0, 0);
    }

    // ------------------------------------------------------------ buyPT

    function test_buyPT_flows_and_price() public {
        uint256 px = 995e15; // 0.995 apxUSD/PT, 18dp — the mock default
        uint256 apxIn = 100e6 * 1e12 - (100e6 * 1e12 * 4 / 10000); // minus 4bp curve fee
        vm.prank(ops);
        uint256 ptOut = exec.buyPT(100e6, 99e18, 100e18);
        assertEq(ptOut, (apxIn * 1e18) / px, "PT out at price");
        assertEq(exec.ptBalance(), ptOut, "PT held by executor");
        assertEq(exec.usdcBalance(), 900e6, "USDC spent");
        assertEq(router.buyCount(), 1);
    }

    function test_buyPT_curve_slippage_reverts() public {
        vm.prank(ops);
        vm.expectRevert("curve: slippage");
        exec.buyPT(100e6, 100e18, 0); // curve gives 99.96e18 — demanding 100 reverts
    }

    function test_buyPT_router_slippage_reverts() public {
        vm.prank(ops);
        vm.expectRevert("router: minPtOut");
        exec.buyPT(100e6, 0, 101e18);
    }

    function test_buyPT_auth() public {
        vm.prank(address(0xB0B));
        vm.expectRevert("PTE: not ops");
        exec.buyPT(1e6, 0, 0);
    }

    function test_buyPT_bad_amount() public {
        vm.prank(ops);
        vm.expectRevert("PTE: bad amount");
        exec.buyPT(1_001e6, 0, 0);
    }

    // ------------------------------------------------------------ sellPT

    function test_sellPT_flows() public {
        uint256 px = 995e15;
        pt.mint(address(exec), 100e18);
        uint256 apxMid = (100e18 * px) / 1e18; // 99.5e18 from the router
        uint256 expectUsdc = apxMid / 1e12;
        expectUsdc -= (expectUsdc * 4) / 10000; // minus 4bp curve fee
        vm.prank(ops);
        uint256 out = exec.sellPT(100e18, 99e18, 0, 99e6);
        assertEq(out, expectUsdc, "USDC out at price");
        assertEq(exec.usdcBalance(), 1_000e6 + expectUsdc, "USDC received");
        assertEq(router.sellCount(), 1);
    }

    function test_sellPT_slippage_reverts() public {
        pt.mint(address(exec), 100e18);
        vm.prank(ops);
        vm.expectRevert("router: minTokenOut");
        exec.sellPT(100e18, 100e18, 0, 0); // real apx mid is 99.5e18
        vm.prank(ops);
        vm.expectRevert("curve: slippage");
        exec.sellPT(100e18, 0, 0, 100e6); // real usdc out is ~99.46e6
    }

    function test_sellPT_bad_amount() public {
        vm.prank(ops);
        vm.expectRevert("PTE: bad amount");
        exec.sellPT(1e18, 0, 0, 0); // no PT held
    }

    // ------------------------------------------------------------ bridgeBack

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

    // ------------------------------------------------------------ config

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

    function test_setMarket_zero_reverts() public {
        vm.expectRevert("PTE: zero market");
        exec.setMarket(address(0), address(0x2));
    }

    function test_setOps_zero_reverts() public {
        vm.expectRevert("PTE: zero ops");
        exec.setOps(address(0));
    }

    function test_ownerRescue_works_for_owner() public {
        exec.ownerRescue(address(usdc), address(0xBEEF), 10e6);
        assertEq(usdc.balanceOf(address(0xBEEF)), 10e6);
    }

    function test_ownerRescue_zero_to_reverts() public {
        vm.expectRevert("PTE: zero to");
        exec.ownerRescue(address(usdc), address(0), 1e6);
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
        exec.buyPT(1e6, 0, 0);
        vm.expectRevert("PTE: too late");
        exec.confirmStrategyReturn(address(0x9999));
        // also too late once a return has been burned
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

    // ------------------------------------------------------------ full cycle

    function test_full_cycle_buy_sell_bridge() public {
        vm.startPrank(ops);
        uint256 ptOut = exec.buyPT(1_000e6, 0, 0);
        assertGt(ptOut, 0, "bought PT");
        uint256 usdcOut = exec.sellPT(ptOut, 0, 0, 0);
        assertGt(usdcOut, 0, "sold PT");
        uint256 bal = exec.usdcBalance();
        exec.bridgeBack(bal, 0);
        vm.stopPrank();
        assertEq(exec.ptBalance(), 0, "PT all sold");
        assertEq(exec.usdcBalance(), 0, "USDC all bridged");
        assertEq(exec.buyCount(), 1);
        assertEq(exec.sellCount(), 1);
        assertEq(exec.bridgeBackCount(), 1);
    }

    // ------------------------------------------------------------ exit path (2-hop)

    function test_setExitPath_validations() public {
        vm.expectRevert("PTE: zero exit asset");
        exec.setExitPath(address(0), address(0), 0, 0);
        vm.expectRevert("PTE: symmetric needs asset");
        exec.setExitPath(address(0x9999), address(0), 0, 0);
        vm.expectRevert("PTE: redundant hop");
        exec.setExitPath(address(apx), address(0x7777), 0, 1);
        vm.expectRevert("PTE: same idx");
        exec.setExitPath(address(0x9999), address(0x7777), 1, 1);
        vm.expectRevert("PTE: idx must be zero");
        exec.setExitPath(address(apx), address(0), 1, 0);
    }

    function test_setExitPath_auth_and_apply() public {
        MockUSDC apy = new MockUSDC();
        MockCurvePair pair = new MockCurvePair(address(apy), address(apx));
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ops));
        exec.setExitPath(address(apy), address(pair), 0, 1);
        exec.setExitPath(address(apy), address(pair), 0, 1);
        assertEq(exec.exitAsset(), address(apy));
        assertEq(exec.exitPool(), address(pair));
        assertEq(exec.exitIdxFrom(), 0);
        assertEq(exec.exitIdxTo(), 1);
    }

    function test_sellPT_two_hop_flows() public {
        MockUSDC apy = new MockUSDC();
        MockCurvePair pair = new MockCurvePair(address(apy), address(apx));
        pair.setRate(14142); // 1.4142 apxUSD per apyUSD
        router.setAltTokenOut(address(apy), 1e18); // PT sells for 1 apyUSD each
        exec.setExitPath(address(apy), address(pair), 0, 1);

        pt.mint(address(exec), 100e18);
        uint256 midAsset = (100e18 * 14142) / 10000; // apy -> apx
        uint256 expectUsdc = midAsset / 1e12;
        expectUsdc -= (expectUsdc * 4) / 10000; // minus 4bp curve fee
        vm.prank(ops);
        uint256 out = exec.sellPT(100e18, 99e18, 140e18, 140e6);
        assertEq(out, expectUsdc, "USDC out via two-hop");
        assertEq(exec.usdcBalance(), 1_000e6 + expectUsdc, "USDC received");
        assertEq(router.sellCount(), 1);
    }

    function test_sellPT_two_hop_slippage_bounds() public {
        MockUSDC apy = new MockUSDC();
        MockCurvePair pair = new MockCurvePair(address(apy), address(apx));
        pair.setRate(14142);
        router.setAltTokenOut(address(apy), 1e18);
        exec.setExitPath(address(apy), address(pair), 0, 1);
        pt.mint(address(exec), 100e18);
        vm.prank(ops);
        vm.expectRevert("router: minTokenOut");
        exec.sellPT(100e18, 101e18, 0, 0); // leg 1 demands more apy than possible
        vm.prank(ops);
        vm.expectRevert("pair: slippage");
        exec.sellPT(100e18, 0, 142e18, 0); // hop demands more apx than possible
        vm.prank(ops);
        vm.expectRevert("curve: slippage");
        exec.sellPT(100e18, 0, 0, 142e6); // final leg demands more USDC than possible
    }

    function test_full_cycle_two_hop_then_symmetric_reset() public {
        MockUSDC apy = new MockUSDC();
        MockCurvePair pair = new MockCurvePair(address(apy), address(apx));
        pair.setRate(14142);
        router.setAltTokenOut(address(apy), 1e18);
        exec.setExitPath(address(apy), address(pair), 0, 1);

        vm.startPrank(ops);
        uint256 ptOut = exec.buyPT(1_000e6, 0, 0);
        uint256 usdcOut = exec.sellPT(ptOut, 0, 0, 0);
        assertGt(usdcOut, 0);
        exec.bridgeBack(exec.usdcBalance(), 0);
        vm.stopPrank();
        assertEq(exec.usdcBalance(), 0, "all bridged");

        // back to symmetric — exit path must point at asset again
        exec.setExitPath(address(apx), address(0), 0, 0);
        assertEq(exec.exitAsset(), address(apx));
        assertEq(exec.exitPool(), address(0));
    }
}

/// @notice Live-fork integration proof for the ETH lane. Runs only when
/// ETH_RPC_URL is set (public mainnet RPC works). Exercises the REAL route:
/// USDC -> Curve (apxUSD-USDC v3) -> apxUSD -> Pendle router -> PT-apyUSD,
/// then back, plus a real CCTP bridgeBack burn.
contract PTSleeveEthForkTest is Test {
    // Live Ethereum mainnet addresses (verified 2026-09-30)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946; // Pendle Router v4
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d; // CCTP V2
    address constant APXUSD = 0x98A878b1Cd98131B271883B390f68D2c90674665;
    address constant CURVE_POOL = 0x6F63deEDc9870D6c16FC644C6654748352cdc87c; // apxUSD-USDC v3
    address constant MARKET = 0xaf0349FB9B1bA07D34381870c59b560b31412660; // apxUSD-5NOV2026 (symmetric SY in/out)
    address constant PT = 0xAF687B5EcB525Ccea96115088999B4eD80C388b6; // PT-apxUSD-5NOV2026

    // Two-hop set: the deeper apyUSD-5NOV market returns apyUSD on exit.
    address constant APYUSD = 0x38EEb52F0771140d10c4E9A9a72349A329Fe8a6A;
    address constant APY_POOL = 0xe41be7B340f7c2EDA4DA1e99b42Ee1b228b526b7; // Curve apyUSD-apxUSD
    address constant APY_MARKET = 0xC5f938A8ef5F3BF9E72F5aA094baF5E03f4727D3; // apyUSD-5NOV2026
    address constant APY_PT = 0xb5Be35D8fF83D431899b95851CB17a2B4bcEF150; // PT-apyUSD-5NOV2026

    PTSleeveEthExecutor exec;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;
        exec = new PTSleeveEthExecutor(
            USDC, ROUTER, TOKEN_MESSENGER, address(0xABCD), address(this), address(this),
            APXUSD, CURVE_POOL, 1, 0 // idx: 1 = USDC, 0 = apxUSD (live layout)
        );
        exec.setMarket(MARKET, PT);
        deal(USDC, address(exec), 1_000e6);
    }

    function test_fork_buy_sell_roundtrip() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        // Quote the curve hop for a sane min-out.
        (bool ok, bytes memory ret) = CURVE_POOL.call(
            abi.encodeWithSignature("get_dy(int128,int128,uint256)", int128(1), int128(0), uint256(1_000e6))
        );
        uint256 quotedApx = ok ? abi.decode(ret, (uint256)) : 0;
        console.log("curve quote USDC->apxUSD (1e18):", quotedApx);

        uint256 ptOut = exec.buyPT(1_000e6, (quotedApx * 99) / 100, 0);
        console.log("USDC in:", uint256(1_000e6), "| PT out:", ptOut);
        assertGt(ptOut, 0, "got PT");

        uint256 ptBal = IERC20(PT).balanceOf(address(exec));
        assertEq(ptBal, ptOut, "all PT held by executor");

        // Sell it all back — measure true round-trip friction.
        uint256 usdcOut = exec.sellPT(ptBal, 0, 0, 0);
        console.log("USDC out (round trip):", usdcOut, "of", uint256(1_000e6));
        console.log("round-trip friction bps:", ((1_000e6 - usdcOut) * 10_000) / 1_000e6);
        assertGt(usdcOut, 900e6, "round trip within 10%");
    }

    function test_fork_buy_sell_roundtrip_2hop() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        // Executor #2 configured for the deeper apyUSD-5NOV market with the
        // two-hop exit (PT -> apyUSD via Pendle, apyUSD -> apxUSD -> USDC).
        PTSleeveEthExecutor exec2 = new PTSleeveEthExecutor(
            USDC, ROUTER, TOKEN_MESSENGER, address(0xABCD), address(this), address(this),
            APXUSD, CURVE_POOL, 1, 0
        );
        exec2.setMarket(APY_MARKET, APY_PT);
        exec2.setExitPath(APYUSD, APY_POOL, 0, 1);
        deal(USDC, address(exec2), 1_000e6);

        (bool ok, bytes memory ret) = CURVE_POOL.call(
            abi.encodeWithSignature("get_dy(int128,int128,uint256)", int128(1), int128(0), uint256(1_000e6))
        );
        uint256 quotedApx = ok ? abi.decode(ret, (uint256)) : 0;

        uint256 ptOut = exec2.buyPT(1_000e6, (quotedApx * 99) / 100, 0);
        console.log("2HOP USDC in:", uint256(1_000e6), "| PT-apyUSD out:", ptOut);
        assertGt(ptOut, 0, "got PT");

        uint256 ptBal = IERC20(APY_PT).balanceOf(address(exec2));
        uint256 usdcOut = exec2.sellPT(ptBal, 0, 0, 0);
        console.log("2HOP USDC out (round trip):", usdcOut, "of", uint256(1_000e6));
        console.log("2HOP round-trip friction bps:", ((1_000e6 - usdcOut) * 10_000) / 1_000e6);
        assertGt(usdcOut, 900e6, "round trip within 10%");
    }

    function test_fork_bridgeBack_live() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint256 beforeBal = IERC20(USDC).balanceOf(address(exec));
        exec.bridgeBack(beforeBal, 0);
        uint256 afterBal = IERC20(USDC).balanceOf(address(exec));
        assertEq(beforeBal - afterBal, beforeBal, "USDC burned out");
        console.log("bridgeBack burned (real CCTP):", beforeBal);
    }
}

/// @notice Minimal mock of an 18dp/18dp stable pair pool (e.g. apyUSD/apxUSD)
/// with a configurable rate. Exercises the executor's optional second hop.
contract MockCurvePair {
    MockUSDC public tokA; // idx0 (e.g. apyUSD)
    MockUSDC public tokB; // idx1 (e.g. apxUSD)
    uint256 public rateBps = 10000; // B per A * 10000

    constructor(address _a, address _b) {
        tokA = MockUSDC(_a);
        tokB = MockUSDC(_b);
    }

    function setRate(uint256 r) external {
        require(r > 0, "pair: zero rate");
        rateBps = r;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external {
        if (i == 0 && j == 1) {
            tokA.transferFrom(msg.sender, address(this), dx);
            uint256 dy = (dx * rateBps) / 10000;
            require(dy >= minDy, "pair: slippage");
            tokB.mint(msg.sender, dy);
        } else if (i == 1 && j == 0) {
            tokB.transferFrom(msg.sender, address(this), dx);
            uint256 dy = (dx * 10000) / rateBps;
            require(dy >= minDy, "pair: slippage");
            tokA.mint(msg.sender, dy);
        } else {
            revert("pair: bad indices");
        }
    }
}
