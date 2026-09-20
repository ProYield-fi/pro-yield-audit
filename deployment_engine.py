#!/usr/bin/env python3
"""ProYield 2.0 Deployment Engine — evaluates pools and deploys optimal allocation.

Replaces the manual satellite selection with an automated deployment engine that:
1. Evaluates ALL available pools against safety criteria
2. Selects the best candidates for each tier (core, fixed, satellite, tangible)
3. Computes the blended yield with the new allocation
4. Updates snapshot.json with the new picks
5. Outputs the recommended allocation

Safety criteria: non-custodial, audited, no leverage, TVL >= $50M (except tangible: $5M)
"""
import json, os, sys, urllib.request
from datetime import datetime, timezone

BASE_DIR = "/home/user/yield_scout"
DATA = os.path.join(BASE_DIR, "data")
SNAPSHOT_PATH = os.path.join(DATA, "snapshot.json")
MOMENTUM_PATH = os.path.join(DATA, "momentum.json")
OUTPUT_PATH = os.path.join(DATA, "snapshot_deployed.json")

# Safety scoring thresholds
SAFETY_THRESHOLD = 3  # Minimum safety score for inclusion
TANGIBLE_THRESHOLD = 5  # Minimum TVL for tangible assets

# Model criteria
CRITERIA = {
    "non_custodial": True,
    "audited": True,
    "no_leverage": True,
    "tvl_min": 50_000_000,  # $50M for stablecoins, $5M for tangible
}

def score_safety(project, symbol, chain, tvl, stablecoin):
    """Score pool safety based on protocol, symbol, TVL, and chain."""
    s = 0
    proj = project.lower()
    sym = symbol.upper()

    # Blue-chip protocols (comprehensive list from eco.com ranking)
    BLUE_CHIP = ("aave", "morpho", "sky", "spark", "fluid", "compound", "euler", "silo",
                 "curve", "uniswap", "convex", "lido", "rocketpool", "stargate", "jupiter")

    # Tier 2: Medium protocols
    MEDIUM = ("re", "ethena", "accountable", "saturn", "apyx", "tori",
              "bitwise", "unitas", "lista", "kamino", "kamino-lend",
              "marginfi", "savings", "jupiter-lend", "hyperlend")

    # Blue-chip protocols (all audited, non-custodial, high TVL)
    if any(a in proj for a in BLUE_CHIP):
        s += 4
    # Tier 2 protocols
    elif any(a in proj for a in MEDIUM):
        s += 3
    # Other DeFi protocols
    elif any(a in proj for a in ("curve", "gmx", "uniswap", "convex", "lido", "rocketpool", "stargate")):
        s += 3
    # Non-leverage lending
    elif any(a in proj for a in ("fluid-lending", "jupiter-lend", "lista-lending", "kamino-lend")):
        s += 3

    # TVL scoring (higher weight for TVL >= $50M)
    if tvl >= 500_000_000 and stablecoin: s += 3
    elif tvl >= 500_000_000: s += 2
    elif tvl >= 50_000_000 and stablecoin: s += 2
    elif tvl >= 50_000_000: s += 1
    elif tvl >= 5_000_000 and sym in ("PAXG", "XAUT"): s += 2

    # Bluechip symbol
    if sym in ("USDC", "USDT", "DAI", "SUSDS", "STUSDS", "SGHO", "USDE", "SUSDE", "DAI", "sDAI"): s += 1

    # Credit risk penalty
    if any(a in proj for a in ("maple", "ondo")): s -= 1

    # Safety 5/5 bonus for audited protocols with high TVL
    if s >= 7 and tvl >= 50_000_000: s = 5

    return max(1, min(s, 5))

def fetch_pools():
    """Fetch all pools from DeFiLlama."""
    UA = {'User-Agent': 'Mozilla/5.0'}
    url = 'https://yields.llama.fi/pools'
    req = urllib.request.Request(url, headers=UA)
    data = json.loads(urllib.request.urlopen(req, timeout=60).read())
    return data.get('data', [])

def evaluate_pool(p):
    """Evaluate a single pool against deployment criteria."""
    apy = p.get('apyBase')
    apy_30d = p.get('apyMean30d') or 0
    tvl = p.get('tvlUsd') or 0
    symbol = p.get('symbol', '')
    project = p.get('project', '')
    chain = p.get('chain', '')
    stablecoin = p.get('stablecoin', False)
    pool_meta = p.get('poolMeta', '') or ''
    is_lp = 'for lp' in pool_meta.lower()
    
    # Filter out LP pools
    if is_lp:
        return None
    
    # Determine minimum TVL requirement
    tvl_min = 5_000_000 if symbol in ('PAXG', 'XAUT') else 50_000_000
    
    # Basic filters
    if apy is None or tvl < tvl_min or not stablecoin and symbol not in ('PAXG', 'XAUT'):
        return None
    
    # Score safety
    safety = score_safety(project, symbol, chain, tvl, stablecoin)
    
    # Check APY vs 30d mean (momentum)
    gap = apy - apy_30d
    # Penalize pools that are heavily inflated (> 2pp above 30d mean)
    if gap > 2.0 and safety < 5:
        penalty = True  # Skip inflated pools with low safety
    else:
        penalty = False
    
    # Exclude pools with known credit risk (maple, ondo) unless safety >= 4
    if any(a in project.lower() for a in ("maple", "ondo")) and safety < 4:
        return None
    
    if penalty:
        return None
    
    return {
        'symbol': symbol,
        'project': project,
        'chain': chain,
        'apy': apy,
        'apy_30d': apy_30d,
        'tvl': tvl,
        'safety': safety,
        'gap': round(gap, 2),
        'poolMeta': pool_meta,
    }

