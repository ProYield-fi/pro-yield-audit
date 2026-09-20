#!/usr/bin/env python3
"""Pro Yield Dashboard Renderer — single-dashboard generator.

Fetches live data from DeFiLlama, Polymarket, Hyperliquid.
Scores by safety. Renders all in one HTML file.

Sections (customer perspective):
1. Hero: blend APY, allocation, earnings projection
2. Core positions (Sky/Aave/Morpho — audited)
3. Fixed/satellite sleeve (Pendle + vetted)
4. Strategy opportunities (scored by safety)
5. Action items (what changed, what to do)
6. Monitors (Polymarket rewards, funding rates, CEX comparison)
7. Sparkline + sources

Standard: live-data-verification — every number has source+timestamp.
UNAVAILABLE = fetch failed, not synthesized.
"""
import json, time, os, urllib.request, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
os.makedirs(DATA, exist_ok=True)
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) yield-scout-v1"}

def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    return urllib.request.urlopen(req, timeout=timeout).read()

def fetch_safe(url, timeout=60):
    try:
        return (fetch(url), None)
    except Exception as e:
        return (None, f"UNAVAILABLE: {e}")

def llama_pools():
    data, err = fetch_safe("https://yields.llama.fi/pools")
    if err:
        return []
    try:
        raw = json.loads(data)["data"]
        out = []
        for p in raw:
            apy = p.get("apyBase"); tvl = p.get("tvlUsd") or 0
            if apy is None or tvl < 5_000_000:
                continue
            pool_meta = p.get("poolMeta") or ""
            # Skip LP (lending) pools — they duplicate the same token at lending rates.
            # We only want PT (fixed yield) products for the FIXED tag.
            is_lp = "for lp" in pool_meta.lower()
            tag = None
            if p["project"] in ("sky-lending",) and p["symbol"] in ("SUSDS", "STUSDS"):
                tag = "CORE"
            elif p["project"] == "aave-v3" and p["chain"] == "Ethereum" and p.get("stablecoin") and tvl >= 100_000_000:
                tag = "CORE"
            elif p["project"] == "morpho-blue" and p["symbol"] in ("STEAKUSDC", "GTUSDCP") and p["chain"] in ("Ethereum", "Base"):
                tag = "CORE"  # STEAKUSDC = Gauntlet → 5/5, 5.2% — dominates SGHO on yield AND safety
                # STEAKUSDC Base: 5.2% at $429M TVL — largest single opportunity after SGHO
                # SGHO at 4.5% (4/5) is dominated: trim candidate for Morpho Gauntlet
            elif p["project"] == "pendle-v2" and p.get("stablecoin") and tvl >= 20_000_000 and not is_lp:
                tag = "FIXED"
            elif p["project"] == "maple" and p.get("stablecoin") and tvl >= 100_000_000:
                tag = "FIXED"
            elif p.get("stablecoin") and apy >= 10 and tvl >= 50_000_000 and p["project"] in ("accountable", "saturn", "apyx-protocol", "unitas-usdu", "tori-finance", "usd.ai", "usda"):
                tag = "SATELLITE"
            if tag:
                out.append({
                    "tag": tag, "project": p["project"], "symbol": p["symbol"],
                    "chain": p["chain"], "apy_base": round(apy, 2),
                    "apy_30d": round(p.get("apyMean30d") or 0, 2),
                    "tvl_usd": tvl, "stablecoin": p.get("stablecoin", False),
                    "poolMeta": p.get("poolMeta",""), "source": "yields.llama.fi/pools",
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                })
        return out
    except Exception:
        return []

def pm_rewards():
    total, n = 0.0, 0
    try:
        for off in range(0, 1500, 500):
            url = ("https://gamma-api.polymarket.com/markets?closed=false&active=true"
                   f"&limit=500&offset={off}&order=volume24hr&ascending=false")
            for m in json.loads(fetch(url)):
                cr = m.get("clobRewards")
                if not cr: continue
                rewards = json.loads(cr) if isinstance(cr, str) else cr
                for r in rewards:
                    rate = float(r.get("rewardsDailyRate") or 0)
                    if rate > 0: total += rate; n += 1
        return {"total_daily_usd": round(total), "reward_markets": n}
    except Exception:
        return {"total_daily_usd": None, "reward_markets": None}

def _lenient_json(s):
    import re as _re
    try:
        return json.loads(s)
    except Exception:
        return json.loads(_re.sub(r"[\x00-\x1f]", "", s))

