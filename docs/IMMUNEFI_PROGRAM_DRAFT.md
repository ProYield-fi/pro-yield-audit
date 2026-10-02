# Immunefi bug-bounty program — submission package

> Status: get-started lead form submitted 2026-10-02 (Immunefi sales flow —
> questionnaire expected at `proyield@pyd.fi` within ~5 business days). This
> document is the ready-to-paste answer set so the questionnaire turnaround is
> same-day. Terms are already fixed in advance in `SECURITY.md` — nothing here
> is negotiable-under-pressure.

## 1. Project identity

| Field | Value |
|---|---|
| Project | ProYield (`ProYield Vault`) |
| Website | https://pyd.fi |
| Source (public, source-mapped) | https://github.com/ProYield-fi/pro-yield-audit — commit `28a940a6bb71aa8fda20224f2a43a7a740b0e74a` (2026-10-02) |
| Security contact | `proyield@pyd.fi`; GitHub issues preferred for non-sensitive reports (`audit` label) |
| Telegram | @ProYieldFi |
| Chain | HyperEVM (Hyperliquid L1), chain id 999, RPC `https://rpc.hyperliquid.xyz/evm` |
| Asset | USDC (`0xb88339CB7199b77E23DB6E890353E22632Ba630f`, 6 decimals) |
| Ownership | Treasury Safe `0x8A1b107e1DDabC868E40b8718F09537B0A50C9aB` (2-of-3) |

## 2. Scope — smart contracts (primary)

Live mainnet addresses, verified on-chain 2026-10-02 (`strategyList()` = 5
entries; caps and TVL read live):

| Contract | Address | Role |
|---|---|---|
| `ProYieldVault.sol` | `0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1` | ERC-4626-style vault: deposits, withdrawals, allocation, harvest, share price |
| `FeeDistributor.sol` | `0x18FB3e2FCd2221EeeB73E8D92ac892E38483b8E9` | Fee routing (60/20/20 recycle policy) |
| `DNCoreStrategy.sol` / `DNCoreBase` | `0xeD40C3c34e2d4D6F2e1C0F0e688a6c05c82F9Bf4` | Delta-neutral sleeve on HyperCore (active) |
| `MorphoStrategy.sol` | `0xBF4C5e339D63EEB393DA2797679879a0a5Af2D53` | Morpho lending sleeve (active) |
| `PendleStrategy` (PT-Arb executor `0xA2e535970dc1492f77843E26F25Ab314735F4dF5`) | `0x2D3E5bf1D34791b8b66Ac4eEA6D281E918577B6b` | Pendle PT sleeve via CCTP↔Arbitrum (active) |
| PT-Eth sleeve | `0xA96D0BB29cee6F9E26239529789CEb74912C4b25` | Pendle PT sleeve via CCTP↔Ethereum (active) |
| Sky sleeve | `0x3AE855B65a021397f7A3CA838ACc8E4C82CF815f` | Registered, inactive (circuit breaker open) |
| `PYDToken.sol` | `0xbF38e441166f44cfc05205B21168a01b8a1ABf4F` | Fixed-supply ERC20, no mint path |
| `PYDStaking.sol` | `0x3211e1C5443B1d178b76B4f0AF1cEf37741DbBb7` | Reward streaming (Synthetix-style) |
| `PYDFunder.sol` | `0x1af2Cc1045584069fA34b0121D4020d28104dd1e` | Capped USDC→PYD conversion (dormant: no swapper set) |
| `PYDFeeDiscount.sol` | `0x2B591845a250258d40B468372F432f7fda7cBE88` | Tiered fee rebates from real fee deltas |

Secondary (lower bounty tier, smart-contract + API category): the auto-earn
permit flow — `functions/api/autoearn.js` + `scripts/autoearn_sweep.js` in the
source repo. The permit spender is the VAULT itself; the sweep is gated
no-op until the r3 deploy ships `depositFor` (community finding #3, fixed
2026-10-02).

**Out of scope:** `contracts/mocks/*`, HyperCore itself (Hyperliquid's system),
the website frontend, off-chain keepers except where they move user funds
(the auto-earn sweep above).

## 3. Assets in flight (honest numbers)

- Vault TVL: **$53.40** USDC (live read 2026-10-02; deposits open).
- Hard caps in code: **$500 per wallet / $500 TVL** (`setCaps` — guarded beta).
- Fees: 10% performance only, 0% withdrawal.
- The caps are the maximum loss ceiling — that is what bounty amounts scale
  against, and they rise only with the audit ladder (`docs/VAULT_UNLOCK_PLAN.md`).

## 4. Severity ladder and bounty amounts

Standard Immunefi severity classification. Amounts are honest against the
capped beta and scale up as the caps do:

| Severity | Impact we care about | Max bounty |
|---|---|---|
| Critical | Direct theft of user deposits (drain up to TVL cap), permanent freezing of funds, vault insolvency, share-price manipulation that steals depositor value | **$500** (= TVL cap; 100% of funds-at-risk ceiling) |
| High | Theft of accrued yield/fees, temporary freezing of deposits, share-price manipulation without theft, keeper-level hedge cap bypass | **$250** |
| Medium | Griefing/DoS of harvest, allocation, or fee-routing; fee split diverges from 60/20/20 policy; strategy accounting that under/over-reports | **$100** |
| Low | Boundary/precision issues with no direct loss path | **$25** |

## 5. Payment terms (fixed in advance — `SECURITY.md`)

- **Recognition immediately**: credited in `AUDIT-LOG.md` and the fix commit
  the moment a finding is acknowledged.
- **USDC paid when revenue exists**: the protocol's 10% performance fee funds
  payouts; the bounty fund is **$0 by design today** (deferred bounty —
  `VAULT_UNLOCK_PLAN.md` §2, tier T0). Cash follows revenue; recognition and
  the published fix are immediate.
- **Never PYD**: payouts are USDC only.
- **Vesting 14–90 days** on cash payouts.
- **Paid on acknowledged fix**: valid, in-scope finding + shipped fix.

## 6. Standing review record (context for Immunefi's team)

- Two community audit rounds completed (round 2 by Firlinata, 2026-10-02) —
  findings, fixes, and fix commits public in `AUDIT-LOG.md` and the repo issues.
- Slither standing gate triaged and published (`docs/ROUND2.md`).
- Test suites: integration 120/120, strategy 28/28, adapter 26/26,
  real-chain read verification 15/15, keeper dry-run 8/8.
- Note: repo source is intentionally ahead of deployed bytecode in places
  (r3 fixes committed, gated mainnet redeploy pending). Reports are welcome
  against either; we will state which one a finding applies to.

## 7. What we need from Immunefi

- Standard (non-Boost) listing, free tier — no paid triage service at this TVL.
- Smart-contract severity matrix; GitHub issue fallback preserved in
  `SECURITY.md` even after the listing is live.
- Program URL under the ProYield name, linked from pyd.fi and the repo README.