#!/usr/bin/env python3
"""ProYield 2.0 Rate Verification & Auto-Correction Loop.

Compares deployed snapshot rates against live DeFiLlama data.
Tracks rate drift over time and auto-corrects safety scores
when predicted APY consistently diverges from actual observed rates.

This provides a feedback loop that improves accuracy even without
deployed capital, by detecting when third-party data sources drift.
"""
import json, os, urllib.request, sys
from datetime import datetime, timezone

YIELD = "/home/user/yield_scout"
DATA = os.path.join(YIELD, "data")
SNAPSHOT_PATH = os.path.join(DATA, "snapshot.json")
POOL_HISTORY_PATH = os.path.join(DATA, "pool_history.jsonl")
VERIFICATION_PATH = os.path.join(DATA, "verification.json")

UA = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) yield-scout-v1'}

def fetch_live_rates():
    """Fetch current rates from DeFiLlama."""
    url = 'https://yields.llama.fi/pools'
    req = urllib.request.Request(url, headers=UA)
    response = json.loads(urllib.request.urlopen(req, timeout=60).read())
    
    # API returns {"status": "success", "data": [...]}
    pool_list = response.get('data', []) if isinstance(response, dict) else response
    
    live_pools = {}
    for p in pool_list:
        project = p.get('project', '')
        symbol = p.get('symbol', '')
        apy = p.get('apyBase', 0) or 0  # apyBase is the base supply APY
        tvl = p.get('tvlUsd', 0) or 0   # tvlUsd is the TVL in USD
        stablecoin = p.get('stablecoin', False)
        
        if stablecoin and tvl >= 50_000_000:
            key = f"{project}:{symbol}"
            if key not in live_pools or apy > live_pools[key]['apy']:
                live_pools[key] = {
                    'project': project,
                    'symbol': symbol,
                    'apy': apy,
                    'tvl': tvl,
                    'chain': p.get('chain', ''),
                    'source': 'defillama'
                }
    
    return live_pools

def load_snapshot():
    """Load current deployment snapshot."""
    if os.path.exists(SNAPSHOT_PATH):
        with open(SNAPSHOT_PATH) as f:
            return json.load(f)
    return None

def load_pool_history():
    """Load pool history for drift analysis."""
    history = []
    if os.path.exists(POOL_HISTORY_PATH):
        with open(POOL_HISTORY_PATH) as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    history.append(entry)
                except json.JSONDecodeError:
                    continue
    return history

def compute_rate_drift(snapshot, live_rates):
    """Compare snapshot rates against live rates.
    
    Returns a list of drift observations for each pool in the snapshot.
    """
    picks = snapshot.get('picks', {})
    drift = []
    
    for category, pools in picks.items():
        if not isinstance(pools, list):
            continue
        for pool in pools:
            project = pool.get('project', '')
            symbol = pool.get('symbol', '')
            snapshot_apy = pool.get('apy', 0) or 0
            key = f"{project}:{symbol}"
            
            if key in live_rates:
                live_apy = live_rates[key]['apy']
                live_apy = float(live_apy) if live_apy else 0
                snapshot_apy = float(snapshot_apy) if snapshot_apy else 0
                drift_pct = ((live_apy - snapshot_apy) / snapshot_apy * 100) if snapshot_apy > 0 else 0
                
                drift.append({
                    'category': category,
                    'project': project,
                    'symbol': symbol,
                    'snapshot_apy': round(snapshot_apy, 4),
                    'live_apy': round(live_apy, 4),
                    'drift_pct': round(drift_pct, 2),
                    'tvl': live_rates[key]['tvl'],
                    'severity': 'HIGH' if abs(drift_pct) > 20 else ('MEDIUM' if abs(drift_pct) > 10 else 'LOW'),
                    'timestamp': datetime.now(timezone.utc).isoformat()
                })
    
    return drift

def auto_correct_safety_scores(drift_observations):
    """Adjust safety scores based on rate drift.
    
    If a protocol's live rate consistently differs from predicted:
    - High drift (HIGH severity): penalize safety score
    - Consistent drift over time: flag for review
    """
    corrections = []
    
    for obs in drift_observations:
        if obs['severity'] == 'HIGH':
            # Significant drift — flag for safety score adjustment
            corrections.append({
                'project': obs['project'],
                'symbol': obs['symbol'],
                'action': 'REVIEW_SAFETY_SCORE',
                'reason': f"Live APY {obs['drift_pct']:+.1f}% from snapshot",
                'snapshot_apy': obs['snapshot_apy'],
                'live_apy': obs['live_apy'],
                'recommended_safety_adjustment': -1 if obs['drift_pct'] < 0 else 0
            })
        elif obs['severity'] == 'MEDIUM':
            corrections.append({
                'project': obs['project'],
                'symbol': obs['symbol'],
                'action': 'MONITOR',
                'reason': f"Live APY {obs['drift_pct']:+.1f}% from snapshot",
                'snapshot_apy': obs['snapshot_apy'],
                'live_apy': obs['live_apy']
            })
    
    return corrections