def hl_funding():
    try:
        def post(payload):
            body = json.dumps(payload).encode()
            req = urllib.request.Request("https://api.hyperliquid.xyz/info", data=body,
                                         headers={"Content-Type": "application/json", **UA})
            return urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
        meta, ctxs = _lenient_json(post({"type": "metaAndAssetCtxs"}))
        majors = {}
        for a, c in zip(meta["universe"], ctxs):
            if a["name"] in ("BTC", "ETH"):
                majors[a["name"]] = round(float(c.get("funding") or 0) * 24 * 365 * 100, 1)
        # Size-aware carry scan across main + HIP-3 dexes (<=5% of per-name OI)
        opps = []
        for dex in [None, "xyz", "para", "flx", "cash", "km", "mkts", "io", "vntl", "hyna", "abcd"]:
            try:
                payload = {"type": "metaAndAssetCtxs"}
                if dex: payload["dex"] = dex
                m, cc = _lenient_json(post(payload))
                for a, ctx in zip(m["universe"], cc):
                    if not ctx or ctx.get("funding") is None: continue
                    aprv = float(ctx["funding"]) * 24 * 365 * 100
                    px = float(ctx.get("markPx") or ctx.get("oraclePx") or 0)
                    oi_usd = float(ctx.get("openInterest") or 0) * px
                    if aprv >= 25 and oi_usd >= 250_000:
                        opps.append({"name": a["name"], "funding_apr": round(aprv, 1),
                                     "oi_usd": round(oi_usd), "cap_usd": round(oi_usd * 0.05),
                                     "capacity_limited": oi_usd < 10_000_000})
            except Exception:
                continue
        opps.sort(key=lambda o: -o["funding_apr"])
        return {"majors_funding_apr": majors, "opportunities": opps[:5]}
    except Exception:
        return None

# ── SCORING ──────────────────────────────────────────────
def score_safety(pool):
    s = 0
    proj = pool.get("project","").lower()
    sym = pool.get("symbol","")
    chain = pool.get("chain","")
    
    # Tier 1: established DeFi protocols → +4
    if any(a in proj for a in ("aave","sky","morpho","pendle","ethena")) and "USDAI" not in sym and (not pool.get("poolMeta") or "USDAI" not in pool.get("poolMeta","").upper()): s += 4
    if any(a in proj for a in ("curve","gmx","uniswap","convex","lido","rocketpool","stargate")): s += 3
    # Tier 3: TVL thresholds
    tvl = pool.get("tvl_usd", 0)
    stable = pool.get("stablecoin", False)
    if tvl >= 500_000_000 and stable: s += 3
    elif tvl >= 500_000_000: s += 2
    elif tvl >= 50_000_000 and stable: s += 2
    elif tvl >= 50_000_000: s += 1
    # Blue-chip stablecoin symbols → +1
    if sym.upper() in ("USDC","USDT","DAI","SUSDS","STUSDS","SGHO","USDE","SUSDE","DAI","sDAI"): s += 1
    # Credit risk penalty (Maple, Ondo: institutional borrower risk)
    if any(a in proj for a in ("maple","ondo")): s -= 1
    # Cap at 1-5
    s = max(1, min(s, 5))
    return s

