#!/usr/bin/env python3
"""Blend-math consistency verifier — the seam guard.

Verifies that every blend number the system publishes is internally consistent:
  1. allocation weights sum to exactly 1.00
  2. blend_apy == sum(weight * apy) over the published allocation table
  3. scout.py weights == deployment_engine.py weights (no drift between engines)

Exit 0 = consistent; exit 1 = SEAM (printed). Run daily; wire into daily_all.py.
Standard: live-data-verification — checks published numbers only, no fetching.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

SEAMS = []

def fail(msg):
    SEAMS.append(msg)
    print(f"  [SEAM] {msg}")

def check_snapshot(path, label):
    if not os.path.exists(path):
        fail(f"{label}: file missing: {path}")
        return None
    with open(path) as f:
        snap = json.load(f)
    blend = snap.get("blend", {})
    blend_apy = blend.get("blend_apy")
    alloc = blend.get("allocation", {})
    if not blend_apy or not alloc:
        fail(f"{label}: missing blend_apy or allocation table")
        return snap

    # 1) weights sum to 1.00
    wsum = sum(v.get("weight", 0) for v in alloc.values())
    if abs(wsum - 1.0) > 1e-9:
        fail(f"{label}: weights sum to {wsum:.4f} (expected 1.0000)")

    # 2) blend_apy == weighted sum of the published table
    computed = sum(v.get("weight", 0) * v.get("apy", 0) for v in alloc.values())
    if abs(computed - blend_apy) > 0.005:
        fail(f"{label}: blend_apy={blend_apy} but allocation table sums to {computed:.2f} "
             f"(drift {computed - blend_apy:+.2f}pp)")
    else:
        print(f"  [OK] {label}: blend_apy {blend_apy}% == table weighted sum {computed:.2f}%")
    return snap

def check_engine_weight_parity():
    """scout.py and deployment_engine.py must use identical weights."""
    weights = {}
    for fname, engine in (("scout.py", "scout"), ("deployment_engine.py", "engine")):
        path = os.path.join(HERE, fname)
        if not os.path.exists(path):
            fail(f"{fname}: missing")
            continue
        src = open(path).read()
        m = re.search(
            r'(?:weights|WEIGHTS)\s*=\s*\{([^}]+)\}', src)
        if not m:
            fail(f"{fname}: weights dict not found by regex")
            continue
        pairs = re.findall(r"['\"]?([A-Za-z_]+)['\"]?\s*:\s*([0-9.]+)", m.group(1))
        w = {k: float(v) for k, v in pairs}
        # normalize engine keys (delta_neutral -> DELTA_NEUTRAL etc.)
        w = {k.upper(): v for k, v in w.items()}
        weights[engine] = w
    if len(weights) == 2:
        s, e = weights["scout"], weights["engine"]
        keys = set(s) | set(e)
        for k in keys:
            if abs(s.get(k, 0) - e.get(k, 0)) > 1e-9:
                fail(f"weight drift scout vs engine on {k}: {s.get(k, 0)} vs {e.get(k, 0)}")
        if not SEAMS:
            print(f"  [OK] scout.py and deployment_engine.py weights match: {s}")

def main():
    print("blend consistency check")
    check_snapshot(os.path.join(DATA, "snapshot.json"), "snapshot.json")
    check_snapshot(os.path.join(DATA, "snapshot_deployed.json"), "snapshot_deployed.json")
    check_engine_weight_parity()
    if SEAMS:
        print(f"\n{len(SEAMS)} SEAM(S) FOUND — fix before publishing")
        sys.exit(1)
    print("all consistent")

if __name__ == "__main__":
    main()
