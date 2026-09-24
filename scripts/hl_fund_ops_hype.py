#!/usr/bin/env python3
"""Fund HyperEVM mainnet ops: test USDC -> HYPE (HyperCore spot), bridge HYPE
to HyperEVM, forward deploy gas to the ops EOA.

Phases (each needs its env flag; without them it's a read-only dry run):
  BUY=1     IOC market-buy HYPE on HYPE/USDC (notional $HYPE_USD)
  BRIDGE=1  sendAsset HYPE -> system addr 0x222..2 (lands as native HYPE at
            THIS wallet's own EVM address, per HL docs; forwarded after)

MAINNET only (asserts api host). Receipt -> ~/.proyield/hype_funding_receipt.json.
"""
import json
import os
import time

import requests
from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info

API = "https://api.hyperliquid.xyz"
EVM_RPC = "https://rpc.hyperliquid.xyz/evm"
assert "testnet" not in API, "refusing: this script is for MAINNET"

SYS_HYPE = "0x2222222222222222222222222222222222222222"
SYS_USDC = "0x2000000000000000000000000000000000000000"
USDC_EVM_TOKEN = "0xb88339CB7199b77E23DB6E890353E22632Ba630f"  # Circle-native USDC on HyperEVM (per Circle docs)
OPS_EOA = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D"
WALLET = os.path.expanduser("~/.proyield/onramp_usertest.json")
RECEIPT = os.path.expanduser("~/.proyield/hype_funding_receipt.json")

SEND = os.environ.get("MAINNET_OK") == "1"
BUY = os.environ.get("BUY") == "1"
BRIDGE = os.environ.get("BRIDGE") == "1"
HYPE_USD = float(os.environ.get("HYPE_USD", "10.5"))
BRIDGE_HYPE = float(os.environ.get("BRIDGE_HYPE", "0.12"))
USDC_EVM = os.environ.get("USDC_EVM") == "1"
USDC_AMT = float(os.environ.get("USDC_AMT", "10"))

_j = json.load(open(WALLET))
acct = Account.from_key(_j["private_key"])
ADDR = acct.address

info = Info(API, skip_ws=True, timeout=15.0)
exch = Exchange(acct, API, account_address=ADDR, timeout=15.0)
IOC = {"limit": {"tif": "Ioc"}}


def rpc_balance(addr):
    r = requests.post(EVM_RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_getBalance",
                                     "params": [addr, "latest"]}, timeout=15)
    return int(r.json()["result"], 16) / 1e18


def spot_bal(coin):
    st = info.spot_user_state(ADDR)
    for b in st.get("balances", []):
        if b["coin"] == coin:
            return float(b["total"])
    return 0.0


def find_hype_pair():
    sm = info.spot_meta()
    usdc = next(t for t in sm["tokens"] if t["name"] == "USDC")
    hype = next(t for t in sm["tokens"] if t["name"] == "HYPE")
    pair = next(u for u in sm["universe"]
                if u["tokens"][0] == hype["index"] and u["tokens"][1] == usdc["index"])
    # sendAsset token param = tokenName:tokenId (API spec), NOT the bare name
    return pair["name"], int(hype["szDecimals"]), "HYPE:" + hype["tokenId"], "USDC:" + usdc["tokenId"]


def best(pair):
    book = info.l2_snapshot(pair)
    bid = float(book["levels"][0][0]["px"]) if book["levels"][0] else None
    ask = float(book["levels"][1][0]["px"]) if book["levels"][1] else None
    return bid, ask


def round_px(px, sz_dec):
    sig = float(f"{px:.5g}")
    return float(f"{sig:.{max(0, 6 - sz_dec)}f}")


def statuses(r):
    return r.get("response", {}).get("data", {}).get("statuses")


