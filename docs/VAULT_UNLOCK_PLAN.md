# Vault Unlock Plan — from pre-mainnet to open deposits

Status: 2026-09-24 (rev 2). Owner questions: *"How do we unlock the vault — self-audit at
first?"* … *"There is no community yet, and I doubt I can afford an external audit.
What would you do?"*

**Short answer (rev 2):** unlock in **safe mode** — self-audit evidence + open review
artifacts + deferred-payment bounty + **hard caps** + insurance first-loss — and let
**fees pay for the eventual external audit**. Don't wait for a community that doesn't
exist yet; don't buy a fake audit; don't leave a fully test-green vault idle either.
Trust is built by *provable operation*: open code, daily attestations, published
findings, and caps small enough that a mistake is survivable. Caps rise only as
evidence (time + revenue + audit tier) accumulates.

## 1. Unlock gate (rev 2 — replaces "external audit first")

The gate to open deposits = ALL of:

1. Self-audit evidence live & reproducible (done — §3).
2. Public artifacts in place (done): open repo, `SECURITY.md`, `CONTRIBUTING.md`,
   `AUDIT-LOG.md`, `docs/AUDIT_SCOPE.md`, audit issue #1 open.
3. Bounty **live on a paid-on-acknowledged-fix basis**: recognition immediately;
   USDC paid when revenue exists; **never PYD**; vesting 14–90 days.
4. Hard caps shipped in code (§2) + insurance first-loss + pause paths.
5. Team money test passed on mainnet (deposit → allocate → harvest → withdraw, real
   money, small).

The paid external audit is **not on the critical path for the capped beta**. It is
the gate for **raising caps beyond the beta band** (§4).

### Why not "wait for a community"? Why not Fiverr?

- A community is an *output* of operating publicly, not a prerequisite. The artifacts
  are open today; reviewers show up when there is something real to review.
- A cut-price "audit" from a generalist is worse than none: it produces a certificate
  nobody credible accepts and manufactures false confidence internally. When we pay,
  we pay a known-good reviewer with a public track record.
- Unaudited-but-capped-and-transparent is a legitimate, well-trodden launch posture
  (guarded launch / canary deploy). Unaudited-and-uncapped is how projects die.

## 2. Caps ladder (safe mode — concrete defaults, adjust freely)

| Stage | Who | Per-user cap | Total TVL cap | Notes |
|---|---|---|---|---|
| S2 | Team (own money) | — | **~$500** | Mainnet E2E money test, real funds, small |
| S3a | Friends / first cohort | **$1,000** | **$10,000** | Insurance first-loss; pause paths tested |
| S3b | Early access (public) | **$5,000** | **$50,000** | Requires 30+ clean daily attestations |
| S4 | Scale | audit-dependent | **$250K → uncapped** | Raise only after the matching audit tier (§4) |

Caps live in code (vault + keeper action bounds), not in policy prose. Site copy
("early access opening in staged cohorts") already matches this ladder.

## 3. What is already true (S0 evidence — all reproducible)

- Battery: 12 suites / ~300 checks on a fresh isolated anvil (integration 120/120,
  DN 28/28 + 26/26, keeper 8/8 + 6/6, PYD demand 29/29, unit 16/16, web smoke PASS,
  journey 25 checks — USDC conserved to the wei, chain guard 12/12, vault caps 12/12).
- Foundry: 50 tests (incl. `Vault.caps.t.sol`) + 10 invariants + independent differential
  model (1200 ops,
  exact equality after every op).
- Real-chain reads: 15/15 live precompiles + 13/13 frozen-byte replay in CI.
- Mutation testing: vault 64/64 revert mutants caught, 82.9% tweaks; survivors
  classified, real gaps closed.
- Slither: no critical, no NEW vs `security_baseline.json` (fresh pass 2026-09-24 —
  reproduce with `python3 scripts/security_monitor.py`). CI green on every push.
- Mainnet deploy rehearsed on a live anvil fork (chain 999): `scripts/deploy_mainnet.js`
  (guards: MAINNET_OK=1 + chain 999 + expected-deployer + manifest + USDC sanity)
  deployed FeeDistributor + ProYieldVault + setCaps, all 10 read-back checks green
  (run 2026-09-24). Hard constraint discovered: **HyperEVM caps a tx at 3,000,000
  gas** (block gas limit) — the unoptimized vault runtime (15.3KB) could never fit
  (code deposit alone = 3.06M); hardhat now builds optimized (runtime 9.2KB, deploy
  ≈ 2.20M, FD ≈ 0.53M). Battery 12/12 + forge 50/50 re-run on the optimized build.

