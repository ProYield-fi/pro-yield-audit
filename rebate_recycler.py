#!/usr/bin/env python3
"""Rebate recycler — routes ARRIVED rebate funds (HL referral claims, Polymarket
rebates, any program income) into the fee-recycling pipeline so a policy share
reaches depositors as share-price boost.

Flow: ops wallet USDC --transfer--> FeeDistributor --> recycle_fees.js (policy
split: boost -> vault.creditYield, treasury, insurance) --> ledger.

Usage:
  python3 rebate_recycler.py --amount 25 --source hl-referral            # apply
  python3 rebate_recycler.py --amount 25 --source demo --dry-run        # preview
  python3 rebate_recycler.py --status                                   # balances + ledger tail
"""
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = "/home/user/hypervault/deployed_addresses.json"
LEDGER = os.path.join(HERE, "data", "recycling.jsonl")


def run_node(script):
    r = subprocess.run(
        ["npx", "hardhat", "run", "scripts/_recycler_ops.js", "--network", "hyperTestnet"],
        cwd="/home/user/hypervault", capture_output=True, text=True, timeout=300,
        env={**os.environ, "RECYCLER_OPS": script},
    )
    out = (r.stdout or "").strip()
    if r.returncode != 0:
        print("node ops failed:", (r.stderr or out)[-400:])
        sys.exit(1)
    return out


def status():
    out = run_node("status")
    print(out)
    if os.path.exists(LEDGER):
        print("\nledger (last 3):")
        lines = open(LEDGER).read().strip().splitlines()[-3:]
        for line in lines:
            try:
                e = json.loads(line)
                print(f"  {e['iso']}  {e['source']:16s} total=${e['total']} boost=${e['boost']} treasury=${e['treasury']} insurance=${e['insurance']}")
            except Exception:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--amount", type=float, help="USDC amount of arrived rebate funds to recycle")
    ap.add_argument("--source", default="unknown", help="rebate source label (hl-referral, pm-rebate, ...)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args()

    if args.status or not args.amount:
        status()
        return

    # 1) move the arrived rebate funds into the FeeDistributor
    if not args.dry_run:
        out = run_node(f"transfer {args.amount}")
        print(out)
    else:
        print(f"[dry-run] would transfer {args.amount} USDC -> FeeDistributor (source={args.source})")

    # 2) run the standard recycle pipeline (same policy as fees)
    env = {**os.environ, "RECYCLE_SOURCE": args.source}
    if args.dry_run:
        env["DRY_RUN"] = "1"
    r = subprocess.run(
        ["npx", "hardhat", "run", "scripts/recycle_fees.js", "--network", "hyperTestnet"],
        cwd="/home/user/hypervault", capture_output=True, text=True, timeout=300, env=env,
    )
    tail = (r.stdout or "").strip().splitlines()[-6:]
    print("\n".join(tail))
    if r.returncode != 0:
        print("recycle failed:", (r.stderr or "")[-400:])
        sys.exit(1)
    if not args.dry_run:
        print(f"\nrebate recycled: {args.amount} USDC from '{args.source}' entered the fee-recycling pipeline")


if __name__ == "__main__":
    main()
