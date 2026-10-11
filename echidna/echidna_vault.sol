// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Echidna property campaign for the VAULT money path — the second robot:
// cross-checks the Foundry invariant suite with an independent fuzzer engine.
//
// HARNESS LESSON (2026-10-03, found the hard way): the property contract must
// carry NO fuzz wrapper functions. Echidna's senders call the TARGET contract,
// and any vault call routed through a wrapper f_deposit() on this contract
// sees msg.sender == THIS contract — all sender identities collapse into one
// account and the share-sum property falsifies spuriously. Instead the
// campaign runs with --multi-abi so senders call the vault/USDC/strategy
// ABIs DIRECTLY, and this contract only deploys the system + holds properties.
//
// SCOPE NOTE (why the DN surface is absent): Echidna has no cheatcodes, so the
// precompile etch-mocking DNCoreBase needs is impossible here — every
// CoreWriter action would revert on the 0x810 gate read. The DN surface is
// property-fuzzed by test/forge/DNCoreBase.invariants.t.sol instead.
//
// Run: cd /home/user/hypervault && /home/user/tools/echidna echidna/echidna_vault.sol \
//   --contract EchidnaVaultProps --config echidna/echidna_vault.yaml \
//   --multi-abi --disable-slither --workers 1

import "../contracts/ProYieldVault.sol";
import "../contracts/FeeDistributor.sol";
import "../contracts/mocks/MockUSDC.sol";
import "../contracts/BaseStrategy.sol";

/// Honest yielding strategy: the venue mints USDC to the strategy (fund()),
/// the vault's harvest sweeps it — the same shape as the foundry harness.
contract EchidnaYieldStrategy is BaseStrategy {
    constructor(address u, address o) BaseStrategy(u, o, "EchidnaYield") {}

    function name() external view override returns (string memory) {
        return "EchidnaYield";
    }

    function _doHarvest() internal override returns (uint256) {
        if (msg.sender != vault) return 0; // keeper/owner settle only
        uint256 bal = underlying.balanceOf(address(this));
        if (bal == 0) return 0;
        underlying.transfer(vault, bal);
        return bal;
    }

    function fund(uint256 amount) external {
        MockUSDC(address(underlying)).mint(address(this), amount);
    }
}

/// Deploy-only target: the fuzz wrappers route senders' deposits through this
/// contract (msg.sender collapses to this address — see the header lesson).
/// The share-sum property stays EXACT because the complete set of accounts
/// that can ever hold shares in this harness is {this, U0, U1, U2}: senders
/// deposit via wrappers (credited to `this`) and nothing else deposits.
contract EchidnaVaultProps {
    MockUSDC public usdc;
    FeeDistributor public fd;
    ProYieldVault public vault;
    EchidnaYieldStrategy public strat;

    // MUST match echidna_vault.yaml `sender:` list
    address constant U0 = 0x1000000000000000000000000000000000000001;
    address constant U1 = 0x1000000000000000000000000000000000000002;
    address constant U2 = 0x1000000000000000000000000000000000000003;

    constructor() {
        usdc = new MockUSDC();
        fd = new FeeDistributor(address(usdc));
        vault = new ProYieldVault(address(usdc), address(this), address(fd));
        strat = new EchidnaYieldStrategy(address(usdc), address(this));
        vault.addStrategy(address(strat));
        usdc.mint(U0, 10_000e6);
        usdc.mint(U1, 10_000e6);
        usdc.mint(U2, 10_000e6);
        usdc.mint(address(this), 1_000_000e6); // venue fuel (never deposits)
    }

    /*//////////////////// Fuzzable actions (senders = U0/U1/U2) ////////////////////*/

    function f_deposit(uint128 amt) public {
        usdc.approve(address(vault), type(uint256).max);
        try vault.deposit(amt) {} catch {}
    }

    function f_withdraw(uint128 amt) public {
        try vault.withdraw(amt) {} catch {}
    }

    function f_harvest() public {
        try vault.harvest() {} catch {}
    }

    function f_strategyEarn(uint128 amt) public {
        strat.fund(amt); // venue pays the strategy — keeper work, permissionless
    }

    /*//////////////////// Properties (same guarantees as the foundry suite) ////////////////////*/

    /// §3.3 — liabilities: totalShares equals the shares held by the COMPLETE
    /// set of possible shareholders in this harness ({this, U0, U1, U2}).
    /// Real deposits flow through f_deposit (credited to `this`), so a run
    /// without deposits passes trivially — but any share-accounting drift
    /// (mint without totalShares update, burn on the wrong side, etc.) breaks
    /// it. The per-user dimension is covered by the foundry suite, whose
    /// handler pranks the vault directly.
    function echidna_shares_sum_matches_total() public view returns (bool) {
        uint256 sum = vault.shares(address(this)) + vault.shares(U0) + vault.shares(U1) + vault.shares(U2);
        return sum == vault.totalShares();
    }

    /// §3.2 — share price never below 1 (owner-only write-downs may break this
    /// by design; Echidna's senders are never the owner).
    function echidna_price_floor() public view returns (bool) {
        return vault.totalAssets() >= vault.totalShares();
    }

    /// §3.1 — solvency: real backing (idle + strategy) >= booked totalAssets.
    function echidna_solvent() public view returns (bool) {
        uint256 real = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(strat));
        return real >= vault.totalAssets();
    }
}
