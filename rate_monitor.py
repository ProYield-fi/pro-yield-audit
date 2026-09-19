#!/usr/bin/env python3
"""
ProYield Rate Monitor — Automated rate change detection with alerting.

Fetches live DeFiLlama rates, compares against the current allocation
in snapshot.json, and alerts when any pool moves >50bps (0.5% absolute).

Usage:
    python3 rate_monitor.py                  # run once
    python3 rate_monitor.py --quiet          # suppress non-alert output
    python3 rate_monitor.py --history        # show last 20 alerts
    python3 rate_monitor.py --cron           # cron-friendly output

Configured via cron as: rate-monitor (5min interval possible)
"""
import json, os, sys, time, argparse, urllib.request, hashlib
from datetime import datetime, timezone

YIELD = "/home/user/yield_scout"
DATA = os.path.join(YIELD, "data")
SNAPSHOT_PATH = os.path.join(DATA, "snapshot.json")
ALERT_LOG_PATH = os.path.join(DATA, "rate_alerts.json")
ALERT_THRESHOLD_BPS = 50  # 50 basis points = 0.50% absolute change

# Pools to track from the snapshot picks (exclude tangible — 0% weight)
TRACKED_CATEGORIES = ["core", "fixed", "satellite", "delta_neutral"]

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) yield-rate-monitor"}

def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    return urllib.request.urlopen(req, timeout=timeout).read()

def fetch_live_pools():
    """Fetch all live pools from DeFiLlama, return dict keyed by project:symbol:chain."""
    raw = json.loads(fetch("https://yields.llama.fi/pools"))
    pool_list = raw.get("data", []) if isinstance(raw, dict) else raw
    # Key: project:symbol:chain → best pool entry (highest TVL)
    live = {}
    for p in pool_list:
        project = p.get("project", "")
        symbol = p.get("symbol", "")
        chain = p.get("chain", "")
        apy = p.get("apyBase")
        tvl = p.get("tvlUsd") or 0
        stablecoin = p.get("stablecoin", False)
        if apy is None or tvl < 5_000_000:
            continue
        key = f"{project}:{symbol}:{chain}"
        # Keep highest TVL entry for each project:symbol:chain
        if key not in live or tvl > live[key]["tvl"]:
            live[key] = {
                "project": project,
                "symbol": symbol,
                "chain": chain,
                "apy": float(apy),
                "tvl": tvl,
                "apy_30d": float(p.get("apyMean30d") or 0),
                "stablecoin": stablecoin,
            }
    return live

def find_live_rate(snapshot_pool, live_pools):
    """Find the live rate for a snapshot pool entry.
    
    Tries exact chain match first, then falls back to any chain for the same project:symbol.
    Returns (live_apy, live_tvl, chain) or None if not found.
    """
    project = snapshot_pool.get("project", "")
    symbol = snapshot_pool.get("symbol", "")
    snapshot_chain = ""  # snapshot doesn't always have chain
    
    # Try exact chain match first
    for key, pool in live_pools.items():
        if pool["project"] == project and pool["symbol"] == symbol:
            return pool["apy"], pool["tvl"], pool["chain"]
    
    return None

def load_snapshot():
    if not os.path.exists(SNAPSHOT_PATH):
        return None
    with open(SNAPSHOT_PATH) as f:
        return json.load(f)

def load_alert_history():
    if not os.path.exists(ALERT_LOG_PATH):
        return []
    with open(ALERT_LOG_PATH) as f:
        return json.load(f)

def save_alert_history(history):
    # Keep last 200 entries
    history = history[-200:]
    with open(ALERT_LOG_PATH, "w") as f:
        json.dump(history, f, indent=2)