def main():
    pair, szs, HYPE_TOK, USDC_TOK = find_hype_pair()
    bid, ask = best(pair)
    gas_px = requests.post(EVM_RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_gasPrice",
                                          "params": []}, timeout=15).json()["result"]
    print(f"wallet {ADDR}")
    print(f"HYPE/USDC pair = {pair} (szDecimals {szs}) · bid {bid} ask {ask}")
    print(f"EVM gas price: {int(gas_px, 16) / 1e9:.4f} gwei · "
          f"EVM HYPE: this wallet {rpc_balance(ADDR):.6f} · ops {rpc_balance(OPS_EOA):.6f}")
    print(f"spot USDC {spot_bal('USDC'):.6f} · spot HYPE {spot_bal('HYPE'):.6f}")

    if BUY:
        if not SEND:
            raise SystemExit("refusing: BUY requires MAINNET_OK=1")
        px = round_px(ask * 1.002, szs)
        qty = round(HYPE_USD / px, szs)
        print(f"plan: BUY {qty} HYPE @ ≤{px} (${qty * px:.2f})")
        r = exch.order(pair, True, qty, px, IOC)
        print("buy:", statuses(r))
        time.sleep(2)
        print(f"after buy: spot HYPE {spot_bal('HYPE'):.6f} · spot USDC {spot_bal('USDC'):.6f}")

    if BRIDGE:
        if not SEND:
            raise SystemExit("refusing: BRIDGE requires MAINNET_OK=1")
        held = spot_bal("HYPE")
        if held < BRIDGE_HYPE:
            raise SystemExit(f"only {held} HYPE spot — cannot bridge {BRIDGE_HYPE}")
        before = rpc_balance(ADDR)
        print(f"plan: sendAsset {BRIDGE_HYPE} HYPE -> {SYS_HYPE} (Core -> HyperEVM)")
        r = exch.send_asset(SYS_HYPE, "spot", "spot", HYPE_TOK, BRIDGE_HYPE)
        print("sendAsset:", r if isinstance(r, dict) else r)
        ok = (r.get("status") == "ok") if isinstance(r, dict) else False
        if not ok:
            raise SystemExit(f"sendAsset not ok — inspect response above, nothing changed if rejected: {str(r)[:300]}")
        for _ in range(20):
            time.sleep(3)
            now = rpc_balance(ADDR)
            if now > before:
                print(f"EVM HYPE landed: {before:.6f} -> {now:.6f}")
                break
        else:
            print(f"not yet visible on EVM (still {rpc_balance(ADDR):.6f}) — check again shortly")
        print(f"after bridge: spot HYPE {spot_bal('HYPE'):.6f}")

    if USDC_EVM:
        if not SEND:
            raise SystemExit("refusing: USDC_EVM requires MAINNET_OK=1")
        spot_usdc = spot_bal("USDC")
        if spot_usdc < USDC_AMT:
            st = info.user_state(ADDR)
            withdrawable = float(st["withdrawable"])
            move = round(USDC_AMT - spot_usdc + 0.05, 2)
            if move > withdrawable:
                raise SystemExit(f"need ${move:.2f} but only ${withdrawable:.2f} withdrawable")
            r = exch.usd_class_transfer(move, False)
            print(f"perp->spot ${move:.2f}:", r.get("status"))
        r = exch.send_asset(SYS_USDC, "spot", "spot", USDC_TOK, USDC_AMT)
        print(f"sendAsset {USDC_AMT} USDC -> {SYS_USDC}:", r if isinstance(r, dict) else r)
        if not (isinstance(r, dict) and r.get("status") == "ok"):
            raise SystemExit("USDC sendAsset not ok — rejected, nothing moved")
        for _ in range(20):
            time.sleep(3)
            ev = requests.post(EVM_RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                "params": [{"to": USDC_EVM_TOKEN,
                            "data": "0x70a08231" + ADDR[2:].lower().rjust(64, "0")}, "latest"]}, timeout=15)
            res = ev.json().get("result")
            got = int(res, 16) / 1e6 if res and res != "0x" else 0
            print(f"EVM USDC: {got:.6f}")
            if got > 0:
                break
        print(f"after USDC bridge: spot USDC {spot_bal('USDC'):.6f}")

    receipt = {
        "at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
        "chain": "hyperliquid-mainnet",
        "account": ADDR,
        "evm_hype": rpc_balance(ADDR),
        "ops_evm_hype": rpc_balance(OPS_EOA),
        "spot_hype": spot_bal("HYPE"),
        "spot_usdc": spot_bal("USDC"),
        "pair": pair,
    }
    with open(RECEIPT, "w") as fh:
        json.dump(receipt, fh, indent=1)
    os.chmod(RECEIPT, 0o600)
    print("receipt ->", RECEIPT)


if __name__ == "__main__":
    main()