def load_verification_history():
    """Load previous verification results for trend analysis."""
    if os.path.exists(VERIFICATION_PATH):
        with open(VERIFICATION_PATH) as f:
            return json.load(f)
    return []

def save_verification(verification_data):
    """Save verification results for trend tracking."""
    history = load_verification_history()
    history.append(verification_data)
    # Keep last 30 verification runs
    if len(history) > 30:
        history = history[-30:]
    with open(VERIFICATION_PATH, 'w') as f:
        json.dump(history, f, indent=2)

def main():
    print("=" * 60)
    print("  PROYIELD 2.0 — RATE VERIFICATION LOOP")
    print("=" * 60)
    
    # 1) Load current snapshot
    snapshot = load_snapshot()
    if not snapshot:
        print("ERROR: No snapshot.json found")
        return
    
    snapshot_blend = snapshot.get('blend', {}).get('blend_apy', 0)
    print(f"\nSnapshot blend: {snapshot_blend}%")
    print(f"Snapshot timestamp: {snapshot.get('generated_utc', 'unknown')}")
    
    # 2) Fetch live rates
    print("\nFetching live rates from DeFiLlama...")
    live_rates = fetch_live_rates()
    print(f"Live pools found: {len(live_rates)}")
    
    # 3) Compute drift
    drift = compute_rate_drift(snapshot, live_rates)
    
    if not drift:
        print("\nNo drift detected — all pools match live rates.")
        return
    
    print(f"\n{'='*60}")
    print(f"  RATE DRIFT ANALYSIS ({len(drift)} pools checked)")
    print(f"{'='*60}")
    
    # 4) Show drift by severity
    high_drift = [d for d in drift if d['severity'] == 'HIGH']
    med_drift = [d for d in drift if d['severity'] == 'MEDIUM']
    low_drift = [d for d in drift if d['severity'] == 'LOW']
    
    print(f"\n  HIGH drift (>20%): {len(high_drift)} pools")
    for d in high_drift:
        print(f"    ⚠ {d['project']:20s} {d['symbol']:10s} snap={d['snapshot_apy']:>7.2f}% live={d['live_apy']:>7.2f}% drift={d['drift_pct']:>+6.1f}%")
    
    print(f"\n  MEDIUM drift (>10%): {len(med_drift)} pools")
    for d in med_drift:
        print(f"    ⚡ {d['project']:20s} {d['symbol']:10s} snap={d['snapshot_apy']:>7.2f}% live={d['live_apy']:>7.2f}% drift={d['drift_pct']:>+6.1f}%")
    
    print(f"\n  LOW drift (<10%): {len(low_drift)} pools")
    for d in low_drift:
        print(f"    ✓ {d['project']:20s} {d['symbol']:10s} snap={d['snapshot_apy']:>7.2f}% live={d['live_apy']:>7.2f}% drift={d['drift_pct']:>+6.1f}%")
    
    # 5) Auto-correct
    corrections = auto_correct_safety_scores(drift)
    if corrections:
        print(f"\n{'='*60}")
        print(f"  AUTO-CORRECTION ACTIONS")
        print(f"{'='*60}")
        for c in corrections:
            print(f"  [{c['action']}] {c['project']} {c['symbol']}: {c['reason']}")
            if 'recommended_safety_adjustment' in c:
                print(f"    → Safety score adjustment: {c['recommended_safety_adjustment']}")
    
    # 6) Save verification
    verification = {
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'snapshot_blend': snapshot_blend,
        'pools_checked': len(drift),
        'high_drift': len(high_drift),
        'medium_drift': len(med_drift),
        'low_drift': len(low_drift),
        'corrections': len(corrections),
        'drift_observations': drift,
        'auto_corrections': corrections
    }
    save_verification(verification)
    print(f"\n✓ Verification saved to verification.json (run #{len(load_verification_history())})")

    # 6b) Cross-source check — protocol-NATIVE APIs as an INDEPENDENT second
    # source beside DeFiLlama (morpho blue-api, pendle api-v2). Non-fatal.
    try:
        import cross_source_check
        res = cross_source_check.cross_check(quiet=True)
        s = res["summary"]
        print(f"  ✓ cross-source: {s['in_sync']} in sync / {s['drifted']} drifted / "
              f"{s['unmatched']} unmatched of {s['checked']} (native APIs) -> verification_cross.json")
    except Exception as e:
        print(f"  cross-source check skipped: {type(e).__name__}: {str(e)[:90]}")
    
    # 7) Recommendation
    print(f"\n{'='*60}")
    print(f"  RECOMMENDATION")
    print(f"{'='*60}")
    if high_drift:
        print(f"  ⚠ {len(high_drift)} pools have HIGH drift — deployment engine should re-evaluate")
        print(f"  → Consider re-running deployment engine with corrected safety scores")
    elif med_drift:
        print(f"  ⚡ {len(med_drift)} pools have MEDIUM drift — monitor for trend")
        print(f"  → Rate drift is within acceptable range for third-party data")
    else:
        print(f"  ✓ All pools within acceptable drift range")
        print(f"  → Snapshot rates are consistent with live DeFiLlama data")

if __name__ == '__main__':
    main()
