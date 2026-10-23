# ProYield Vault — Community Audit Scope

> Status: **live on mainnet** (HyperEVM 999) + **testnet**. This document is the package
> auditors and community reviewers should read first.
> Last updated: **2026-10-23** (deployed-build disclosure added — read §1.4 before anything else).

> ⚠ **The code in this repository is NOT what book #1 runs.** Book #1
> (`0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1`) was deployed 2026-09-25 from source commit
> **`8daa2ce5`** and has **not** been redeployed since. Every vault/FeeDistributor/strategy fix
> landed after that commit — `c652e006` (r1), `609ad90b` (r3 CEI), `e9c899a8` (sUSD3), `bec2ff29`
> (yossweh 2026-10-22) — is **source-only, undeployed**. Proved by ipfs metadata-hash identity on
> a from-source rebuild, not by inspection. **An audit of this repository is an audit of the
> intended next build, not of the deployed one.** §1.4 lists the delta; the full ruling is
> `docs/SECURITY_FINDING_PY-SCOPE-02_VAULT_BUILD_DRIFT_2026-10-23.md`.

## 1. What is in scope

Primary (holds or routes user funds):

| Contract | Lines | Role |
|---|---|---|
| `contracts/ProYieldVault.sol` | 313 | ERC-4626-style vault: deposits, withdrawals, allocation, harvest, share price |
| `contracts/BaseStrategy.sol` | 107 | Strategy base: recall, harvest booking, keeper/vault auth |
| `contracts/DNCoreStrategy.sol` | 210 | Delta-neutral sleeve: honest Core accounting + vault wiring |
| `contracts/adapters/DNCoreBase.sol` | 326 | Shared HyperCore execution: CoreWriter sends, read precompiles, gates |
| `contracts/adapters/DNCoreAdapter.sol` | 67 | Standalone DN execution wrapper (same surface, no vault) |
| `contracts/FeeDistributor.sol` | 79 | Fee routing (60/20/20 recycle policy) |
| `contracts/PYDStaking.sol` | 171 | PYD reward streaming (Synthetix-style) |
| `contracts/PYDToken.sol` | 26 | Fixed-supply OZ ERC20 (standard events); no mint path |
| `contracts/PYDFeeDiscount.sol` | ~390 nSLOC | v3 universal USDC rebate pool over ≤8 registered vault books: normalized tier-weighted accrual, epoch-lagged clamps, paginated sweep, one claim; source-only, not deployed |
| `contracts/PYDFunder.sol` | 175 | Capped USDC→PYD conversion → PYDStaking streams (dormant until a swapper is set) |

**PT fixed-rate sleeve (LIVE, holding real USDC — audited in round 1):**

| Contract | Lines | Role |
|---|---|---|
| `contracts/PTSleeveStrategy.sol` | 221 | HyperEVM side: CCTP burn/return, keeper-attested Arb value. **Live** `0x2D3E5bf1…` (+ a second instance `0x3AE855B6…`) |
| `contracts/arbi/PTSleeveExecutor.sol` | 273 | Arbitrum side: buys/sells PT via the Pendle router, burns USDC back. **Live on Arbitrum One** `0xA2e53597…` — NOTE: that literal address is `HLEarnStrategy` on HyperEVM (see §1.2 index 5). Same hex, different chains, different contracts: always scope an address by chain id. |
| `contracts/ethi/PTSleeveEthExecutor.sol` | 348 | Ethereum lane (CCTP domain 0). Built + fork-tested, **not deployed** |
| `contracts/arbi/PendleTypes.sol` | 111 | Pendle router structs (shared by both executors) |

**Lending / secondary:**

| Contract | Lines | Role |
|---|---|---|
| `contracts/MorphoStrategy.sol` | 219 | **LIVE** `0xBF4C5e33…` — Morpho Blue supply on HyperEVM, position-based yield accounting |
| `contracts/HLEarnStrategy.sol` | 345 | HYPE-earning sleeve. **LIVE on HyperEVM mainnet** at `0xA2e535970dc1492f77843E26F25Ab314735F4dF5` (vault `strategyList` index 5, ACTIVE; `totalAssets` = 17,970,861 USDC-6dp = **$17.97** at block 49,277,256, 2026-10-23). PY-SCOPE-01 (yossweh 2026-10-22): this row previously said "testnet only (`0x08EC018f…` on chain 998); not in the live vault's strategyList" — both halves were false. Do not confuse it with the Arbitrum-lane `PTSleeveExecutor` that shares the same hex (see above). |

