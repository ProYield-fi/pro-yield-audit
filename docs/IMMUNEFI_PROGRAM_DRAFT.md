# Immunefi bug-bounty program — submission package

> Status: get-started lead form submitted 2026-10-02 (Immunefi sales flow —
> questionnaire expected at `proyield@pyd.fi` within ~5 business days). This
> document is the ready-to-paste answer set so the questionnaire turnaround is
> same-day. Terms are already fixed in advance in `SECURITY.md` — nothing here
> is negotiable-under-pressure.
>
> ⚠ **Refreshed 2026-10-26 against on-chain reads (HyperEVM 999, blocks 49,585,504–49,585,667).**
> Book #1 was replaced on 2026-10-25 (R1 generation): live vault `0x9DA979aD…AcFD9`, FeeDistributor
> `0xc8cc10dd…C27970`, caps **$10,000 TVL / $1,000 per user**, two active strategies (Morpho
> `0xb7F5DD7b…` $5.974999, HLEarn `0xA2e53597…` $5.974999), `totalAssets` **$12.95**. Every row
> below now carries its own status as of that read — **both the addresses and the statuses were
> wrong here before**, not just the numbers: four contracts still labelled `(active)` are in fact
> registered on the *superseded* vault and read `strategyActive=false`, and the actually-live Morpho
> instance was missing. Remaining stale items are in **§3** (TVL/caps) and **§4** (bounty amounts
> written against the old $500 cap), both flagged there.

## 1. Project identity

| Field | Value |
|---|---|
| Project | ProYield (`ProYield Vault`) |
| Website | https://pyd.fi |
| Source (public, source-mapped) | https://github.com/ProYield-fi/pro-yield-audit — `main` as of 2026-10-26. The vault/FeeDistributor/base-strategy source in `main` is byte-identical to the source cut that produced the deployed book (file hashes in `docs/AUDIT_SCOPE.md` §1.4). The 2026-10-02 export pin `28a940a6` is history, not what runs. |
| Security contact | `proyield@pyd.fi`; GitHub issues preferred for non-sensitive reports (`audit` label) |
| Telegram | @ProYieldFi |
| Chain | HyperEVM (Hyperliquid L1), chain id 999, RPC `https://rpc.hyperliquid.xyz/evm` |
| Asset | USDC (`0xb88339CB7199b77E23DB6E890353E22632Ba630f`, 6 decimals) |
| Ownership | Treasury Safe `0x8A1b107e1DDabC868E40b8718F09537B0A50C9aB` (2-of-3) |

## 2. Scope — smart contracts (primary)

Live mainnet addresses with **per-contract status read on chain 2026-10-26** (block 49,585,504,
`vault.strategyActive(addr)`; `strategyList` enumerated through the index accessor
`vault.strategyList(i)`). `active` below means **on the live R1 vault** `0x9DA979…`. A contract that
is deployed and healthy — even one whose flag is still `true` on the *superseded* 2026-09-25 vault
— is marked **INACTIVE** here, because the live book cannot allocate to it.

