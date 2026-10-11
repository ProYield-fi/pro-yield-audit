// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// CreditPool/FrontierBase invariant suite — property fuzzing over the gated
// frontier surface:
//   1. Pool principal can only exist if the venue was DD-cleared
//   2. The per-name cap ceiling can never be raised above 15%
//   3. totalAssets is ALWAYS exactly idle + the venue mark (no drift)
//   4. After a harvest, the baseline never sits above the mark (a loss is
//      re-baselined at the harvest that observes it — no negative-profit hole)
//   5. USDC is conserved across the whole harness (mint-only token)
//
// Run: forge test --match-path 'test/forge/CreditPool.invariants.t.sol'

import {Test} from "forge-std/Test.sol";
import {CreditPoolStrategy} from "../../contracts/CreditPoolStrategy.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockCreditPool} from "../../contracts/mocks/MockCreditPool.sol";

contract CreditPoolHandler is Test {
    MockUSDC public usdc;
    ProYieldVault public vault;
    FeeDistributor public fd;
    MockCreditPool public pool;
    CreditPoolStrategy public strat;
    address[3] public actors; // [owner, keeper, stranger]
    address public vaultAddr = makeAddr("vault");

    uint256 public totalMinted;

    constructor(address[3] memory actors_) {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), actors_[0], address(fd));
        pool = new MockCreditPool(usdc);
        strat = new CreditPoolStrategy(address(usdc), actors_[0], address(pool));
        actors = actors_;
        vm.prank(actors_[0]);
        strat.setKeeper(actors_[1]);
        vm.prank(actors_[0]);
        strat.setVault(address(vault));
        vm.prank(actors_[0]);
        vault.addStrategy(address(strat));

        // a real book so the cap has a denominator
        usdc.mint(actors_[0], 20_000e18);
        totalMinted += 20_000e18;
        vm.prank(actors_[0]);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(actors_[0]);
        vault.deposit(10_000e18); // book 10,000 → the venue can hold ≤1,500
        _topUp(1_500e18); // seed the strategy to its cap edge
    }

    function _topUp(uint256 amount) internal {
        usdc.mint(address(this), amount);
        totalMinted += amount;
        usdc.transfer(address(strat), amount);
    }

    /*//////////////////// fuzz actions ////////////////////*/

    function setVenueCleared(uint256 role, bool cleared) external {
        address a = actors[role % 3];
        vm.prank(a);
        try strat.setVenueCleared(cleared) {} catch {}
    }

    function setMaxShareBps(uint256 role, uint256 bps) external {
        address a = actors[role % 3];
        vm.prank(a);
        try strat.setMaxShareBps(bps) {} catch {}
    }

    function topUp(uint256 amount) external {
        _topUp(amount % 5_000e18);
    }

    function deploy(uint256 role) external {
        address a = actors[role % 3];
        bool clearedBefore = strat.venueCleared();
        uint256 tokensBefore = pool.positionTokens(address(strat));
        vm.prank(a);
        try strat.deploy() {} catch {}
        // POST-CONDITION at the exact moment: if pool tokens grew, the venue
        // was DD-cleared when it happened. (A global "tokens imply cleared"
        // invariant is timing-blind: tokens legitimately remain after a
        // re-lock, and end-of-sequence checks can't see when growth happened.)
        if (pool.positionTokens(address(strat)) > tokensBefore) {
            assertTrue(clearedBefore, "supplied while not DD-cleared");
        }
    }

    function injectYield(uint256 bps) external {
        pool.injectYieldBps(bps % 3000);
    }

    function injectLoss(uint256 bps) external {
        pool.injectLossBps(bps % 3000);
    }

    function recallAsVault(uint256 amount) external {
        vm.prank(address(vault));
        try strat.recall(amount % 2_000e18) {} catch {}
    }

    function harvest() external {
        vm.prank(address(vault));
        try strat.harvest() {} catch {}
        // POST-CONDITION of the harvest action: after it re-baselines, the
        // baseline never sits above the mark. (Between a loss and its
        // observing harvest, baseline > mark is DESIGNED — the loss shows in
        // the mark instantly; the baseline catches up at that harvest.)
        assertLe(strat.lastHarvestPosition(), strat.positionValue(), "harvest left a stale baseline above the mark");
    }

    function depositToVault(uint256 amount) external {
        vm.prank(actors[0]);
        try vault.deposit(amount % 2_000e18) {} catch {}
    }
}

contract CreditPoolInvariants is Test {
    CreditPoolHandler public handler;
    CreditPoolStrategy public strat;

    function setUp() public {
        address[3] memory actors = [makeAddr("owner"), makeAddr("keeper"), makeAddr("stranger")];
        handler = new CreditPoolHandler(actors);
        strat = handler.strat();
        // TARGET THE HANDLER ONLY. Without this, foundry also drives every
        // public function of the transitively-deployed contracts — the fuzzer
        // called MockCreditPool.supply/injectLossBps directly, bypassing the
        // DD gate and overflowing the knob math. (Lesson from the DNCoreBase
        // round: gate mocks that represent single-caller system components —
        // or restrict the target set, which is what we do here.)
        targetContract(address(handler));
    }

    /// 1. (Moved into the handler's deploy() as a post-condition: pool tokens
    /// may only grow while DD-cleared. Tokens remaining after a re-lock is
    /// correct — the re-lock never traps money.)

    /// 2. The per-name cap ceiling is policy-immutable: ≤15% always.
    function invariant_cap_ceiling_immutable() public view {
        assertLe(strat.maxShareBps(), 1500, "cap ceiling was raised");
    }

    /// 3. totalAssets is exactly idle + venue mark — no accounting drift.
    function invariant_totalAssets_identity() public view {
        assertEq(
            strat.totalAssets(),
            handler.usdc().balanceOf(address(strat)) + strat.positionValue(),
            "totalAssets drifted from idle + mark"
        );
    }

    /// 4. (Moved into the handler's harvest() as a post-condition: between a
    /// loss and its observing harvest, baseline > mark is designed behavior.)

    /// 5. USDC conserved: minted == Σ balances (transfers never burn).
    function invariant_usdc_conserved() public view {
        uint256 total = handler.usdc().balanceOf(address(handler.vault()))
            + handler.usdc().balanceOf(address(strat))
            + handler.usdc().balanceOf(address(handler.pool()))
            + handler.usdc().balanceOf(address(handler)) // the handler mints top-ups
            + handler.usdc().balanceOf(handler.actors(0))
            + handler.usdc().balanceOf(handler.actors(1))
            + handler.usdc().balanceOf(handler.actors(2));
        assertEq(total, handler.totalMinted(), "USDC vanished or appeared");
    }
}