## 4. Audit funding ladder (fees pay — not the owner's pocket)

Policy: **the treasury fee share accumulates first toward audit tiers.** (Fee model:
10% performance fee on profits only; 20% of fees → treasury.) Engage by size of money
at risk — never before it's justified:

| Tier | Trigger | Cost ballpark | What you get |
|---|---|---|---|
| T0 — deferred bounty | At launch | **$0 now** | Recognition now; USDC on acknowledged fixes once revenue exists |
| T1 — focused freelancer review | ~$5–15K budget available | 3–7 days, one senior auditor, **small frozen scope** (lending core first) | Report + fix list, publishable |
| T2 — competitive mini-contest | TVL ≥ $250K / ~$15–40K budget | Codehawks / Sherlock / Cantina-style format | Many eyes, public report, marketing value |
| T3 — boutique audit | Before uncapping / institutional | $50K+ | Full protocol incl. DN sleeve + off-chain keepers |

The site's standing promise ("fee contract audited before any fee is charged") stays
satisfiable: `FeeDistributor` is a ~60-line contract — a T1-tier review is a realistic
way to honor it.

## 5. Free assurance while the budget is zero

- **Symbolic/equivalence checks** (Halmos / hevm) on the core invariants — spend
  compute, not money. Next free hardening item after S2 mechanics.
- **Scope freeze after S2**: every change re-runs the full battery + CI and re-logs
  in `AUDIT-LOG.md`. A frozen, small, reviewable surface is the product.
- **Optional staged unlock**: lending core first (standard ERC-4626 — the most
  reviewable mechanics), DN sleeve opens as a second cohort after a clean month.
  Both are battery-green; staging is about the reviewability story, not bug counts.
- **The attestation streak is the trust graph**: every clean day is publishable,
  verifiable evidence. Time + honesty is the cheapest security marketing there is.

## 6. Launch-mechanics checklist (S2/S3)

- [ ] Owner decision on §1 (this rev 2 gate)
- [x] Community pack files — `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
      `AUDIT-LOG.md` (shipped 2026-09-24)
- [ ] Bounty live (paid-on-fix wording) + kickoff announcement
- [x] **Deployer gas funded (2026-09-24)** — ops EOA holds **0.05 HYPE** on HyperEVM
      (path: test-wallet USDC → HYPE spot swap → Core→EVM bridge → forward;
      `scripts/hl_fund_ops_hype.py`, receipt `~/.proyield/hype_funding_receipt.json`).
      Test wallet also holds **10 USDC on HyperEVM** — the team-test deposit is
      EVM-ready. Vault asset = Circle-native USDC `0xb88339CB…` (6dp, per Circle docs)
- [ ] Mainnet Safes (2-of-3, phone backup owner) + **vault ownership transfer**
      (owner is an EOA today — flagged in `docs/AUDIT_SCOPE.md` §4)
- [ ] Minimal deploy set: `ProYieldVault` + lending strategy + `DNCoreStrategy` +
      `FeeDistributor`. **PYD suite stays undeployed until needed** (attack-surface rule).
      Script ready + fork-verified (`scripts/deploy_mainnet.js`); first real deploy will
      be **vault + FeeDistributor only** — no venue adapter exists for HyperEVM yet
      (HyperLend adapter is its own future increment), so the team-stage vault holds
      idle USDC: zero venue risk while the money path is proven end-to-end.
- [x] Caps in code per §2 — vault `tvlCap` / `perUserCap` / `depositsPaused` shipped
      2026-09-24 (+ existing per-strategy pause and keeper bounds); stage values set at deploy
- [ ] Insurance fund seeded; 20% fee stream wired
- [ ] Mainnet keeper configs + alerts + gas tank
- [ ] Attestation flips testnet → mainnet (config); `/transparency` fills; Dune public
- [ ] Team E2E on mainnet (S2), then cohort 1 opens (S3a)
- [ ] Comms: "how to verify" page, evidence links, cohort invites

## 7. Deliberately deferred (attack-surface rule)

PYD suite (token / staking / discount / funder), extra venue adapters, satellite
expansion — deploy only when the product needs them; each addition re-runs the full
battery + CI before it touches a chain.
