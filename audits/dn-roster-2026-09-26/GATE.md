# DN Keeper Roster Widening — Change Gate (2026-09-26)

## Change summary
The DN keeper was HYPE-only by construction (hardcoded asset map 0/1/159). This
change widens the sleeve to a **verified 9-coin roster** with a governed
rotation path. **No send-path logic changed** — decision, sizing, order, bridge
and harvest code paths are byte-identical; the diff adds:

1. `scripts/dn_roster.json` — verified perp+spot coin set (BTC, ETH, SOL, XRP,
   HYPE, PUMP, ZEC, MON, XMR) with live-derived spot pair/token/pxScale.
2. `scripts/dn_keeper.js`:
   - coin resolution now ROSTER-gated (unknown asset → refuse loudly, exit 2);
   - config-consistency guard: OPEN requires on-chain spot config == roster
     entry (blocks half-applied rotations);
   - rotation advice: compares the strategy's coin vs the scout capacity board
     across the roster; alerts when a verified alternative beats it by
     ≥3pp (env `DN_ROTATION_MIN_GAIN_PP`) and clears 12% 30d mean; deduped 24h;
   - log strings now use the resolved coin name.
3. `scripts/dn_roster_check.js` — read-only live verifier (re-run each session).
4. `scripts/dn_rotate_prep.js` — read-only rotation pre-flight + Safe calldata.
5. Tests: `dn_keeper_roster_test.js` (new, 15 asserts) + `dn_keeper_dryrun_test.js`
   hardened (deterministic funding, strict OPEN assert, spot-config mock).

## Rollback
- git baseline: `767a13f4` (clean tree at change start) — `git revert` restores.
- pre-edit copy: `/tmp/dn_keeper.js.pre-roster`.

## Gate evidence (all run 2026-09-26 ~05:00Z)
| Check | Result |
|---|---|
| Roster live check (`dn_roster_check.js`, mainnet) | **9/9 ok** — pxScale formula verified against 0x808 reads; basis ≤0.04%; all spot pairs liquid |
| `dn_keeper_roster_test.js` (testnet, real keeper subprocess) | **15/15** — refusal / ZEC resolution+OPEN / mismatch→HOLD+alert / rotation alert+dedup / negative |
| `dn_keeper_dryrun_test.js` | **8/8** (strict `decision: OPEN` with roster config) |
| `dn_keeper_unwind_test.js` | **6/6** (silent-drop probe still fires) |
| Clone gate — keeper DRY vs LIVE mainnet strategy, cron env (`DN_TARGET_USD=10.15`, `DN_MARGIN_UTIL_BPS=2050`) | **PASS** — HOLD, equity $2.02 / szi −11 / funding 10.95% / target 10.15 / drift −0.09% — parity with live cycle 04:20Z; no config mismatch; exit 0 |

Clone gate log: `gate_clone_dryrun.log` (this dir).

## Roster (verified_utc 2026-09-26T04:50Z)
| coin | perp idx | spot pair | token | spot $/day | 30d mean (board) |
|---|---|---|---|---|---|
| BTC | 0 | @142 UBTC | 197 | $29.4M | 9.3% |
| ETH | 1 | @151 UETH | 221 | $11.6M | 10.1% |
| SOL | 5 | @156 USOL | 254 | $12.9M | 7.3% |
| XRP | 25 | @267 FXRP | 367 | $0.15M | 11.2% |
| HYPE | 159 | @107 | 150 | $61.2M | 9.1% (current live coin) |
| PUMP | 200 | @188 UPUMP | 299 | $1.9M | 13.1% |
| ZEC | 214 | @272 UZEC | 419 | $13.5M | 12.4% |
| MON | 215 | @243 UMON | 383 | $0.06M | 12.9% |
| XMR | 224 | @260 XMR1 | 404 | $5.1M | 47.3% (issuer DD pending) |

Excluded (no HL spot → not hedgeable → never roster): NEAR, LIT, PONS, ENA,
CASHCAT, TAO, SKHX (HIP-3), and all other board names.

## Approval + remaining gates
- User directive: "widen that sleeve" (keeper capability + roster).
- **Live rotation (asset switch) remains operator-gated**: `dn_rotate_prep.js`
  prints the two Safe txs (`setPerpAsset` + `setSpotConfig`); execution needs
  the 2-of-3 treasury Safe (both on-box owner keys sign via
  `safe_exec_mainnet.js`). The keeper's config guard makes a half-applied
  rotation safe (HOLD + alert, never a trade).
- Post-deploy verification: run the live cycle once (`dn_keeper_cron.sh`) →
  expect HOLD + harvest no-op; next cron cycle 10:20Z uses the new keeper.
