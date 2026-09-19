#!/usr/bin/env python3
"""Schema-drift canary — asserts snapshot.json schema matches every consumer.

The evaluator emitted EMPTY recommendations for ~2 days because it read
`llama_pools.pools` while the snapshot used `pools`. This canary fails loudly
at 09:00 (before the evaluator at 09:05) whenever a consumer's expectations
drift from the snapshot's actual schema. Add a block per consumer.
Exit 1 = schema drift detected -> advisor/cron output shows the failure.
"""
import json, os, sys

SNAP = "/home/user/yield_scout/data/snapshot.json"

def main():
    if not os.path.exists(SNAP):
        print("CANARY FAIL: snapshot.json missing")
        sys.exit(1)
    with open(SNAP) as f:
        snap = json.load(f)

    errors = []

    # --- scout.py blend() consumer ---
    if "pools" not in snap:
        errors.append("scout: missing top-level 'pools'")
    else:
        p = snap["pools"][0] if snap["pools"] else {}
        for k in ("tag", "project", "symbol", "apy_base", "tvl_usd"):
            if k not in p:
                errors.append(f"scout: pool missing '{k}'")

    # --- blend allocation consumer (render_dashboard, verify_blend) ---
    blend = snap.get("blend", {})
    alloc = blend.get("allocation", {})
    for tier in ("CORE", "FIXED", "SATELLITE", "DELTA_NEUTRAL"):
        if tier not in alloc:
            errors.append(f"blend.allocation missing '{tier}'")
        elif "weight" not in alloc[tier] or "apy" not in alloc[tier]:
            errors.append(f"blend.allocation.{tier} missing weight/apy")

    # --- evaluator consumer ---
    # Two producers overwrite snapshot.json: scout.py (blend.picks schema) and
    # deployment_engine.py (top-level picks + tier_apys). Canary accepts either,
    # but the fields the evaluator reads MUST exist in whichever is present.
    hf = snap.get("hyperliquid_funding", {})
    if "majors_funding_apr" not in hf:
        errors.append("evaluator: hyperliquid_funding missing 'majors_funding_apr'")

    top_picks = snap.get("picks")
    blend_picks = snap.get("blend", {}).get("picks")
    if isinstance(top_picks, dict):
        pick_src, picks = "picks", top_picks
    elif isinstance(blend_picks, dict):
        pick_src, picks = "blend.picks", blend_picks
    else:
        pick_src, picks = None, {}
        errors.append("evaluator: no picks dict at picks or blend.picks")
    if pick_src:
        for cat in ("core", "fixed", "satellite"):
            if cat not in picks:
                errors.append(f"evaluator: {pick_src} missing '{cat}'")
        if pick_src == "picks" and "delta_neutral" not in picks:
            errors.append("evaluator: picks missing 'delta_neutral'")

    if errors:
        print("SCHEMA CANARY FAIL:")
        for e in errors:
            print("  ✗", e)
        sys.exit(1)
    print(f"schema canary OK ({len(snap.get('pools', []))} pools, "
          f"blend={blend.get('blend_apy')}%, {len(picks)} pick categories)")

if __name__ == "__main__":
    main()
