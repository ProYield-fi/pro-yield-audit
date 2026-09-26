// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// MorphoStrategy — the REAL lending adapter. Properties proven here:
//   1. deploy() supplies idle funds; totalAssets = position value + idle.
//   2. Yield accrues in the position and the VAULT's harvest() sweeps it as
//      real USDC — principal is structurally excluded from profit.
//   3. recall() (vault-only) unwinds the position synchronously: partial,
//      full, and illiquid-market paths all return what they can without
//      reverting (the vault's _recallShortfall measures what arrived).
//   4. Auth: non-keeper deploy reverts; non-vault recall reverts.
//   5. End-to-end with the real vault: allocate -> deploy -> user deposit
//      earns -> user withdraw recalls from Morpho -> user gets paid.

import {Test} from "forge-std/Test.sol";
import {MorphoStrategy, IMorpho} from "../../contracts/MorphoStrategy.sol";
import {MockMorpho} from "../../contracts/mocks/MockMorpho.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";

contract MorphoStrategyTest is Test {
    MockUSDC usdc;
    MockMorpho morpho;
    MorphoStrategy strat;

    address vaultAddr = address(0xF00D);
    address keeper = address(0xCAFE);
    address user = address(0xA11CE);

    address constant COLL = address(0x5555555555555555555555555555555555555555);
    address constant ORACLE = address(0x194FFF37872BAC3531a41fA5C426090ff84f4f31);
    address constant IRM = address(0xD4a426F010986dCad727e8dd6eed44cA4A9b7483);
    uint256 constant LLTV = 0.77e18;

    function setUp() public {
        usdc = new MockUSDC();
        morpho = new MockMorpho();
        strat = new MorphoStrategy(address(usdc), address(this), address(morpho), COLL, ORACLE, IRM, LLTV);
        strat.setVault(vaultAddr);
        strat.setKeeper(keeper);
        usdc.mint(address(strat), 1_000e6);
    }

    function _id() internal view returns (bytes32) {
        return keccak256(abi.encode(address(usdc), COLL, ORACLE, IRM, LLTV));
    }

    // 1 — supply + accounting
    function test_deploy_supplies_and_counts() public {
        vm.prank(keeper);
        strat.deploy();
        assertEq(strat.totalAssets(), 1_000e6, "totalAssets after supply");
        assertEq(usdc.balanceOf(address(strat)), 0, "all supplied");
        assertEq(usdc.balanceOf(address(morpho)), 1_000e6, "morpho holds principal");
    }

    function test_deploy_respects_buffer() public {
        strat.setBufferBps(1000); // 10%
        vm.prank(keeper);
        strat.deploy();
        assertEq(strat.totalAssets(), 1_000e6, "total unchanged");
        assertEq(usdc.balanceOf(address(strat)), 100e6, "10% buffer idle");
        assertEq(usdc.balanceOf(address(morpho)), 900e6, "90% supplied");
    }

    // 2 — harvest sweeps YIELD ONLY, never principal
    function test_harvest_sweeps_yield_not_principal() public {
        vm.prank(keeper);
        strat.deploy();
        morpho.accrue(_id(), 25e6); // +2.5% interest

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr) - before, 25e6, "swept exactly the yield");
        assertEq(strat.totalAssets(), 1_000e6, "principal intact in position");

        // second harvest with no new yield = 0
        before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr) - before, 0, "no double sweep");
    }

    function test_harvest_unwinds_from_position_when_needed() public {
        vm.prank(keeper);
        strat.deploy();
        morpho.accrue(_id(), 10e6);
        // nothing idle (buffer 0) -> harvest must withdraw the yield from Morpho
        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr) - before, 10e6, "yield withdrawn + swept");
    }

    // 3 — recall paths
    function test_recall_partial_unwinds() public {
        vm.prank(keeper);
        strat.deploy();
        vm.prank(vaultAddr);
        strat.recall(400e6);
        assertEq(usdc.balanceOf(vaultAddr), 400e6, "vault got requested");
        assertEq(strat.totalAssets(), 600e6, "position reduced");
    }

    function test_recall_full_empties_position() public {
        vm.prank(keeper);
        strat.deploy();
        vm.prank(vaultAddr);
        strat.recall(2_000e6); // over-ask: capped at balance
        assertEq(usdc.balanceOf(vaultAddr), 1_000e6, "all funds returned");
        assertEq(strat.totalAssets(), 0, "position empty");
    }

    function test_recall_illiquid_returns_idle_no_revert() public {
        vm.prank(keeper);
        strat.deploy();
        morpho.setIlliquid(true);
        vm.prank(vaultAddr);
        strat.recall(500e6); // withdraw reverts internally -> caught
        assertEq(usdc.balanceOf(vaultAddr), 0, "no cash available, no revert");
        assertEq(strat.totalAssets(), 1_000e6, "position intact");
    }

    function test_recall_after_harvest_never_books_principal_as_profit() public {
        vm.prank(keeper);
        strat.deploy();
        morpho.accrue(_id(), 30e6);
        vm.prank(vaultAddr);
        strat.harvest(); // sweeps 30
        vm.prank(vaultAddr);
        strat.recall(500e6); // principal out; baseline must drop by 500
        assertEq(strat.totalAssets(), 500e6, "half the position left");
        morpho.accrue(_id(), 5e6);
        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr) - before, 5e6, "only real new yield, not the recalled principal");
    }

    // 4 — auth
    function test_deploy_only_keeper_or_owner() public {
        vm.prank(user);
        vm.expectRevert("Morpho: not keeper");
        strat.deploy();
    }

    function test_recall_only_vault() public {
        vm.prank(user);
        vm.expectRevert("Morpho: not vault");
        strat.recall(1e6);
    }

    function test_harvest_from_keeper_is_noop_sweep() public {
        vm.prank(keeper);
        strat.deploy();
        morpho.accrue(_id(), 7e6);
        vm.prank(keeper);
        strat.harvest();
        assertEq(usdc.balanceOf(vaultAddr), 0, "keeper settles, vault sweeps");
    }

    // 5 — end-to-end with the real vault
    function test_e2e_vault_allocate_earn_withdraw() public {
        FeeDistributor fd = new FeeDistributor(address(usdc));
        ProYieldVault vault = new ProYieldVault(address(usdc), address(this), address(fd));
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
        vault.setCaps(1_000_000e6, 1_000_000e6);

        // user deposits 1,000
        usdc.mint(user, 1_000e6);
        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // vault allocates everything (only strategy active -> all of deployable)
        vault.allocate();
        uint256 onStrategy = usdc.balanceOf(address(strat));
        assertGt(onStrategy, 0, "vault sent funds to strategy");
        vm.prank(keeper);
        strat.deploy();
        assertEq(usdc.balanceOf(address(strat)), 0, "strategy fully supplied");

        // yield accrues -> vault harvest books NET of the 10% perf fee
        morpho.accrue(_id(), 40e6); // 4% interest
        vault.harvest();
        assertEq(vault.totalAssets(), 1_036e6, "vault booked yield net of fee");

        // user withdraws everything: recall must unwind Morpho synchronously
        vm.prank(user);
        vault.withdraw(1_000e6); // principal
        assertEq(usdc.balanceOf(user), 1_000e6, "principal paid from recall");
        // remaining shares (the earned 36 after fee) still claimable
        uint256 rest = vault.convertToAssets(vault.shares(user));
        assertApproxEqAbs(rest, 36e6, 100, "earned yield claim (dust from share rounding)");
        vm.prank(user);
        vault.withdraw(rest);
        assertApproxEqAbs(usdc.balanceOf(user), 1_036e6, 100, "net yield paid too");
        assertLe(vault.totalAssets(), 100, "vault drained cleanly");
    }
}
