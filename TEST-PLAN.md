# Test Plan — $20 Budget, No Deploy Required

## You Can Test Right Now (Free, No Deposit Needed)

### 1. Dashboard (live)
http://localhost:8123/dashboard.html
- Shows real DeFi rates from DeFiLlama
- Core/Float/Satellite split
- CEX comparison
- Fee recycling status
- Safety scores on every pool
- Your existing data, no login needed

### 2. Website (live)
http://localhost:8080/
- Landing page with product positioning
- Vault page (deposit UI mock — real deposit needs USDC on-chain)
- Dashboard page (shows the app interface)
- Updated FeeTransparency, RevenueSharing, OurCommitments

### 3. What $20 Actually Gets You

With $20 of USDC, you CANNOT:
- Deposit into real vaults (needs minimums $50-$100 on Aave/Sky/Morpho)
- Pay MoonPay on-ramp fees (would eat most of $20)
- Test actual yield (too small to matter)

With $20, you CAN:
- Verify both interfaces render correctly at localhost
- Check that safety scores, CEX comparison, fee recycling all display
- Confirm the fee_distributor.py script runs clean
- Verify daily_all.py cron chain executes
- Test that render_dashboard.py regenerates without errors

## Test Commands

```bash
# Dashboard check
curl -s http://localhost:8123/dashboard.html | grep -o 'blend=[0-9.]*%'

# Website check
curl -s http://localhost:8080/ | grep -o 'Pro Yield'

# Re-render dashboard (simulates tomorrow's cron)
cd /home/user/yield_scout && python3 render_dashboard.py

# Run full cron chain
cd /home/user/yield_scout && python3 daily_all.py

# Check fee distributor
cd /home/user/.hermes/scripts && python3 fee_distributor.py stats
```

## When You're Ready to Deposit Real Money

Minimum practical deposit: **$200+**
- Aave/Sky/Morpho: no minimum, but gas fees on Ethereum ($5-20)
- Pendle: ~$50 minimum per position
- MoonPay on-ramp: ~1% fee (meaningful on $20)

For $20, consider:
- Wait until you have $200+ to deploy
- Use the dashboard to monitor rates
- Test on Polygon/Avalanche (lower gas) if you want to experiment sooner

## What's Actually Changed That Matters

1. Website now advertises fee recycling (was vague "planned")
2. FeeTransparency shows concrete rebate recycling message
3. OurCommitments includes fee recycling promise
4. RevenueSharing describes actual mechanism (50% to stakers, rebate recycling)
5. ReferralCard mentions recycled rebates
6. liveRates.ts data matches dashboard exactly
7. Maple flagged with credit risk everywhere it appears
8. Fee redistribution code ready (fee_distributor.py)

## Verdict

With $20: Test the interfaces, verify the code, confirm everything renders.
With $200+: Actually deposit, earn yield, see fee recycling in action (when implemented).