Legacy/secondary (deployed but pending migration review):
`DeltaNeutralStrategy.sol`, `SkyStrategy.sol`, `PendleStrategy.sol` —
reentrancy-hardened 2026-09-18 (23 findings fixed). **Verified 2026-09-30: all three
are dead code** — absent from every manifest and from the live vault's
`strategyList`. `DeltaNeutralStrategy` was never deployed.

### 1.1 Scope corrections made 2026-09-30 (round-1 audit)

This document previously (last edited 2026-09-20) omitted the entire PT sleeve while
`PTSleeveStrategy` and `PTSleeveExecutor` were **live and holding real USDC**, and it
listed `MorphoStrategy` as merely "legacy" when it is the live lending core. Both are
now corrected above. Findings and fixes: `AUDIT_HANDOFF_2026-09-30.md` and
`docs/AUDIT_ROUND1.md`.

**SUSD3 sleeve (registered + ACTIVE on the live vault):**

| Contract | Lines | Role |
|---|---|---|
| `contracts/SUSD3Strategy.sol` | — | Legacy sUSD3 CCTP sleeve (v1). **Live** `0x9978e8745cdb0d3e5B970aC36C38575eC70D612A` (registered + ACTIVE, index 6; superseded by the dormant `0x7dc1874F…` replacement but never de-registered). |
| `contracts/ethi/SUSD3Executor.sol` | — | Ethereum-side executor for the sUSD3 sleeve |

### 1.2 Live `strategyList` — 7 registered strategies → sources (live-verified 2026-10-23)

The vault `0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1` holds **7 registered
strategies** on-chain. The manifest previously named only 5 (indices 2 and 6
were absent, and index 6 is ACTIVE); it was reconciled 7-vs-5 on 2026-10-10
(`deployed_addresses.mainnet.json:strategyList_reconciled`). **The on-chain
`strategyList` is the source of truth — never enumerate strategies from the
manifest.** Every registered address maps to a source file below; the legacy
SUSD3 adapter, previously unmapped, is included.

PY-SCOPE-01 (yossweh 2026-10-22): this table used to mark indices 3 and 4
ACTIVE. A live read at block **49,277,256** (2026-10-23) shows both are
`strategyActive == false`. Index 4 is deactivated but **still carries value**
(18,891,846 USDC-6dp = $18.89) — money-out is not gated on `strategyActive`, so
it stays recallable. Values below are `totalAssets()` read in the same block.

| # | Live strategy address | Active | Value (USDC-6dp) | Source |
|---|---|---|---|---|
| 0 | `0xeD40C3c34e2d4D6F2e1C0F0e688a6c05c82F9Bf4` | yes | 1,134,268 ($1.13) | `contracts/DNCoreStrategy.sol` (+ `contracts/adapters/DNCoreBase.sol`) |
| 1 | `0xBF4C5e339D63EEB393DA2797679879a0a5Af2D53` | yes | 50,547,918 ($50.55) | `contracts/MorphoStrategy.sol` |
| 2 | `0x3AE855B65A021397f7a3ca838acc8E4c82cF815f` | no | 0 | `contracts/PTSleeveStrategy.sol` (v1, quarantined 2026-10-10) |
| 3 | `0x2D3E5bf1D34791b8b66Ac4eEA6D281E918577B6b` | **no** | 0 | `contracts/PTSleeveStrategy.sol` |
| 4 | `0xA96D0BB29cEE6F9e26239529789CEb74912C4b25` | **no** | 18,891,846 ($18.89) | `contracts/PTSleeveStrategy.sol` (ETH lane, CCTP domain 0) |
| 5 | `0xA2e535970dc1492f77843E26F25Ab314735F4dF5` | yes | 17,970,861 ($17.97) | `contracts/HLEarnStrategy.sol` |
| 6 | `0x9978e8745cdb0d3e5B970aC36C38575eC70D612A` | yes | 0 | `contracts/SUSD3Strategy.sol` (legacy v1) |

Regenerate with `node scripts/reconcile_strategy_manifest.js`
(read-only; refuses to write on a degraded read). The sentinel guard
(`scripts/strategy_manifest_guard.js`) now also compares the **per-strategy
active flag** against the manifest and alerts on drift.

