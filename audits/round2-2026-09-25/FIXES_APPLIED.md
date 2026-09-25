# Round-2 fixes applied — 2026-09-25

Executable remediation for the two deploy-gate items green-lit from
`REPORT.md` (round-2). Every claim below is backed by a forge run on this
date; commands and outputs are reproducible.

## 1. HIGH-1 — keeper profit-bridge booked as principal (FIXED)

**Root cause (deeper than the report's phrasing):** `bridgeBackToEvm` split
outflows *principal-first* (`principalRed = min(amount, principal)`). That
split is only correct for a full drain; for the keeper's profit-sized skim
(`amount = equity - principal`) it booked **the whole skim as principal
return** — `profitRealized` stayed 0, `harvestableProfit()` stayed 0, the
vault's `harvest()` swept nothing, and the keeper still alerted
"💰 DN profit harvested". Repeating skims silently shaved the principal
ledger.

**Fix:** the split is now **PROFIT-FIRST** — while `equity > principal`, an
outflow draws from the profit portion first (`profitRed = min(amount, equity -
principal)`), so a skim realizes profit and the principal (hedge margin)
stays on Core. Full drains behave exactly as before; in a loss
(`equity < principal`) every unit books as principal (no phantom profit).

**Files:** `contracts/DNCoreStrategy.sol` (`bridgeBackToEvm`).
**Keeper reconciled:** `scripts/dn_keeper.js` — the skim amount is unchanged
(`equity - principal`), the misleading alert now fires **only when a sweep
actually happened** (reads `profitSwept` before/after `vault.harvest()`), and
a new **loss alert** fires when `equity < principal`, instructing the owner to
reconcile via `reportLoss`. The stale "1:1 notional vs margin" comment was
aligned to the real policy (`marginUtilBps = 3300`, ≈3× max).

**Evidence:**
- `test/forge/Fixes.round2.t.sol::test_fix_keeperProfitOnlyBridge_realizesAndSweeps`
  — principal stays 500, `profitRealized == 5e18`, vault receives 5e18 (was:
  principal 495, realized 0, vault 0).
- `…::test_fix_fullAmountBridge_unchanged` — regression: full drain unchanged.
- `…::test_fix_lossEquityBelowPrincipal_noPhantomProfit` — no profit in a loss.
- Audit harness re-run: the original repro
  (`test/audit/Round2.dn_accounting.t.sol`) now asserts the fixed behavior —
  `test_FIXED_keeperProfitOnlyBridge_realizesProfit_andSweeps` PASS.

## 2. H1 — no strategy-loss accounting (ADDRESSED: write-down + partial redemption)

**Gap:** losses were invisible to the vault; `totalAssets()` stayed phantom
and full withdrawals reverted (first-come-first-served salvage).

**Fix (two additive functions on `ProYieldVault`):**
- `reportLoss(uint256)` — **owner-only** (beta owner = treasury Safe). Writes
  booked liabilities down to real backing; the loss socialises pro-rata via
  the share price; emits `LossReported`. The keeper now alerts the owner with
  the numbers when a venue loss is observed.
- `withdrawUpTo(uint256) → paid` — partial-redemption escape hatch: pays what
  idle + recallable balance can **actually** cover right now; never reverts
  for illiquidity alone; shares burn only for what is paid (the rest of the
  claim stays on the books).

**Files:** `contracts/ProYieldVault.sol` (+ keeper loss alert above).

**Evidence:** `test/forge/Fixes.round2.t.sol` —
- `test_fix_reportLoss_socialises_bothUsersExit`: 2×1000 in, 1800 lost →
  `reportLoss` → both users withdraw a fair 100 each (was: first user salvages
  everything, second trapped).
- `test_fix_withdrawUpTo_partialUnderUnreportedLoss`: unreported loss — plain
  `withdraw(1000)` still reverts (documented gap), but `withdrawUpTo` pays the
  real 200 and burns only 200 of shares.
- `test_fix_withdrawUpTo_neverOverpays`, `test_fix_reportLoss_ownerOnly_andBounded`.

**Design note (honest limitation):** the vault cannot *auto-detect* venue
losses on-chain (no deployed-debt ledgers on strategies — unchanged); the
write-down is an explicit owner action triggered by the keeper's alert. Until
a loss is reported, `withdrawUpTo` still lets users exit with real backing —
worst case first-come-first-served instead of fully trapped. Auto-detection
is a candidate for the next audit round.

## Test totals (2026-09-25)

- Main repo: `forge test` → **57 passed, 0 failed** (was 50; +7 fix tests).
- Audit workspace re-run (`test/audit/*`): **10 passed, 0 failed** — all five
  round-1 repros (H1/H3/M1/M2/L1) still PASS and the Part-B accounting repro
  now passes in its FIXED form.
- Contract sizes: `ProYieldVault` 9,747 B runtime (+499 B), `DNCoreStrategy`
  12,513 B — both far under EIP-170 and the HyperEVM 3M-gas deploy budget.

## Deployment implications

- **DN stack:** not deployed (mainnet manifest = vault + FeeDistributor only)
  → the HIGH-1 fix lands before any DN deploy. ✓
- **Live vault (`0xadaE15e2…`, caps $500/$500, no TVL yet):** does NOT contain
  `reportLoss`/`withdrawUpTo` — these ship with the **next vault deploy**
  (scheduled before the first cohort opens / cap ladder step). No user funds
  at risk meanwhile (TVL = $0); ops must not open deposits against the old
  vault build without the loss tooling.

## Still open from round-2 (NOT in this green light)

- **HIGH-2 (DN long leg):** the coded DN stack is a levered perp short, not a
  delta-neutral pair — needs either spot-leg support + keeper leg management,
  or a formal re-scope/risk-size. **Do not market the sleeve as
  "delta-neutral" anywhere until this is resolved.**
- MED items: cumulative keeper authority caps, on-chain price sanity checks.
- LOW items: cloid tracking/cancel path, HYPE-gas monitoring for sendAsset.
