#!/usr/bin/env python3
"""First REAL delta-neutral trade on Hyperliquid MAINNET — the $10 live test.

Wallet: the fresh on-ramp test wallet (~/.proyield/onramp_usertest.json) holding
the on-ramped USDC on HyperCore. Pair: spot @151 UETH/USDC + ETH perp (both
szDecimals 4; mainnet funding ~11%/yr).

Guards: nothing is SENT unless MAINNET_OK=1 (reads/sizing plan otherwise).
Never runs against testnet APIs. CLOSE=1 unwinds both legs (mainnet books are
deep, so the reduce-only path fills — unlike thin testnet books).

Writes a fill receipt to ~/.proyield/mainnet_trade_receipt.json (0600).
"""
import json
import os
import sys

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info

API = "https://api.hyperliquid.xyz"
assert "testnet" not in API, "refusing: this script is for MAINNET"

SPOT_PAIR = os.environ.get("SPOT_PAIR", "@151")  # UETH/USDC
PERP = os.environ.get("PERP", "ETH")
SPOT_USD = float(os.environ.get("SPOT_USD", "10.6"))
SEND = os.environ.get("MAINNET_OK") == "1"
CLOSE = os.environ.get("CLOSE", "") not in ("", "0", "false")

WALLET = os.path.expanduser("~/.proyield/onramp_usertest.json")
RECEIPT = os.path.expanduser("~/.proyield/mainnet_trade_receipt.json")

_j = json.load(open(WALLET))
acct = Account.from_key(_j["private_key"])
ADDR = acct.address

info = Info(API, skip_ws=True, timeout=15.0)
exch = Exchange(acct, API, account_address=ADDR, timeout=15.0)
IOC = {"limit": {"tif": "Ioc"}}


def spot_bal(coin):
    st = info.spot_user_state(ADDR)
    for b in st.get("balances", []):
        if b["coin"] == coin:
            return float(b["total"])
    return 0.0


def perp_state():
    st = info.user_state(ADDR)
    szi = 0.0
    for p in st.get("assetPositions", []):
        if p["position"]["coin"] == PERP:
            szi = float(p["position"]["szi"])
    return float(st["withdrawable"]), szi


def best(coin):
    book = info.l2_snapshot(coin)
    bid = float(book["levels"][0][0]["px"]) if book["levels"][0] else None
    ask = float(book["levels"][1][0]["px"]) if book["levels"][1] else None
    return bid, ask


def mid(coin):
    px = info.all_mids().get(coin)
    return float(px) if px else None


def last_fill_px(coin):
    for f in info.user_fills(ADDR):
        if f.get("coin") == coin:
            return float(f["px"])
    return None


def round_px(px, sz_dec):
    sig = float(f"{px:.5g}")
    return float(f"{sig:.{max(0, 6 - sz_dec)}f}")


def ref_px(coin, side, sz_dec):
    bid, ask = best(coin)
    if side == "buy":
        px = ask * 1.001 if ask else (mid(coin) or last_fill_px(coin) or 0) * 1.01
    else:
        px = bid * 0.999 if bid else (mid(coin) or last_fill_px(coin) or 0) * 0.99
    if px <= 0:
        raise SystemExit(f"no price reference for {coin}")
    return round_px(px, sz_dec)


def sz_decimals(coin):
    for u in info.meta()["universe"]:
        if u["name"] == coin:
            return int(u["szDecimals"])
    raise SystemExit(f"no perp meta for {coin}")


def spot_sz_decimals(pair):
    sm = info.spot_meta()
    base = next(u["tokens"][0] for u in sm["universe"] if u["name"] == pair)
    for t in sm["tokens"]:
        if t["index"] == base:
            return int(t["szDecimals"])
    raise SystemExit(f"no spot meta for {pair}")


def statuses(r):
    return r.get("response", {}).get("data", {}).get("statuses")


def fills_of(coin):
    return [f for f in info.user_fills(ADDR) if f.get("coin") == coin and f.get("dir", "").startswith(("Buy", "Sell", "Open", "Close"))]


