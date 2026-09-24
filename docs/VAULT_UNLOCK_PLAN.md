# Vault Unlock Plan — from pre-mainnet to open deposits

Status: 2026-09-24. Owner question: *"How do we unlock the vault — self-audit at first?"*

**Short answer: yes.** Self-audit → public/community review → capped beta is the launch
path. The paid external audit is the gate to **scale**, not to start (typical cost
$50–150K — affordable post-revenue; see open questions in `BETA-LAUNCH-CHECKLIST.md`).

## 1. Gate decision (the only thing that needs an owner call)

The standing rule is "no product contracts on mainnet until the audit passes." "The
audit" now needs a concrete definition:

- **Option A (recommended) — self + community audit + hard caps = unlock.**
  Internal program (done, §3) + published evidence pack + community review window +
  live bounty + hard caps (TVL / per-user / keeper action bounds / pause) + insurance
  first-loss. Unlocks a **capped beta, staged in cohorts** — exactly what the site
  already promises ("early access opening in staged cohorts").
- **Option B — wait for a paid external audit before any mainnet deploy.**
  Strongest external trust signal; blocks launch for weeks at a cost not yet budgeted.

**Recommendation: A now, B before raising caps / institutional scale.** Every artifact
already assumes this path: the community-audit framework explicitly replaces the paid
audit at beta stage, and `SECURITY.md` gates on "the audited mainnet deployment" where
"audited" = the published, reproducible program below.

## 2. Stage ladder

| Stage | What | When | Exit condition |
|---|---|---|---|
| **S0 · Self-audit** | Internal program (§3) | **DONE** | All suites green in CI |
| **S1 · Community review open** | Pack published, audit issue #1 updated, bounty live, announcement | This week | Review window opened publicly |
| **S2 · Mainnet deploy + team money test** | Minimal deploy set, ownership → Safe, caps, insurance, attestation flip, small real deposit→withdraw E2E | Days after S1 | E2E verified with real funds |
| **S3 · Cohort 1 (early access)** | "Vault deposit — opens with early access" turns real; caps + monitoring hold | Staged cohorts | Caps stable, attestations daily |
| **S4 · Scale** | Post external audit: raise caps, institutional outreach | Post-revenue | External audit passed |

## 3. Evidence the gate is met (S0 — all reproducible)

- Battery: 11 suites / ~290 checks on a fresh isolated anvil (integration 120/120,
  DN 28/28 + 26/26, keeper 8/8 + 6/6, PYD demand 29/29, unit 16/16, web smoke PASS,
  journey 24 checks — USDC conserved to the wei, chain guard 12/12).
- Foundry: 43 tests + 10 invariants + independent differential model (1200 ops,
  exact equality after every op).
- Real-chain reads: 15/15 live precompiles + 13/13 frozen-byte replay in CI.
- Mutation testing: vault 64/64 revert mutants caught, 82.9% tweaks; survivors
  classified, real gaps closed.
- Slither: no critical, no NEW vs `security_baseline.json` (fresh pass 2026-09-24 —
  reproduce with `python3 scripts/security_monitor.py`). CI green on every push.

## 4. Launch-mechanics checklist (S2/S3)

- [ ] **Owner decision on §1** (the one blocker)
- [x] Community pack files — `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
      `AUDIT-LOG.md` (shipped 2026-09-24)
- [ ] Bounty: flip site "Bug Bounty (Coming Soon)" → live; announcement post
- [ ] Mainnet Safes (2-of-3, phone backup owner) + **vault ownership transfer**
      (owner is an EOA today — flagged in `docs/AUDIT_SCOPE.md` §4)
- [ ] Minimal deploy set: `ProYieldVault` + lending strategy + `DNCoreStrategy` +
      `FeeDistributor`. **PYD suite stays undeployed until needed** (attack-surface rule)
- [ ] Caps in code: total TVL cap, per-user cap, keeper `maxActionUsd6`, pause paths
- [ ] Insurance fund seeded + 20% fee stream wired
- [ ] Mainnet keeper configs + alerts + gas tank
- [ ] Attestation flips testnet → mainnet (config); `/transparency` fills; Dune public
- [ ] Team E2E on mainnet: deposit → allocate → harvest → withdraw (real money, small)
- [ ] Comms: "how to verify" page, evidence links, cohort invites

## 5. Deliberately deferred (attack-surface rule)

PYD suite (token / staking / discount / funder), extra venue adapters, satellite
expansion — deploy only when the product needs them; each addition re-runs the full
battery + CI before it touches a chain.
