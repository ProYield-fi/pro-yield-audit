# Audit Log — Published Findings & Evidence Index

This is the public record of findings, fixes, and the evidence behind every
security claim. It complements `docs/AUDIT_SCOPE.md` (scope, invariants, threat
model) and `SECURITY.md` (reporting policy). **Pre-mainnet** — no real funds at
risk; the launch gate is the audited mainnet deployment.

> **Repository note (2026-09-30).** This repository is the public audit surface
> (contracts, tests, evidence, attestations, audit record). It is published as a
> scope-filtered export of the ProYield development history; the app, planning,
> and operations live in private repositories. Where entries below reference
> internal design notes or cite commit hashes from before this export, those
> refer to the development history — ask and we will point reviewers at the
> relevant material. Nothing in the findings below depends on those references.

## How to verify (all commands reproducible)

| Claim | Command |
|---|---|
| Static analysis clean vs justified baseline | `python3 scripts/security_monitor.py` |
| Invariants + adversarial + differential model | `forge test` |
| Full isolated battery (11 suites, ~290 checks) | `./scripts/run_battery.sh` |
| CI on every push | GitHub Actions (`ci.yml`) |

## Findings history

| Date | Finding | Status |
|---|---|---|
| 2026-09-30 | **PT executor owner was a hot EOA** (audit F-1): Arbitrum `PTSleeveExecutor` `0xA2e53597…` was owned by the ops EOA `0xaDD8f267…`, not the treasury Safe, so that key held `ownerRescue` (transfer any token to any address) | **Fixed on-chain** — ownership transferred to the 2-of-3 Safe `0x8A1b107e…`, verified by read-back on two independent RPCs; both PT deploy scripts now default `owner` to the Safe and hard-fail on an EOA owner |
| 2026-09-30 | **Phantom share price via `creditYield`** (F-4): the guard was a total-balance check, so the idle float could be re-credited with zero new money — an early depositor could redeem at a doubled price and take real USDC from others while honest withdrawals reverted | **Fixed** — credit is now bounded by a tracked `_accountedBalance` ledger (`uncreditedArrivals()`); `allocate()` also refuses to deploy uncredited arrivals |
| 2026-09-30 | **Emergency lever was silent and brickable** (F-5): `emergencyWithdraw` emitted no event, and `_totalAssets -= balance` underflowed (Panic 0x11) on a stray 1-wei donation, letting anyone disable the crisis exit | **Fixed** — emits `EmergencyWithdraw`; the write-down is bounded by booked assets. `setStrategyActive` / `setVault` now emit too |
| 2026-09-30 | **DN dropped Core actions could re-book principal as profit** (F-3): `bridgeBackToEvm` commits state before the fire-and-forget send, and `profitRealized` was never reversible | **Fixed** — added owner-only `reconcileProfit` (ported from `HLEarnStrategy`), refuses to go below already-swept profit |
| 2026-09-30 | **`PYDFunder.topUp` could freeze rewards permanently** (F-8): unvalidated `duration` floored `rewardRate` to 0, stranding converted PYD unrecoverably | **Fixed** — duration bounds + an explicit zero-rate rejection |
| 2026-09-30 | **Morpho yield could never be swept** (F-9): buffer was computed on `totalAssets()` (incl. the whole position) but subtracted from the idle balance, so any non-zero `bufferBps` made `sweep == 0` forever | **Fixed** — buffer now measured on the idle balance |
| 2026-09-30 | **`FeeDistributor.totalFeesReceived` froze after the first recycle** (F-13): a high-water mark, not cumulative | **Fixed** — cumulative accounting; `peakBalance` retained for the dashboard |
| 2026-09-30 | **`Harvest` event emitted gross while booking net** (F-14), overstating dashboard yield by the fee | **Fixed** — added `HarvestBooked(net, fee)` |
| 2026-09-30 | **`addStrategy` accepted codeless addresses** (F-15): `allocate()` burned real USDC into an EOA with no revert | **Fixed** — requires code, rejects duplicates |
| 2026-09-30 | **Scope drift** (F-12): this scope doc omitted the entire PT sleeve while it held live real USDC, and listed `MorphoStrategy` as legacy when it is the live lending core | **Fixed** — scope corrected; see `docs/AUDIT_SCOPE.md` §1.1 |
| 2026-09-18 | **Reentrancy class** — 23 findings across strategies/vault (deposit/withdraw/harvest interactions, event ordering) | **Fixed** — CEI reordering + `nonReentrant` on every mutating entry point; re-verified after DN consolidation |
| 2026-09-23 | **PYDStaking rollover double-accrual** (found by the forge invariant suite): a keeper top-up after an expired window double-banked rewards — claimable beyond the funded pool | **Fixed** (commit `3111a6d6`); regression test `test_rollover_without_interaction_no_double_accrual` |
| 2026-09-18→23 | **Mutation-campaign survivors** (real test gaps: paused-strategy sweep bypass, recall over-pull bound, zero-value transfer logs, contract-caller identity) | **Fixed** — new coverage tests in `test/forge/Vault.coverage.t.sol` / `PYD.coverage.t.sol`, kill-verified by hand-applying mutants |
| 2026-10-09 | **Slither delta on newer surfaces** (PT/sUSD3 executors, KinkWrapper, CreditPool/Morpho strategies, DN core, PYDFunder suite): 97 unbaselined signatures incl. 24 critical-class reentrancy — every one reviewed against its actual guards; **no exploitable path found** (`onlyOps`+`nonReentrant` on all executor entries; try/catch no-op unwinds; vault-only recall paths; mocks not deployed) | **Triaged** — 4 source cleanups (MorphoStrategy shadowing renames, PYDFunder `minConvertUsd6` → constant, DNCoreBase/KinkWrapper immutables); baseline 32→129 with per-signature reasons; `security_monitor.py` exit 0; hardhat 16/16 + full_test re-passed |
| Ongoing | Slither accepted baseline | **129 entries, each justified** in `security_baseline.json` (OZ assembly, intentional zero-guards, timestamp accrual, nonReentrant class Slither can't model, owner-managed loops, executors `onlyOps`+guarded, test mocks). Expanded 2026-10-09: monitor alerts **only** on findings not listed |

## Evidence snapshot (2026-09-30 — round-1 audit)

- **Manual audit**: 4 isolated domain reviewers (vault core / PT sleeve / DN stack /
  PYD+lending) on byte-verified repo copies, 49 executable PoC tests. Findings and
  per-domain reports: `docs/AUDIT_SCOPE.md`, and the handoff for the sessions that
  own the PT sleeve in `docs/AUDIT_HANDOFF_2026-09-30.md`.
- **Battery**: 12/12 suites PASS on the fixed tree (93s, fresh isolated anvil,
  cold-start deploy) — integration 123/123 · DN strategy 39/39 · adapter 23/23 ·
  keeper dry-runs 8/8 + 6/6 · PYD demand 29/29 · vault caps 12/12 · real-read
  replay 13/13 · journey 25 checks (USDC conserved to the wei) · chain guard 12/12
  ("never mainnet" enforced).
- **Foundry**: 158 tests passing across 16 suites, including the new
  `test/forge/Audit.fixes.t.sol` (9 tests pinning the round-1 fixes) and 3 new
  `creditYield` regressions in `Vault.invariants.t.sol`.
- **Ecosystem audit**: `node scripts/ecosystem_audit.js` — 27 passed. Two failures
  are pre-existing operator-state items, NOT contract defects: a stale
  `~/yield_scout/data/vault_state.json` heartbeat (81h) and 3 test-origin alert
  lines dated 2026-09-29 left in the scout notification queue by an earlier
  keeper dry-run.
- **Live mainnet state** (read-only, chain 999): vault owner = 2-of-3 treasury Safe,
  caps $500/$500, deposits open, 10% performance fee, 0 withdrawal fee.
  Venues-vs-book delta **+$0.0014 USDC** — the phantom-asset class (F-4) had not
  been exploited on-chain.
- **F-1 executed on-chain**: the Arbitrum PT executor ownership transfer was
  broadcast and verified by independent read-back on two RPCs (`ops()` unchanged,
  `bridgeBackCount` unchanged — no funds moved).

## Prior evidence snapshot (2026-09-24)

- **Static analysis (fresh pass 2026-09-24)**: no critical issues detected; 31
  informational findings, all baselined and justified; alerts only on NEW findings —
  reproduce with `python3 scripts/security_monitor.py`.
- **Note**: the static baseline predates the PT sleeve. A round-1 run reported 26
  NEW critical findings, all `reentrancy-balance` in contracts absent from
  `security_baseline.json`. Every affected function carries `nonReentrant`, so they
  are expected to be the documented-benign class — but they are **not yet
  triaged**, and the baseline must not be extended until they are.

- **Battery**: 12 suites / ~300 checks / ~96s on a fresh isolated anvil, per-suite
  exit codes — integration 120/120 · DN strategy 28/28 · adapter 26/26 · keeper
  dry-runs 8/8 + 6/6 · PYD demand 29/29 · vault caps 12/12 · unit 16/16 · web smoke
  PASS ($100k → $105k → $100k) · journey 25 checks (USDC conserved to the wei) ·
  ecosystem audit · chain guard 12/12 ("never mainnet" enforced).
- **Foundry**: 50 tests + 10 invariants; differential model (independent integer
  implementation) asserts exact equality after every op across 1200 randomized
  operations + fuzzed seeds.
- **Real-chain reads**: 15/15 against LIVE mainnet precompiles (manual) + 13/13
  frozen-byte replay (fixture block 46644202, in CI).
- **Mutation testing**: vault — 64/64 revert mutants caught, 296/357 tweak
  mutants (82.9%), survivors classified (equivalents proven; artifacts fixed).
  PYD — 82.7% kill rate, triaged.
- **Chain guard**: every money-mover refuses chain-id 1 (and refuses an implicit
  RPC); positive control proves chain 998 still allowed.

## Known / accepted risks

See `docs/AUDIT_SCOPE.md` §4 §6 and `security_baseline.json`. Notably:
vault `owner` is an **EOA today** — moving to a 2-of-3 Safe is a tracked
pre-mainnet item (see `docs/VAULT_UNLOCK_PLAN.md`).

**F-1 (HIGH — accepted, time-boxed; recorded 2026-10-10, kanban `t_c6e22ed9`;
bytecode sweep `t_edbb5fb7`; on-chain containment `t_f8d19d9d`).** The Book #1 vault's two **registered** PT sleeve strategies — ACTIVE until 2026-10-10, now **INACTIVE** (`strategyActive=false`) — run the **pre-remediation** `PTSleeveStrategy` source —
`0x2D3E5bf1D34791b8b66Ac4eEA6D281E918577B6b` (PT-Arb) and
`0xA96D0BB29cEE6F9e26239529789CEb74912C4b25` (PT-ETH). In that build
`completeInbound` books `retFace6` but does **not** consume `inFlight6` (zeroing
it is a separate keeper `ackArrival`), so a forgotten/failed ack makes an inbound
mint count **twice** (`idle` + still-"in-flight") → `totalAssets()` can report
**up to 2× the real money** (a false-HIGH book that masks a shortfall). R-1
(un-swept realized yield bridgeable back to the venue) is also unfixed live.

- **Loss bound (live 2026-10-10).** The overstatement per lane = the un-acked
  inbound, bounded by that lane's outstanding sent face; reported `totalAssets()`
  reaches at most ~2× real for the lane. Measured: **PT-Arb = $0** (lane flat,
  fully unwound 2026-10-09; `inFlight6`=0, `arbValue6`=0, `totalAssets`=0);
  **PT-ETH = up to $18.953737** (sent face; `arbValue6` $18.959029,
  `inFlight6`=0 → no active phantom). Vault book $126.269032 could therefore be
  overstated by up to ~$18.95 (+15%) in the worst case. This is **not a direct
  money loss** — it is a book overstatement realizable only by overpaying a
  withdrawing depositor. (The card's "$41 of real arbValue" was the stale
  2026-10-05 picture; the Arb lane has since unwound.)
- **Compensating control (live).** `scripts/pt_phantom_check.js` (Check A
  exact-phantom: `inFlight6>0` AND `sentFace6−retFace6==0`) runs every 10 min via
  `vault_watch_mainnet.js`; the alert remedy is a keeper `ackArrival` (a
  bookkeeping ack, not a money movement). No active phantom on either lane
  2026-10-10.
- **Gate.** No new TVL into those two lanes until the remediated pair is
  registered. `vault.allocate()` (owner/Safe-only) splits only across **active**
  strategies, so keeping the old lanes inactive keeps new deposits out of them.
- **Containment executed on-chain (2026-10-10, kanban `t_f8d19d9d`; owner GO
  verbatim "do the on chain lock").** Both pre-remediation lanes are now
  `strategyActive=false`, set through the 2-of-3 treasury Safe (the vault owner),
  **one Safe tx per lane — not batched**:
  - PT-Arb `0x2D3E5bf1…` — Safe tx `0x24d36b966670c905585dfccef4270e7033d09e1f7186ac0715852ca1400851a1`, block 48210915 (safe nonce 50)
  - PT-ETH `0xA96D0BB2…` — Safe tx `0xb7c7534da6c1e9b4f55f6dd20c1f96079dbc8fb0f0742bc4292c0b02148f9ae9`, block 48210929 (safe nonce 51)

  Read-back: `strategyActive == false` on both. No other state touched
  (`owner`, `tvlCap`/`perUserCap`, `depositsPaused`, and the DN/Morpho/HL-Earn/
  sUSD3 flags all unchanged; Safe nonce 50→52). **Silent on-chain:** the live
  Book #1 vault is the pre-F-5 build — its runtime bytecode has the
  `setStrategyActive` selector (`0xb0f42a1d`) but **not** the
  `StrategyActiveSet` topic (`0xe3101062…`), so the flip emits no event (the
  receipt carries only the Safe's `ExecutionSuccess`). Detect it via
  `strategyActive()` reads, not event logs. Keeper-safety verified from source:
  the return path `onStrategyReturn` requires only `strategies[msg.sender]`, not
  `strategyActive`, so the ~2026-11-05 PT-ETH lane push-return is **not** blocked.
- **Resolution (remaining).** Register the remediated pair (Arb
  `0xd7075C9BD95649b3d6831182bea2986552097A2f` / ETH
  `0x9238320Cc802863c7c1d78D1aaA6cbe0F7975092`, deployed 2026-10-05 carrying the
  F-1/F-5/yield-split + R-1 source) at the per-lane unwind boundary — Arb already
  unwound 2026-10-09 (re-point unblocked), ETH matures ~2026-11-05. Registration
  is a vault-**owner (Safe)** action. Machine-readable copy: `deployed_addresses.mainnet.json`
  `_accepted_risks[F-1]` (`onchain_lock_2026-10-10`). The PT-ETH lane's deployed
  build is now byte-verifiable (vendored: `deploy-artifacts/pt-sleeve-old/`).