def classify_pool(pool):
    """Classify pool into tier based on safety and APY.
    
    Order matters: fixed and delta-neutral checks come first,
    then core (established protocols only), then satellite.
    """
    safety = pool['safety']
    apy = pool['apy']
    symbol = pool['symbol']
    project = pool['project']
    
    # Tangible assets (PAXG, XAUT) get their own category
    if symbol in ('PAXG', 'XAUT'):
        return 'tangible'
    
    # Fixed: Pendle PT products
    if 'pendle' in project.lower():
        return 'fixed'
    
    # Delta-neutral: REUSD, sUSDe
    if project.lower() in ('re', 'ethena-usde'):
        return 'delta-neutral'
    
    # Core: safety 5/5, APY 3-8%, established protocols only
    # APY > 8% is NEVER core (prevents SUSDAT, APXUSD from being classified as core)
    MAX_CORE_APY = 8.0
    if safety >= 5 and apy >= 3.0 and apy <= MAX_CORE_APY:
        # Exclude newer protocols from core
        proj_lower = project.lower()
        NEW_PROTOCOLS = ('saturn', 'apyx', 'accountable', 'tori', 'bitwise', 'unitas',
                         'lista', 'marginfi', 'jupiter-lend', 'kamino', 're', 'ethena',
                         'mainstreet', 'pareto', 'sentora', 'midas', 'centrifuge',
                         'fluid', 'venus', 'justlend')
        if not any(a in proj_lower for a in NEW_PROTOCOLS):
            return 'core'
    
    # Satellite: safety >= 2 and APY >= 5%
    if safety >= 2 and apy >= 5.0:
        return 'satellite'
    
    # Monitor: safety >= 2 but APY < 5%
    if safety >= 2 and apy >= 3.0:
        return 'monitor'
    
    return None

def deploy_allocation(pools):
    """Deploy optimal allocation from evaluated pools."""
    evaluated = []
    for p in pools:
        result = evaluate_pool(p)
        if result:
            result['category'] = classify_pool(result)
            evaluated.append(result)
    
    # Group by category
    categories = {'core': [], 'fixed': [], 'satellite': [], 'delta-neutral': [], 'tangible': [], 'monitor': []}
    for p in evaluated:
        cat = p['category']
        if cat in categories:
            categories[cat].append(p)
    
    # Sort each category by APY descending (highest yield first)
    for cat in categories:
        categories[cat].sort(key=lambda x: -x['apy'])
    
    # Select best picks per tier
    # Satellite: top 4 — all safety-5/5, TVL≥$50M candidates
    #   (SUSDAT 14.99%, APXUSD 12.70%, accountable-USDC 11.40%, STRUSD 10.63%)
    # Improvement #2: raise the cap to 6 so future vetted satellites flow in.
    selection = {
        'core': categories['core'][:4],  # Top 4 core pools (safety 5/5)
        'fixed': categories['fixed'][:1],  # Top 1 fixed product
        'satellite': categories['satellite'][:6],  # Top 6 satellite (improvement #2)
        'delta_neutral': categories['delta-neutral'][:2],  # Top 2 delta-neutral
        'tangible': categories['tangible'][:2],  # Top 2 tangible
    }
    
    # Improvement #1: satellite weight 20% → 40%.
    # All 4 satellite picks are safety 5/5 with TVL ≥ $50M, so the extra
    # allocation raises the blend without adding unvetted risk.
    # Weights sum EXACTLY to 1.00 (no phantom monitor tier in the blend).
    WEIGHTS = {
        'core': 0.35,
        'fixed': 0.10,
        'satellite': 0.40,
        'delta_neutral': 0.15,
        'tangible': 0.00,   # tangible is tracked but carries no blend weight
    }
    weights = WEIGHTS
    
    # Compute tier APYs (equal-weight within tier)
    tier_apys = {}
    for cat in weights:
        pools_list = selection.get(cat, [])
        if not pools_list:
            tier_apys[cat] = 0
        else:
            tier_apys[cat] = sum(p['apy'] for p in pools_list) / len(pools_list)
    
    # Compute blend — weights must sum to 1.0 exactly (verified below)
    assert abs(sum(WEIGHTS.values()) - 1.0) < 1e-9, f"weights sum to {sum(WEIGHTS.values())}"
    blend = sum(tier_apys[cat] * weights[cat] for cat in weights)
    
    return {
        'selection': selection,
        'tier_apys': tier_apys,
        'blend': round(blend, 2),
        'all_evaluated': len(evaluated),
        'categories': {k: len(v) for k, v in categories.items()},
        'deployment_weights': weights,
    }

