# Security Policy

## Reporting

- **GitHub**: open an issue with the `audit` label on
  https://github.com/ProYield-fi/pro-yield-audit (preferred — public, timestamped).
- **Email**: proyield@pyd.fi for sensitive disclosures.

Please include: contract/function, reproduction (tx hash or test), impact
assessment. We acknowledge within 72h and publish fix commits with the
finding referenced.

## Scope

Contracts in `hypervault/contracts/` (see `docs/AUDIT_SCOPE.md` §1 for the
table). Off-scope: mocks, scripts (off-chain keepers/tests), HyperCore itself,
the website frontend.

## Current status

- **Live on HyperEVM mainnet since 2026-09-25.** Vault
  `0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1` (asset USDC
  `0xb88339CB…630f`), owned by treasury Safe
  `0x8A1b107e1DDabC868E40b8718F09537B0A50C9aB`. **Real USDC is in the
  vault and deposits are open** (`depositsPaused == false`). Current
  `totalAssets()` as of 2026-09-30: **53.39 USDC**.
- **Five strategies are registered** (`strategyList`, all `registered=true`):
  delta-neutral core `0xeD40C3c3…9Bf4` (active) · Morpho lending
  `0xBF4C5e33…2D53` (active) · Pendle PT-Arb `0x2D3E5bf1…7B6b` (active) ·
  Pendle PT-Eth `0xA96D0BB2…4b25` (active) · `0x3AE855B6…F815f`
  (registered, **inactive** — circuit breaker open). Cross-chain PT uses
  CCTP (Arbitrum ↔ Ethereum ↔ HyperEVM).
- **Caps are in force** (`setCaps`, see `CapsSet`): per-wallet and TVL caps
  keep exposure small while the product is in beta. Live TVL sits far below
  the cap.
- Static analysis: 0 critical findings vs the accepted baseline
  (`security_baseline.json`, each entry justified).
- Test suites: integration 120/120, strategy 28/28, adapter 26/26,
  real-chain read verification 15/15, keeper dry-run 8/8.
- Reentrancy: hardened 2026-09-18 (23 findings fixed) and re-verified after
  the DN consolidation; `nonReentrant` on every mutating entry point.
- Honest accounting invariants documented in `docs/AUDIT_SCOPE.md` §3 —
  principal is never counted as yield; the loss path realizes nothing.

> **Why this section used to say "pre-mainnet".** The launch gate in
> `docs/VAULT_UNLOCK_PLAN.md` was written before the mainnet deploy landed;
  the docs were not updated when it did. A researcher reading the policy
  before the evidence would reasonably conclude no funds were at risk. That
  is a real defect in the disclosure, not a subtlety — treat this note as
  the correction of record. (Flagged 2026-09-30 by an external security
> researcher reviewing this repository.)

## Honest disclosure

The product never substitutes estimates for facts: every rate carries its
source and timestamp, and the transparency page renders empty panels rather
than projected numbers. If a number on the site and the chain disagree, the
chain wins.
