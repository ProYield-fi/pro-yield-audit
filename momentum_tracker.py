#!/usr/bin/env python3
"""APY momentum tracker — flags stablecoin pools with rising/falling yields.

Reads pool_history.jsonl and compares current APY to 30d mean from DeFiLlama.
Also compares to previous day's data if available.

Outputs: rising (enter), falling (exit), stable (hold) recommendations per pool.
"""
import json, os, sys
from collections import defaultdict
from datetime import datetime, timezone

# Config
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
POOL_HISTORY = os.path.join(BASE_DIR, "data", "pool_history.jsonl")
SNAPSHOT = os.path.join(BASE_DIR, "data", "snapshot.json")
OUTPUT = os.path.join(BASE_DIR, "data", "momentum.json")

# Thresholds
GAP_RISING = -0.5     # current > 30d mean + 0.5pp → rising
GAP_FALLING = 2.0     # current < 30d mean - 2.0pp → declining
GAP_EXTENDED = 3.0    # current > 30d mean + 3.0pp → past peak
MIN_APY_FOR_REVIEW = 2.0  # only flag pools with APY >= 2% for entry review


def load_history():
    """Load pool history, return list of entries sorted by ts."""
    if not os.path.exists(POOL_HISTORY):
        return []
    entries = []
    with open(POOL_HISTORY) as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    entries.sort(key=lambda e: e.get("ts", ""))
    return entries


def compute_momentum(entries):
    """Compute momentum for each pool based on history."""
    # Group by pool key (symbol + project + chain)
    pools = defaultdict(list)
    for e in entries:
        key = f"{e.get('symbol','')}|{e.get('project','')}|{e.get('chain','')}"
        pools[key].append(e)

    results = []
    for key, hist in pools.items():
        current = hist[-1]
        apy = current.get("apy", 0)
        apy_30d = current.get("apy_mean_30d", 0)  # populated by fetch
        tvl = current.get("tvl", 0) or 0
        symbol = current.get("symbol", "")
        project = current.get("project", "")
        chain = current.get("chain", "")
        gap = apy - apy_30d if apy_30d else 0

        # Day-over-day change (if we have history)
        dod_change = 0
        if len(hist) >= 2:
            prev = hist[-2]
            dod_change = apy - prev.get("apy", apy)

        # Momentum classification
        if gap > GAP_EXTENDED:
            momentum = "PAST_PEAK"
            action = "EXIT"
        elif gap > GAP_FALLING:
            momentum = "DECLINING"
            action = "MONITOR"
        elif gap > GAP_RISING:
            momentum = "STABLE"
            action = "HOLD"
        elif apy >= MIN_APY_FOR_REVIEW:
            momentum = "RISING"
            action = "REVIEW"
        else:
            momentum = "STABLE"
            action = "HOLD"

        results.append({
            "symbol": symbol,
            "project": project,
            "chain": chain,
            "apy": apy,
            "apy_30d": apy_30d,
            "gap": round(gap, 2),
            "dod_change": round(dod_change, 2),
            "tvl": tvl,
            "momentum": momentum,
            "action": action,
            "poolMeta": current.get("poolMeta", ""),
        })

    return results


def main():
    entries = load_history()
    if not entries:
        print("No pool history found", file=sys.stderr)
        sys.exit(1)

    results = compute_momentum(entries)

    # Sort by gap descending (most inflated first)
    results.sort(key=lambda x: -x["gap"])

    # Write output
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    output_data = {
        "ts": ts,
        "total_pools": len(results),
        "by_momentum": {
            "past_peak": [r for r in results if r["momentum"] == "PAST_PEAK"],
            "declining": [r for r in results if r["momentum"] == "DECLINING"],
            "stable": [r for r in results if r["momentum"] == "STABLE"],
            "rising": [r for r in results if r["momentum"] == "RISING"],
        },
        "all": results,
    }

    with open(OUTPUT, "w") as f:
        json.dump(output_data, f, indent=2)

    # Summary
    past_peak = output_data["by_momentum"]["past_peak"]
    declining = output_data["by_momentum"]["declining"]
    stable = output_data["by_momentum"]["stable"]
    rising = output_data["by_momentum"]["rising"]

    print(f"=== APY MOMENTUM TRACKER — {ts} ===")
    print(f"Pools analyzed: {len(results)}")
    print(f"  PAST PEAK (exit): {len(past_peak)}")
    print(f"  DECLINING (monitor): {len(declining)}")
    print(f"  STABLE (hold): {len(stable)}")
    print(f"  RISING (review): {len(rising)}")
    print()

    if past_peak:
        print("🔴 PAST PEAK — consider exiting:")
        for p in past_peak[:5]:
            print(f"  {p['symbol']:12s} {p['project']:20s} {p['chain']:12s} APY={p['apy']:.2f}% 30d={p['apy_30d']:.2f}% gap={p['gap']:+.2f}pp")
        print()

    if rising:
        print("🟢 RISING — consider entering:")
        for p in rising[:5]:
            print(f"  {p['symbol']:12s} {p['project']:20s} {p['chain']:12s} APY={p['apy']:.2f}% 30d={p['apy_30d']:.2f}% gap={p['gap']:+.2f}pp")
        print()

    if declining:
        print("🟡 DECLINING — monitor closely:")
        for p in declining[:5]:
            print(f"  {p['symbol']:12s} {p['project']:20s} {p['chain']:12s} APY={p['apy']:.2f}% 30d={p['apy_30d']:.2f}% gap={p['gap']:+.2f}pp")
        print()

    print(f"Output: {OUTPUT}")


if __name__ == "__main__":
    main()