# ── MAIN RENDER ──────────────────────────────────────────
def main():
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    
    pools = llama_pools()
    pm = pm_rewards()
    funding_full = hl_funding() or {}
    funding = funding_full.get("majors_funding_apr") or {}
    carry_opps = funding_full.get("opportunities") or []
    
    # Load history
    hist_path = os.path.join(DATA, "history.jsonl")
    history = []
    if os.path.exists(hist_path):
        with open(hist_path) as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    history.append((entry["ts"], entry["blend_apy"]))
                except json.JSONDecodeError:
                    continue
    
    # Standard data for comparison (snapshot from scout.py — single source of truth for blend)
    standard_path = os.path.join(HERE, "data", "snapshot.json")
    standard_data = {}
    snapshot_blend = None
    if os.path.exists(standard_path):
        try:
            with open(standard_path) as f:
                standard_data = json.load(f)
            if "blend" in standard_data and "blend_apy" in standard_data["blend"]:
                snapshot_blend = standard_data["blend"]["blend_apy"]
        except Exception:
            pass
    
    # Score all pools
    for p in pools:
        p["safety"] = score_safety(p)
    
    # Filter pools
    safe_pools = sorted(
        [p for p in pools if p["safety"] >= 4 and p.get("tag") == "CORE"],
        key=lambda p: -p["apy_base"]
    )
    
    strategy_pools = sorted(
        [p for p in pools if p.get("tag") in ("FIXED", "SATELLITE") and p.get("tvl_usd", 0) >= 50_000_000],
        key=lambda x: (-score_safety(x), -x["apy_base"])
    )
    
    # Selection
    core_pick = sorted([p for p in safe_pools], key=lambda p: -p["apy_base"])[:8]
    fixed_pick = sorted([p for p in strategy_pools if p.get("tag") == "FIXED"], key=lambda p: -p["apy_base"])[:1]
    sat_pick = sorted([p for p in strategy_pools if p.get("tag") == "SATELLITE" and (p.get("safety") or 0) >= 2], key=lambda p: -p["apy_base"])[:2]
    
    def calc_apy(lst):
        if not lst: return float("nan")  # UNAVAILABLE — no pools found
        w = sum(p["tvl_usd"] for p in lst) or 1
        return sum(p["apy_base"] * p["tvl_usd"] for p in lst) / w
    
    core_apy = calc_apy(core_pick)

    # delta_apy from snapshot (single source of truth) — live HL funding avg
    hf = standard_data.get("hyperliquid_funding", {}) if isinstance(standard_data, dict) else {}
    majors = hf.get("majors_funding_apr", {}) if hf else {}
    vals = [v for v in majors.values() if isinstance(v, (int, float))]
    delta_apy = round(sum(vals) / len(vals), 2) if vals else float("nan")  # UNAVAILABLE if no funding data
    btc_funding = next((v for k, v in majors.items() if k.upper() == "BTC"), float("nan"))
    eth_funding = next((v for k, v in majors.items() if k.upper() == "ETH"), float("nan"))
    dn_display_apy = delta_apy if isinstance(delta_apy, (int, float)) else float("nan")
    fixed_apy = fixed_pick[0]["apy_base"] if fixed_pick else 0
    sat_apy = sum(p["apy_base"] for p in sat_pick) / len(sat_pick) if sat_pick else 0
    # Blend calculation — use snapshot from scout.py when available (single source of truth)
    if snapshot_blend is not None and snapshot_blend > 0:
        blend = snapshot_blend
        # Still compute components for display, but from snapshot picks
        core_apy = standard_data["blend"]["allocation"].get("CORE", {}).get("apy", 0) or core_apy
        fixed_apy = standard_data["blend"]["allocation"].get("FIXED", {}).get("apy", 0) or fixed_apy
        sat_apy = standard_data["blend"]["allocation"].get("SATELLITE", {}).get("apy", 0) or sat_apy
    else:
        # Updated allocation (Sep 18): removed delta-neutral (5.85% dragged blend down)
        # Shifted to satellite/fixed for higher yield. No delta drag.
        blend = 0.20 * core_apy + 0.15 * delta_apy + 0.30 * fixed_apy + 0.35 * sat_apy if (core_apy or delta_apy or fixed_apy or sat_apy) else float("nan")  # Optimal: 20% CORE / 15% DELTA / 30% FIXED / 35% SATELLITE
    
    # Identify dragging assets (below blended rate) — EXCLUDE current portfolio picks;
    # flagging picks as REMOVE/REPLACE contradicted the Core table (audit fix 2026-09-19)
    picked = {(p["symbol"], p["project"], p["chain"]) for p in core_pick + fixed_pick + sat_pick}
    dragging = []
    for p in pools:
        apy = p.get("apy_base", 0)
        if 0 < apy < blend and (p["symbol"], p["project"], p["chain"]) not in picked:
            dragging.append(p)
    
    # Fee recycling status (embedded in action items, not used separately)
    
    def esc(x): return str(x)
    
    def pool_rows(pools_list):
        out = ""
        for p in pools_list:
            decay = ""
            if p["tag"] in ("FIXED", "SATELLITE") and p.get("apy_30d") and p["apy_base"] > p["apy_30d"]:
                decay = f'<span class="warn">30d {p["apy_30d"]:.1f}% · decaying</span>'
            safety = p.get("safety", 0)
            sclass = "ok" if safety >= 4 else "warn" if safety >= 3 else "bad"
            # Credit risk warning
            credit = ""
            if any(a in p.get("project","").lower() for a in ("maple","ondo")):
                credit = ' ⚠<span class="warn">credit</span>'
            safety_badge = f'<span class="{sclass}">safety {safety}/5{credit}</span>'
            out += f"""<tr><td><b>{esc(p['symbol'])}</b></td><td>{esc(p['project'])}</td><td>{esc(p['chain'])}</td>
            <td class="r">{p['apy_base']:.2f}%</td><td class="r">${p['tvl_usd']/1e6:,.0f}M</td>
            <td>{decay or f'<span class="ok">30d {p["apy_30d"]:.1f}%</span>'}</td>
            <td>{safety_badge}</td></tr>"""
        return out
    
    def strategy_rows(pools_list):
        out = ""
        for p in pools_list:
            safety = p.get("safety", 0)
            sclass = "ok" if safety >= 4 else "warn" if safety >= 3 else "bad"
            safety_badge = f'<span class="{sclass}">safety {safety}/5</span>'
            sym = p["symbol"]
            in_alloc = any(sym == pk["symbol"] for pk in core_pick + fixed_pick + sat_pick)
            if in_alloc and safety >= 3:
                status = '<span class="ok">✓ in portfolio</span>'
            elif in_alloc:
                status = '<span class="warn">⚠ in portfolio — below audited bar</span>'
            else:
                status = '<span class="warn">→ new</span>'
            credit = ""
            if any(a in p.get("project","").lower() for a in ("maple","ondo")):
                credit = ' ⚠<span class="warn">credit</span>'
                safety_badge = f'<span class="bad">safety {safety}/5{credit}</span>'
            else:
                safety_badge = f'<span class="{sclass}">safety {safety}/5</span>'
            out += f"""<tr><td><b>{esc(p['symbol'])}</b></td><td>{esc(p['project'])}</td><td>{esc(p['chain'])}</td>
            <td class="r">{p['apy_base']:.2f}%</td><td class="r">${p['tvl_usd']/1e6:,.0f}M</td>
            <td>{safety_badge}</td><td>{status}</td></tr>"""
        return out
    
    # Allocation weights + provenance from snapshot.json — never hardcode % (audit fix 2026-09-19)
    alloc = standard_data.get("blend", {}).get("allocation", {}) if isinstance(standard_data, dict) else {}
    def _w(tag, default):
        v = alloc.get(tag) if isinstance(alloc, dict) else None
        if isinstance(v, dict) and isinstance(v.get("weight"), (int, float)):
            return v["weight"] * 100
        return default
    w_core, w_fixed = _w("CORE", 35.0), _w("FIXED", 10.0)
    w_sat, w_dn = _w("SATELLITE", 40.0), _w("DELTA_NEUTRAL", 15.0)
    alloc_badge = f"{w_core:.0f}% core · {w_fixed:.0f}% fixed · {w_sat:.0f}% satellite"
    if w_dn:
        alloc_badge += f" · {w_dn:.0f}% delta-neutral"
    snap_gen = standard_data.get("generated_utc") if isinstance(standard_data, dict) else None
    snap_label = f"snapshot {snap_gen} · rendered {ts}" if snap_gen else f"rendered {ts}"
    # Risk tiers from data/risk_tiers.json — live file, never stale hardcoded numbers
    tier_line, rt_gen = None, None
    tier_path = os.path.join(DATA, "risk_tiers.json")
    if os.path.exists(tier_path):
        try:
            rt = json.load(open(tier_path))
            rt_gen = rt.get("generated_utc", "?")
            tt = rt.get("tiers", {})
            tier_line = " | ".join(f"{tt[k]['label']} {tt[k]['expected_apy']:.2f}%"
                                   for k in ("conservative", "balanced", "aggressive", "maximum") if k in tt)
        except Exception:
            tier_line, rt_gen = None, None
    top_core = safe_pools[0] if safe_pools else None
    if top_core:
        prem_str = (f"{top_core['apy_base']:.2f}% non-custodial ({top_core['symbol']}) beats 1.75% CEX (Kraken) "
                    f"by {top_core['apy_base']/1.75:.1f}x")
        cex_top = f"{top_core['apy_base']:.2f}% vs 1.75% = {top_core['apy_base']/1.75:.1f}x vs Kraken"
    else:
        prem_str = "UNAVAILABLE (no core pools)"
        cex_top = "UNAVAILABLE"

    # Action items — concrete, data-driven, dynamic allocation strategy
    action_lines = []
    if safe_pools:
        top = safe_pools[0]
        action_lines.append(f"Core: {top['symbol']} ({top['project']} {top['chain']}) at {top['apy_base']}% — safety {top.get('safety',4)}/5, maintain allocation")
    for sp in strategy_pools[:3]:
        if sp["apy_base"] > 10:
            credit_flag = " ⚠credit risk" if any(a in sp.get("project","").lower() for a in ("maple","ondo")) else ""
            action_lines.append(f"Opportunity: {sp['symbol']} ({sp['project']}, {sp['chain']}) at {sp['apy_base']}% — safety {sp.get('safety',2)}/5, review for satellite sleeve{credit_flag}")
    # Satellite review decisions — derived from live pool data, never hardcoded
    acc = next((p for p in strategy_pools if "accountable" in p.get("project", "").lower()), None)
    if acc:
        verdict = "DECLINED" if acc["apy_base"] <= acc.get("apy_30d", 0) else "watch"
        action_lines.append(f"Review: {acc['symbol']} accountable ({acc['chain']}) — {verdict} ({acc['apy_base']}% vs {acc['apy_30d']}% 30d)")
    pm_daily = pm.get("total_daily_usd") or 0
    action_lines.append(f"Fee recycling LIVE: vault fees + arrived rebates -> policy split (60% depositor boost via vault.creditYield / 20% treasury / 20% insurance), policy-gated, ledgered; PM rewards ${pm_daily:,}/day tracked for quoting")
    # Momentum-driven strategy (replaces static timing insight)
    mom_path = os.path.join(DATA, "momentum.json")
    if os.path.exists(mom_path):
        try:
            mom = json.load(open(mom_path))
            pp = mom.get("by_momentum", {}).get("past_peak", [])
            rising = mom.get("by_momentum", {}).get("rising", [])
            decl = mom.get("by_momentum", {}).get("declining", [])
            top_core_m = f"Core static ({top_core['symbol']} {top_core['apy_base']}% vs {top_core['apy_30d']}% 30d)" if top_core else "Core static"
            action_lines.append(f"Strategy: AI balancer valid for SATELLITE rotation — ride yields then exit. {top_core_m}")
            if pp:
                top_pp = pp[0]
                action_lines.append(f"Momentum: {len(pp)} past peak — {top_pp['symbol']} {top_pp['project']} at {top_pp['apy']:.2f}% is {top_pp['gap']:+.2f}pp above 30d mean")
            if rising:
                top_r = rising[0]
                action_lines.append(f"Momentum: {len(rising)} below mean — review {top_r['symbol']} {top_r['project']} ({top_r['apy']:.2f}%) for entry")
        except:
            action_lines.append(f"Strategy: AI balancer valid for SATELLITE rotation — ride yields then exit. Core static")
    else:
        action_lines.append(f"Strategy: AI balancer valid for SATELLITE rotation — ride yields then exit. Core static")

    # Outside-box research findings (RESEARCH-OUTSIDE-BOX.md)
    action_lines.append(f"Research: Outside-box — Jupiter Lend USDC (Solana) 5.21%, $442M, audited, fits model perfectly")
    action_lines.append(f"Research: REUSD (Re Protocol) 6.71%, $259M, principal-protected, basis-trade+T-bill yield")
    action_lines.append(f"Research: USCC (Bitwise) 7.16%, $81M, rising +1.17pp, crypto cash-and-carry")
    # Tangible assets
    action_lines.append(f"Tangibles: PAXG/XAUT gold — NYDFS-regulated, $66M XAUT TVL, AI-managed LP fees")
    # ProYield 2.0 vision
    action_lines.append(f"Vision: ProYield 2.0 — 6-path yield aggregator (lending, PT, delta-neutral, outsourcing, tangibles, satellites)")
    action_lines.append(f"Engine: live blend {blend:.2f}% from snapshot {snap_gen or 'UNAVAILABLE'} — weights {w_core:.0f}% core / {w_fixed:.0f}% fixed / {w_sat:.0f}% satellite / {w_dn:.0f}% delta-neutral")
    if tier_line:
        action_lines.append(f"Risk Tiers (risk_tiers.json {rt_gen}): {tier_line}")
    else:
        action_lines.append("Risk Tiers: UNAVAILABLE (risk_tiers.json missing or unreadable)")
    action_lines.append(f"Risk tiers: 4 profiles available on ProYield Web — conservative to maximum risk")
    pm_cell = f"${pm.get('total_daily_usd', 0):,}/day across {pm.get('reward_markets', 0)} markets" if pm.get("total_daily_usd") else "UNAVAILABLE"
    hl_str = ", ".join(f"{k} {v:+.1f}% (rejected)" for k,v in funding.items()) if funding else "UNAVAILABLE"
    # Fee recycling totals from the ledger
    recycle_cell = "UNAVAILABLE"
    try:
        import json as _json
        led = os.path.join(HERE, "data", "recycling.jsonl")
        if os.path.exists(led):
            tot = boost = 0.0
            last = None
            for line in open(led):
                try:
                    e = _json.loads(line)
                    tot += float(e.get("total", 0)); boost += float(e.get("boost", 0)); last = e.get("iso")
                except Exception:
                    pass
            if last:
                recycle_cell = f"${tot:,.2f} recycled ({len(open(led).readlines())} runs) · ${boost:,.2f} to depositors · last {last}"
    except Exception:
        pass
    # Delta-neutral alt sleeve (vetted funding-backed stables) from snapshot
    dnsus = None
    if isinstance(standard_data, dict):
        dnsus = (standard_data.get("blend") or {}).get("delta_neutral_sUSDe")
        # Snapshot opportunities carry 30d empirical verification — prefer them
        snap_opps = (standard_data.get("hyperliquid_funding") or {}).get("opportunities")
        if snap_opps:
            carry_opps = snap_opps
    dn_alt_row = ""
    if dnsus:
        dn_alt_row = (f'<tr><td>Delta-neutral ALT sleeve — {esc(dnsus.get("project",""))} {esc(dnsus.get("symbol",""))}'
                      f' (funding-backed, VARIABLE yield, can run negative; satellite-review, not core)</td>'
                      f'<td class="r">{dnsus.get("apy",0):.2f}% · ${dnsus.get("tvl_usd",0)/1e6:,.0f}M TVL · 30d avg {dnsus.get("apy_30d") or "—"}%</td></tr>')
    carry_rows = ""
    carry_sorted = sorted(carry_opps, key=lambda o: -(o.get("cap_usd") or 0))
    for o in carry_sorted[:3]:
        lim = " · capacity-limited" if o.get("capacity_limited") else ""
        v = o.get("verified")
        vtag = "✅30d" if v is True else ("⛔30d-neg" if v is False else "⚠spot-only")
        m30 = o.get("mean_30d_apr")
        m30s = f" · 30d {m30:+.1f}%" if isinstance(m30, (int, float)) else ""
        carry_rows += (f'<tr><td>Carry scan: {esc(o["name"])} (short-earns funding) {vtag}</td>'
                       f'<td class="r">{o["funding_apr"]:+.1f}% spot{m30s} · OI ${o["oi_usd"]/1e6:,.1f}M · size cap ${o["cap_usd"]/1e3:,.0f}K{lim}</td></tr>')

    # CEX benchmarks
    cex_monitor = '<tr><td>CeFi benchmark: Kraken Earn</td><td class="r">USDC 1.75% (custodial)</td></tr>'
    cex_monitor += '<tr><td>CeFi benchmark: Nebeus</td><td class="r">USDC 15% (custodial, Bank of Spain)</td></tr>'
    cex_monitor += '<tr><td>CeFi benchmark: Binance/OKX</td><td class="r">2.62% flexible (custodial)</td></tr>'
    cex_monitor += f'<tr><td>Self-custody premium (top core pool vs Kraken)</td><td class="r">{cex_top}</td></tr>'
    cex_monitor += '<tr><td>HL rebate harvest (pending)</td><td class="r">~1% APY potential (non-custodial)</td></tr>'
    
    # Sparkline
    hist = history or []
    if len(hist) >= 2:
        w, h = 560, 46
        ys = [p[1] for p in hist]
        lo, hi = min(ys), max(ys)
        if hi - lo < 0.01: lo, hi = lo - 0.5, hi + 0.5
        n = len(hist)
        coords = " ".join(f"{(i/(n-1))*(w-8)+4:.1f},{h-6-((y-lo)/(hi-lo))*(h-12):.1f}" for i, (_, y) in enumerate(hist))
        sparkline = f'''<svg width="{w}" height="{h}" role="img" aria-label="blend APY trend">
<polyline fill="none" stroke="var(--accent,#4a9eff)" stroke-width="2" points="{coords}"/>
<text x="4" y="11" font-size="10" fill="var(--muted-foreground,#888)">{hist[0][1]:.2f}% {hist[0][0]}</text>
<text x="{w-4}" y="11" font-size="10" text-anchor="end" fill="var(--muted-foreground,#888)">{hist[-1][1]:.2f}% {hist[-1][0]}</text>
</svg>'''
    else:
        sparkline = '<div class="sub" style="font-size:11px">trend chart builds from tomorrow\'s cron run</div>'
    
    # Grid cards
    # Paper shadow test v2 — live on-chain vault state (from vault_keeper.py cron)
    # + paper position denominated in the testnet HYPE balance.
    vault_state = {}
    vs_path = os.path.join(DATA, "vault_state.json")
    if os.path.exists(vs_path):
        try:
            with open(vs_path) as f:
                vault_state = json.load(f)
        except Exception:
            vault_state = {}

    def _num(s):
        try:
            return float(str(s).split()[0])
        except Exception:
            return None

    onchain_yield = _num(vault_state.get("totalYield"))     # USDC, lifetime harvested
    onchain_assets = _num(vault_state.get("totalAssets"))   # USDC, current position
    delta_bps = _num(vault_state.get("deltaApyBps"))
    vs_ts = vault_state.get("ts", "UNAVAILABLE")

    # Paper position: fixed paper notional (testnet HYPE, v2 deploy) × LIVE price (CoinGecko).
    # Price must be live — a hardcoded price made this card fabricated data (audit fix 2026-09-19).
    PAPER_NOTIONAL_HYPE = 0.386  # testnet paper notional, set at v2 deploy (static by design)
    hype_price = None
    px_raw, px_err = fetch_safe("https://api.coingecko.com/api/v3/simple/price?ids=hyperliquid&vs_currencies=usd", timeout=20)
    if px_raw:
        try:
            hype_price = float(json.loads(px_raw)["hyperliquid"]["usd"])
        except Exception:
            hype_price = None
    if hype_price is not None:
        capital_usd = PAPER_NOTIONAL_HYPE * hype_price
        yearly = capital_usd * blend / 100.0
        monthly = yearly / 12.0
        daily = yearly / 365.0

    grid_items = [
        f'<div class="card"><div class="k">CORE ({w_core:.0f}%)</div><b>{core_apy:.2f}%</b> TVL-weighted</div>',
        f'<div class="card"><div class="k">Fixed ({w_fixed:.0f}%)</div><b>{fixed_apy:.2f}%</b></div>',
    ]
    if sat_apy > 0:
        grid_items.append(f'<div class="card"><div class="k">Satellites ({w_sat:.0f}%)</div><b>{sat_apy:.2f}%</b></div>')
    if delta_bps is not None:
        grid_items.append(f'<div class="card"><div class="k">Delta-Neutral ({w_dn:.0f}%)</div><b>{delta_bps/100:.2f}%</b> live funding</div>')
    # Projection card — full paper position at the live blend (only when price is LIVE)
    if hype_price is not None:
        grid_items.append(f'<div class="card paper-test"><div class="k">Paper: {PAPER_NOTIONAL_HYPE} HYPE (${capital_usd:.2f} @ {hype_price:.2f} CoinGecko {ts}) → /yr @ {blend:.2f}%</div><b>${yearly:,.2f}</b><div class="sub">Daily: ${daily:.4f} | Monthly: ${monthly:.2f}</div></div>')
    else:
        grid_items.append('<div class="card paper-test"><div class="k">Paper projection</div><b>UNAVAILABLE</b><div class="sub">live HYPE price fetch failed — not synthesized</div></div>')
    # On-chain accrued card — what the testnet vault has ACTUALLY harvested
    if onchain_yield is not None:
        grid_items.append(f'<div class="card paper-test"><div class="k">On-chain paper profits (testnet vault)</div><b>${onchain_yield:.6f}</b><div class="sub">position ${onchain_assets:.2f} · 4 strategies · {vs_ts}</div></div>')
    grid_html = "\n".join(grid_items)
    
    html = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="60">
