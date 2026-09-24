# Audit Log — Published Findings & Evidence Index

This is the public record of findings, fixes, and the evidence behind every
security claim. It complements `docs/AUDIT_SCOPE.md` (scope, invariants, threat
model) and `SECURITY.md` (reporting policy). **Pre-mainnet** — no real funds at
risk; the launch gate is the audited mainnet deployment.

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
| 2026-09-18 | **Reentrancy class** — 23 findings across strategies/vault (deposit/withdraw/harvest interactions, event ordering) | **Fixed** — CEI reordering + `nonReentrant` on every mutating entry point; re-verified after DN consolidation |
| 2026-09-23 | **PYDStaking rollover double-accrual** (found by the forge invariant suite): a keeper top-up after an expired window double-banked rewards — claimable beyond the funded pool | **Fixed** (commit `3111a6d6`); regression test `test_rollover_without_interaction_no_double_accrual` |
| 2026-09-18→23 | **Mutation-campaign survivors** (real test gaps: paused-strategy sweep bypass, recall over-pull bound, zero-value transfer logs, contract-caller identity) | **Fixed** — new coverage tests in `test/forge/Vault.coverage.t.sol` / `PYD.coverage.t.sol`, kill-verified by hand-applying mutants |
| Ongoing | Slither accepted baseline | **23 entries, each justified** in `security_baseline.json` (OZ assembly, intentional zero-guards, timestamp accrual, nonReentrant class Slither can't model, owner-managed loops) |

## Evidence snapshot (2026-09-24)

- **Static analysis (fresh pass 2026-09-24)**: no critical issues detected; 31
  informational findings, all baselined and justified; alerts only on NEW findings —
  reproduce with `python3 scripts/security_monitor.py`.

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
