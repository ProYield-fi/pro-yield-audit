// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ROUND-2 FIX TESTS — the two green-lit fixes, proven executable.
//
// A) Keeper/split fix (round-2 HIGH-1): bridgeBackToEvm now splits
//    PROFIT-FIRST. A profit-sized skim (the keeper's amount, equity-principal)
//    realizes profit while the principal (hedge margin) stays on Core; a full
//    drain behaves as before. Losses (equity < principal) book as principal.
//
// B) Vault loss accounting (round-2 H1): reportLoss() lets the owner write
//    booked liabilities down to real backing (loss socialises pro-rata), and
//    withdrawUpTo() is the partial-redemption escape hatch: it pays what
//    idle+recallable can actually cover instead of reverting on phantom value.
//    Shares burn only for what is paid.
//
// Run: forge test --match-path 'test/forge/Fixes.round2.t.sol' -vv

import {Test} from "forge-std/Test.sol";
import {DNCoreStrategy} from "../../contracts/DNCoreStrategy.sol";
import {ProYieldVault} from "../../contracts/ProYieldVault.sol";
import {FeeDistributor} from "../../contracts/FeeDistributor.sol";
import {BaseStrategy} from "../../contracts/BaseStrategy.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {
    MockCoreUserExists,
    MockMarginSummary,
    MockPosition2
} from "../../contracts/mocks/MockPrecompiles.sol";
import {MockCoreWriter, MockCoreDepositWallet} from "../../contracts/mocks/MockCoreWriter.sol";

/*//////////////////////// A) DN split fix ////////////////////////*/

contract Round2SplitFixTest is Test {
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

        MockPosition2 pos = new MockPosition2();
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

    /// @dev The keeper's exact BRIDGE_PROFIT amount (equity - principal) must
    /// realize profit AND leave the principal (hedge margin) on Core.
    function test_fix_keeperProfitOnlyBridge_realizesAndSweeps() public {
        assertEq(strat.corePrincipal6(), 500_000_000, "principal before");
        assertEq(strat.coreEquity6(), 505_000_000, "equity before");

        vm.prank(keeper);
        strat.bridgeBackToEvm(5_000_000); // dn_keeper BRIDGE_PROFIT amount

        assertEq(strat.corePrincipal6(), 500_000_000, "FIX: principal untouched by profit skim");
        assertEq(strat.coreEquity6(), 500_000_000, "equity reduced by exactly the skim");
        assertEq(strat.profitRealized(), 5 * U, "FIX: profit realized");
        assertEq(strat.harvestableProfit(), 5 * U, "harvestable");

        // Simulate the Core->EVM credit, then the vault-side sweep. Buffer 0
        // so the skim is fully sweepable in this scenario.
        strat.setBufferBps(0);
        usdc.mint(address(strat), 5 * U);
        vm.prank(dnVault);
        strat.harvest();
        assertEq(strat.profitSwept(), 5 * U, "swept recorded");
        assertEq(usdc.balanceOf(dnVault), 5 * U, "FIX: vault received the profit");
    }

    /// @dev Full-amount drain (end of life) keeps its old, correct behavior.
    function test_fix_fullAmountBridge_unchanged() public {
        usdc.mint(address(strat), 505 * U);
        vm.prank(keeper);
        strat.bridgeBackToEvm(505_000_000);

        assertEq(strat.corePrincipal6(), 0, "principal fully returned");
        assertEq(strat.profitRealized(), 5 * U, "profit realized");
        assertEq(strat.harvestableProfit(), 5 * U, "harvestable");

        strat.setBufferBps(0);
        vm.prank(dnVault);
        strat.harvest();
        assertEq(usdc.balanceOf(dnVault), 5 * U, "vault swept");
    }

    /// @dev Loss (equity < principal): every bridged unit is principal —
    /// no phantom profit from a drawdown.
    function test_fix_lossEquityBelowPrincipal_noPhantomProfit() public {
        MockMarginSummary(P_80F).set(490_000_000, 0, 0, 0);
        strat.syncCore();
        assertEq(strat.coreEquity6(), 490_000_000, "equity shows the loss");

        vm.prank(keeper);
        strat.bridgeBackToEvm(5_000_000);

        assertEq(strat.profitRealized(), 0, "no profit in a loss");
        assertEq(strat.corePrincipal6(), 495_000_000, "bridge reduces principal only");
        assertEq(strat.coreEquity6(), 485_000_000, "equity consistent");
    }
}

/*//////////////////////// B) Vault loss accounting ////////////////////////*/

/// @dev Minimal strategy that can LOSE funds (sink them out of reach),
/// standing in for a venue loss.
contract LossyStrategy is BaseStrategy {
    constructor(address _underlying, address owner_)
        BaseStrategy(_underlying, owner_, "LossyStrategy")
    {}

    function name() external view override returns (string memory) {
        return "LossyStrategy";
    }

    function sink(uint256 amount) external {
        require(MockUSDC(address(underlying)).transfer(address(0xDEAD), amount), "sink failed");
    }
}

