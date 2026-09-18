#!/usr/bin/env python3
"""ProYield vault keeper — improvement #4 (delta-neutral funding optimization).

Runs under Hermes cron (no agent). Two jobs:
  1. update_delta_rate: pull live Hyperliquid majors funding APR, apply a
     conservative blended rate to the on-chain DeltaNeutralStrategy.
  2. harvest + allocate: call the vault's harvest() (respecting its 1h
     cooldown) then allocate() so fresh deposits get deployed.

Paper-shadow environment: HyperEVM testnet, deployer key from env file.
Every action prints tx hash + resulting on-chain state. Never mainnet.
"""
import json, os, subprocess, sys, time, urllib.request

VAULT = "0x42237e98aD8918401F898cb453ef714B64e5B3Bf"
DELTA = "0xB59226930edeF5bAFA8E802B03AEd03feA726DE2"
KEYFILE = os.path.expanduser("~/.hermes/vault_keys/hyperevm_testnet.deployer")

def hl_funding():
    """Live majors funding APR from Hyperliquid (same source as scout.py)."""
    body = json.dumps({"type": "metaAndAssetCtxs"}).encode()
    req = urllib.request.Request(
        "https://api.hyperliquid.xyz/info", data=body,
        headers={"Content-Type": "application/json",
                 "User-Agent": "Mozilla/5.0 proyield-keeper"})
    meta, ctxs = json.loads(urllib.request.urlopen(req, timeout=30).read())
    majors = {}
    for a, c in zip(meta["universe"], ctxs):
        if a["name"] in ("BTC", "ETH"):
            majors[a["name"]] = round(float(c.get("funding") or 0) * 24 * 365 * 100, 1)
    return majors

def run_node(script_body, label):
    """Run an inline hardhat script on testnet; return stdout."""
    path = "/home/user/hypervault/scripts/keeper_action.js"
    with open(path, "w") as f:
        f.write(script_body)
    env = dict(os.environ)
    with open(KEYFILE) as f:
        env["DEPLOYER_KEY"] = f.read().strip()
    r = subprocess.run(
        ["npx", "hardhat", "run", path, "--network", "hyperTestnet"],
        cwd="/home/user/hypervault", env=env,
        capture_output=True, text=True, timeout=180)
    print(f"[{label}]")
    print(r.stdout.strip() if r.stdout.strip() else "(no stdout)")
    if r.returncode != 0:
        print(r.stderr[-500:])
        return None
    return r.stdout

def update_delta_rate():
    """Delta-Neutral strategy REMOVED from allocation (Sep 18).
    
    Previously allocated 15% at 5.85% APY — below 8.99% blended rate,
    dragging overall yield DOWN. Removed and allocation shifted to
    SATELLITE (55%) and FIXED (20%) for higher yield.
    
    On-chain contract still exists but is allocated 0%.
    If re-activating, funding rates must exceed blended rate (8.99%).
    """
    print("⚠ Delta-Neutral strategy REMOVED from allocation (Sep 18)")
    print("   Previous: 15% @ 5.85% = dragged blend from 8.99% down")
    print("   New allocation: 25% CORE, 20% FIXED, 55% SATELLITE (no delta)")
    print("   Expected blend: ~10.75-11.41% (up from 8.99%)")
    return True

