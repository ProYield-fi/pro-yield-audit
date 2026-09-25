// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ROUND-2 PART B EVIDENCE — DN stack accounting repro (offline, mocks etched
// at the real precompile/system addresses, mirroring the repo's hardhat DN
// suite but without anvil).
//
// Finding under test: dn_keeper.js BRIDGE_PROFIT passes only the profit
// portion (equity - principal, dn_keeper.js:214-235) to
// DNCoreStrategy.bridgeBackToEvm, but the contract splits principal-first
// (DNCoreStrategy.sol:104-117) -> the whole bridged amount is booked as
// principal return, profitRealized stays 0, and the subsequent vault.harvest()
// sweeps NOTHING (the keeper still logs "profit harvested").
//
// Run: forge test --match-path 'test/audit/*' -vvv

import {Test} from "forge-std/Test.sol";
import {DNCoreStrategy} from "../../contracts/DNCoreStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {
    MockCoreUserExists,
    MockMarginSummary,
    MockPosition2
} from "../../contracts/mocks/MockPrecompiles.sol";
import {MockCoreWriter, MockCoreDepositWallet} from "../../contracts/mocks/MockCoreWriter.sol";

contract Round2DNTest is Test {
    MockUSDC usdc;
    DNCoreStrategy strat;
    address dnVault = makeAddr("dnVault");
    address keeper = makeAddr("keeper");
    uint256 constant U = 1e18;

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant P_810 = 0x0000000000000000000000000000000000000810;
    address constant P_813 = 0x0000000000000000000000000000000000000813;
    address constant P_80F = 0x000000000000000000000000000000000000080F;
    // chainid 31337 != 998 -> HLConstants picks the MAINNET deposit wallet
    address constant DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

    function setUp() public {
        usdc = new MockUSDC();

        MockCoreUserExists exists = new MockCoreUserExists();
        vm.etch(P_810, address(exists).code);
        MockCoreUserExists(P_810).setExists(true);

        MockMarginSummary marg = new MockMarginSummary();
        vm.etch(P_80F, address(marg).code);

        MockPosition2 pos = new MockPosition2(); // _syncCore also reads position()
        vm.etch(P_813, address(pos).code);

        MockCoreDepositWallet wal = new MockCoreDepositWallet();
        vm.etch(DEPOSIT_WALLET, address(wal).code);
        MockCoreDepositWallet(DEPOSIT_WALLET).setToken(address(usdc));

        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(cw).code);

        strat = new DNCoreStrategy(address(usdc), address(this), 0, 1_000_000e6);
        strat.setKeeper(keeper);
        strat.setVault(dnVault);

        usdc.mint(address(strat), 500 * U);
        vm.prank(keeper);
        strat.bridgeUsdcToCore(500 * U);
        // Core account: equity 505 = principal 500 + 5 profit
        MockMarginSummary(P_80F).set(505_000_000, 0, 0, 0);
        strat.syncCore();
    }

    /// @dev Keeper BRIDGE_PROFIT path: bridge only the profit portion.
    function test_PartB_keeperProfitOnlyBridge_realizesZeroProfit() public {
        assertEq(strat.corePrincipal6(), 500_000_000, "principal tracked");
        assertEq(strat.coreEquity6(), 505_000_000, "equity synced");

        vm.prank(keeper);
        strat.bridgeBackToEvm(5_000_000); // dn_keeper.js:233 — amount6 = equity - principal

        // Split is principal-first: the profit-sized bridge books as principal return.
        assertEq(strat.corePrincipal6(), 495_000_000, "BUG: profit bridge REDUCED PRINCIPAL");
        assertEq(strat.profitRealized(), 0, "BUG: profit NOT realized");
        assertEq(strat.harvestableProfit(), 0, "nothing harvestable");

        // Simulate the Core->EVM credit of what was bridged, then run the
        // vault-side harvest exactly as the keeper would (dn_keeper.js:243).
        usdc.mint(address(strat), 5 * U);
        vm.prank(dnVault);
        strat.harvest(); // vault sweep path: min(available=0, idle-buffer) = 0
        assertEq(strat.profitSwept(), 0, "BUG: vault harvest swept nothing");
        assertEq(usdc.balanceOf(dnVault), 0, "BUG: no profit reaches the vault");
    }

    /// @dev Repo's own DN test path: bridge the FULL amount (principal+profit).
    function test_PartB_fullAmountBridge_realizesProfit_sweepWorks() public {
        usdc.mint(address(strat), 505 * U); // simulate Core->EVM credit of full bridge
        vm.prank(keeper);
        strat.bridgeBackToEvm(505_000_000); // principal 500 + profit 5, split correctly

        assertEq(strat.corePrincipal6(), 0, "principal fully returned");
        assertEq(strat.profitRealized(), 5 * U, "profit realized ONLY on full bridge");
        assertEq(strat.harvestableProfit(), 5 * U, "harvestable");

        vm.prank(dnVault);
        strat.harvest();
        assertEq(usdc.balanceOf(dnVault), 5 * U, "vault swept realized profit");
        assertEq(strat.profitSwept(), 5 * U, "swept recorded");
    }
}
