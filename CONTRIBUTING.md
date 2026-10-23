# Contributing — Community Audit & Testing Guide

Thanks for helping test ProYield. This repo is public specifically so anyone can
reproduce every security claim. Start with `docs/AUDIT_SCOPE.md` — it is the
reviewer's front door (scope, architecture, invariants, threat model, evidence).

## Reproduce the evidence

```bash
git clone https://github.com/ProYield-fi/pro-yield-audit
cd pro-yield-audit

# 1. Static analysis gate (0 critical vs the justified baseline)
npx hardhat compile
python3 scripts/security_monitor.py

# 2. Stateful invariants + adversarial cases + differential model (Foundry)
forge test

# 3. The full isolated battery (fresh anvil per suite, ~11 suites / ~290 checks)
./scripts/run_battery.sh
```

CI runs the battery + Slither + forge on every push — a green CI badge is
reproducible locally with the commands above.

## Report a finding

- **GitHub issue** with the `audit` label (preferred — public, timestamped):
  https://github.com/ProYield-fi/pro-yield-audit/issues
- **Email** `proyield@pyd.fi` for sensitive disclosures.

Include: contract/function, reproduction (tx hash or failing test), impact
assessment. We acknowledge within 72h and publish fix commits referencing the
finding. Disclosure timeline: **90 days** (earlier by agreement if fixed).

## Rewards (community audit program)

- There is **no active paid bounty program**. The old token-denominated
  schedule is withdrawn; we do not require a token stake to submit a finding,
  and we do not promise token or cash payments.
- Valid findings earn **recognition**: every acknowledged finding is published
  here in `AUDIT-LOG.md` with the fix, unless the reporter asks to remain
  anonymous.
- We offer early, private access to the fix commit for re-testing.
- Any future paid program will be announced in writing with clear scope,
  eligibility, and payment terms. Nothing in this repo is an offer of payment.

## House rules

- One finding per issue; minimal repro preferred over prose.
- Don't test against live user funds; use testnet (`998`) or local anvil.
- Security > speed: if you find something critical, email before posting.