def main():
    perp_usd, szi = perp_state()
    hold = spot_bal("UETH")
    print(f"account {ADDR}")
    print(f"before: perp ${perp_usd:.2f} · spot UETH {hold} · perp szi {szi}")

    if CLOSE:
        if not SEND:
            raise SystemExit("refusing: CLOSE requires MAINNET_OK=1")
        if szi < 0:
            sz = round(abs(szi), sz_decimals(PERP))
            r = exch.order(PERP, True, sz, ref_px(PERP, "buy", sz_decimals(PERP)), IOC, reduce_only=True)
            print("perp buy-back:", statuses(r))
        if hold > 0:
            sz = round(hold, spot_sz_decimals(SPOT_PAIR))
            if sz > 0:
                r = exch.order(SPOT_PAIR, False, sz, ref_px(SPOT_PAIR, "sell", spot_sz_decimals(SPOT_PAIR)), IOC)
                print("spot sell:", statuses(r))
        perp_usd, szi = perp_state()
        print(f"after close: perp ${perp_usd:.2f} · spot {spot_bal('UETH')} · szi {szi}")
        return

    if szi != 0 or hold > 0:
        print("already positioned — nothing to do (CLOSE=1 to unwind)")
        return

    szs = spot_sz_decimals(SPOT_PAIR)
    buy_px = ref_px(SPOT_PAIR, "buy", szs)
    qty = round(SPOT_USD / buy_px, szs)
    print(f"plan: spot BUY {qty} UETH @ ~{buy_px} (${qty*buy_px:.2f}) + perp SHORT same qty")

    if not SEND:
        print("DRY (reads only). Re-run with MAINNET_OK=1 to execute.")
        return

    # 0. referral — attach the ProYield code once, on the fresh account (product flow)
    try:
        r = exch.set_referrer("PROYIELD")
        print("set_referrer PROYIELD:", r if isinstance(r, dict) else r)
    except Exception as e:
        print("set_referrer skipped:", str(e)[:140])

    # 1. fund the spot side
    need = qty * buy_px * 1.05 + 1
    spot_usdc = spot_bal("USDC")
    if spot_usdc < need:
        mv = min(need - spot_usdc, perp_usd - 5.0)
        r = exch.usd_class_transfer(round(mv, 6), False)
        print(f"transfer perp->spot ${mv:.2f}:", r.get("status"))
        spot_usdc = spot_bal("USDC")

    # 2. spot BUY
    r = exch.order(SPOT_PAIR, True, qty, buy_px, IOC)
    print(f"spot BUY {qty} UETH @ ~{buy_px}:", statuses(r))
    recv = spot_bal("UETH")

    # 3. perp SHORT — qty matched to what was actually received (spot fees are in-kind)
    szp = max(round(recv, sz_decimals(PERP)), 0)
    fill_px = ref_px(PERP, "sell", sz_decimals(PERP))
    r2 = exch.order(PERP, False, szp, fill_px, IOC)
    print(f"perp SHORT {szp} {PERP} @ ~{fill_px}:", statuses(r2))

    # 4. verify + receipt
    perp_usd, szi = perp_state()
    hold = spot_bal("UETH")
    net = hold + szi
    print(f"after:  perp ${perp_usd:.2f} · spot UETH {hold} · szi {szi}")
    print(f"DELTA CHECK: {hold} + {szi} = net {net:.6f} UETH ({'~NEUTRAL OK' if abs(net) < 0.0005 else 'CHECK'})")
    receipt = {
        "at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
        "chain": "hyperliquid-mainnet",
        "account": ADDR,
        "spot_pair": SPOT_PAIR,
        "perp": PERP,
        "spot_qty": hold,
        "perp_szi": szi,
        "net_delta": net,
        "perp_withdrawable": perp_usd,
        "recent_fills": [
            {k: f.get(k) for k in ("coin", "dir", "px", "sz", "fee", "oid", "time")}
            for f in info.user_fills(ADDR)[:6]
        ],
    }
    with open(RECEIPT, "w") as fh:
        json.dump(receipt, fh, indent=1)
    os.chmod(RECEIPT, 0o600)
    print("receipt ->", RECEIPT)


if __name__ == "__main__":
    main()