**Out of scope:** `contracts/mocks/*` (test-only), `contracts/mocks/DecodeVerifier.sol`
(read-verification harness), HyperCore itself (Hyperliquid's system), everything in
`scripts/` (keepers/tests are off-chain liveness, they hold no funds — with the
exception of deploy scripts, whose ownership defaults ARE in scope as an
attack-surface concern; see audit F-1).

### 1.3 Carry-forward constraints (internal adversarial pass, 2026-10-14)

- Internal AI-assisted adversarial review — **supplement only, never a substitute** for the third-party audit lane: `docs/research/INTERNAL_AI_ADVERSARIAL_REVIEW_2026-10-14.md` (ranked findings, dispositions, failing-Forge-repro evidence).
- **v3 is the only rebate build that may be funded/wired.** It replaces the one-vault v1 model and the known-drift v2 (`PY-REBATE-01`); v1/v2 must not be activated. v3 is source-only, not deployed; funding waits on third-party audit + owner activation. The legacy contract now lives under `test/legacy/` as a test fixture and is out of production scope.
- **Pin the `DNCoreBase.hedgeTransferOut` destination** (internal IA-1) in the DN revision that ships the F3/F6 fixes.

### 1.4 Deployed build vs this source (PY-SCOPE-02, live-verified 2026-10-23)

Book #1 vault runtime is **9,952 B**, ipfs `1220e58e6bea…24ea`, = rebuild of **`8daa2ce5`**
(solc 0.8.28, optimizer runs **200**, no viaIR, evm target paris). HEAD artifacts cannot reproduce
it: `hardhat.config.js` was changed to `runs=1 + viaIR` in `2534780f`, *after* the deploy. 380
differing bytes vs the rebuild, **0 outside** the constructor-immutable slots.

| what HEAD has that the chain does not | commit | live consequence |
|---|---|---|
| `uncreditedArrivals()`, `creditYield` arrival clamp (**F-4**) | `c652e006` | the owner (2-of-3 Safe) can credit idle float as yield — no third-party path |
| `onStrategyReturn(uint256)` (**F-5** vault half) | `e9c899a8` | returned principal has no booking hook; live `allocate()` ships raw balance so principal is still redeployable |
| `addStrategy` codeless-address check (**F-15**) | `c652e006` | a typo'd strategy address would accept and burn allocated USDC |
| `emergencyWithdraw` bounded write-down + emit (**F-5**) | `c652e006` / `609ad90b` | live writes down *after* the transfer and underflows (Panic 0x11) once `balance > totalAssets` — a 1-wei donation then bricks the crisis lever (`PY-EMERG-02`) |
| FD `peakBalance` / cumulative fees (**F-13**), `route()` CEI | `c652e006` / `609ad90b` | lifetime fee counter freezes after the first route |
| `MAX_PERFORMANCE_FEE()`, `MAX_WITHDRAWAL_FEE()` | *removed by* `c652e006` | present live, absent at HEAD — the live build is a **sibling generation**, so a "missing-from-HEAD" selector check reports a false all-clear |

Also stale on chain, and accepted/tracked: `DNCoreStrategy` (no `reconcileProfit`, and no A3
spot-cash NAV — its own `totalAssets()` under-reports by **$30.35**), the two registered
pre-remediation PT lanes (`_accepted_risks[F-1]`), the legacy SUSD3 v1, and the live
`FeeDistributor`. `MorphoStrategy` is selector-clean but **not** current (`PY-RECALL-01` is a body
change). **A selector diff is not a currency test** — verify ipfs against a rebuild of the intended
commit.

Nothing in §1.4 changes §3's invariants for the *intended build*; it changes what an auditor may
assert about the *deployed* one.

## 2. Architecture in one page

```
users → ProYieldVault (USDC) → allocate() → strategies
                                  │            ├─ Sky/Morpho/Pendle (lending, EVM)
                                  │            └─ DNCoreStrategy (HyperCore via CoreWriter)
                                  │                 ├─ bridge USDC in/out (CoreDepositWallet / sendAsset)
                                  │                 ├─ class-transfer → perp margin
                                  │                 ├─ short hedge (limit orders)
                                  │                 └─ syncCore() ← read precompiles (0x80f/0x813/…)
                                  └─ harvest() ← strategies sweep realized profit
        FeeDistributor ← vault fees → 60% depositors / 20% insurance / 20% treasury
        PYDStaking ← reward streams funded from the recycle loop
```

Target chain: **HyperEVM mainnet (chainId 999)**; test runs on local anvil 8545
(chainId 998) with mocked system contracts.

## 3. Core invariants (what we believe holds — try to break it)

1. **Principal is never counted as yield.** `DNCoreStrategy.corePrincipal6`
   tracks net USDC bridged to Core; `bridgeBackToEvm` splits principal-first
   at freshly-synced equity; equity below principal realizes NOTHING. No
   path books principal as profit.
2. **Share price cannot be inflated by a first depositor.** `SHARE_OFFSET = 1e3`
   virtual offset (OZ ERC4626 pattern); dust guard rejects zero-share deposits.
3. **Liabilities stay in sync with assets.** Withdrawals/emergency exits shrink
   `_totalAssets` by exactly what left (T-012 follow-up).
4. **Checks-effects-interactions everywhere.** Shares minted BEFORE
   `transferFrom`; every state update precedes every external call; events emit
   before external calls (tx atomicity keeps ordering equivalent).
5. **`nonReentrant` on every mutating entry point** — all strategies, vault,
   FD, staking, DN base.
6. **Vault withdrawals are honored by real assets.** `recall` is vault-only and
   capped at balance; the vault's reserve + each strategy's buffer keep
   liquidity ahead of claims. A withdrawal that cannot be backed reverts.
7. **No custody path.** The vault moves funds only by owner/keeper policy;
   strategies move only by keeper policy; CoreWriter actions are sent by the
   contracts AS THEMSELVES (no agent wallet, no delegated signer).
8. **Silent-drop prevention.** CoreWriter drops actions from accounts without a
   Core account, and applies actions after a delay — every action is gated on
   the 0x810 read, and keepers verify-after-delay (contract-level gate:
   `coreAccountRequired`).
9. **Fixed supply.** PYD has no mint path; staking rewards are transferred, not
   minted.
10. **Staking rewards never exceed the funded pool.** `PYDStaking` holds
   `balance ≥ totalSupply` at all times; claims are bounded by
   `balance − totalSupply` (funded minus already claimed); accrual stops at
   `periodFinish`. A rollover bug (a keeper top-up after a lapsed window with
   no user interaction double-banked the tail — rewards could be paid out of
   staked principal) was FOUND by the forge invariant suite and fixed;
   `test_rollover_without_interaction_no_double_accrual` pins it.
11. **Vault solvency + share-price floor.** The backing (vault plus every
   strategy's USDC) is ≥ `totalAssets` at all times, and
   `totalAssets ≥ totalShares` — the share price never falls below 1 except
   through the two explicit owner loss paths: `emergencyWithdraw()` (full
   dilution) and `reportLoss()` (a reported venue/strategy loss, which writes
   assets down while shares stay put — live boost book 38.007055 / 50.000000 =
   0.760146). `invariant_price_never_below_one` asserts the floor only for
   loss-free runs and skips it once a write-down has been reported; the
   carve-out is behavioural, not cosmetic. Related (audit F-4 residual,
   `t_b0874348`): a VALUATION write-down must never debit the cash ledger nor
   make already-booked cash creditable —
   `test_F4_residual_reportLossBeyondIdleMustNotStrandCash`,
   `test_F4_residual_falseSplitIsRefused` (the two-arg `fromIdle` split is
   bounded by the MEASURED cash shortfall, not by the cash ledger), echidna
   `echidna_credit_cannot_exceed_backing`, and forge
   `invariant_creditable_capacity_is_backed` (statement: every dollar
   `uncreditedArrivals()` could still credit is real backing, so crediting ALL
   of it can never push `totalAssets` above vault + strategy USDC) pin it.
   Evidence for the harness command — the passing transcript, the pre-fix
   falsification, and the deterministic gate control — is
   `audits/f4-residual-2026-10-23/GATE.md`.
   Related (audit F-4R-2, `t_27c2410c`, Low — fixed): after a write-down the
   CASH ledger can no longer exceed the claim total. `_totalAssets` = booked
   idle cash + deployed book value, so a reported valuation loss larger than
   the deployed book left the ledger describing idle cash no claim owned
   (deposit 100 all-idle → `reportLoss(60)` → totalAssets 40 / ledger 100) and
   `allocate()` shipped 96 of the 100 — cash the books no longer owned, with
   the written-down claim free to exit and strand the rest in a strategy. Note
   this survives the F-4R-1 split guard: that guard bounds `fromIdle`, it does
   not bound an over-reported `amount`. `_reportLoss` now caps the ledger at
   `_totalAssets` and emits `LossLedgerCappedToClaims` when the cap binds. The
   cap only moves the ledger DOWN, which is why it is not a second F-4: after
   it `accounted == totalAssets`, so either the vault holds at least that much
   idle cash (the residue is REAL unclaimed USDC, and
   `totalAssets + arrivals == balanceOf <= backing`, so crediting it stays
   solvent) or it holds less (a carried cash shortfall — then
   `uncreditedArrivals()` is 0 and nothing becomes creditable, exactly as
   fail-closed as before). It can never manufacture capacity that is not
   backed. Pinned by `test_F4R2_writeDownCapsLedgerAtClaimsAndBoundsDeployment`,
   `invariant_loss_never_raises_or_overstates_cash_ledger` (a write-down may
   lower the ledger, never raise it and never leave it above `_totalAssets`)
   and echidna `echidna_cash_ledger_within_claims`.
12. **Caps are rails, not traps.** Deposits are bounded by owner-set `tvlCap` /
    `perUserCap` (0 = uncapped; per-user is value-based) and can be paused
    (`depositsPaused`). Neither the caps nor the pause ever gate withdrawals — a
    capped or paused vault still lets every user exit.

Items 2, 3, 5, 10, 11, 12 have executable counterparts in `test/forge/`:
`Vault.invariants.t.sol` — `invariant_solvency`,
`invariant_price_never_below_one`, `invariant_user_shares_sum_to_total`,
`invariant_no_zero_valued_depositor`, `invariant_fd_bookkeeping`,
`invariant_credited_leq_routed`, plus the two loss-property invariants
`invariant_loss_never_raises_or_overstates_cash_ledger` and
`invariant_creditable_capacity_is_backed`, plus
adversarial cases (donation attack neutralized by the offset, emergency-exit
dilution semantics, dust deposits, strategy recall, paused-strategy
containment, one broken strategy never bricks harvest).
`PYD.invariants.t.sol` — `invariant_principal_intact`,
`invariant_claims_bounded_by_pool`, `invariant_accrual_bounded_by_pool`,
`invariant_stake_sum_to_total`, plus tier boundaries, budget-capped claims,
zero-share/below-tier stakers, no accrual past the window, mid-period top-up,
and the rollover regression above.
`Vault.caps.t.sol` — S2 beta safety rails: a deposit at the EXACT cap passes, one
wei over reverts (message-asserted), withdrawal paths stay open while paused / above
cap, setters owner-only.
`Vault.differential.t.sol` — an independent integer model (written from the
spec, no vault code) runs the same randomized op sequence as the contract
(deposit/withdraw/yield/harvest/recycle/warp; 1200 deterministic ops + fuzzed
seeds) and asserts EXACT equality after every op: totalAssets, totalShares,
per-user shares, cash conservation (vault + strategies == modeled assets +
unswept yield) and fee deltas, plus the share-price floor.

## 4. Threat model highlights

- **Reentrancy**: external calls are intrinsic to the design (ETH forwarding,
  ERC-4626 interactions, CoreDepositWallet deposits). All guarded; Slither's
  residual flags are the documented-benign class (see §6).
- **Share-price manipulation**: deposit → inflate → donate attacks blunted by
  SHARE_OFFSET; the vault tracks assets/shares atomically.
- **Keeper compromise**: keepers can execute the policy set (orders within
  caps, bridges within caps) but cannot change caps, fees, or ownership.
  Worst case is bounded by `maxActionUsd6` per action. Ownership is behind a
  2-of-3 Safe on mainnet (treasury `0x8A1b107e…`, transferred 2026-09-24 —
  ops EOA + box signer + user-held phone backup; the testnet demo vault keeps
  its generation's EOA owner).
- **Oracle/precompile trust**: reads come from HyperCore precompiles (verified
  against mainnet — `scripts/dn_realread_check.js`, 15/15). The read layer's
  encoding was validated against LIVE mainnet bytes through the contract's own
  struct decodes.
- **CoreWriter semantics**: actions are fire-and-forget; the strategy never
  assumes an immediate post-send read reflects the action. Async recall design:
  buffer covers ordinary recalls; larger ones need keeper unwind first.
- **Size limits**: EIP-170 (24,576 B) enforced on HyperEVM. Strategy is
  21,585 B, adapter 14,344 B (custom errors keep headroom).
- **Fee/first-depositor on harvest**: net profit raises share price pro-rata;
  fees leave accounting (never double-counted).

## 5. Test evidence (all green at last run)

| Suite | What it proves | Result |
|---|---|---|
| `scripts/run_battery.sh` | Every suite below on a FRESH isolated anvil (cold-start deploy, per-suite exit codes, disposable chain) | 12/12 suites |
| `scripts/integration_tests.js` | Full protocol: deposit→harvest→withdraw, fee→staker loop, token invariants | 120/120 |
| `scripts/dn_strategy_tests.js` | Vault DN money loop: allocate→bridge→sync→split→harvest→withdraw; loss case | 28/28 |
| `scripts/dn_adapter_tests.js` | Byte-exact CoreWriter encodings + all gates | 26/26 |
| `scripts/dn_realread_check.js` | Read layer vs LIVE mainnet precompiles (read-only, manual) | 15/15 |
| `scripts/dn_realread_replay.js` | Read-layer decoders (JS + real Solidity structs) vs FROZEN real mainnet bytes at block 46644202 — offline, in the battery + CI (`dn_realread_capture.js` refreshes the fixture) | 13/13 |
| `scripts/web_smoke.sh` + `pro-yield-web/web-smoke-local.mjs` | Web-app data path vs local chain: `vault_status.json` → rendered `/account` + `/transparency` (marker + TVL + share price + no console/page/request errors), with a real customer deposit→withdraw round-trip visibly updating the UI | PASS ($100k → $105k → $100k) |
| `scripts/dn_keeper_dryrun_test.js` | Keeper sizing policy end-to-end (subprocess) | 8/8 |
| `scripts/dn_keeper_unwind_test.js` | Keeper unwind policy end-to-end (subprocess) | 6/6 |
| `scripts/pyd_demand_tests.js` | PYD demand layer: discount tiers/accrual/claims + funder conversion → real staking stream + **K: mutation-survivor regression** (exact-value kills for the campaign survivors) | 29/29 |
| `scripts/test_all.js` | Unit suite | 16/16 |
| `scripts/vault_caps_test.js` | Beta safety rails: TVL + per-user caps at their boundaries, pause blocks deposits but never withdrawals | 12/12 |
| `forge test` (`test/forge/*.t.sol`) | Stateful invariants + adversarial/edge cases (mapping in §3) + independent-model differential sim (1200 ops, exact-equality after every op) + mutation-survivor coverage (`Vault.coverage.t.sol`, `PYD.coverage.t.sol`) | 436 tests, 26 invariants (`ffdbf0f4`) |
| `echidna/echidna_vault.sol` — `--all-contracts` (command in the harness header) | Independent fuzzer on the vault money path: `echidna_shares_sum_matches_total`, `echidna_price_floor` (reportLoss carve-out), `echidna_solvent`, `echidna_credit_cannot_exceed_backing`, `echidna_cash_ledger_within_claims` (F-4R-2). Transcript: `audits/f4-residual-2026-10-23/echidna_all_contracts_dca15b6a.log`; the harness-only gate on the strategy's `fund()`/`lose()` is pinned by `test/forge/Echidna.harness.gate.t.sol` (a green campaign alone is not evidence — the ungated target falsifies seed-dependently) | 5/5 passing, 20,035 calls (pre-F-4R-2) + 3,092 local |
| Slither (vs `security_baseline.json`) | 0 critical, no NEW findings (22 accepted, each justified) | clean |
| CI (`.github/workflows/ci.yml`) | battery + slither + forge on a fresh runner, every push/PR | green |
| `slither-mutate` (RR,ROR,LOR,AOR,UOR,LIR,SBR,ASOR) | Mutation kill-rate on core contracts — tests must KILL injected bugs | vault 85.5% · PYD 82.7% (all survivors triaged) |

**Mutation triage (slither-mutate campaigns, 2026-09-23).** Campaign 1 (ProYieldVault, test-cmd = battery): every survivor was classified — real gaps (`name()`, the zero-supply `_toShares/_toAssets` branches, the `_feeOn` fee==0 branch, the `harvestStrategy` success path + message-asserted reverts, and the recall round-up math) are now covered by `test/forge/Vault.coverage.t.sol`. Core insight: failure-path assertions cannot kill `require/body ==> revert()` mutants — the mutant still reverts (same observable) — only success-path + `expectRevert(message)` kill them. One equivalent mutant documented: `strategy != address(0)` in `harvestStrategy` is unreachable (the `strategies[]` check fires first for 0x0). Campaign 2 (PYDStaking + PYDFeeDiscount, test-cmd = pyd suite + forge PYD invariants): the first pass exposed loose assertions (`claimed > 0` cannot kill a `-=`→`+=` flip) and missing success paths (setTiers/unstake/exit/claim exact values) — closed by the K regression section in `scripts/pyd_demand_tests.js` (10 exact-value checks). **Re-run complete (kill set = full battery + forge PYD invariants): 403 caught / 114 uncaught / 145 compile-fail — 82.7% of compile-able mutants killed.** Survivor classification: (a) *equivalent mutants* — unsigned `== 0 → <= 0`/`< 0`, `i < len → i != len`, `i++ → ++i`, `constant → immutable`/widening casts, `>=` flips differing only at exact-equality boundaries, emit-only and staticcall-fallback paths (no observable difference — not killable by construction); (b) *EOA-only test artifact* — the `msg.sender → tx.origin` family (differs only when a contract is the caller) — killed by `test_contract_callers` in `test/forge/PYD.coverage.t.sol`; (c) *real gaps, now covered* — PYDStaking `withdraw()` end-to-end (was entirely untested), the rollover `(amount + leftover)/duration` math, the rewards accumulator across two unclaimed accruals, constructor zero-guards, setTiers equality/cap boundaries, the snapshot-below-balance no-op, `name()`/`stakerCount()`/`receiveBudget()`/`lastSnapshotAt` — `PYD.coverage.t.sol`, 9 tests. Note found while writing the kills: `harvestStrategy()` is a bare sweep (no fee split, no `totalAssets` credit — that bookkeeping lives in `vault.harvest()`); operator-only, the keeper calls `harvest()`, so no yield strands in practice.

**Campaign 3 (ProYieldVault, full re-run — kill set = the 11-suite battery + full `forge test`): 64/64 revert mutants caught (100%), 296/357 tweak mutants caught (82.9%), 61 survivors.** Triage:

- *Real gaps — now covered by 6 new tests in `test/forge/Vault.coverage.t.sol` (4 kill-verified by hand-applying the mutant and watching the test fail):* the harvest sweep condition `strategies[s] && strategyActive[s]` (`&&`→`||` sweeps a REGISTERED-but-PAUSED strategy, bypassing the circuit breaker); the recall loop's `missing > 0` (`>= 0` keeps pulling from later strategies after the shortfall is covered — the 3-strategy test measures 6 wei pulled vs the 4-wei bound, i.e. user funds stranded idle); `idle >= needed` → `>`; `lastHarvest = block.timestamp` (`= 0` leaves the heartbeat unset); zero-value transfer paths (`fee > 0`→`>= 0` in harvest, `perStrategy > 0`→`>= 0` in allocate — observable only as 0-value `Transfer` logs, asserted via `vm.recordLogs`); and the **`msg.sender → tx.origin` family** (line 97 `Deposit` emit, line 109 `emergencyWithdraw` payout, line 183 `Withdraw` emit) — killed only by a *contract* caller (`VaultActor`), since with EOA callers `msg.sender == tx.origin` and every mutant of this family is invisible.
- *Equivalents — documented, not killable by construction:* unsigned `== 0`→`<= 0`/`< 0` (the branch is unreachable for unsigned); `i < len`→`i != len` and `i++`→`++i` (monotonic counters, value unused elsewhere); `constant`→`immutable` and casts that fit (`uint256`→`uint128`); `totalProfit > _feeOn(totalProfit)`→`>=`/`!=` (differs only at exact equality — unreachable while `performanceFee < 10000` and profit > 0); `totalProfit > 0 && performanceFee > 0`→`||` (a zero-fee body either way); `idle >= needed`→`>` (the continuation is a *proven* no-op: `missing == 0` exits the recall loop before any call).

**Campaign-design lesson (why Campaign 1's vault pass was misleading):** the earlier kill set exercised the vault through a SINGLE strategy instance and only EOA callers, so every mutant in a multi-instance condition or a caller-identity condition survived *by construction* — the campaign was measuring the tests' shape, not the contract's correctness. A kill set must include ≥2 live instances (≥3 for loops where a counter can reach its bound mid-iteration) and at least one CONTRACT caller; and an "equivalent" verdict must be proven unreachable rather than assumed — the over-pull mutant looked equivalent (`missing` reaching 0 only at loop end) until a third strategy let it reach 0 mid-loop.

**Bug found by the new invariant suite and fixed** (commit `3111a6d6`):
`PYDStaking.fundRewards` double-banked an expired reward window on rollover
(keeper top-up after a lull with no user interaction in between) — rewards
became claimable beyond the funded pool and paid out of staked principal.
Fixed by ordering `_updatePeriod()` before the reward-per-token banking;
regression test `test_rollover_without_interaction_no_double_accrual`.

Mocks assert calldata shapes (a wrong precompile encoding reverts in tests
rather than silently passing — this exact trap was caught by real-chain
verification and fixed).

## 6. Known / accepted findings

See `security_baseline.json` — every accepted finding carries its reason.
Summary: OZ library assembly (library code), intentional zero-guards
(`incorrect-equality`), floating pragma pinned by config, timestamp-based
yield accrual (intentional DeFi pattern), benign reentrancy classes where
Slither cannot model `nonReentrant` guards, documented loops over the
owner-managed strategy list.

## 7. Deployment gates (what happens after audit)

1. Audit findings triaged; criticals fixed + re-tested, acceptances re-justified.
2. Mainnet deploy (deployer `0xaDD8…EA1D`; vault address published on
   `/transparency` + Dune dashboard params flip from placeholders).
3. Contracts submitted for Hyperliquid/Kinetiq decoding (~24h).
4. Dune dashboard flips private draft → public; `/transparency` panels fill.
5. On-chain DN rate must exceed the blended rate before the sleeve allocates
   (keeper-enforced sizing policy is live).

## 7b. Ecosystem-level testing (the whole product, not one module)

Beyond the per-module suites, three angles cover the ecosystem as a system:

| Angle | Artifact | What it proves |
|---|---|---|
| **Journey — one continuous customer path** | `scripts/ecosystem_journey_test.js` (24 checks) | on-ramp → deposit → fee income → FD reconcile → **the real `recycle_fees.js` run against the test chain** (60/20/20 split to the wei, FD fully drained, cold-start must not touch the shared ledger) → PYD demand (funder converts, documented swapper delivers, stream pays over time, `getReward` transfers) → tier + `snapshotHarvest` on a real fee delta → `claimRebate` equals the documented formula exactly → redemption (pays the exact quote, no cross-user leakage, floor dust bounded) → **USDC conservation to the wei summed over every ecosystem contract**. |
| **Cross-artifact integrity audit** | `scripts/ecosystem_audit.js` (offline + RPC identity probes) | every artifact names the same canonical vault; no operating loop is silently stale; the deploy manifest is complete and non-zero; **every recycling ledger run matches the live policy split to the wei**; the web feed matches the reader's schema; website blend == scout's live blend; the operator alert queue carries no test-generated alerts; **§8 chain identity** — the testnet RPC answers as 998, the manifest vault is verified to have code on the chain the ops actually read, the keeper's vault is verified on the real testnet, a chain map shows where each vault generation lives, the recycler refuses an implicit RPC, and the insurance module pins + verifies its chain and sources reserves from the ledger (never a hardcoded stub). Checks whose artifact root is absent on the host SKIP (point `AUDIT_SCOUT_DIR` / `AUDIT_WEB_DIR` at a checkout to run them anywhere); `AUDIT_MODE=strict` turns FAILs into a non-zero exit (CI gate), default info mode reports operator-state drift without failing contract-correctness suites. See `docs/ATTACK_SURFACE_PLAN.md` for the reduction plan this informs. |
| **Chain guard — "never mainnet", enforced** | `scripts/chain_guard.js` + `scripts/chainid_guard_test.js` (12 checks) | a decoy anvil with **chain id 1 (mainnet's id)** is stood up and every money-mover is pointed at it: hardhat's own config chainId check refuses first (HH101), an explicit `REFUSING` guard is present in `dn_keeper.js` and `recycle_fees.js`, and `vault_keeper.check_chain()` (raw JSON-RPC path — no hardhat layer) refuses outright before any on-chain action. **Implicit-RPC class** (which put real recycling on a local chain spoofing chain-id 998): the recycler must refuse an unset `HYPEREVM_RPC_URL` before touching the network, while an explicit RPC passes the check — controls proving the guard is neither a brick nor a rubber stamp. Positive control: chain 998 is still allowed. |

All three run inside the default battery (`./scripts/run_battery.sh`,
12 suites / ~300 checks / ~96s).

## 8. How to review

- `git clone https://github.com/ProYield-fi/pro-yield-fi` (shared repo;
  `hypervault/` is the contracts root).
- `cd hypervault && npx hardhat compile && python3 scripts/security_monitor.py`
  reproduces the static-analysis gate.
- `cd hypervault && forge test` reproduces the stateful invariant suite
  (Foundry; `lib/forge-std` is vendored). `./scripts/run_battery.sh
  --with-deploy` reproduces the full isolated battery end-to-end.
- Questions/findings: open a GitHub issue with the `audit` label, or contact
  `proyield@pyd.fi` (see SECURITY.md).
