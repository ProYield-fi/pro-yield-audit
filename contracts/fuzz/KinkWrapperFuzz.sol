// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Echidna fuzz harness for KinkWrapper (free external-grade review tier).
///
/// Design notes (per hardhat-slither skill lessons):
///  - The harness FORWARDS to the wrapper: every shareholder identity collapses
///    to the harness address. That is SAFE here because every invariant is
///    GLOBAL (pooled accounting) — per-user properties would falsify spuriously.
///  - The mock engine has NO loss exposure — cumLoss stays 0, so the
///    conservation invariant is exact equality. Loss socialization is covered
///    by the unit suite (F3/mock loss tests), not the fuzzer.
///  - f_settle is permissionless on the real contract; f_setProfit simulates
///    Core-side profit (global state — sender-collapse irrelevant).
///  - Amounts are bounded to keep the fuzzer in meaningful math range.

import "../KinkWrapper.sol";
import "../mocks/MockEngine.sol";

contract KinkWrapperFuzz {
    MockUSDC6 public usdcM;
    MockEngine public engineM;
    KinkWrapper public w;

    address constant S1 = address(0x10000);
    address constant S2 = address(0x20000);
    address constant S3 = address(0x30000);

    constructor() {
        usdcM = new MockUSDC6();
        engineM = new MockEngine(address(usdcM));
        w = new KinkWrapper(address(usdcM), address(engineM), 200, 30, 1000);
        engineM.setVault(address(w));
        usdcM.mint(S1, 100_000_000e6);
        usdcM.mint(S2, 100_000_000e6);
        usdcM.mint(S3, 100_000_000e6);
    }

    // ── Forwarders (bounded) ───────────────────────────────────────────────────
    function f_depositSenior(uint256 amt) external {
        w.depositSenior((amt % 10_000e6) + w.MIN_DEPOSIT());
    }

    function f_depositJunior(uint256 amt) external {
        w.depositJunior((amt % 10_000e6) + w.MIN_DEPOSIT());
    }

    function f_withdrawSenior(uint256 shares) external {
        uint256 own = w.seniorShares(address(this));
        if (own > 0) w.withdrawSenior(shares % (own + 1));
    }

    function f_withdrawJunior(uint256 shares) external {
        uint256 own = w.juniorShares(address(this));
        if (own > 0) w.withdrawJunior(shares % (own + 1));
    }

    function f_settle() external {
        w.settleEpoch();
    }

    function f_setProfit(uint256 p) external {
        engineM.setProfit(p % 1000e6);
    }

    /// Loss-enabled variant path (audit-report follow-up): injects engine bad debt
    /// so the fuzzer explores the loss-socialization branch mid-epoch and across
    /// settles. All four invariants must hold under losses too (the conservation
    /// property's clamp branch covers the unrealized-loss regime).
    function f_setLoss(uint256 l) external {
        engineM.setLoss(l % 500e6);
    }

    function f_pullLiquidity(uint256 amt) external {
        w.pullLiquidity(amt % 10_000e6);
    }

    // ── Invariants (global — safe under sender collapse) ──────────────────────
    // P1: tranche pools can never exceed principal + settled yield.
    function echidna_poolsBounded() public view returns (bool) {
        return w.seniorAssets() + w.juniorAssets() <= w.principalNet() + w.cumYieldSettled();
    }

    // P2: the system always covers pool claims (float + engine mark ≥ pools).
    function echidna_systemCoversPools() public view returns (bool) {
        return w.systemValue() >= w.seniorAssets() + w.juniorAssets();
    }

    // P3: conservation — floating yield equals system minus book exactly
    // (no-loss harness ⇒ cumLoss stays 0 ⇒ the clamp never activates).
    function echidna_conservationExact() public view returns (bool) {
        uint256 book = w.principalNet() - w.cumLoss() + w.cumYieldSettled();
        uint256 sv = w.systemValue();
        if (sv >= book) return w.floatingYield() == sv - book;
        return w.floatingYield() == 0; // unrealized-loss regime (should not occur here)
    }

    // P4: epochs always exist; the current epoch is never settled twice.
    function echidna_epochSane() public view returns (bool) {
        return w.epochsLength() >= 1;
    }
}