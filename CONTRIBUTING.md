# Contributing — Community Audit & Testing Guide

Thanks for helping test ProYield. This repo is public specifically so anyone can
reproduce every security claim. Start with `docs/AUDIT_SCOPE.md` — it is the
reviewer's front door (scope, architecture, invariants, threat model, evidence).

## Reproduce the evidence

```bash
git clone https://github.com/ProYield-fi/pro-yield-fi
cd pro-yield-fi

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
  https://github.com/ProYield-fi/pro-yield-fi/issues
- **Email** `proyield@pyd.fi` for sensitive disclosures.

Include: contract/function, reproduction (tx hash or failing test), impact
assessment. We acknowledge within 72h and publish fix commits referencing the
finding. Disclosure timeline: **90 days** (earlier by agreement if fixed).

## Rewards (community audit program)

- Valid findings earn **recognition first, bounty second**: every acknowledged
  finding is published here in `AUDIT-LOG.md` with the fix.
- Monetary bounties are **USDC-backed and paid once the vault is revenue-
  positive** — we do not promise what we cannot yet fund, and we **never pay in
  $PYD**.
- **Vesting**: bounty payouts vest over **14–90 days** depending on severity.
- **Anti-Sybil**: reward eligibility requires a staked position and passes
  basic chain analysis. Spam/duplicate reports don't qualify.

## House rules

- One finding per issue; minimal repro preferred over prose.
- Don't test against live user funds; use testnet (`998`) or local anvil.
- Security > speed: if you find something critical, email before posting.
