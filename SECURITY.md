# Security Policy

## Reporting

- **GitHub**: open an issue with the `audit` label on
  https://github.com/ProYield-fi/pro-yield-fi (preferred — public, timestamped).
- **Email**: proyield@pyd.fi for sensitive disclosures.

Please include: contract/function, reproduction (tx hash or test), impact
assessment. We acknowledge within 72h and publish fix commits with the
finding referenced.

## Scope

Contracts in `hypervault/contracts/` (see `docs/AUDIT_SCOPE.md` §1 for the
table). Off-scope: mocks, scripts (off-chain keepers/tests), HyperCore itself,
the website frontend.

## Current status

- **Pre-mainnet.** The audited mainnet deployment is the launch gate; no real
  funds are at risk before that deploy.
- Static analysis: 0 critical findings vs the accepted baseline
  (`security_baseline.json`, each entry justified).
- Test suites: integration 120/120, strategy 28/28, adapter 26/26,
  real-chain read verification 15/15, keeper dry-run 8/8.
- Reentrancy: hardened 2026-09-18 (23 findings fixed) and re-verified after
  the DN consolidation; `nonReentrant` on every mutating entry point.
- Honest accounting invariants documented in `docs/AUDIT_SCOPE.md` §3 —
  principal is never counted as yield; the loss path realizes nothing.

## Honest disclosure

The product never substitutes estimates for facts: every rate carries its
source and timestamp, and the transparency page renders empty panels rather
than projected numbers. If a number on the site and the chain disagree, the
chain wins.
