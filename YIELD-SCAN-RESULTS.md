# Pro Yield — Yield Opportunity Scan (from external AI, 2026-09-15)

> **DATA STATUS**: Estimates from training data, as-of ~early 2025. VERIFY LIVE before ingest. Use DefiLlama/Pendle/Morpho APIs for current rates.

## CRITICAL ISSUES TO FIX

1. **sUSDe collision** — `Ethena sUSDe` excluded, but Sky also has sUSDe. Fix: disambiguate by (project, symbol) tuple, not symbol alone. Fixed in COMPETITIVE_ANALYSIS.md, YIELD-SEARCH-JSON.json.
2. **USDAI PT decay** — 8.82% is incentive-boosted outlier. At maturity, rate compresses. Schedule rollover scan 2-4 weeks prior.
3. **Fixed yield 6% target** — Unreachable without Ethena sUSDe. Realistic: 4.5-6.5%. Relax to ~5.5%.
4. **fee_distributor.py address** — `0x41610566c042395ce46ff1d210d321c2432191` verified 40 hex chars (VALID). No bug.

## NEW OPPORTUNITIES (not in current portfolio)

| Protocol | Symbol | Chain | APY | Score | TVL | Audit | Note |
|---|---|---|---|---|---|---|---|
| Fluid USDC | USDC | Ethereum/Arbitrum | 5.4% | 3/5 | ~$497M | Statemind | Verify per-vault TVL clears $50M floor |
| Compound V3 USDC | USDC | Ethereum | 5.61% | 4/5 | $35M | Audited since 2018 | TVL small ($35M), outlier rate |
| Morpho Gauntlet USDC Core | USDC | Ethereum | 5.2% | 5/5 | $800M | Trail of Bits + Spearbit | Direct upgrade vs STEAKUSDC 4.3% |
| Morpho Gauntlet USDC Base | USDC | Base | 5.0% | 3/5 | $100M | Same | Base utilization hotter, rate more volatile |
| Pendle PT-sUSDS | PT-sUSDS | Ethereum | 4.74-5.38% | 3/5 | $150M+ | Certora, ChainSecurity | Safest PT option |

## OPPORTUNITIES ALREADY IN PORTFOLIO — RECHECK

| Position | Current APY | Issue | Action |
|---|---|---|---|
| STUSDS 5.11% | Rate fluctuates with SSR | SSR moves with Sky governance | Re-fetch live rate |
| SGHO 4.50% | Aave V3 ($177M TVL), 4.35% 30d | Gauntlet USDC Core 5.2% ($800M TVL, 5/5) dominates yield AND safety | Trim to fund Morpho Gauntlet position |
| USDAI (PT) 8.82% | Incentive-boosted | Will decay at maturity (Oct 2026) | Schedule rollover scan |
| PENDLEUSDC 6.28% | LP returns fee-dependent | Decay, incentive-driven | Re-fetch live |
| STEAKUSDC 4.3% | Likely dominated | Gauntlet USDC Core 5.2% higher | Compare live |

## UPDATED RENDER_DASHBOARD.PY

Render_dashboard.py currently shows blend=5.77%, safe=18, strategy=9. Needs update when new positions are added (Fluid, Compound V3, Morpho Gauntlet).

## NEXT STEPS

1. **Fluid USDC** (3/5, 5.4%, ~$497M TVL) — strongest risk-adjusted new opportunity. Per-vault TVL may be below $50M floor — verify before adding.
2. **Compound V3 USDC** (4/5, 5.61%) — TVL only $35M, may fail $50M floor. Outlier rate may not persist.
3. **Morpho Gauntlet USDC Core** (5/5, 5.2%, $800M TVL) — dominates current SGHO position (4.5%, 4/5). Could replace SGHO in core allocation.
4. **Pendle PT-sUSDS** (3/5, 4.74-5.38%) — safest fixed-yield PT alternative.
5. **SGHO trim analysis** — 4.5% (Aave V3, 4/5) vs Gauntlet 5.2% (Morpho, 5/5). Yield gain +1.7%, safety gain +1. Is diversification worth the loss?
