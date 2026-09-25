# Pro Yield — community audit repository

Pro Yield is a **non-custodial, stablecoin-lending vault on HyperEVM**. This repository is the public **audit surface**: everything needed to review and reproduce the vault's security claims lives here — and nothing else.

## Start here

- **`docs/AUDIT_SCOPE.md`** — the reviewer's front door: scope, architecture, invariants, threat model, evidence index.
- **`CONTRIBUTING.md`** — reproduction commands (static analysis, Foundry invariants, the full isolated battery), how to report, reward terms.
- **`AUDIT-LOG.md`** — public findings/fixes record with the evidence index.
- **`docs/VAULT_UNLOCK_PLAN.md`** — the staged unlock: self-audit → community review → capped beta → external audit before scaling.
- **`attestations/`** — daily on-chain attestations (chain 999).

## Reproduce

```bash
git clone https://github.com/ProYield-fi/pro-yield-fi
cd pro-yield-fi

npx hardhat compile
python3 scripts/security_monitor.py   # static gate: 0 critical vs justified baseline
forge test                            # invariants + adversarial + differential model
./scripts/run_battery.sh              # full isolated battery (~11 suites, fresh anvil each)
```

CI runs the battery + Slither + forge on every push — a green badge is reproducible locally with the commands above.

## Verify on-chain

Contract addresses live in `deployed_addresses.json` / `deployed_addresses.mainnet.json`; daily attestations (balances, fees, coverage) are published under `attestations/`. The website (pyd.fi) serves the same feed verbatim.

## Report a finding

Open an issue with the `audit` label (preferred — public, timestamped) or email `proyield@pyd.fi` for sensitive disclosures. We acknowledge within 72h and publish fix commits referencing the finding. Disclosure window: 90 days (shorter by agreement once fixed).

## Rewards

Recognition first, bounty second: every acknowledged finding is published in `AUDIT-LOG.md` with its fix. Monetary bounties (USDC — **never** other assets, never via unsolicited "solution" PRs) begin once the vault is revenue-positive, with vesting.

**We never solicit payments to any wallet.** Any comment attaching a payout address to a "fix" is a scam — it is removed, the author is blocked, and the submission is not reviewed.

## License

MIT — see `LICENSE`. This repository intentionally contains only the audit surface; internal operations, research, and tooling live elsewhere.
