Yield Strategy Scout
===================

Daily at 09:00 (no_agent) → collects live rates from DeFiLlama (735+ pools),
protocol revenues (Aave/Sky/Morpho/Pendle), funding rates. Writes:
  strategy_data/latest.json (current snapshot)

At 09:05 → yield-strategy-evaluator.py scores all pools 0-5 safety,
filters by criteria (audited/non-custodial/no leverage/TVL≥$50M),
writes strategy_data/evaluation_YYYY-MM-DD.json

At 09:15 → yield-strategy-advisor.py generates daily recommendation
(8 strategy categories, safety gates) → strategy_data/daily_report.md

Composite run:
  yield-strategy-chain.py → runs scout + evaluator in sequence
  (used by cron at 09:00)

Single dashboard:
  yield_scout/dashboard.html → renders EVERYTHING from live data
  (run: cd yield_scout && python3 render_dashboard.py)

Safety criteria (TIGHT):
  - Audited protocols: Aave, Sky, Morpho, Pendle → +4 safety pts
  - Known DeFi (Curve, GMX, Uniswap, Lido): +3
  - TVL ≥ $500M + stablecoin: +3
  - TVL ≥ $50M + stablecoin: +2
  - TVL ≥ $50M non-stablecoin: +1
  - Blue-chip stablecoin (USDC/USDT/DAI/etc): +1
  - CUTOFF: ≥ 3 to appear as opportunity; ≥ 4 to auto-portfolio
  - All strategies: non-custodial, no leverage, TVL ≥ $50M minimum

Strategy Categories evaluated:
  1. Maker/Taker fee capture (volume-dependent)
  2. Delta-neutral (funding rate arb)
  3. Cross-chain arbitrage
  4. Fixed yield (Pendle PT tokens)
  5. Protocol fee capture (ve-model)
  6. RWA yields (tokenized bills, T-bills)
  7. LST staking rewards (synthetic)
  8. Incentive liquidity mining (short-term, MATIC risk)

Standards: live-data-verification, no synthesized values.
UNAVAILABLE = fetch failed, shown as gap.
