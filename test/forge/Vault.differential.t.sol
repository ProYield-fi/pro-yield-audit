// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Item 4b — long-horizon differential sim: an INDEPENDENT integer model
// (plain uint accounting written from the spec — no vault code involved) runs
// the same randomized op sequence as the deployed contract, and after EVERY
// op asserts exact equality between the model and on-chain accounting:
//   - totalAssets / totalShares / per-actor shares
//   - cash conservation: usdc(vault) + usdc(s1) + usdc(s2) == model.A + unswept
//   - fee exactness: FD balance delta == modeled performance fee
//   - share-price floor: A >= S at all times
// Ops: deposit / withdraw / fund-yield / harvest / recycle (route+credit) / warp.
// allocate+recall is deliberately excluded (money LOCATION, not accounting —
// covered by Vault.invariants.t.sol solvency + recall tests); with everything
// idle the model can demand exact — not just >= — conservation.

import {Test} from "forge-std/Test.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {YieldStrategy} from "./Vault.invariants.t.sol";

contract VaultDifferentialTest is Test {
    ProYieldVault vault;
    MockUSDC usdc;
    FeeDistributor fd;
    YieldStrategy s1;
    YieldStrategy s2;
    address[3] actors;

    // ── independent model ────────────────────────────────────────────
    uint256 mAssets; // modeled totalAssets
    uint256 mShares; // modeled totalShares
    mapping(address => uint256) mUserShares;
    uint256 mPending; // yield minted into strategies, not yet swept
    uint256 mFeeBps;
    uint256 mNonce;

    uint256 constant SHARE_OFFSET = 1e3;

    function setUp() public {
        usdc = new MockUSDC();
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        s1 = new YieldStrategy(address(usdc), address(this));
        s2 = new YieldStrategy(address(usdc), address(this));
        vault.addStrategy(address(s1));
        vault.addStrategy(address(s2));
        s1.setVault(address(vault));
        s2.setVault(address(vault));
        mFeeBps = vault.performanceFee();
        for (uint256 i; i < 3; i++) {
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // ── model math (mirrors the spec, written independently) ─────────
    function _modelToShares(uint256 assets) internal view returns (uint256) {
        if (mShares == 0) return assets;
        return (assets * (mShares + SHARE_OFFSET)) / (mAssets + SHARE_OFFSET);
    }

    function _modelToAssets(uint256 sh) internal view returns (uint256) {
        if (mShares == 0) return sh;
        return (sh * (mAssets + SHARE_OFFSET)) / (mShares + SHARE_OFFSET);
    }

    /// Deterministic PRNG: same seed ⇒ same sequence (seeded by the fuzzer
    /// in the short variant, fixed in the long-horizon variant).
    function _rand(uint256 mod) internal returns (uint256) {
        require(mod > 0, "rand mod 0");
        mNonce++;
        return uint256(keccak256(abi.encode(mNonce, block.timestamp))) % mod;
    }

    function _check() internal view {
        assertEq(vault.totalAssets(), mAssets, "totalAssets diverged");
        assertEq(vault.totalShares(), mShares, "totalShares diverged");
        for (uint256 i; i < 3; i++) {
            assertEq(vault.shares(actors[i]), mUserShares[actors[i]], "user shares diverged");
        }
        assertEq(
            usdc.balanceOf(address(vault)) + usdc.balanceOf(address(s1)) + usdc.balanceOf(address(s2)),
            mAssets + mPending,
            "cash != modeled assets + unswept yield"
        );
        if (mShares > 0) {
            assertGe(mAssets, mShares, "share price below one");
        }
    }

    function _step() internal {
        uint256 op = _rand(6);
        if (op == 0) {
            // deposit
            address a = actors[_rand(3)];
            uint256 amount = 1 + _rand(1e18);
            uint256 sh = _modelToShares(amount);
            if (sh == 0) return; // contract would revert on zero shares
            usdc.mint(a, amount);
            vm.prank(a);
            vault.deposit(amount);
            mUserShares[a] += sh;
            mShares += sh;
            mAssets += amount;
        } else if (op == 1) {
            // withdraw
            address a = actors[_rand(3)];
            uint256 max = _modelToAssets(mUserShares[a]);
            if (max == 0) return;
            uint256 amount = 1 + _rand(max);
            uint256 sh = _modelToShares(amount);
            if (sh == 0 || sh > mUserShares[a]) return;
            uint256 balBefore = usdc.balanceOf(a);
            vm.prank(a);
            vault.withdraw(amount);
            assertEq(usdc.balanceOf(a), balBefore + amount, "withdraw paid wrong amount");
            mUserShares[a] -= sh;
            mShares -= sh;
            mAssets -= amount;
        } else if (op == 2) {
            // honest venue yield lands in a strategy (unswept)
            uint256 amount = 1 + _rand(1e18);
            ( _rand(2) == 0 ? s1 : s2 ).fund(amount);
            mPending += amount;
        } else if (op == 3) {
            // harvest: sweep everything + take the performance fee
            uint256 fdBefore = usdc.balanceOf(address(fd));
            uint256 profit = mPending;
            uint256 fee = (profit * mFeeBps) / 10000;
            vault.harvest();
            assertEq(usdc.balanceOf(address(fd)) - fdBefore, fee, "fee taken != modeled fee");
            if (profit > fee) {
                mAssets += profit - fee;
            }
            mPending = 0;
        } else if (op == 4) {
            // recycle: FD routes fresh USDC in, then creditYield (the exact
            // pairing the ops policy uses — credit only what just arrived)
            uint256 x = 1 + _rand(1e18);
            usdc.mint(address(fd), x);
            fd.route(address(vault), x);
            vault.creditYield(x);
            mAssets += x;
        } else {
            // long-horizon drift
            vm.warp(block.timestamp + 1 + _rand(7 days));
        }
    }

    /// Deep deterministic run — 1200 ops, checked after every op.
    function test_differential_long_horizon() public {
        mNonce = 0x5eed;
        for (uint256 i; i < 1200; i++) {
            _step();
            _check();
        }
        // public helper consistency at the final state
        assertEq(vault.convertToAssets(1e18), _modelToAssets(1e18), "convertToAssets diverged");
        for (uint256 i; i < 3; i++) {
            assertEq(vault.maxWithdraw(actors[i]), _modelToAssets(mUserShares[actors[i]]), "maxWithdraw diverged");
        }
    }

    /// Fuzzed variants (shorter) over random seeds.
    function testFuzz_differential_short(uint96 seed) public {
        mNonce = uint256(seed) | 1;
        for (uint256 i; i < 60; i++) {
            _step();
            _check();
        }
    }
}