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
| FeeDistributor | 90.9% | good |
| DNCoreStrategy | 88.2% | good |
| BaseStrategy | 73.2% | recall/harvest edge paths to add |
| **DNCoreBase** | **48.2%** | **gap — the shared HyperCore execution surface (CoreWriter sends, precompile reads, gates) is half-untested. Target ≥90% before the r3 redeploy.** |
| **PYDFunder** | **0.0%** | dormant (no swapper set) but funds-touching — unit-test before any activation |

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
- **Queued next (free, downloadable): Foundry invariant suite + Echidna/Medusa
  property fuzzing** on the vault core (share/asset accounting, cap
  enforcement, pause semantics) and DNCoreBase order paths — property-based
  testing is the biggest remaining internal gap after coverage.