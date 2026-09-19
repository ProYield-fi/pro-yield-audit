#!/usr/bin/env python3
"""ProYield 2.0 Risk Tier System — configurable risk profiles for customers.

Provides multiple risk tiers so customers can choose their risk/reward balance.
Uses the deployment engine's computed tier APYs.
"""
import json, os
from datetime import datetime, timezone

BASE_DIR = "/home/user/yield_scout"
DATA = os.path.join(BASE_DIR, "data")
SNAPSHOT_PATH = os.path.join(DATA, "snapshot.json")

RISK_TIERS = {
    "conservative": {
        "label": "Conservative",
        "description": "Maximum safety. 55% core, 20% fixed, 10% satellite. Safety 5/5 preferred.",
        "weights": {"core": 0.55, "fixed": 0.20, "satellite": 0.10, "delta_neutral": 0.05, "tangible": 0.05, "monitor": 0.05},
        "safety_min": 4,
        "satellite_max_apy": 0.08,
        "risk_level": "LOW",
        "color": "#22c55e",
    },
    "balanced": {
        "label": "Balanced",
        "description": "Optimal risk/reward. 35% core, 10% fixed, 35% satellite. Current default.",
        "weights": {"core": 0.35, "fixed": 0.10, "satellite": 0.35, "delta_neutral": 0.15, "tangible": 0.05, "monitor": 0.0},
        "safety_min": 3,
        "satellite_max_apy": 0.15,
        "risk_level": "MEDIUM",
        "color": "#3b82f6",
    },
    "aggressive": {
        "label": "Aggressive",
        "description": "Higher yield focus. 25% core, 10% fixed, 45% satellite. AI-managed.",
        "weights": {"core": 0.25, "fixed": 0.10, "satellite": 0.45, "delta_neutral": 0.15, "tangible": 0.05, "monitor": 0.0},
        "safety_min": 2,
        "satellite_max_apy": 0.18,
        "risk_level": "HIGH",
        "color": "#f59e0b",
    },
    "maximum": {
        "label": "Maximum",
        "description": "Highest yield. 15% core, 5% fixed, 55% satellite, 20% delta-neutral. AI-managed.",
        "weights": {"core": 0.15, "fixed": 0.05, "satellite": 0.55, "delta_neutral": 0.20, "tangible": 0.05, "monitor": 0.0},
        "safety_min": 1,
        "satellite_max_apy": 0.20,
        "risk_level": "VERY_HIGH",
        "color": "#ef4444",
    },
}

def compute_blend(weights, tier_apys):
    """Compute blended yield given weight allocation and tier APYs."""
    return sum(weights.get(cat, 0) * tier_apys.get(cat, 0) for cat in weights)

def get_tier_apys():
    """Get tier APYs from the deployment engine's snapshot.
    UNAVAILABLE semantics: no snapshot -> empty dict (never invented numbers).
    Consumers must treat missing keys as UNAVAILABLE, not fall back to fiction."""
    if os.path.exists(SNAPSHOT_PATH):
        try:
            with open(SNAPSHOT_PATH) as f:
                snap = json.load(f)
            return snap.get("tier_apys", {})
        except Exception:
            pass
    return {}  # UNAVAILABLE — no plausible-looking defaults

def main():
    print("=" * 60)
    print("  PROYIELD 2.0 — RISK TIER ANALYSIS")
    print("=" * 60)
    
    # Get tier APYs from deployment engine output
    tier_apys = get_tier_apys()
    print(f"\nTier APYs (from snapshot.json): { {k: round(v, 2) for k, v in tier_apys.items()} }")
    
    # Compute blend for each tier
    # tier_apys values are already in percentage form (e.g., 12.31 means 12.31%)
    results = {}
    for tier_name, tier_config in RISK_TIERS.items():
        weights = tier_config["weights"]
        blend = compute_blend(weights, tier_apys)  # Result is already in percentage
        tier_config["computed_apy"] = round(blend, 2)  # Already percentage, no *100 needed
        results[tier_name] = tier_config
    
    print()
    for tier_name, tier_config in results.items():
        print(f"  {tier_config['label']:15s} {tier_config['computed_apy']:.2f}%  {tier_config['risk_level']:12s}")
    
    print(f"\n{'=' * 60}")
    print(f"  SUMMARY")
    print(f"{'=' * 60}")
    print(f"  Conservative: ~{results['conservative']['computed_apy']:.2f}%  |  Risk: LOW")
    print(f"  Balanced:     ~{results['balanced']['computed_apy']:.2f}%  |  Risk: MEDIUM  ← CURRENT DEFAULT")
    print(f"  Aggressive:   ~{results['aggressive']['computed_apy']:.2f}%  |  Risk: HIGH")
    print(f"  Maximum:     ~{results['maximum']['computed_apy']:.2f}%  |  Risk: VERY_HIGH (AI-managed)")
    print(f"\n  User target: ~12% (1%/month) achievable with Maximum + momentum")
    print(f"{'=' * 60}")
    
    # Write risk tiers config
    config = {
        "generated_utc": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        "tiers": {},
        "default_tier": "balanced",
        "tier_apys": {k: round(v, 2) for k, v in tier_apys.items()},
    }
    for tier_name, tier_config in results.items():
        config["tiers"][tier_name] = {
            "label": tier_config["label"],
            "description": tier_config["description"],
            "risk_level": tier_config["risk_level"],
            "color": tier_config["color"],
            "weights": tier_config["weights"],
            "safety_min": tier_config["safety_min"],
            "expected_apy": tier_config["computed_apy"],
            "satellite_max_apy": tier_config["satellite_max_apy"],
        }
    
    config["tier_apys"] = {k: round(v, 2) for k, v in tier_apys.items()}
    config_path = os.path.join(DATA, "risk_tiers.json")
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print(f"\nRisk tiers config written to: {config_path}")

if __name__ == "__main__":
    main()
