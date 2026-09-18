# Rewards & Incentives Deep-Dive — verified 2026-09-09
Standing rule: every number below carries a source + timestamp. UNAVAILABLE = fetch failed, not zero.

## Polymarket (sources: gamma-api.polymarket.com live poll 2026-09-09 14:28 UTC; docs.polymarket.com/programs/*.md fetched 2026-09-09)

### 1. Liquidity Rewards (get paid for resting limit orders, no fill needed)
- LIVE POOL: **$9,353/day across 96 reward-bearing markets** (~$3.4M/yr). Top market $1,200/day (US-Iran ceasefire); Fed-rate markets $1,000/day each.
- Crypto 5m/15m/4h TWAP special allocation ($1M, BTC 5m $300k etc.) was **August-only** — absent from Sept 9 live poll.
- Mechanics: quadratic score `S=(v−s/v)²·b`, both sides boosted, single-side scores; minSize + maxSpread per market; daily 00:00 UTC payout, $1 min, no rollover.
- VERDICT: real but small pool split among all global quoters; requires active market-making infrastructure (= the archived bot class). NOT passive yield.

### 2. Maker Rebates (share of taker fees when your resting order gets FILLED)
- Rebate % of taker fees by category: Crypto 20%, Sports 15%, Finance/Politics/Economics/Culture/Weather/Tech/Mentions/Other 25%, Geopolitics 0 (fee-free).
- `fee_equivalent = C × feeRate × p × (1−p)`; your share of per-market pool; daily pUSD, $1 min.
- Taker fee rates: Crypto 0.07, Sports/Economics/Culture/Weather/Other 0.05, Finance/Politics/Mentions/Tech 0.04.

### 3. Taker Rebate Tiers (rebate on your own taker fees)
- 7 tiers, 30-day weighted volume `wV = size × (1−entryPrice) × catWeight × bonuses`. Crypto weight 2.3, Economics/Culture/Weather 1.7, Politics/Finance/Mentions/Tech 1.3, Sports 1.0.
- Bronze $2k wV → 3% … Gold $200k → 18% … Obsidian $10M+ → 50%. One-time level-up bonuses $10→$25,000.
- VERDICT: only matters if trading large volume — it's a discount, not income.

### 4. Referral Program (10% of net fees of referred traders)
- Gate: $10,000 lifetime personal volume to activate. 10% of net fees, **30 days per referral**, ends when referral hits Platinum. Daily pUSD payout.
- VERDICT: distribution revenue, not yield. Fits proyield.fi IF it ever drives trading traffic. Requires personal $10K volume first.

### 5. Builder Program
- docs.polymarket.com/programs/builder-program → **UNAVAILABLE (404 on 2026-09-09)**. Do not quote terms from memory.

## Hyperliquid (sources: api.hyperliquid.xyz live 2026-09-08/09; hyperliquid.gitbook.io docs fetched 2026-09-09)

### 1. HLP vault (passive deposit into protocol's own market-making vault)
- Live APR: **UNAVAILABLE** (vault endpoints returned 422 during 2026-09-08/09 pulls). Historical claim of low-teens APR is NOT verified live — treat as unverified.
- VERDICT: it is a TRADING vault — drawdowns are structural (user's own bot history proves the class of risk). Not for house money core.

### 2. HIP-3 builder-dex deployer (the big one)
- Requirement: **stake 500,000 HYPE (~$25M)**, held min 183 days per dex. Deployer earns **50% of all trading fees** on their dex + configurable deployer fee share **0–300%** (0–100% in growth mode; >100% raises protocol fee to match). First 3 assets per dex skip the Dutch auction; further assets auctioned.
- VERDICT: the actual "yield without trading" at HL is deployer economics — but gated at ~$25M. Not accessible.

### 3. Builder codes (fee share on trades routed through your frontend)
- Builders earn fee share on orders submitted with their code (works on perps and, per HIP-4 docs, spot-style outcome trading). No special rebate program beyond that (Hyperliquid Wiki: "no special programs or rebates").
- Staking referral program: "coming soon" per wiki — do not bank on it.
- VERDICT: fits proyield.fi distribution layer IF users ever trade through the frontend. Zero fit for passive parking.

### 4. HIP-4 outcome markets (HL's Polymarket competitor)
- Fees currently ZERO during rollout; builder codes work on outcome trades. Recurring binary daily 06:00 UTC BTC market live; multi-outcome later.
- VERDICT: early. Watch for a liquidity-rewards program appearing here (PM-style) — that would be the signal to re-evaluate.

### 5. HIP-3 funding carry (for completeness — REJECTED for house money)
- Live extremes 2026-09-08: para:ANSEM +465% APR, xyz:BRENTOIL −166%, xyz:SOFTBANK −143%, xyz:NATGAS +126%. Majors: BTC +8.3%, ETH +11.0%.
- Harvesting = shorting the asset = directional trading with margin/liquidation risk. Rejected per 09-06 pivot.

## Bottom line (unchanged after deep dive)
- **No program anywhere pays passive yield without either (a) active quoting work, (b) referred/attributed trading activity, or (c) ~$25M capital (HIP-3 deployer).**
- The zero-trading yield remains the stablecoin lending sleeve (3.6–5.3% verified live) + Pendle PT fixed + capped satellites.
- proyield.fi monetizes via the DISTRIBUTION layer (PM referral 10%, HL builder codes) — only once there is traffic worth attributing. Not before.