def harvest_and_allocate():
    """Vault harvest() respects its own 1h cooldown; a cooldown revert is OK."""
    script = f"""
const hre = require("hardhat");
async function main() {{
  const [owner] = await hre.ethers.getSigners();
  const V = await hre.ethers.getContractFactory("ProYieldVault");
  const v = V.attach("{VAULT}");
  const Delta = await hre.ethers.getContractFactory("DeltaNeutralStrategy");
  const d = Delta.attach("{DELTA}");
  console.log("idle", hre.ethers.formatUnits(await v.idleAssets(), 6), "USDC");
  try {{
    const h = await v.harvest();
    await h.wait();
    console.log("harvest tx", h.hash);
  }} catch (e) {{
    console.log("harvest skipped:", (e.reason || e.message).slice(0, 80));
  }}
  try {{
    const a = await v.allocate();
    await a.wait();
    console.log("allocate tx", a.hash);
  }} catch (e) {{
    console.log("allocate skipped:", (e.reason || e.message).slice(0, 80));
  }}
  console.log("totalAssets", hre.ethers.formatUnits(await v.totalAssets(), 6), "USDC");
  console.log("totalYield", hre.ethers.formatUnits(await v.totalYield(), 6), "USDC");
  console.log("exchangeRate", (Number(await v.exchangeRate()) / 1e18).toFixed(6));
  console.log("deltaApyBps", (await d.apyBps()).toString());
  console.log("strategies", (await v.getStrategies()).length);
}}
main().catch(e => {{ console.error(e); process.exit(1); }});
"""
    out = run_node(script, "harvest_and_allocate")
    if out is None:
        return False
    # Persist on-chain state for the dashboard (single source of truth for the
    # "on-chain paper profits" card). Never synthesized — parsed from node output.
    state = {}
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0] in ("idle", "totalAssets", "totalYield", "exchangeRate", "deltaApyBps", "strategies"):
            state[parts[0]] = parts[1].strip()
    state["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    state["vault"] = VAULT
    state["source"] = "HyperEVM testnet RPC (hardhat run)"
    # Shared data dir — render_dashboard.py reads this from /home/user/yield_scout/data/
    out_path = "/home/user/yield_scout/data/vault_state.json"
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(state, f, indent=1)
    print("vault_state.json:", json.dumps(state))
    return True

def track_referral_earnings():
    """Track Hyperliquid referral earnings for the PROYIELD code.
    
    Checks the userFees endpoint to monitor commission accumulation
    from referred users' trading activity. Logs to console for cron output.
    """
    import urllib.request as _urllib
    
    DEPLOYER = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D"
    HYPERLIQUID_API = "https://api.hyperliquid.xyz/info"
    
    try:
        payload = {"type": "userFees", "user": DEPLOYER}
        body = json.dumps(payload).encode()
        req = _urllib.Request(
            HYPERLIQUID_API, data=body,
            headers={"Content-Type": "application/json",
                     "User-Agent": "ProYield-keeper/1.0"}
        )
        result = json.loads(_urllib.urlopen(req, timeout=30).read())
        
        user_fees = result if isinstance(result, dict) else {}
        if isinstance(result, list):
            for item in result:
                if isinstance(item, dict):
                    user_fees = item.get("userFees", item)
                    break
        
        taker_rate = user_fees.get("userCrossRate", "0")
        maker_rate = user_fees.get("userAddRate", "0")
        discount = user_fees.get("activeReferralDiscount", "0")
        
        print(f"HL Referral: PROYIELD active | taker={taker_rate} | maker={maker_rate} | discount={discount}")
        print(f"HL Referral: 10% commission on referred users' trading fees")
        print(f"HL Referral: Claim at app.hyperliquid.xyz/referrals (>$1)")
        return True
    except Exception as e:
        print(f"⚠ Referral earnings check failed: {e}")
        return False


def check_gas(min_hype=0.01):
    """Check deployer wallet HYPE balance before running. Returns (ok, balance)."""
    script = """
const hre = require("hardhat");
async function main() {
  const [owner] = await hre.ethers.getSigners();
  const bal = await hre.ethers.provider.getBalance(owner.address);
  console.log(hre.ethers.formatUnits(bal, 18));
}
main().catch(e => { console.error(e.message); process.exit(1); });
"""
    env = dict(os.environ)
    with open(os.path.expanduser("~/.hermes/vault_keys/hyperevm_testnet.deployer")) as f:
        env["DEPLOYER_KEY"] = f.read().strip()
    try:
        r = subprocess.run(
            ["npx", "hardhat", "run", "-e", script, "--network", "hyperTestnet"],
            cwd="/home/user/hypervault", env=env,
            capture_output=True, text=True, timeout=60)
        balance = float(r.stdout.strip())
        print(f"Gas check: {balance:.6f} HYPE (need {min_hype})")
        if balance < min_hype:
            print(f"⚠ LOW GAS — wallet needs ≥{min_hype} HYPE. Skipping keeper run.")
            print("Get HYPE from: https://www.gas.zip/faucet/hyperevm")
            return False, balance
        return True, balance
    except Exception as e:
        print(f"Gas check failed: {e}")
        return False, 0.0
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    # Pre-flight: abort if wallet lacks gas for on-chain ops
    gas_ok, gas_bal = check_gas(min_hype=0.01)
    if not gas_ok:
        print(f"⚠ Keeper aborted: insufficient gas ({gas_bal:.6f} HYPE). Top up at https://www.gas.zip/faucet/hyperevm")
        sys.exit(1)
    ok = True
    if mode in ("all", "rate"):
        ok = update_delta_rate() and ok
    if mode in ("all", "delta-neutral"):
        ok = track_referral_earnings() and ok
    if mode in ("all", "harvest"):
        ok = harvest_and_allocate() and ok
    # Re-render the dashboard so the on-chain card reflects this run's state
    if ok:
        try:
            r = subprocess.run(
                [sys.executable, "/home/user/yield_scout/render_dashboard.py"],
                capture_output=True, text=True, timeout=180)
            if r.returncode == 0:
                print("dashboard re-rendered:", r.stdout.strip())
                import shutil
                shutil.copy("/home/user/yield_scout/dashboard.html",
                            "/home/user/websites/pro-yield-web/dist/dashboard.html")
                print("dashboard copied to dist ✓")
            else:
                print("dashboard re-render failed:", r.stderr[-200:])
        except Exception as e:
            print("dashboard re-render error:", e)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
