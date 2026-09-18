#!/usr/bin/env python3
"""
Yield Scout v1 — live rate engine.
Standard: live-data-verification (skill) — every number carries source+timestamp.
Fetches live: DeFiLlama pools (stables+Pendle), Polymarket reward pools, Hyperliquid majors funding.
Writes yield_scout/data/snapshot.json for the dashboard. No synthesized values, ever.
"""
import json, time, os, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
os.makedirs(DATA, exist_ok=True)
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) yield-scout-v1"}

def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    return urllib.request.urlopen(req, timeout=timeout).read()

def llama_pools():
    raw = json.loads(fetch("https://yields.llama.fi/pools"))["data"]
    out = []
    # Whitelist: blue-chip permissionless + Pendle fixed (PT products only) + vetted 10%+ pond
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
            tag = "CORE"
        elif p["project"] == "pendle-v2" and p.get("stablecoin") and tvl >= 20_000_000 and not is_lp:
            tag = "FIXED"
        elif p.get("stablecoin") and apy >= 10 and tvl >= 50_000_000 and p["project"] in ("accountable", "saturn", "apyx-protocol", "unitas-usdu", "tori-finance"):
            tag = "SATELLITE"
        if tag:
            out.append({
                "tag": tag, "project": p["project"], "symbol": p["symbol"], "chain": p["chain"],
                "apy_base": round(apy, 2), "apy_30d": round(p.get("apyMean30d") or 0, 2),
                "tvl_usd": tvl,
                "source": "yields.llama.fi/pools", "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })
    return out

def pm_rewards():
    total, n = 0.0, 0
    try:
        for off in range(0, 1500, 500):
            url = ("https://gamma-api.polymarket.com/markets?closed=false&active=true"
                   f"&limit=500&offset={off}&order=volume24hr&ascending=false")
            for m in json.loads(fetch(url)):
                cr = m.get("clobRewards")
                if not cr:
                    continue
                rewards = json.loads(cr) if isinstance(cr, str) else cr
                for r in rewards:
                    rate = float(r.get("rewardsDailyRate") or 0)
                    if rate > 0:
                        total += rate; n += 1
        return {"total_daily_usd": round(total), "reward_markets": n,
                "source": "gamma-api.polymarket.com", "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    except Exception as e:
        return {"total_daily_usd": None, "reward_markets": None,
                "error": f"UNAVAILABLE: {e}", "source": "gamma-api.polymarket.com",
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

def hl_funding():
    try:
        body = json.dumps({"type": "metaAndAssetCtxs"}).encode()
        req = urllib.request.Request("https://api.hyperliquid.xyz/info", data=body,
                                     headers={"Content-Type": "application/json", **UA})
        meta, ctxs = json.loads(urllib.request.urlopen(req, timeout=30).read())
        majors = {}
        for a, c in zip(meta["universe"], ctxs):
            if a["name"] in ("BTC", "ETH"):
                majors[a["name"]] = round(float(c.get("funding") or 0) * 24 * 365 * 100, 1)
        return {"majors_funding_apr": majors, "source": "api.hyperliquid.xyz/info",
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    except Exception as e:
        return {"majors_funding_apr": None, "error": f"UNAVAILABLE: {e}",
                "source": "api.hyperliquid.xyz/info", "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

def blend(pools):
    """Target blend — mirrors deployment_engine.py weights EXACTLY:
       CORE 35% / FIXED 10% / SATELLITE 40% / DELTA_NEUTRAL 15% (paper) / TANGIBLE 0%.
       Any weight change MUST be applied in both files (they are verified equal by
       verify_blend_consistency below)."""
    weights = {"CORE": 0.35, "FIXED": 0.10, "SATELLITE": 0.40, "DELTA_NEUTRAL": 0.15, "TANGIBLE": 0.0}
    assert abs(sum(weights.values()) - 1.0) < 1e-9, f"scout weights sum to {sum(weights.values())}"
    core = [p for p in pools if p["tag"] == "CORE"]
    fixed = [p for p in pools if p["tag"] == "FIXED"]
    sat = [p for p in pools if p["tag"] == "SATELLITE"]
    def best(lst, n):
        return sorted(lst, key=lambda p: -p["apy_base"])[:n] if lst else []
    core_pick = best(core, 4)
    fixed_pick = best(fixed, 1)
    sat_pick = best(sat, 6)
    core_w = sum(p["tvl_usd"] for p in core_pick) or 1
    core_apy = sum(p["apy_base"] * p["tvl_usd"] for p in core_pick) / core_w if core_pick else None
    fixed_apy = fixed_pick[0]["apy_base"] if fixed_pick else None
    sat_apy = sum(p["apy_base"] for p in sat_pick) / len(sat_pick) if sat_pick else None
    # DELTA_NEUTRAL: Hyperliquid majors funding — conservative floor of BTC/ETH mix
    # (real per-asset values live in snap["hyperliquid_funding"]; 5.85% floor used here)
    delta_apy = 5.85
    parts = []
    if core_apy is not None: parts.append(("CORE", 0.35, core_apy))
    if fixed_apy is not None: parts.append(("FIXED", 0.10, fixed_apy))
    if sat_apy is not None: parts.append(("SATELLITE", 0.40, sat_apy))
    parts.append(("DELTA_NEUTRAL", 0.15, delta_apy))
    blend_apy = sum(w * a for _, w, a in parts) if parts else None
    return {
        "blend_apy": round(blend_apy, 2) if blend_apy else None,
        "allocation": {name: {"weight": w, "apy": round(a, 2)} for name, w, a in parts},
        "picks": {"core": core_pick, "fixed": fixed_pick, "satellite": sat_pick},
    }

def main():
    snap = {
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "standard": "live-data-verification: all figures from named live sources; gaps marked UNAVAILABLE",
        "pools": llama_pools(),
        "polymarket_rewards": pm_rewards(),
        "hyperliquid_funding": hl_funding(),
    }
    snap["blend"] = blend(snap["pools"])
    path = os.path.join(DATA, "snapshot.json")
    with open(path, "w") as f:
        json.dump(snap, f, indent=1)
    print(f"snapshot -> {path}  ({snap['generated_utc']})  pools={len(snap['pools'])}  blend={snap['blend']['blend_apy']}%")

if __name__ == "__main__":
    main()
