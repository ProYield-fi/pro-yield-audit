# Internal audit round — free toolchain results (2026-10-03)

> All free, all reproducible, all run against the r3-ready source. This round
> complements the standing Slither gate and the two community rounds with
> three more tool classes: a second static analyzer, test-coverage mapping,
> and a deploy-drift audit (repo vs live bytecode).

## 1. Aderyn 0.6.8 (Cyfrin static analyzer, 88 detectors)

Raw: 4 High / 22 Low. Triage against source:

| Finding | Instances | Triage |
|---|---|---|
| H-1 ether lock | 1 | `MockPendleRouterMin.sol` only — test-noise |
| H-2 state change after external call | ~24 | Two REAL CEI-order tidy-ups: `ProYieldVault.emergencyWithdraw` (L185: writes `_totalAssets` after the owner transfer) and `FeeDistributor.route` (L73: writes `totalFeesRouted` after `safeTransfer`). Both are `onlyOwner nonReentrant` and the external call is a plain USDC transfer (no hooks) — not exploitable, but the write should move BEFORE the transfer. **→ r3 queue.** Remaining instances are the known balance-delta pattern on `onlyOps nonReentrant` executor entries (same triage as the Slither run) |
| H-3 contract name reuse | — | mocks sharing names across test files — noise |
| H-4 unsafe integer casts | — | the usd6 downcast class; guarded by bounds; accepted with justification (matches security_baseline) |

L-9 (`nonReentrant` not first modifier) and L-12 (state change without event)
worth a skim during r3; the rest is style.

## 2. solhint (recommended ruleset)

All style/gas classes: `gas-custom-errors` (require→custom error in the
PTSleeve/adapter files), natspec gaps, strict-inequality suggestions. No
security-class hits. Fold into the r3 tidy-up pass.

## 3. Test coverage (forge, 163/163 passing)

| Contract | Line coverage | Verdict |
|---|---|---|
| ProYieldVault | 99.5% | excellent |
| PYDToken / PYDStaking | 100% | done |
| PYDFeeDiscount | 98.1% | done |
| PTSleeveStrategy | 97.3% | done |
| MorphoStrategy | 96.2% | done |
| **PYDFunder** | **100%** (2026-10-03) | done — `test/forge/PYDFunder.t.sol`, 18 tests incl. the F-8 rate-freeze family, allowance-revocation discipline, and a re-entering swapper |
| FeeDistributor | 90.9% | good |
| DNCoreStrategy | 92.7% | good (up from 88.2%) |
| **DNCoreBase** | **100%** stmts / 93.8% branch (2026-10-03) | done — was 48.2%; `test/forge/DNCoreBase.coverage.t.sol` (33 tests): every gate (keeper/paused/core-account), every action's byte-exact CoreWriter encoding, all precompile reads incl. blackout fail-safe paths, bridge in/out |
| **BaseStrategy** | **100%** stmts/branch (2026-10-03) | done — `test/forge/BaseStrategy.coverage.t.sol`, 18 tests: base deposit/harvest defaults, inactive-harvest revert, recall clamp + silent-noop edges, setter guards/events. All product contracts ≥90% |

## 3b. Property fuzzing (2026-10-03, queued item CLOSED)

- **Foundry invariants — DNCoreBase order paths** (`test/forge/DNCoreBase.invariants.t.sol`):
  8 properties over randomized action sequences (12,800 calls, 64 runs):
  writer payload well-formedness, order cap + $10 min-notional, USD-transfer
  cap, pause freezes the writer, strangers never mutate, admin never mutates
  while hedged, `totalAssets()` never reverts (even mid precompile blackout),
  action-count monotonicity. All passing.
- **Echidna — vault money path** (`echidna/echidna_vault.sol` + config):
  3 properties (share-sum, price floor, solvency) × 20,066 calls, passing,
  corpus populated. Second-engine cross-check of the foundry suite.
  - **Harness lesson**: Echidna's senders call the TARGET contract — routing
    vault calls through wrapper functions on the property contract collapses
    every sender identity into the property contract's address (falsified the
    share-sum property spuriously until replayed in foundry). Wrappers stay;
    the share-sum property is expressed over the COMPLETE shareholder set of
    the harness ({property contract, U0, U1, U2}), so it remains exact.
  - `--multi-abi` does not exist in Echidna 2.3.3 (`--all-contracts` is the
    flag — and it fuzzes file-level contracts, NOT deployed children, so it
    passes vacuously; non-vacuousness must be verified from the corpus).
- **Echidna on DNCoreBase: NOT APPLICABLE** — Echidna has no cheatcodes, so
  the precompile etch-mocking the DN surface requires is impossible (every
  CoreWriter action reverts on the 0x810 gate read). The DN surface is
  property-fuzzed by the foundry invariant suite instead.

## 4. Deploy-drift audit (repo vs live bytecode, selector-level)

Repo-ahead-of-deploy is now exact, per contract:

| Contract | Repo-only function (not on-chain) |
|---|---|
| ProYieldVault `0x8954…D1C1` | `uncreditedArrivals()` — the fee-recycle arrival accounting |
| FeeDistributor `0x18FB…b8E9` | `peakBalance()` — cumulative fee accounting read |
| DNCoreStrategy `0xeD40…9Bf4` | `reconcileProfit(uint256)` — DN reconcile fix |
| MorphoStrategy `0xBF4C…2D53` | in sync |

This is the precise r3 redeploy delta — never build owner kits against
repo-only functions (the recycle-kit rule), and this table is the checklist
that the r3 deploy closes.

## 5. Dependency audit (npm)

- `pro-yield-web`: 51 findings, overwhelmingly dev-chain transitives. The one
  production-relevant item: `@coinbase/cdp-sdk` flagged High via `axios` —
  check the CDP SDK patch release and bump (the on-ramp must stay on a
  non-vulnerable axios).
- `hypervault`: 2 findings, ethers-v5 transitives pulled by the hardhat
  toolchain — accepted, none reachable from contracts.

## 6. Standing from here

- This toolchain joins the standing gate: Slither + Aderyn + coverage +
  drift-audit run before every deploy; results land here.
- ~~Queued next: Foundry invariant suite + Echidna/Medusa property fuzzing~~
  **DONE 2026-10-03** — see §3b (foundry DNCoreBase invariants 8 props; Echidna
  vault campaign 3 props × 20k calls). Remaining fuzzing follow-up: Medusa
  (optional third engine) — deprioritized; two independent engines already
  cover the queued scope.
- **Remaining before r3 redeploy**: DONE — BaseStrategy coverage 100% and
  both CEI-order fixes committed on repo HEAD (FD.route books before transfer;
  vault.emergencyWithdraw writes down before sweep; 233/233 green, slither
  re-run pending in this doc). The r3 deploy itself closes the §4 drift list.
  Sequence from here: pause drill (owner GO) → 30-day attest clock (10/30,
  ETA ~Oct 23) → r3 redeploy → S4/T1 audit gate.