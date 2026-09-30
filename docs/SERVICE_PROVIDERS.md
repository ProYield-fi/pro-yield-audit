# Service Providers — public record

*Companion to the audit surface: [docs/AUDIT_SCOPE.md](AUDIT_SCOPE.md) · live transparency feed: [pyd.fi/transparency](https://pyd.fi/transparency) · last updated 2026-09-30.*

Every on-ramp, every strategy, every service provider — documented, with rates, fees, and status. No black boxes.

## On-ramps — getting USDC in

| Provider | How it works | Fees | Status |
|---|---|---|---|
| **Coinbase Onramp (CDP)** | Buy USDC with a card or bank transfer directly into your wallet; the same USDC flows on to the vault | **Zero ProYield fee** — Coinbase applies its standard payment fees, shown in its checkout | ✅ **Live** |
| **MoonPay** | Card / bank purchase with in-flow KYC; signed URLs, webhooks, and the widget are already built | ProYield adds no fee; MoonPay charges its own rates at checkout | ⏳ Built — enabling is pending a compliance step in our operating jurisdictions |
| **Ramp Network** | Checkout-style purchase — no standing account; KYC happens inside the flow, USDC delivered to your wallet | ProYield adds no fee; Ramp charges its own rates at checkout | ⏳ Partner verification in progress |

ProYield adds no fees on top of a provider's shown rates, and no provider is enabled anywhere until its compliance requirements are met for that jurisdiction.

## Strategies — what the vault actually does

- **Lending-first.** Returns come from stablecoin borrower interest and hedged funding — never directional trading with user funds. Core lending runs on battle-tested venues (Morpho live today).
- **Capped sleeves.** Higher-yield sleeves are limited to a maximum of 10% of the portfolio, in the product itself. Diversification across venues and stablecoin issuers is enforced in code — policy, not discretion.
- **Live roster.** The full strategy roster — every sleeve, its status, and its on-chain address — is published continuously in the transparency feed (`vault_status.json`). The feed is the source of truth, and it updates as the roster changes.

## Fees

- **Performance fee only:** a flat **10% of profits**, charged only once fees activate (early beta: nothing is charged). Never on deposits, withdrawals, or principal.
- **$PYD staking tiers** reduce the fee through rebates once staking launches.
- **Deposits and withdrawals are free**, and withdrawals are never gated by anything except the vault's own solvency.
- On-ramp providers charge their own rates, shown in their checkout.

## Infrastructure & processors

- **Cloudflare** — website hosting, CDN, and security services.
- **Privy** — embedded wallet authentication.
- **MoonPay** — fiat-to-crypto payment processing (when enabled).
- The complete processor list, with purposes, is in the privacy policy: [pyd.fi/privacy](https://pyd.fi/privacy).

## Status & honesty notes

- **Guarded beta** on HyperEVM mainnet: hard caps enforced in code (**$500 TVL / $500 per user**), stepped up as confidence grows. The external audit gates the cap-raise and is funded from protocol fees.
- **Contracts are not yet externally audited.** Static analysis (Slither), a full isolated test battery, and a public community audit run continuously — [github.com/ProYield-fi/pro-yield-audit](https://github.com/ProYield-fi/pro-yield-audit), issue #1. Do not treat unaudited contracts as risk-free.
- This page describes only services in use or under evaluation, and is updated as the lineup changes.
