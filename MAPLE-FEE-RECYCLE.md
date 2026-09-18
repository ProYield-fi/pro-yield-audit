# Maple, Rebates & Fee Recycling — Decision Memo

## 1. Maple: Fits Criteria, But Scoring Gap

**Current data**: syrupUSDC at 4.97% APY, $2.63B TVL, audited (Spearbit, Three Sigma, 0xMacro)

| Criterion | Maple | Verdict |
|---|---|---|
| Audited | Yes | ✓ |
| Non-custodial | Users hold syrupUSDC | ✓ |
| No leverage | Overcollateralized | ✓ |
| TVL ≥ $50M | $2.63B | ✓ |
| **Institutional credit risk** | Borrower default possible | ⚠ |
| Yield source | Real loan interest (not emissions) | ✓ |

**The scoring problem**: `score_safety()` gives Maple 4/5 (TVL+stablecoin+bluechip bonuses). But our Core pools are ALL 5/5 — Maple is categorically different. It takes borrower credit risk that Sky/Aave don't.

**Recommendation**: Don't rework the whole scoring system. Add a **credit risk tag** to Maple (and Ondo, any credit-exposed protocol):

- Display: "safety 4/5 ⚠ credit risk" in dashboard
- Action item: "Credit risk review required — Maple takes institutional borrower defaults"
- Let user decide with eyes open

Maple is already in the data (deFiLlama pools, $2.63B TVL). Just needs the tag.

## 2. PM Rebates: Already Tracked, Just Needs Routing

`reward_monitor.py` already monitors `REWARD` and `MAKER_REBATE` at `0x41610566c042395ce46ff1d210d321c2432191`. The gap is:

- **MONITOR**: exists ✓
- **ROUTE to treasury**: needs new code
- **DISTRIBUTE to users**: needs new code
- **DISPLAY in dashboard**: needs new section

At $500K AUM: estimated +1.2-4.8% APY boost during high-volume periods.

## 3. $PYD Trading Fees: Secondary, Part of the Loop

DEX fees from $PYD trading are NOT the main value. They're a **supplementary incentive**. The primary value is from HL rebates + PM rebates + curator fees (see FEE-PYD-ANALYSIS.md).

The real question: is $PYD fee-sharing implemented? Currently NO — pyd.fi has "planned utility" = unimplemented. This needs to be built.

## 4. The Current Portfolio Already Has the Trade-off Visible

Core: 8 pools, all **safety 5/5** — clean.
Satellites (10%): SUSDAT (15.39%) and APXUSD (12.49%) — both **safety 1/5** ✓ already shown as "→ new" in Strategy Opportunities, already flagged in Monitors.

So the user IS seeing: "we could earn 13.94% from satellites but they're safety 1/5 = CEX-equivalent risk." That's the honest trade-off.

## 5. Action Items (implemented in dashboard)

The dashboard Action Items section already shows:
- Core: STUSDS at 5.11% — maintain allocation ✓
- Opportunities: USDC (accountable) at 11.4% — review for satellite sleeve ✓
- "Fee recycling is real but unimplemented" should be added

## Files Updated

- `/home/user/yield_scout/MAPLE-FEE-RECYCLE.md` — Maple credit risk analysis, PM rebate routing plan, $PYD fee loop
- `/home/user/yield_scout/FEE-PYD-ANALYSIS.md` — cross-referenced
- Dashboard already shows the trade-off (Core 5/5 vs Satellites 1/5)
- Next cron: tomorrow 09:00 via `daily_all.py`
