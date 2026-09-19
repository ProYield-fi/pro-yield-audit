#!/usr/bin/env python3
"""ProYield Insurance Fund — REAL STATE ONLY (live-data-verification standard).

Rewritten Sep 19 2026 after audit finding: the previous version (a) counted
paper-era Polymarket trading rewards as platform revenue and skimmed 5% into
"reserves", (b) ESTIMATED user deposits as "1% of pool TVL", and (c) labeled
the result "hardware wallet multi-sig cold storage". None of that was real.
The website FAQ promises "20% of vault fees go to the insurance fund" — this
module now tracks only fees ACTUALLY received, and deposits from the vault
contract on-chain.

HONESTY CONTRACT:
- reserves grow ONLY from fees actually received (none yet — performance fees
  launch post-audit). Caller must pass verified amounts; never modeled numbers.
- deposits are read on-chain (ProYieldVault.totalAssets), never estimated.
- cold storage reports 0/"unverified" until a hardware-wallet balance exists.
- every number carries a source; gaps are UNAVAILABLE/0, never invented.
- protocol-compromise detection (real snapshot analysis) is preserved.
"""
import json, os, subprocess
from datetime import datetime, timezone

YIELD = "/home/user/yield_scout"
DATA = os.path.join(YIELD, "data")
INSURANCE_PATH = os.path.join(DATA, "insurance_fund.json")
SNAPSHOT_PATH = os.path.join(DATA, "snapshot.json")
HYPERVAULT = "/home/user/hypervault"


def _vault_address():
    """Read vault address from deployed_addresses.json (single source of truth)."""
    p = os.path.join(HYPERVAULT, "deployed_addresses.json")
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f).get("pro_yield_vault")
    return "0x596B5fd3D9Abfb5392cd96D1E509DD6F2690443c"  # last known; manifest preferred

VAULT = _vault_address()

INSURANCE_CONFIG = {
    "reserve_ratio": 1.0,     # 1:1 coverage requirement
    "fee_share": 0.20,        # 20% of platform fees -> insurance (website promise)
}


def _now():
    return datetime.now(timezone.utc).isoformat()


def fresh_state():
    """Real state: nothing collected, nothing deposited, nothing claimed."""
    return {
        "created_utc": _now(),
        "updated_utc": _now(),
        "standard": "live-data-verification: reserves from ACTUAL collected fees only; "
                    "deposits on-chain; no estimates, no paper-era data",
        "total_reserves_usd": 0.0,
        "total_user_deposits_usd": 0.0,
        "coverage_ratio": 0.0,
        "reserve_status": "NO_DEPOSITS",   # nothing to cover yet — honest, not INSUFFICIENT
        "deposits_source": "on-chain ProYieldVault.totalAssets() via hardhat",
        "cold_storage": {
            "balance_usd": 0.0,
            "wallet_type": "none_yet",
            "security": "unverified",
            "note": "UNAVAILABLE: no hardware wallet configured. Stays 0 until a "
                    "verifiable cold-storage balance exists.",
        },
        "active_deployment": {
            "balance_usd": 0.0,
            "tier": None,
            "apy": 0.0,
            "protocols": [],
            "note": "UNAVAILABLE: no reserves to deploy.",
        },
        "fee_accumulation": {
            "performance_fees": 0.0,   # vault performance fees actually collected
            "referral_fees": 0.0,      # MoonPay/HL kickbacks actually received
            "total_collected": 0.0,    # 20% share that went to the fund
            "last_collection": None,
        },
        "coverage_history": [],
        "claims": [],
        "config": INSURANCE_CONFIG,
    }


def load_insurance():
    if os.path.exists(INSURANCE_PATH):
        with open(INSURANCE_PATH) as f:
            return json.load(f)
    return fresh_state()


def migrate_legacy(state):
    """Zero out fabricated legacy numbers once. Keeps a migration log for the audit trail."""
    fabricated = state.get("total_reserves_usd", 0) > 0 and "pm_rewards_7d" in state.get("fee_accumulation", {})
    if fabricated:
        hist = state.get("coverage_history", [])[-20:]
        fresh = fresh_state()
        fresh["created_utc"] = state.get("created_utc", fresh["created_utc"])
        fresh["coverage_history"] = hist
        fresh["migration_log"] = [{
            "ts": _now(),
            "action": "PURGED_FABRICATED_STATE",
            "purged_reserves_usd": state.get("total_reserves_usd", 0),
            "reason": "pre-migration reserves came from paper-era Polymarket rewards, "
                      "not platform fees (audit finding 2026-09-19)",
        }]
        return fresh
    return state


