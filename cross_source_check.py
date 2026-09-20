#!/usr/bin/env python3
"""Cross-source rate verification -- protocol-NATIVE APIs as an INDEPENDENT
second source beside DeFiLlama.

For each DEPLOYED pool with a known native source:
  morpho-blue  -> blue-api.morpho.org (GraphQL)  : vault netApy
  pendle-v2    -> api-v2.pendle.finance (REST)   : PT impliedApy

Match by normalized symbol/name with TVL-proximity disambiguation.
Drift tolerance: max(1.0pp, 25% relative) -- the two sources update on
different cadences, so exact equality is not expected. Unmatched pools are
reported EXPLICITLY (never approximated).

Writes data/verification_cross.json (history, last 60 runs).
Standard: live-data-verification -- every number traces to a named source.
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone

DATA = "/home/user/yield_scout/data"
SNAPSHOT_PATH = os.path.join(DATA, "snapshot.json")
OUT_PATH = os.path.join(DATA, "verification_cross.json")

UA = {"User-Agent": "ProYield-cross-source/1.0"}
CHAIN_IDS = {"Ethereum": 1, "Base": 8453, "Arbitrum": 42161, "Monad": 143}
REL_TOL, ABS_TOL = 0.25, 1.0


def _get(url, data=None, timeout=45):
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode() if data is not None else None,
        headers={**UA, "Content-Type": "application/json"},
    )
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read())


def _norm(s):
    return "".join(ch for ch in (s or "").lower() if ch.isalnum())


def morpho_native(chain, want_symbol, want_tvl):
    cid = CHAIN_IDS.get(chain)
    if cid is None:
        return None
    items = []
    for skip in (0, 500):  # full listing (~511 vaults on Base)
        q = {"query": "{ vaults(first: 500, skip: %d, where:{chainId_in:[%d]}) { items "
                     "{ symbol name asset{symbol decimals} state{ netApy totalAssets } } } }" % (skip, cid)}
        page = _get("https://blue-api.morpho.org/graphql", q)["data"]["vaults"]["items"]
        items.extend(page)
        if len(page) < 500:
            break
    want = _norm(want_symbol)
    cands = [v for v in items
             if want and (want in _norm(v.get("symbol")) or want in _norm(v.get("name")))]
    if not cands:
        return None

    def usd(v):
        dec = v["asset"].get("decimals") if isinstance(v["asset"], dict) else 6
        return float(v["state"]["totalAssets"]) / (10 ** (dec if dec is not None else 6))

    best = min(cands, key=lambda v: abs(usd(v) - (want_tvl or 0)))
    best_usd = usd(best)
    # confidence gate: >35% TVL gap means we are NOT looking at the same vault
    # (e.g. DeFiLlama tracks a legacy vault absent from Morpho's active listing)
    if want_tvl and best_usd > 0 and abs(best_usd - want_tvl) > 0.35 * want_tvl:
        return {
            "source": "morpho-blue-api",
            "low_confidence": True,
            "closest": best["name"],
            "closest_tvl": round(best_usd),
            "note": ("closest name-match carries $%s vs tracked $%s -- tracked vault is likely "
                     "legacy/not in Morpho's active API listing (DeFiLlama may still track it on-chain)"
                     % (format(best_usd, ",.0f"), format(want_tvl, ",.0f"))),
        }
    return {
        "source": "morpho-blue-api",
        "matched": best["name"],
        "apy_pct": float(best["state"]["netApy"]) * 100,
        "tvl": round(best_usd),
    }


def pendle_native(chain, want_symbol, want_tvl):
    cid = CHAIN_IDS.get(chain)
    if cid is None:
        return None
    d = _get("https://api-v2.pendle.finance/core/v1/%d/markets?limit=100" % cid, timeout=30)
    want = _norm(want_symbol)
    for m in d.get("results", []):
        pt = (m.get("pt") or {}).get("symbol") or ""
        if want and want in _norm(pt):
            return {
                "source": "pendle-api",
                "matched": pt,
                "apy_pct": float(m.get("impliedApy") or 0) * 100,
                "tvl": None,
            }
    return None


def cross_check(quiet=False):
    snap = json.load(open(SNAPSHOT_PATH))
    pools = snap.get("pools", [])
    rows = []
    for p in pools:
        proj, sym, chain = p.get("project"), p.get("symbol"), p.get("chain")
        if proj not in ("morpho-blue", "pendle-v2"):
            continue
        llama = p.get("apy_base")
        native, err = None, None
        try:
            native = (morpho_native(chain, sym, p.get("tvl_usd")) if proj == "morpho-blue"
                      else pendle_native(chain, sym, p.get("tvl_usd")))
        except Exception as e:
            err = f"{type(e).__name__}: {str(e)[:90]}"
        row = {"pool": f"{proj}/{sym}/{chain}", "llama_apy": llama, "native": native, "error": err}
        if native and "apy_pct" in native and llama is not None:
            diff = abs(native["apy_pct"] - llama)
            tol = max(ABS_TOL, abs(llama) * REL_TOL)
            row.update(diff_pp=round(diff, 3), ok=diff <= tol)
        rows.append(row)

    matched = [r for r in rows if "ok" in r]
    drifted = [r for r in rows if r.get("ok") is False]
    unmatched = [r for r in rows if "ok" not in r]
    result = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sources": ["defillama", "morpho-blue-api", "pendle-api"],
        "rows": rows,
        "summary": {"checked": len(rows), "in_sync": len(matched) - len(drifted),
                    "drifted": len(drifted), "unmatched": len(unmatched)},
    }

    hist = []
    if os.path.exists(OUT_PATH):
        try:
            hist = json.load(open(OUT_PATH)).get("history", [])
        except Exception:
            hist = []
    hist.append(result)
    json.dump({"history": hist[-60:]}, open(OUT_PATH, "w"), indent=1)

    if not quiet:
        print(f"Cross-source check @ {result['ts']}  (DeFiLlama vs protocol-native APIs)")
        for r in rows:
            if "ok" in r:
                flag = "OK " if r["ok"] else "DRIFT"
                n = r["native"]
                print(f"  [{flag}] {r['pool']:<30} llama={r['llama_apy']:>6.2f}%  "
                      f"{n['source']}={n['apy_pct']:>6.2f}%  |d|={r['diff_pp']:.2f}pp  ({n['matched']})")
            elif r["error"]:
                print(f"  [ERR ] {r['pool']:<30} {r['error']}")
            elif r["native"] and r["native"].get("low_confidence"):
                print(f"  [WARN] {r['pool']:<30} low confidence: {r['native']['note']}")
            else:
                print(f"  [----] {r['pool']:<30} no confident native match (explicit, not approximated)")
        s = result["summary"]
        print(f"  summary: {s['in_sync']} in sync, {s['drifted']} drifted, {s['unmatched']} unmatched "
              f"of {s['checked']} checked -> {os.path.basename(OUT_PATH)}")
    return result


if __name__ == "__main__":
    cross_check(quiet="--quiet" in sys.argv)