| Contract | Address | Role / status |
|---|---|---|
| `ProYieldVault.sol` | `0x9DA979aD9F44dBC96f3977F305cea9D1E1EAcFD9` | ERC-4626-style vault: deposits, withdrawals, allocation, harvest, share price. **LIVE** — `depositsPaused=false`, `totalAssets` = $12.95, caps $10,000 TVL / $1,000 per user. (The 2026-09-25 vault `0x8954a73B…D1C1` is superseded, `depositsPaused=true`, $0.004768.) |
| `FeeDistributor.sol` | `0xc8cc10ddC8a6605CfDDB3886962C184829C27970` | Fee routing (60/20/20 recycle policy). **LIVE** — `vault.feeDistributor()` returns it. (The 2026-09-25 FD `0x18FB3e2F…b8E9` belongs to the superseded vault and receives nothing.) |
| `MorphoStrategy.sol` | `0xb7F5DD7bF4b94540d3B7f8CEC9C59c7eBefe0A3E` | Morpho Blue lending sleeve. **LIVE, ACTIVE** — R1 `strategyList` index 0, $5.974999. Build `head-fixed`, source `168310a5` (contains the PY-RECALL-01 fix), runtime 7,985 B, ipfs `12202e64…`. |
| `HLEarnStrategy.sol` | `0xA2e535970dc1492f77843E26F25Ab314735F4dF5` | HYPE-earning sleeve. **LIVE, ACTIVE** — R1 `strategyList` index 1, $5.974999, `vault()` = R1. Same hex exists as `PTSleeveExecutor` on Arbitrum One — different chain, different contract; always scope an address by chain id. |
| `DNCoreStrategy.sol` / `DNCoreBase` | `0xeD40C3c34e2d4D6F2e1C0F0e688a6c05c82F9Bf4` | Delta-neutral sleeve on HyperCore. **INACTIVE — not on the live book.** Registered on the superseded vault only (its `vault()` = `0x8954…`, `strategyActive=true` there); the strategy's own `paused()` is **true** and it holds **$0**. Runs the pre-remediation `2534780f` build: no `reconcileProfit`, no A3 spot-cash NAV, and the F-8 `bridgeBackToEvm` scaling defect is live code on it. HEAD source has a fixed build that is **not deployed**. |
| `MorphoStrategy.sol` (pre-R1 instance) | `0xBF4C5e339D63EEB393DA2797679879a0a5Af2D53` | **INACTIVE — superseded book only** (`strategyActive=true` on `0x8954…`, not in the R1 list). Holds **26 µUSDC**. |
| `PTSleeveStrategy.sol` (PT-Arb) | `0x2D3E5bf1D34791b8b66Ac4eEA6D281E918577B6b` | Pendle PT via CCTP↔Arbitrum. **INACTIVE** — registered on the superseded vault, `strategyActive=false` (locked 2026-10-10), $0. Carries accepted risk F-1. |
| `PTSleeveStrategy.sol` (PT-ETH lane) | `0xA96D0BB29cEE6F9e26239529789CEb74912C4b25` | Pendle PT via CCTP↔Ethereum. **INACTIVE** — same as PT-Arb; read $18.89 on 2026-10-23 and **$0** on 2026-10-26. Carries accepted risk F-1. |
| `PTSleeveStrategy.sol` (v1, quarantined) | `0x3AE855B65A021397f7a3ca838acc8E4c82cF815f` | **INACTIVE** — registered on the superseded vault, `strategyActive=false` since 2026-10-10 (circuit-breaker quarantine), $0. |
| `SUSD3Strategy.sol` (legacy v1) | `0x9978e8745cdb0d3e5B970aC36C38575eC70D612A` | **INACTIVE** — registered on the superseded vault (index 6), `strategyActive=false`, $0. Superseded in source by the dormant `0x7dc1874F…`, which is not registered either. |
| `PYDToken.sol` | `0xbF38e441166f44cfc05205B21168a01b8a1ABf4F` | Fixed-supply ERC20, no mint path. Deployed, unchanged. |
| `PYDStaking.sol` | `0x3211e1C5443B1d178b76B4f0AF1cEf37741DbBb7` | Reward streaming (Synthetix-style). **DORMANT** — its owner is still `PYDFunder 0x1af2Cc10…`, which is retired and paused, so no new streams can start. |
| `PYDFunder.sol` | `0x1af2Cc1045584069fA34b0121D4020d28104dd1e` | **RETIRED 2026-10-23 (owner decision B)** — paused, unwired (swapper null), holds no USDC, runs a build that predates the F-8 fix. Do not wire; history, not a money path. |
| `PYDFeeDiscount.sol` | `0xD31e6E62F3A2378C12B993BFF6022aD68a8c583e` | v3 universal USDC rebate pool over ≤8 registered books. **DEPLOYED 2026-10-26 BUT INERT** — `budgetAvailable()` = 0, no rebates accrue, both R1 books registered and `booksHealthy=true`, owner = treasury Safe, `minEpochSeconds` 24h, runtime 9,791 B. Activation waits on the 10% fee slice plus a signed activation review. Previous builds, both retired: `0x2B591845…` (PY-REBATE-01, never activated, out of scope) and `0xcFC78dc4…` (A2, 2026-10-23, wired to the superseded vault pair). |

Every other deployment ever made (the superseded vault, its FeeDistributor, the two retired rebate
builds, the retired funder) is **history**: findings there are only in scope if they reach the live
book, which they cannot.