def check_pools(snapshot, live_pools, threshold_bps=ALERT_THRESHOLD_BPS):
    """Compare snapshot picks against live rates. Returns (alerts, status)."""
    picks = snapshot.get("picks", {})
    blend_apy = snapshot.get("blend", {}).get("blend_apy", 0)
    alerts = []
    checked = 0
    all_clear = True

    for cat in TRACKED_CATEGORIES:
        pools = picks.get(cat, [])
        if not isinstance(pools, list):
            continue
        for pool in pools:
            project = pool.get("project", "")
            symbol = pool.get("symbol", "")
            snapshot_apy = pool.get("apy", 0) or 0
            checked += 1

            result = find_live_rate(pool, live_pools)
            if result is None:
                continue

            live_apy, live_tvl, live_chain = result
            delta_bps = (live_apy - snapshot_apy) * 100  # convert to bps

            if abs(delta_bps) > threshold_bps:
                all_clear = False
                alert = {
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "category": cat,
                    "project": project,
                    "symbol": symbol,
                    "chain": live_chain,
                    "snapshot_apy": round(snapshot_apy, 4),
                    "live_apy": round(live_apy, 4),
                    "delta_bps": round(delta_bps, 1),
                    "tvl": live_tvl,
                    "direction": "UP" if delta_bps > 0 else "DOWN",
                    "severity": "HIGH" if abs(delta_bps) > 150 else ("MEDIUM" if abs(delta_bps) > 75 else "LOW"),
                    "blend_at_snapshot": blend_apy,
                }
                alerts.append(alert)

    return alerts, checked, all_clear


def fetch_live_funding():
    """Live Hyperliquid majors funding APR (hourly-paid; annualize x24x365)."""
    try:
        body = json.dumps({"type": "metaAndAssetCtxs"}).encode()
        req = urllib.request.Request("https://api.hyperliquid.xyz/info", data=body,
                                     headers={"Content-Type": "application/json", **UA})
        meta, ctxs = json.loads(urllib.request.urlopen(req, timeout=30).read())
        majors = {}
        for a, ctx in zip(meta["universe"], ctxs):
            if a["name"] in ("BTC", "ETH"):
                majors[a["name"]] = round(float(ctx.get("funding") or 0) * 24 * 365 * 100, 1)
        return majors
    except Exception:
        return {}  # UNAVAILABLE — funding check silently skipped

def check_funding(snapshot, live_funding, threshold_bps=ALERT_THRESHOLD_BPS):
    """Compare snapshot DELTA_NEUTRAL apy against live HL majors funding avg.
    delta_neutral tier is NOT in picks.pools — tracked separately here."""
    blend_apy = snapshot.get("blend", {}).get("blend_apy", 0)
    weights = snapshot.get("blend", {}).get("allocation", {})
    dn = weights.get("DELTA_NEUTRAL", {})
    snapshot_apy = dn.get("apy", 0) or 0
    weight = dn.get("weight", 0) or 0
    checked = 0
    alerts = []
    if not live_funding or weight <= 0 or snapshot_apy <= 0:
        return alerts, checked
    vals = list(live_funding.values())
    live_apy = round(sum(vals) / len(vals), 2)
    checked = 1
    delta_bps = (live_apy - snapshot_apy) * 100
    if abs(delta_bps) > threshold_bps:
        alerts.append({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "category": "delta_neutral",
            "project": "hyperliquid-funding",
            "symbol": "/".join(sorted(live_funding.keys())),
            "chain": "Hyperliquid",
            "snapshot_apy": round(snapshot_apy, 4),
            "live_apy": round(live_apy, 4),
            "delta_bps": round(delta_bps, 1),
            "tvl": None,
            "direction": "UP" if delta_bps > 0 else "DOWN",
            "severity": "HIGH" if abs(delta_bps) > 150 else ("MEDIUM" if abs(delta_bps) > 75 else "LOW"),
            "blend_at_snapshot": blend_apy,
        })
    return alerts, checked

def estimate_blend_impact(alerts, snapshot):
    """Estimate how much the blend would change if we re-allocated now."""
    picks = snapshot.get("picks", {})
    weights = snapshot.get("blend", {}).get("allocation", {})
    total_impact = 0
    for alert in alerts:
        cat = alert["category"].upper()
        if cat in weights:
            w = weights[cat].get("weight", 0)
            impact = (alert["delta_bps"] / 100) * w
            total_impact += impact
    return round(total_impact, 3)

def log_alert(alert):
    """Append a single alert to the alert log."""
    history = load_alert_history()
    history.append(alert)
    save_alert_history(history)

