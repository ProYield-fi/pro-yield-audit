// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// BaseStrategy coverage — the last sub-90% surface flagged in
// INTERNAL_TOOLS_ROUND §3 (was 73.2%). The base's own implementations rarely
// run in product: children override name/_doHarvest/totalAssets/recall, and
// strategies never receive deposits through the base deposit(). This suite
// exercises the BASE implementations directly through two minimal concrete
// children, plus the recall clamp/early-return edges (the money path).
//
// Run: forge test --match-path 'test/forge/BaseStrategy.coverage.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {BaseStrategy} from "../../contracts/BaseStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";

/// No overrides: exercises the BASE name(), totalAssets(), _doHarvest(),
/// deposit(), recall(), setters.
contract BareStrategy is BaseStrategy {
    constructor(address u, address o) BaseStrategy(u, o, "BareTest") {}
}

/// Only _doHarvest overridden (configurable profit) — exercises the base
/// harvest() booking path with a real profit.
contract YieldBumpStrategy is BaseStrategy {
    uint256 public bump;

    constructor(address u, address o) BaseStrategy(u, o, "YieldBump") {}

    function setBump(uint256 b) external {
        bump = b;
    }

    function _doHarvest() internal override returns (uint256) {
        return bump;
    }
}

contract BaseStrategyCoverageTest is Test {
    MockUSDC usdc;
    BareStrategy bare;
    YieldBumpStrategy yb;
    address keeper = makeAddr("keeper");
    address vault_ = makeAddr("vault");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC();
        bare = new BareStrategy(address(usdc), address(this));
        yb = new YieldBumpStrategy(address(usdc), address(this));
    }

    /*//////////////////// Constructor guards ////////////////////*/

    function test_constructor_zero_underlying_reverts() public {
        vm.expectRevert(bytes("BaseStrategy: zero underlying"));
        new BareStrategy(address(0), address(this));
    }

    function test_constructor_zero_owner_reverts() public {
        // OZ v5 Ownable reverts first with its own error before our require
        vm.expectRevert();
        new BareStrategy(address(usdc), address(0));
    }

    function test_constructor_sets_state() public {
        assertEq(bare.name(), "BareTest"); // base name() default path
        assertTrue(bare.isActive());
        assertEq(bare.lastHarvest(), block.timestamp);
        assertEq(address(bare.underlying()), address(usdc));
        assertEq(bare.owner(), address(this));
    }

    /*//////////////////// Base deposit() (dead in product, alive in code) ////////////////////*/

    function test_base_deposit_zero_reverts() public {
        vm.expectRevert(bytes("BaseStrategy: zero amount"));
        bare.deposit(0);
    }

    function test_base_deposit_credits_shares_and_pulls_tokens() public {
        usdc.mint(stranger, 100e6);
        vm.startPrank(stranger);
        usdc.approve(address(bare), 100e6);
        vm.expectEmit(true, true, true, true, address(bare));
        emit BaseStrategy.Deposit(stranger, 100e6);
        bare.deposit(100e6);
        vm.stopPrank();

        assertEq(bare.shares(stranger), 100e6);
        assertEq(usdc.balanceOf(address(bare)), 100e6);
    }

    /*//////////////////// Base harvest() + default _doHarvest() ////////////////////*/

    function test_base_harvest_default_doHarvest_is_noop() public {
        vm.expectEmit(true, true, true, true, address(bare));
        emit BaseStrategy.Harvest(0);
        bare.harvest(); // base _doHarvest returns 0
        assertEq(bare.totalDebt(), 0);
        assertEq(bare.lastHarvest(), block.timestamp);
    }

    function test_base_harvest_books_profit_into_totalDebt() public {
        yb.setBump(7e6);
        vm.expectEmit(true, true, true, true, address(yb));
        emit BaseStrategy.Harvest(7e6);
        yb.harvest();
        assertEq(yb.totalDebt(), 7e6);
        assertEq(yb.lastHarvest(), block.timestamp);
    }

    function test_base_harvest_cumulative_across_cycles() public {
        yb.setBump(3e6);
        yb.harvest();
        yb.setBump(4e6);
        yb.harvest();
        assertEq(yb.totalDebt(), 7e6);
    }

    function test_base_harvest_reverts_when_inactive() public {
        bare.setActive(false);
        vm.expectRevert(bytes("BaseStrategy: inactive"));
        bare.harvest();
    }

    /*//////////////////// Setters: guards + events ////////////////////*/

    function test_setKeeper_guards_and_event() public {
        vm.prank(stranger);
        vm.expectRevert();
        bare.setKeeper(keeper); // onlyOwner

        vm.expectRevert(bytes("BaseStrategy: zero keeper"));
        bare.setKeeper(address(0));

        vm.expectEmit(true, true, true, true, address(bare));
        emit BaseStrategy.KeeperSet(keeper);
        bare.setKeeper(keeper);
        assertEq(bare.keeper(), keeper);
    }

    function test_setVault_guards_and_event() public {
        vm.prank(stranger);
        vm.expectRevert();
        bare.setVault(vault_); // onlyOwner

        vm.expectRevert(bytes("BaseStrategy: zero vault"));
        bare.setVault(address(0));

        vm.expectEmit(true, true, true, true, address(bare));
        emit BaseStrategy.VaultSet(vault_);
        bare.setVault(vault_);
        assertEq(bare.vault(), vault_);
    }

    function test_setActive_both_directions_and_event() public {
        vm.expectEmit(true, true, true, true, address(bare));
        emit BaseStrategy.ActiveChanged(false);
        bare.setActive(false);
        assertFalse(bare.isActive());

        vm.expectEmit(true, true, true, true, address(bare));
        emit BaseStrategy.ActiveChanged(true);
        bare.setActive(true);
        assertTrue(bare.isActive());
    }

    function test_setActive_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        bare.setActive(false);
    }

    /*//////////////////// recall(): the money path ////////////////////*/

    function test_recall_only_vault() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("BaseStrategy: not vault"));
        bare.recall(1e6);
    }

    function test_recall_clamps_at_real_balance() public {
        bare.setVault(vault_);
        usdc.mint(address(bare), 5e6); // only $5 exists

        vm.prank(vault_);
        bare.recall(99e6); // ask for $99 → clamped to $5
        assertEq(usdc.balanceOf(vault_), 5e6);
        assertEq(usdc.balanceOf(address(bare)), 0);
    }

    function test_recall_zero_request_is_silent_noop() public {
        bare.setVault(vault_);
        usdc.mint(address(bare), 5e6);

        vm.prank(vault_);
        bare.recall(0); // early return — no transfer, no revert
        assertEq(usdc.balanceOf(address(bare)), 5e6); // tokens stay put
        assertEq(usdc.balanceOf(vault_), 0); // nothing moved

        // balance 0 + request > 0 → clamp to 0 → early return too
        BareStrategy empty = new BareStrategy(address(usdc), address(this));
        empty.setVault(vault_);
        vm.prank(vault_);
        empty.recall(1e6);
        assertEq(usdc.balanceOf(vault_), 0); // still nothing moved
    }

    function test_recall_full_success_path() public {
        bare.setVault(vault_);
        usdc.mint(address(bare), 10e6);

        vm.prank(vault_);
        bare.recall(10e6);
        assertEq(usdc.balanceOf(vault_), 10e6);
        assertEq(usdc.balanceOf(address(bare)), 0);
    }

    /*//////////////////// Base totalAssets() default ////////////////////*/

    function test_base_totalAssets_is_idle_balance() public {
        assertEq(bare.totalAssets(), 0);
        usdc.mint(address(bare), 42e6);
        assertEq(bare.totalAssets(), 42e6); // base default: balanceOf
    }
}