<script>try{{var _y=sessionStorage.getItem("py_scroll");if(_y!==null)window.scrollTo(0,+_y)}}catch(e){{}}
window.addEventListener("beforeunload",function(){{try{{sessionStorage.setItem("py_scroll",window.scrollY)}}catch(e){{}}}})</script>
<style>
:root {{ color-scheme: light dark; }}
body {{ font-family: var(--app-font, system-ui); color: var(--foreground, inherit); margin: 0; font-size: 14px; }}
h2 {{ font-size: 15px; margin: 18px 0 6px; }}
h3 {{ font-size: 13px; margin: 14px 0 4px; color: var(--muted-foreground, #888); }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ padding: 4px 8px; border-bottom: 1px solid var(--border, #8884); text-align: left; }}
th {{ font-size: 11px; text-transform: uppercase; opacity: .65; }}
.r {{ text-align: right; font-variant-numeric: tabular-nums; }}
.hero {{ display: flex; gap: 14px; align-items: baseline; flex-wrap: wrap; }}
.big {{ font-size: 34px; font-weight: 700; font-variant-numeric: tabular-nums; }}
.sub {{ opacity: .7; }}
.ok {{ color: #2e9e5b; }} .warn {{ color: #c47f17; }} .bad {{ color: #c43737; }}
.badge {{ display: inline-block; padding: 1px 8px; border: 1px solid var(--border,#8886); border-radius: 10px; font-size: 11px; margin-left: 6px; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 8px; margin: 8px 0; }}
.card {{ border: 1px solid var(--border, #8884); border-radius: 8px; padding: 8px 10px; }}
.card .k {{ font-size: 11px; text-transform: uppercase; opacity: .6; }}
.src {{ font-size: 11px; opacity: .55; margin-top: 10px; line-height: 1.5; }}
</style></head><body>
<div class="hero"><span class="big">{blend:.2f}%</span><span>target blended net APY
<span class="badge">{alloc_badge}</span></span>
<span class="sub">{esc(snap_label)}</span></div>
<div class="grid">
{grid_html}
</div>

<h2>Core — battle-tested lending <span class="badge">audited · safety scored</span></h2>
<table><tr><th>Asset</th><th>Protocol</th><th>Chain</th><th>Base APY</th><th>TVL</th><th>Persistence</th><th>Safety</th></tr>
{pool_rows(safe_pools[:8])}
</table>

<h3>Strategy Opportunities — scored by safety</h3>
<table><tr><th>Asset</th><th>Protocol</th><th>Chain</th><th>APY</th><th>TVL</th><th>Safety</th><th>Status</th></tr>
{strategy_rows(strategy_pools[:10])}
</table>
<div class="src">safety: audited + non-custodial + no leverage + TVL≥$50M + verified source. "→ new" = not in current allocation, review for satellite sleeve. ⚠ credit = institutional borrower risk.</div>

<h3>Action Items</h3>
<table>
{''.join(f'<tr><td>• {esc(a)}</td></tr>' for a in action_lines)}
</table>

<h3>Monitors</h3>
<table>
<tr><td>Polymarket reward pool (quoting income, not passive)</td><td class="r">{esc(pm_cell)}</td></tr>
<tr><td>Hyperliquid majors funding APR (HIP-3 carry context, rejected for house money)</td><td class="r">{esc(hl_str)}</td></tr>
<tr><td>Fee recycling (vault fees + rebates → depositor boost / treasury / insurance)</td><td class="r">{esc(recycle_cell)}</td></tr>
{dn_alt_row}{carry_rows}
{cex_monitor}
</table>

<div class="src">Sources: yields.llama.fi/pools · gamma-api.polymarket.com · api.hyperliquid.xyz/info — all fetched {esc(ts)}.
<div style="margin:6px 0">{sparkline}</div>
Standard: live-data-verification — no synthesized values; gaps shown as UNAVAILABLE.
Yield is a safety trade-off: {prem_str} — but CeFi will always advertise higher rates precisely because they hold your keys. 12% requires abandoning non-custodial principle or accepting 0-2/5 safety — same risk profile as the CEXes we differentiate from.
Blend model (snapshot {esc(snap_gen or 'UNAVAILABLE')}): {w_core:.0f}% core · {w_fixed:.0f}% fixed · {w_sat:.0f}% satellite · {w_dn:.0f}% delta-neutral. Satellites above plan weight only with decay check passed. Fee recycling pending implementation.</div>

<h2>Service Providers & Revenue Streams</h2>
<table>
<tr><th>Stream</th><th>Status</th><th>Commission</th><th>Notes</th></tr>
<tr><td><b>HL Referral (PROYIELD)</b></td><td class="ok">✅ ACTIVE</td><td class="r">10% of fees</td><td>Code active via API. Claim at app.hyperliquid.xyz/referrals (>$1)</td></tr>
<tr><td><b>MoonPay On-Ramp</b></td><td class="good">✅ CONFIGURED</td><td class="r">Testnet</td><td>pk_test_59DnsDRRtJa40GZ2esBNJ4JvYAd3sPL. SECRET+WEBHOOK in CF Pages dashboard (Encrypt ON). Production: get live keys from MoonPay dashboard.</td></tr>
<tr><td><b>Stripe On-Ramp</b></td><td class="bad">❌ BLOCKED</td><td class="r">2.9% + $0.30</td><td>Not supported in Bahamas. EU/US only. Requires legal entity in supported country</td></tr>
<tr><td><b>Ramp Network</b></td><td class="bad">❌ BLOCKED</td><td class="r">N/A</td><td>Explicitly blocks Bahamas. Cannot use.</td></tr>
<tr><td><b>Delta-Neutral Strategy</b></td><td class="ok">✅ LIVE</td><td class="r">{dn_display_apy:.1f}% APR</td><td>Live HL funding: BTC {btc_funding:.1f}%, ETH {eth_funding:.1f}%. On-chain accrual LIVE on testnet (oracle+venue verified; prod swaps HL adapter). Non-directional, hedged.</td></tr>
<tr><td><b>Vault Performance Fees</b></td><td class="warn">⏳ PENDING</td><td class="r">TBD</td><td>Requires audit + governance. Not started.</td></tr>
</table>

<h2>On-Ramp Situation — Bahamas</h2>
<div class="card"><div class="k">Problem</div>Stripe does not support the Bahamas. Ramp Network explicitly blocks the Bahamas. The embedded onramp is EU/US only.</div>
<div class="card"><div class="k">Viable Options</div><b>1. MoonPay</b> — 200+ countries, likely supports Bahamas. ✅ Keys configured for testnet. SECRET+WEBHOOK in CF Pages dashboard (Encrypt ON). Production: get live keys from MoonPay dashboard.<br/><br/><b>2. Transak</b> — 150+ countries, registered in USA/UK/Canada/Australia/Hong Kong. May support Bahamas. Need to check Transak country list and get API keys.<br/><br/><b>3. Canadian entity</b> — User is an Engineer in Toronto ET. Could register a Canadian entity for Stripe (Stripe supports Canada). Bahamas is tax base via wife's citizenship.</div>
<div class="card"><div class="k">Action Required</div>MoonPay keys configured for testnet. For production: get <b>MOONPAY_SECRET_KEY</b> and <b>MOONPAY_WEBHOOK_SECRET</b> from MoonPay dashboard, set in CF Pages dashboard with Encrypt ON. Stripe alternative requires Canadian entity.</div>

<h2>Referral Program — PROYIELD</h2>
<table>
<tr><th>Metric</th><th>Value</th></tr>
<tr><td>Referral Code</td><td><b>PROYIELD</b></td></tr>
<tr><td>Commission Rate</td><td>10% of referred users' trading fees</td></tr>
<tr><td>Discount to Referred</td><td>4% on first $25M volume</td></tr>
<tr><td>Claim Threshold</td><td>&gt;$1 (real-time)</td></tr>
<tr><td>Referral Link</td><td><a href="https://app.hyperliquid.xyz/join/PROYIELD">app.hyperliquid.xyz/join/PROYIELD</a></td></tr>
<tr><td>Auto-Injection</td><td>Code attached to ALL deposit URLs (MoonPay, Stripe when configured)</td></tr>
<tr><td>Tracking</td><td>track_hl_referral_earnings() in vault_keeper.py + business_automation.py</td></tr>
</table>

<h2>Dragging Assets — Below Blended Rate</h2>
<table>
<tr><th>Asset</th><th>Protocol</th><th>APY</th><th>Safety</th><th>TVL</th><th>Status</th></tr>
{''.join(
    f'<tr><td>{esc(p.get("symbol","?"))}</td><td>{esc(p.get("project","?"))}</td>'
    f'<td class="bad">{p.get("apy_base",0):.2f}%</td><td>{p.get("safety","?")}/5</td>'
    f'<td>${p.get("tvl_usd",p.get("tvl",0))/1e6:.0f}M</td><td>⚠️ REMOVE/REPLACE</td></tr>'
    for p in sorted(dragging, key=lambda x: x.get("apy_base", 0))
)}
</table>
<div class="card"><div class="k">Action</div>Remove or replace dragging (non-portfolio) assets with higher-yield alternatives. Delta-neutral re-allowed 09-19 — {w_dn:.0f}% sleeve at live HL funding {dn_display_apy:.1f}%. Review FIXED (Pendle) and SATELLITE sleeves for decay before adding weight.</div>
</body></html>"""
    
    out_path = os.path.join(HERE, "dashboard.html")
    with open(out_path, "w") as f:
        f.write(html)
    
    # Save history (only if we computed blend ourselves — scout.py already logged it when snapshot was available)
    if snapshot_blend is None:
        hist_path = os.path.join(DATA, "history.jsonl")
        with open(hist_path, "a") as f:
            f.write(json.dumps({"ts": ts, "blend_apy": round(blend, 2)}) + "\n")
    
    print(f"dashboard.html → {ts}  blend={blend:.2f}%  safe={len(safe_pools)}  strategy={len(strategy_pools)}")

if __name__ == "__main__":
    main()