contract Round2VaultLossFixTest is Test {
    MockUSDC usdc;
    FeeDistributor fd;
    ProYieldVault vault;
    LossyStrategy strat;

    uint256 constant U = 1e18;
    address user1 = address(0xA11CE);
    address user2 = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        strat = new LossyStrategy(address(usdc), address(this));
        vault.addStrategy(address(strat));
        strat.setVault(address(vault));
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        vault.deposit(amount);
    }

    /// Scenario: 2 × 1000 deposited; 1800 allocated then LOST at the venue.
    /// reportLoss(1800) socialises the loss — both users exit with their fair
    /// 100 each (nobody trapped, nobody overpaid).
    function test_fix_reportLoss_socialises_bothUsersExit() public {
        _fund(user1, 1_000 * U);
        _fund(user2, 1_000 * U);
        _deposit(user1, 1_000 * U);
        _deposit(user2, 1_000 * U);

        vault.allocate(); // 1800 to the strategy, 200 reserve stays idle
        assertEq(usdc.balanceOf(address(strat)), 1_800 * U, "allocated");
        strat.sink(1_800 * U); // venue loss

        // Pre-fix: books still claim 2000 while only 200 backs them.
        assertEq(vault.totalAssets(), 2_000 * U, "phantom books before write-down");

        vault.reportLoss(1_800 * U); // owner reconciles to real backing
        assertEq(vault.totalAssets(), 200 * U, "honest books after write-down");

        uint256 v1 = vault.convertToAssets(vault.shares(user1));
        uint256 v2 = vault.convertToAssets(vault.shares(user2));
        assertApproxEqAbs(v1, 100 * U, 1e6, "user1 fair value");
        assertApproxEqAbs(v2, 100 * U, 1e6, "user2 fair value");

        vm.prank(user1);
        vault.withdraw(100 * U);
        vm.prank(user2);
        vault.withdraw(100 * U);
        assertEq(usdc.balanceOf(user1), 100 * U, "user1 paid her fair share");
        assertEq(usdc.balanceOf(user2), 100 * U, "user2 paid her fair share - NOT trapped");
        assertEq(vault.totalAssets(), 0, "fully reconciled");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault drained exactly");
    }

    /// Unreported loss: withdrawUpTo still lets users out with what exists
    /// instead of reverting on phantom value (partial redemption path).
    function test_fix_withdrawUpTo_partialUnderUnreportedLoss() public {
        _fund(user1, 1_000 * U);
        _fund(user2, 1_000 * U);
        _deposit(user1, 1_000 * U);
        _deposit(user2, 1_000 * U);
        vault.allocate();
        strat.sink(1_800 * U);

        // Pre-fix: withdraw(1000) reverts (transfer of phantom value fails).
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1_000 * U);

        // Escape hatch: user1 asks for everything, gets the real 200 idle.
        vm.prank(user1);
        uint256 paid = vault.withdrawUpTo(1_000 * U);
        assertEq(paid, 200 * U, "paid what actually exists");
        assertEq(usdc.balanceOf(user1), 200 * U, "user1 escaped with real backing");
        assertEq(vault.shares(user1), 800 * U, "shares burned only for what was paid");
        assertEq(vault.totalAssets(), 1_800 * U, "book still phantom until owner reports (documented gap)");

        // Nothing left to pay — second mover reverts honestly, not silently.
        vm.prank(user2);
        vm.expectRevert("ProYieldVault: no liquidity");
        vault.withdrawUpTo(1_000 * U);
    }

    /// Healthy path: withdrawUpTo pays exactly the caller's share value and
    /// can never overpay.
    function test_fix_withdrawUpTo_neverOverpays() public {
        _fund(user1, 1_000 * U);
        _deposit(user1, 1_000 * U);

        vm.prank(user1);
        uint256 paid = vault.withdrawUpTo(type(uint256).max);
        assertEq(paid, 1_000 * U, "asks max, gets exactly the share value");
        assertEq(usdc.balanceOf(user1), 1_000 * U, "full exit");
        assertEq(vault.shares(user1), 0, "all shares burned");

        // Partial request: pays the amount asked, keeps the rest of the claim.
        _fund(user1, 500 * U);
        _deposit(user1, 500 * U);
        vm.prank(user1);
        uint256 paid2 = vault.withdrawUpTo(200 * U);
        assertEq(paid2, 200 * U, "partial request honored");
        assertEq(vault.convertToAssets(vault.shares(user1)), 300 * U, "rest of claim retained");
    }

    /// reportLoss permissioning + bounds.
    function test_fix_reportLoss_ownerOnly_andBounded() public {
        _fund(user1, 100 * U);
        _deposit(user1, 100 * U);

        vm.prank(user1);
        vm.expectRevert(); // OZ v5 Ownable custom error
        vault.reportLoss(1 * U);

        vm.expectRevert("ProYieldVault: exceeds assets");
        vault.reportLoss(101 * U);

        vm.expectEmit(true, true, true, true, address(vault));
        emit LossReported(50 * U);
        vault.reportLoss(50 * U);
        assertEq(vault.totalAssets(), 50 * U, "write-down applied");
    }

    /// Same signature as the vault's event so expectEmit matches exactly.
    event LossReported(uint256 amount);
}
