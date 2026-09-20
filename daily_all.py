#!/usr/bin/env python3
"""Pro Yield — composite daily runner.

09:00 UTC daily (no_agent):
  1. Render dashboard (fetches rates, scores pools, renders all)
  2. Sync strategy data
  3. Check fee rebates and update status
  4. Run advisor (09:15)

One script → one cron entry.
"""
import json, os, sys, time, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
os.makedirs(DATA, exist_ok=True)

def step(name, func):
    try:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        result = func()
        if result is False:
            print(f"  [FAIL] {name} ({ts})")
            return False
        print(f"  [PASS] {name} ({ts})")
        return result
    except Exception as e:
        print(f"  [FAIL] {name}: {e}")
        return None

# ── Step 1: Render dashboard (includes rate fetching) ──
def render_dashboard():
    rd = f"{HERE}/render_dashboard.py"
    result = subprocess.run([sys.executable, rd], capture_output=True, text=True, timeout=120)
    if result.returncode == 0:
        print(f"  {result.stdout.strip()}")
        return True
    else:
        print(f"  Render failed: {result.stderr[:200]}")
        return False

# ── Step 2: Sync strategy data ────────────────────────
def sync_strategy_data():
    """Record a sync marker WITHOUT clobbering snapshot.json (the scout's
    real data). The old version overwrote snapshot.json with a 3-field stub,
    destroying the blend data for every consumer until the next scout run."""
    marker_path = os.path.join(HERE, "data", "last_sync.json")
    snap_meta = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "render_dashboard.py",
        "dashboard": "dashboard.html",
    }
    with open(marker_path, "w") as f:
        json.dump(snap_meta, f)
    return True

# ── Step 3: Check fee rebates ─────────────────────────
def check_fees():
    fd = os.path.join(HERE, "..", ".hermes", "scripts", "fee_distributor.py")
    if os.path.exists(fd):
        result = subprocess.run(
            [sys.executable, fd, "stats"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0:
            print(f"  Fees: {result.stdout.strip()}")
            return True
        else:
            print(f"  Fee check: no history yet")
            return True
    return False

# ── Step 4: Verify blend math (seam guard) ─────────────
def recycle_fees():
    """Policy-gated fee recycling: splits FD fees (boost/treasury/insurance).
    No-op below the policy minimum; every run lands in data/recycling.jsonl."""
    r = subprocess.run(
        ["npx", "hardhat", "run", "scripts/recycle_fees.js", "--network", "hyperTestnet"],
        cwd="/home/user/hypervault", capture_output=True, text=True, timeout=300,
    )
    out = (r.stdout or "").strip()
    tail = out.splitlines()[-1] if out else ""
    if r.returncode != 0:
        print("  recycle:", (r.stderr or out)[-200:])
        return False
    print("  recycle:", tail[:160])
    return True

def _run_verify():
    v = os.path.join(HERE, "verify_blend.py")
    result = subprocess.run([sys.executable, v], capture_output=True, text=True, timeout=60)
    if result.returncode == 0:
        print(f"  {result.stdout.strip()}")
        return True
    print(f"  BLEND SEAM DETECTED:\n{result.stdout}")
    return False

# ── Main ──────────────────────────────────────────────
if __name__ == "__main__":
    print(f"daily_all.py — {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    
    ok_dashboard = step("Render dashboard", render_dashboard)
    step("Sync data", sync_strategy_data)
    step("Check fees", check_fees)
    step("Recycle fees", recycle_fees)
    
    # Seam guard: verify blend math consistency across all published numbers.
    # Runs AFTER render so it validates what the dashboard actually published today.
    step("Verify blend math", _run_verify)
    
    print("  done")