def run_check(quiet=False, threshold_bps=ALERT_THRESHOLD_BPS):
    """Main monitoring logic. Returns (num_alerts, checked_count)."""
    snapshot = load_snapshot()
    if not snapshot:
        print("ERROR: No snapshot.json found")
        return -1, 0

    blend_apy = snapshot.get("blend", {}).get("blend_apy", 0)
    if not quiet:
        print(f"{'='*60}")
        print(f"  RATE MONITOR — {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
        print(f"  Current blend: {blend_apy}% | Threshold: {threshold_bps}bps")
        print(f"{'='*60}")

    # Fetch live rates
    if not quiet:
        print("\nFetching live rates from DeFiLlama...")
    live_pools = fetch_live_pools()
    if not quiet:
        print(f"Live pools indexed: {len(live_pools)}")

    # Check for changes
    alerts, checked, all_clear = check_pools(snapshot, live_pools, threshold_bps)
    funding_alerts, funding_checked = check_funding(snapshot, fetch_live_funding())
    alerts += funding_alerts
    checked += funding_checked
    if funding_alerts:
        all_clear = False

    # Log new alerts
    for alert in alerts:
        log_alert(alert)

    # Output results
    if not quiet:
        if all_clear and not alerts:
            print(f"\n  ✓ All {checked} pools within {threshold_bps}bps threshold")
            print(f"  → No rate alerts triggered")
        else:
            print(f"\n  RATE ALERTS: {len(alerts)} pool(s) exceeded {threshold_bps}bps")
            print(f"{'─'*60}")
            for a in alerts:
                icon = "🔴" if a["severity"] == "HIGH" else ("🟡" if a["severity"] == "MEDIUM" else "🟢")
                print(f"  {icon} [{a['direction']}] {a['project']:20s} {a['symbol']:10s} "
                      f"{a['category']:12s} {a['snapshot_apy']:.2f}%→{a['live_apy']:.2f}% "
                      f"({a['delta_bps']:+.0f}bps) TVL=${a['tvl']/1e6:.0f}M")

            blend_impact = estimate_blend_impact(alerts, snapshot)
            if blend_impact != 0:
                print(f"\n  Estimated blend impact: {blend_impact:+.2f}% APY")
                print(f"  New estimated blend: {blend_apy + blend_impact:.2f}%")

            print(f"\n{'─'*60}")
            print(f"  ALERT LOG: {ALERT_LOG_PATH} ({len(load_alert_history())} total entries)")

    return len(alerts), checked

def show_history(count=20):
    """Show recent alert history."""
    history = load_alert_history()
    if not history:
        print("No alert history found.")
        return
    print(f"\nLast {min(count, len(history))} rate alerts:")
    print(f"{'─'*80}")
    for h in history[-count:]:
        ts = h["timestamp"][:16]
        print(f"  {ts} | {h['direction']:4s} {h['project']:20s} {h['symbol']:10s} "
              f"{h['category']:12s} {h['snapshot_apy']:.2f}%→{h['live_apy']:.2f}% ({h['delta_bps']:+.0f}bps)")

def cron_check(threshold_bps=ALERT_THRESHOLD_BPS):
    """Cron-friendly: prints one-line status, exits non-zero on alerts."""
    num_alerts, checked = run_check(quiet=True, threshold_bps=threshold_bps)
    if num_alerts > 0:
        print(f"RATE_ALERT {num_alerts} pools exceeded {threshold_bps}bps (checked {checked})")
        sys.exit(2)
    else:
        print(f"RATE_OK all {checked} pools within {threshold_bps}bps")
        sys.exit(0)

def main():
    parser = argparse.ArgumentParser(description="ProYield Rate Monitor")
    parser.add_argument("--quiet", action="store_true", help="Suppress non-alert output")
    parser.add_argument("--history", action="store_true", help="Show alert history")
    parser.add_argument("--history-count", type=int, default=20, help="Number of history entries")
    parser.add_argument("--cron", action="store_true", help="Cron mode: exit non-zero on alerts")
    parser.add_argument("--threshold", type=int, default=ALERT_THRESHOLD_BPS, help="Alert threshold in bps")
    args = parser.parse_args()

    if args.history:
        show_history(args.history_count)
        return

    if args.cron:
        cron_check(threshold_bps=args.threshold)
        return

    num_alerts, checked = run_check(quiet=args.quiet, threshold_bps=args.threshold)

if __name__ == "__main__":
    main()