Secondary (lower bounty tier, smart-contract + API category): the auto-earn
permit flow — `functions/api/autoearn.js` + `scripts/autoearn_sweep.js` in the
source repo. The permit spender is the VAULT itself (`0x9DA979…`), never a keeper EOA, so a
leaked row can only pull the signer's own USDC into the signer's own vault position — bounded by
the signed permit value (≤ $500) and the vault's `perUserCap` ($1,000).

**The old “gated no-op until the r3 deploy ships `depositFor`” wording is retired: `depositFor` is
live.** The R1 vault runtime carries `depositFor(address,uint256)` (`0x2f4f21e2`) and
`uncreditedArrivals()` (`0x5f36bab8`) — read 2026-10-26 at block 49,585,455 — so the sweep's
capability probe **passes**. It no longer refuses on capability grounds. Two operational facts keep
it from moving funds today, and both are checkable by the reviewer:

1. it is **dry by default** — `SWEEP_OK=1` must be set explicitly, and no scheduled job runs it;
2. the only stored permit row names the **superseded vault** `0x8954a73B…` as spender (signed
   before R1), and the sweep skips any row whose spender ≠ its live vault, marking it
   `legacy-spender` without acting.

A permit signed today through the live API names the R1 vault, so it **would be sweepable**: the
vault pulls inside the signed allowance and mints to the user in one atomic tx. Reports against
that path are in scope. Per-row fault isolation records `last_error` and continues; the sweep floor
is $5.

**Out of scope:** both retired `PYDFeeDiscount` builds — `0x2B591845a250258d40B468372F432f7fda7cBE88`
(PY-REBATE-01, never registered or activated) and `0xcFC78dc4Ad488f0f3b5345ceC26BB5354Cd4f0aF`
(A2, 2026-10-23, wired to the superseded vault pair and never funded) — findings there are not in
scope; the dormant `SUSD3`/PT lanes and the retired funder in §2; `contracts/mocks/*`, HyperCore
itself (Hyperliquid's system), the website frontend, off-chain keepers except where they move user
funds (the auto-earn sweep above).

## 3. Assets in flight (honest numbers)

- Vault TVL: **$12.95** USDC — live read 2026-10-26, block 49,585,504 (`totalAssets` = `totalShares`
  = 12,950,000, 6dp), of which $11.949998 is in the two active strategies and $1.000002 is idle in
  the vault. Deposits are open.
- Hard caps in code: **$10,000 TVL / $1,000 per wallet** (`setCaps`, R1 restart rung GO-C
  2026-10-23). The superseded 2026-09-25 vault ran $500 / $500.
- Fees: 10% performance only, 0% withdrawal.
- The caps are the maximum loss ceiling — that is what bounty amounts scale against, and they rise
  only with the audit ladder (`docs/VAULT_UNLOCK_PLAN.md`). **§4 still quotes amounts sized against
  the old $500 cap.** Re-scaling them to the $10,000 ceiling is an owner decision; this package must
  not be submitted until that decision is recorded here.

## 4. Severity ladder and bounty amounts

> ⚠ The amounts below are the last values written against the **$500** TVL cap (2026-10-02 state).
> The live ceiling is **$10,000**. The severity *definitions* are current; the *amounts* await the
> owner's re-scale. Do not submit this table as-is.

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
- Note on source vs deployed bytecode: **for the vault and FeeDistributor there is no longer a gap.**
  The live R1 runtime matches the pinned artifact outside constructor-immutable slots (proof in
  `docs/AUDIT_SCOPE.md` §1.4), so a finding in either contract applies to code you can read here.
  The remaining drift is finite and named in §1.4: DN core runs the pre-remediation `2534780f`
  build (superseded vault only), the PT/sUSD3 lanes are registered there and inactive, and the live
  Morpho instance is the `168310a5` `head-fixed` build. We will state which build a finding applies
  to.

## 7. What we need from Immunefi

- Standard (non-Boost) listing, free tier — no paid triage service at this TVL.
- Smart-contract severity matrix; GitHub issue fallback preserved in
  `SECURITY.md` even after the listing is live.
- Program URL under the ProYield name, linked from pyd.fi and the repo README.