def collect_real_fees(state, performance_fees=0.0, referral_fees=0.0):
    """Add ONLY fees actually received. Wire to FeeDistributor events /
    MoonPay payout statements when live. Never call with modeled numbers."""
    share = (performance_fees + referral_fees) * INSURANCE_CONFIG["fee_share"]
    if share > 0:
        state["fee_accumulation"]["performance_fees"] += performance_fees
        state["fee_accumulation"]["referral_fees"] += referral_fees
        state["fee_accumulation"]["total_collected"] = round(
            state["fee_accumulation"]["total_collected"] + share, 6)
        state["fee_accumulation"]["last_collection"] = _now()
        state["total_reserves_usd"] = round(state["total_reserves_usd"] + share, 6)
    return state


def read_onchain_deposits():
    """Real deposits: ProYieldVault.totalAssets() via hypervault/scripts/read_vault.js.
    0.0 + UNAVAILABLE note on failure (chain down = no fabricated backup number)."""
    try:
        r = subprocess.run(
            ["npx", "hardhat", "run", "scripts/read_vault.js", "--network", "hyperTestnet"],
            capture_output=True, text=True, timeout=90, cwd=HYPERVAULT)
        lines = [l for l in (r.stdout or "").strip().splitlines() if l]
        if r.returncode == 0 and lines:
            val = lines[-1].strip()
            return float(val), f"on-chain ProYieldVault.totalAssets() at {VAULT[:10]}…"
        err = ((r.stderr or "").strip().splitlines() or ["unknown"])[-1][:100]
        return 0.0, f"UNAVAILABLE: vault read failed ({err})"
    except Exception as e:
        return 0.0, f"UNAVAILABLE: {e}"


def update_coverage(state, deposits, source_note=None):
    state["total_user_deposits_usd"] = round(deposits, 2)
    if source_note:
        state["deposits_source"] = source_note
    res = state["total_reserves_usd"]
    dep = state["total_user_deposits_usd"]
    state["coverage_ratio"] = round(res / dep, 3) if dep > 0 else 0.0
    if dep == 0:
        state["reserve_status"] = "NO_DEPOSITS"
    else:
        state["reserve_status"] = ("FULLY_COVERED" if state["coverage_ratio"] >= 1.0
                                   else "INSUFFICIENT")
    state["updated_utc"] = _now()
    state["coverage_history"].append({
        "timestamp": state["updated_utc"],
        "reserves_usd": round(res, 2),
        "deposits_usd": round(dep, 2),
        "coverage_ratio": state["coverage_ratio"],
        "status": state["reserve_status"],
    })
    state["coverage_history"] = state["coverage_history"][-100:]
    return state


def detect_protocol_compromise(snapshot):
    """Real analysis on real snapshot data: rate drops >50% vs 30d mean = flag."""
    compromised = []
    picks = snapshot.get("picks", {}) if snapshot else {}
    for category, pools in picks.items():
        if not isinstance(pools, list):
            continue
        for pool in pools:
            apy_base = pool.get("apy_base", 0) or 0
            apy_30d = pool.get("apy_30d", 0) or 0
            if apy_base > 0.5 and apy_30d > 0 and apy_base < apy_30d * 0.5:
                compromised.append({
                    "project": pool.get("project", ""),
                    "symbol": pool.get("symbol", ""),
                    "category": category,
                    "reason": f"APY dropped from {apy_30d:.2f}% to {apy_base:.2f}%",
                    "severity": "HIGH",
                    "action": "REVIEW_POSITION",   # claim only on real exploit, operator decides
                })
    return compromised


def main():
    state = load_insurance()
    state = migrate_legacy(state)
    # Real fees: none collected yet. Zeros until FeeDistributor events are live.
    state = collect_real_fees(state, performance_fees=0.0, referral_fees=0.0)
    # Real deposits: on-chain read.
    deposits, note = read_onchain_deposits()
    state = update_coverage(state, deposits, note)
    with open(INSURANCE_PATH, "w") as f:
        json.dump(state, f, indent=1)
    print(f"insurance_fund -> reserves=${state['total_reserves_usd']:.2f} "
          f"deposits=${state['total_user_deposits_usd']:.2f} "
          f"coverage={state['coverage_ratio']} status={state['reserve_status']} "
          f"({state['deposits_source'][:60]})")
    # Compromise check (no auto-claim — operator decides)
    try:
        with open(SNAPSHOT_PATH) as f:
            snap = json.load(f)
        comp = detect_protocol_compromise(snap)
        for c in comp:
            print(f"  COMPROMISE FLAG: {c['project']} {c['symbol']}: {c['reason']} -> {c['action']}")
    except Exception:
        pass


if __name__ == "__main__":
    main()