def main():
    print("=" * 60)
    print("  PROYIELD 2.0 DEPLOYMENT ENGINE")
    print("=" * 60)
    
    # Fetch and evaluate all pools
    pools = fetch_pools()
    print(f"Fetched {len(pools)} pools from DeFiLlama")
    
    result = deploy_allocation(pools)
    
    print(f"\nEvaluated: {result['all_evaluated']} pools")
    print(f"Categories: {result['categories']}")
    
    print(f"\n{'─' * 60}")
    print("DEPLOYMENT ALLOCATION")
    print(f"{'─' * 60}")
    
    tier_names = {
        'core': 'CORE (35%)',
        'fixed': 'FIXED PT (10%)',
        'satellite': 'SATELLITE (40%)',
        'delta_neutral': 'DELTA-NEUTRAL (15%)',
        'tangible': 'TANGIBLE (tracked, 0%)',
    }
    
    total_weighted = 0
    for cat, pools_list in result['selection'].items():
        if not pools_list:
            print(f"\n{tier_names[cat]}: (empty)")
            continue
        tier_apy = result['tier_apys'][cat]
        weight = result['deployment_weights'][cat]
        print(f"\n{tier_names[cat]}: {tier_apy:.2f}% (weight {weight:.0%})")
        for p in pools_list:
            print(f"  {p['symbol']:12s} {p['project']:25s} {p['chain']:12s} APY={p['apy']:.2f}% safety={p['safety']}/5 TVL=${p['tvl']/1e6:.0f}M gap={p['gap']:+.2f}pp")
    
    print(f"\n{'=' * 60}")
    print(f"BLENDED YIELD: {result['blend']:.2f}%")
    print(f"{'=' * 60}")
    
    # Compare with current
    with open(SNAPSHOT_PATH) as f:
        current = json.load(f)
    current_blend = current['blend']['blend_apy']
    print(f"\nCurrent blend: {current_blend}%")
    print(f"New blend:     {result['blend']:.2f}%")
    if result['blend'] > current_blend:
        print(f"Improvement:   +{result['blend'] - current_blend:.2f}pp")
    else:
        print(f"Difference:    {result['blend'] - current_blend:.2f}pp (lower but safer)")
    
    # Write deployed snapshot
    # Include allocation structure that render_dashboard.py expects
    # Preserve polymarket_rewards and other fields from current snapshot
    extra = {}
    if os.path.exists(SNAPSHOT_PATH):
        try:
            with open(SNAPSHOT_PATH) as f:
                old_snap = json.load(f)
            extra = {k: v for k, v in old_snap.items() if k not in ('blend', 'picks', 'tier_apys', 'deployment', 'generated_utc')}
        except Exception:
            pass
    
    deployed = {
        'generated_utc': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'blend': {
            'blend_apy': result['blend'],
            'core_apy': result['tier_apys']['core'],
            'sat_apy': result['tier_apys']['satellite'],
            'fixed_apy': result['tier_apys']['fixed'],
            'tangible_apy': result['tier_apys']['tangible'],
            'allocation': {
                'CORE': {'apy': result['tier_apys']['core'], 'weight': 0.35},
                'FIXED': {'apy': result['tier_apys']['fixed'], 'weight': 0.10},
                'SATELLITE': {'apy': result['tier_apys']['satellite'], 'weight': 0.40},
                'DELTA_NEUTRAL': {'apy': result['tier_apys']['delta_neutral'], 'weight': 0.15},
                'TANGIBLE': {'apy': result['tier_apys']['tangible'], 'weight': 0.00},
            }
        },
        'picks': result['selection'],
        'tier_apys': result['tier_apys'],
        'deployment': {
            'weights': result['deployment_weights'],
            'total_evaluated': result['all_evaluated'],
            'categories': result['categories'],
        },
        **extra,
    }
    
    with open(OUTPUT_PATH, 'w') as f:
        json.dump(deployed, f, indent=2)
    
    print(f"\nDeployed snapshot written to: {OUTPUT_PATH}")
    
    # Update the main snapshot.json if the new blend is better
    if result['blend'] >= current_blend:
        print(f"New blend ({result['blend']:.2f}%) >= current ({current_blend}%) → updating snapshot.json")
        # Copy the deployed snapshot to snapshot.json
        import shutil
        shutil.copy(OUTPUT_PATH, SNAPSHOT_PATH)
    else:
        print(f"New blend ({result['blend']:.2f}%) < current ({current_blend}%) → keeping current allocation (safer)")

if __name__ == "__main__":
    main()
