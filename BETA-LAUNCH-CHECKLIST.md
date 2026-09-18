# Beta → Live Launch Checklist

## Phase 0: Pre-Beta (IN PROGRESS)

### Infrastructure (P0)
- [x] Website built (pending CF Pages deploy)
- [x] Domain pyd.fi referenced in meta tags
- [ ] SSL via CF Pages (auto)
- [ ] Dashboard data served on production website
- [x] All 5 components built and verified locally

### Code Verification (P0)
- [x] Render dashboard tested (blend=5.79%, exit 0)
- [x] Daily all tested (exit 0)
- [x] Safety scores verified (4 bugs fixed)
- [x] USDAI risk disclosed

### Documentation (P1)
- [x] $20 test plan documented
- [ ] Fee recycling design documented
- [ ] Risk disclosure for all pools

---

## Phase 1: Beta (Internal Testing)

### Integration (P0)
- [ ] Dashboard connects to live snapshot.json
- [ ] $20-$200 deposit by team (testing yield flow)
- [ ] Withdraw test
- [ ] Fee recycling simulation

### Testing (P1)
- [ ] Website mobile responsive
- [ ] External beta testers (2+)
- [ ] No critical bugs

---

## Phase 2: Soft Launch (Limited Public)

### Production (P0)
- [ ] Terms + risk disclosure published
- [ ] First external deposit (>$200)
- [ ] Insurance fund operational (fee-to-insurance flow)

### Community (P2)
- [ ] Discord/Telegram launch
- [ ] Twitter announcement

---

## Phase 3: Full Launch (TVL > $100K, 30+ days stable)

### Features (P1-P2)
- [ ] Satellite allocation (USDAI 2/5+)
- [ ] Fee recycling fully on-chain
- [ ] $PYD for all depositors
- [ ] L2 deployment (Sky Arbitrum)
- [ ] Core swap STEAKUSDC → PENDLEUSDC
- [x] Fee-to-insurance fund — implemented (insurance_fund.py, collects PM rewards + fees)

### Growth (P2)
- [ ] Institutional outreach
- [ ] Quarterly audit reports
- [ ] Delta-neutral tier (if user decides)

---

## Immediate Next Steps
1. Deploy front-end to Cloudflare Pages
2. Configure SSL + custom domain
3. Verify all 5 components on production
4. Deploy vault contract (testnet)
5. Test deposit/withdraw end-to-end
6. Run $20-$200 test deposit
7. Connect fee recycling to live addresses
8. Deploy mainnet
9. First real deposit
10. Monthly review

## Blocking Questions
1. Capital for initial vault test ($200+)?
2. Budget for audit ($50K-$150K)?
3. Cloudflare Pages or self-hosted?
4. Delta-neutral tier (relaxed criteria)?
5. L2 deployment priority?
