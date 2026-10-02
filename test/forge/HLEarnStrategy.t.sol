// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HLEarnStrategy} from "../../contracts/HLEarnStrategy.sol";
import {HLEarnLib} from "../../contracts/adapters/HLEarnLib.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCoreUserExists, MockSpotBalance} from "../../contracts/mocks/MockPrecompiles.sol";
import {MockCoreWriter, MockCoreDepositWallet} from "../../contracts/mocks/MockCoreWriter.sol";
import {MockBorrowLendUserState, MockAlwaysRevert} from "../../contracts/mocks/MockBorrowLend.sol";

/// @notice HLEarnStrategy unit tests — mocks copied to the fixed precompile
/// addresses (anvil_setCode discipline), byte-exact CoreWriter assertions.
///
/// UNITS: MockUSDC is 18-dec (like the other repo mocks) → coreScale = 1e12.
/// EVM-side amounts are 18-dec; Core/wire amounts are USDC 6-dec or wei
/// (6-dec × 100). The wire conversion (×100) is INDEPENDENT of mock decimals.
contract HLEarnStrategyTest is Test {
    HLEarnStrategy strat;
    MockUSDC usdc;

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant P_801 = 0x0000000000000000000000000000000000000801;
    address constant P_810 = 0x0000000000000000000000000000000000000810;
    address constant P_811 = 0x0000000000000000000000000000000000000811;
    // chainid 31337 != 998 -> HLConstants picks the MAINNET deposit wallet
    address constant DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    address keeper = makeAddr("keeper");
    address vaultAddr = makeAddr("vault");
    address other = makeAddr("other");

    function setUp() public {
        usdc = new MockUSDC();

        MockCoreUserExists exists = new MockCoreUserExists();
        vm.etch(P_810, address(exists).code);
        MockCoreUserExists(P_810).setExists(true);

        MockSpotBalance spot = new MockSpotBalance();
        vm.etch(P_801, address(spot).code);

        MockBorrowLendUserState bl = new MockBorrowLendUserState();
        vm.etch(P_811, address(bl).code);

        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(cw).code);

        MockCoreDepositWallet dw = new MockCoreDepositWallet();
        vm.etch(DEPOSIT_WALLET, address(dw).code);
        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));

        strat = new HLEarnStrategy(address(usdc), address(this), 0);
        strat.setKeeper(keeper);
        strat.setVault(vaultAddr);

        usdc.mint(address(strat), 1_000e18);
    }

    /*//////////////////////// Helpers ////////////////////////*/
    /// @dev Mock setters take USDC 6-dec; the mock stores wire units (wei = 6dp × 100).
    function _setSupplyWei(uint64 sixDp) internal {
        MockBorrowLendUserState(P_811).set(0, 0, 0, sixDp * 100);
    }

    function _setSpot(uint64 sixDp) internal {
        MockSpotBalance(P_801).set(sixDp * 100, 0, 0);
    }

    function _sendAssetExpected(uint64 weiAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(1),
            uint24(13),
            abi.encode(
                address(uint160(0x2000000000000000000000000000000000000000)),
                address(0),
                type(uint32).max,
                type(uint32).max,
                uint64(0),
                weiAmount
            )
        );
    }

    /*//////////////////////// Core flows ////////////////////////*/
    function test_bridge_then_supply_byte_exact() public {
        vm.prank(keeper);
        strat.bridgeUsdcToCore(100e18); // → 100 USDC 6-dec on Core

        assertEq(usdc.balanceOf(address(strat)), 900e18);
        assertEq(MockCoreDepositWallet(DEPOSIT_WALLET).lastAmount(), 100e18);
        assertEq(MockCoreDepositWallet(DEPOSIT_WALLET).lastDex(), type(uint32).max);
        assertEq(strat.corePrincipal6(), 100e6);

        // simulate arrival on Core spot, then supply to the reserve
        _setSpot(100e6);
        vm.prank(keeper);
        strat.supplyToReserve(100e6);

        bytes memory expected = HLEarnLib.encodeSupply(0, 100e6 * 100);
        bytes memory sent = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(sent, expected);
        assertEq(sent.length, 100); // 4-byte header + (uint8,uint64,uint64)
        assertEq(uint8(sent[0]), 1); // version
        assertEq(uint8(sent[3]), 15); // action id, big-endian uint24 low byte
        assertEq(MockCoreWriter(CORE_WRITER).actionCount(), 1);
    }

    function test_withdraw_vectors_max_and_partial() public {
        vm.prank(keeper);
        strat.requestWithdraw(0); // full reserve balance
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), HLEarnLib.encodeWithdrawMax(0));

        vm.prank(keeper);
        strat.requestWithdraw(25e6);
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), HLEarnLib.encodeWithdraw(0, 25e6 * 100));
    }

    function test_bridge_back_profit_first_split() public {
        vm.prank(keeper);
        strat.bridgeUsdcToCore(100e18); // principal 100e6

        // value = supply 100.5 + spot 12 = 112.5; profit = 12.5
        _setSupplyWei(100_500_000);
        _setSpot(12e6);

        vm.prank(keeper);
        strat.bridgeBackToEvm(10e6);

        assertEq(strat.corePrincipal6(), 100e6); // untouched: all profit
        assertEq(strat.profitRealized(), 10e18); // underlying units (18-dec mock)
        assertEq(strat.coreSpot6(), 2e6);
        assertEq(MockCoreWriter(CORE_WRITER).lastAction(), _sendAssetExpected(10e6 * 100));
    }

    function test_bridge_back_principal_path_when_no_profit() public {
        vm.prank(keeper);
        strat.bridgeUsdcToCore(200e18); // principal 200e6

        // value = supply 190 + spot 5 = 195 < principal 200 -> nothing is profit
        _setSupplyWei(190e6);
        _setSpot(5e6);

        vm.prank(keeper);
        strat.bridgeBackToEvm(5e6);

        assertEq(strat.corePrincipal6(), 195e6); // full amount reduces principal
        assertEq(strat.profitRealized(), 0);
        assertEq(strat.coreSpot6(), 0);
    }

    /*//////////////////////// Reads / accounting ////////////////////////*/
    function test_sync_and_total_assets() public {
        vm.prank(keeper);
        strat.bridgeUsdcToCore(100e18);
        _setSpot(10e6);
        _setSupplyWei(90_500_000);

        strat.syncEarn();

        assertEq(strat.supplyValue6(), 90_500_000);
        assertEq(strat.coreSpot6(), 10e6);
        // idle 900e18 + (spot 10e6 + supply 90.5e6) * 1e12
        assertEq(strat.totalAssets(), 900e18 + (10e6 + 90_500_000) * 1e12);
    }

    function test_sync_fallback_to_principal_when_read_broken() public {
        vm.prank(keeper);
        strat.bridgeUsdcToCore(100e18);

        MockAlwaysRevert reverter = new MockAlwaysRevert();
        vm.etch(P_811, address(reverter).code);

        strat.syncEarn();
        assertEq(strat.supplyValue6(), 100e6); // conservative: principal, never less
    }

    function test_spot_read_failure_keeps_previous_value() public {
        _setSpot(7e6);
        strat.syncEarn();
        assertEq(strat.coreSpot6(), 7e6);

        MockAlwaysRevert reverter = new MockAlwaysRevert();
        vm.etch(P_801, address(reverter).code);

        strat.syncEarn();
        assertEq(strat.coreSpot6(), 7e6); // stale, not zeroed
    }

    /*//////////////////////// Vault surfaces ////////////////////////*/
    function test_recall_vault_only_and_capped_at_idle() public {
        vm.prank(other);
        vm.expectRevert(HLEarnStrategy.HLEarn__NotAuthorized.selector);
        strat.recall(1e18);

        vm.prank(vaultAddr);
        strat.recall(400e18);
        assertEq(usdc.balanceOf(vaultAddr), 400e18);
        assertEq(usdc.balanceOf(address(strat)), 600e18);

        // over-ask caps at balance, never reverts (vault measures what arrived)
        vm.prank(vaultAddr);
        strat.recall(10_000e18);
        assertEq(usdc.balanceOf(address(strat)), 0);
    }

    function test_harvest_sweeps_realized_profit_to_vault() public {
        vm.prank(keeper);
        strat.bridgeUsdcToCore(100e18);
        _setSupplyWei(100_500_000);
        _setSpot(12e6);
        vm.prank(keeper);
        strat.bridgeBackToEvm(10e6); // realizes 10e18 profit (underlying units)
        assertEq(strat.harvestableProfit(), 10e18);

        strat.setBufferBps(0);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr) - before, 10e18);
        assertEq(strat.profitSwept(), 10e18);
        assertEq(strat.harvestableProfit(), 0);

        // second vault harvest: nothing left to sweep
        vm.prank(vaultAddr);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr) - before, 10e18);

        // keeper harvest = sync only, never transfers
        vm.prank(keeper);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr) - before, 10e18);
    }

    /*//////////////////////// Guards ////////////////////////*/
    function test_guards_auth_min_cap_pause() public {
        // non-keeper
        vm.prank(other);
        vm.expectRevert(HLEarnStrategy.HLEarn__NotKeeper.selector);
        strat.bridgeUsdcToCore(10e18);

        // below min
        vm.prank(keeper);
        vm.expectRevert(HLEarnStrategy.HLEarn__BelowMin.selector);
        strat.supplyToReserve(4e6);

        // zero
        vm.prank(keeper);
        vm.expectRevert(HLEarnStrategy.HLEarn__ZeroAmount.selector);
        strat.bridgeUsdcToCore(0);

        // bridge (no cap yet), then NeedSpot: cannot send back more than Core spot
        vm.prank(keeper);
        strat.bridgeUsdcToCore(100e18);
        vm.prank(keeper);
        vm.expectRevert(HLEarnStrategy.HLEarn__NeedSpot.selector);
        strat.bridgeBackToEvm(10e6); // coreSpot6 == 0

        // per-action cap
        strat.setMaxActionUsd6(50e6);
        vm.prank(keeper);
        vm.expectRevert(HLEarnStrategy.HLEarn__Cap.selector);
        strat.supplyToReserve(60e6);

        // pause blocks keeper flows
        strat.setPaused(true);
        vm.prank(keeper);
        vm.expectRevert(HLEarnStrategy.HLEarn__Paused.selector);
        strat.supplyToReserve(10e6);

        // buffer bound
        vm.expectRevert(HLEarnStrategy.HLEarn__BufferTooHigh.selector);
        strat.setBufferBps(5001);
    }

    function test_supply_requires_core_account() public {
        MockCoreUserExists(P_810).setExists(false);
        assertFalse(strat.coreAccountExists());

        vm.prank(keeper);
        vm.expectRevert(HLEarnStrategy.HLEarn__NotInitialized.selector);
        strat.supplyToReserve(10e6);

        MockCoreUserExists(P_810).setExists(true);
        assertTrue(strat.coreAccountExists());
        vm.prank(keeper);
        strat.supplyToReserve(10e6); // no revert now
    }

    function test_reconcile_profit_owner_only_and_bounds() public {
        // seed realized profit via a bridge-back split
        vm.prank(keeper);
        strat.bridgeUsdcToCore(100e18);
        _setSupplyWei(100_500_000);
        _setSpot(12e6);
        vm.prank(keeper);
        strat.bridgeBackToEvm(10e6); // realizes 10e18
        assertEq(strat.profitRealized(), 10e18);

        // non-owner cannot reconcile
        vm.prank(other);
        vm.expectRevert();
        strat.reconcileProfit(0);

        // sweep, then: cannot set below already-swept
        strat.setBufferBps(0);
        vm.prank(vaultAddr);
        strat.harvest();
        assertEq(strat.profitSwept(), 10e18);
        vm.expectRevert(HLEarnStrategy.HLEarn__BelowSwept.selector);
        strat.reconcileProfit(9e18);

        // valid reconciliation: down to swept (drop-retry correction), and up
        strat.reconcileProfit(10e18);
        assertEq(strat.harvestableProfit(), 0);
        strat.reconcileProfit(12e18);
        assertEq(strat.profitRealized(), 12e18);
    }

    function test_reconcile_noop_ok() public {
        strat.reconcileProfit(0);
        assertEq(strat.profitRealized(), 0);
    }
}
