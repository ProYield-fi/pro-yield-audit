#!/usr/bin/env python3
"""First LIVE exercise of the delta-neutral sleeve's venue path — Hyperliquid TESTNET only.

What it does (the same action sequence the on-chain DN strategy must emit):
  1. perp USDC -> spot USDC (usd_class_transfer)
  2. BUY spot  (HYPE @1035 — the only testnet spot pair with a live book)
  3. SHORT perp (HYPE), same coin quantity -> delta ~ 0
  4. verify both legs on-chain, print the summary

  CLOSE=1 unwinds: reduce-only perp buy-back, then spot sell.

Guard: hard-fails unless the API URL is the testnet endpoint. NEVER prints key material.
Key resolution mirrors hardhat.config.js: env DEPLOYER_PRIVATE_KEY -> local key file.
"""
import os
import sys

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info

API = "https://api.hyperliquid-testnet.xyz"  # TESTNET
assert "testnet" in API, "refusing: not the testnet endpoint"

KEY_FILE = "/home/user/.hermes/vault_keys/hyperevm_testnet.deployer"
pk = os.environ.get("DEPLOYER_PRIVATE_KEY") or open(KEY_FILE).read().strip()
acct = Account.from_key(pk)
ADDR = acct.address

SPOT_PAIR = os.environ.get("SPOT_PAIR", "@1035")   # HYPE/USDC (testnet)
PERP_COIN = os.environ.get("PERP_COIN", "HYPE")
SPOT_USD = float(os.environ.get("SPOT_USD", "11"))
CLOSE = os.environ.get("CLOSE", "") not in ("", "0", "false")

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
        pos = p["position"]
        if pos["coin"] == PERP_COIN:
            szi = float(pos["szi"])
    return float(st["withdrawable"]), szi


def best(coin):
    """Book snapshot; either side may be empty on thin testnet books -> None."""
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


def ref_px(coin, side, sz_dec):
    """Crossing price with book -> mid -> last-fill fallback chain."""
    bid, ask = best(coin)
    if side == "buy":
        px = ask * 1.01 if ask else (mid(coin) or last_fill_px(coin) or 0) * 1.03
    else:
        px = bid * 0.99 if bid else (mid(coin) or last_fill_px(coin) or 0) * 0.97
    if px <= 0:
        raise SystemExit(f"no price reference for {coin}")
    return round_px(px, sz_dec)


def sz_decimals(coin):
    md = info.meta()
    for u in md["universe"]:
        if u["name"] == coin:
            return int(u["szDecimals"])
    raise SystemExit(f"no perp meta for {coin}")


def spot_sz_decimals(pair):
    sm = info.spot_meta()
    base_tok = next(u["tokens"][0] for u in sm["universe"] if u["name"] == pair)
    for t in sm["tokens"]:
        if t["index"] == base_tok:
            return int(t["szDecimals"])
    raise SystemExit(f"no spot meta for {pair}")


def round_px(px, sz_dec):
    """HL price rule: max 5 significant figures, max (6 - szDecimals) decimals."""
    sig = float(f"{px:.5g}")
    return float(f"{sig:.{max(0, 6 - sz_dec)}f}")


def main():
    perp_usd, szi = perp_state()
    hold = spot_bal(PERP_COIN)
    print(f"account {ADDR}")
    print(f"before: perp/withdrawable ${perp_usd:.2f} · spot {PERP_COIN} {hold} · perp szi {szi}")

    if CLOSE:
        if szi < 0:
            sz = round(abs(szi), sz_decimals(PERP_COIN))
            if sz > 0:
                r = exch.order(PERP_COIN, True, sz, ref_px(PERP_COIN, "buy", sz_decimals(PERP_COIN)), IOC, reduce_only=True)
                print("perp buy-back (reduce-only):", r.get("response", {}).get("data", {}).get("statuses"))
        if hold > 0:
            sz = round(hold, spot_sz_decimals(SPOT_PAIR))
            if sz > 0:
                r = exch.order(SPOT_PAIR, False, sz, ref_px(SPOT_PAIR, "sell", spot_sz_decimals(SPOT_PAIR)), IOC)
                print("spot sell:", r.get("response", {}).get("data", {}).get("statuses"))
        perp_usd, szi = perp_state()
        print(f"after close: perp ${perp_usd:.2f} · spot {hold}->{spot_bal(PERP_COIN)} · szi {szi}")
        return

    if szi != 0 or hold > 0:
        print("already positioned — nothing to do (CLOSE=1 to unwind)")
        return

    # 1. fund the spot side if needed (keep >=$5 on the perp side)
    ask_spot = ref_px(SPOT_PAIR, "buy", spot_sz_decimals(SPOT_PAIR)) / 1.01
    need = SPOT_USD * 1.05
    spot_usdc = spot_bal("USDC")
    if spot_usdc < need:
        mv = min(need - spot_usdc, perp_usd - 5.0)
        if mv <= 1:
            raise SystemExit("not enough perp USDC to fund the spot leg")
        r = exch.usd_class_transfer(round(mv, 6), False)
        print(f"transfer perp->spot ${mv:.2f}:", r.get("status"))
        spot_usdc = spot_bal("USDC")

    # 2. BUY spot (marketable IOC crossing the ask)
    szs = spot_sz_decimals(SPOT_PAIR)
    buy_px = ref_px(SPOT_PAIR, "buy", szs)
    qty = round(SPOT_USD / buy_px, szs)
    if qty <= 0:
        raise SystemExit("spot qty rounds to zero")
    r = exch.order(SPOT_PAIR, True, qty, buy_px, IOC)
    print(f"spot BUY {qty} {PERP_COIN} @ ~{ask_spot}:", r.get("response", {}).get("data", {}).get("statuses"))

    # 3. SHORT perp, same coin quantity -> delta ~ 0
    qty_p = round(qty, sz_decimals(PERP_COIN))
    short_px = ref_px(PERP_COIN, "sell", sz_decimals(PERP_COIN))
    r = exch.order(PERP_COIN, False, qty_p, short_px, IOC)
    print(f"perp SHORT {qty_p} {PERP_COIN} @ ~{short_px}:", r.get("response", {}).get("data", {}).get("statuses"))

    # 4. verify
    perp_usd, szi = perp_state()
    hold = spot_bal(PERP_COIN)
    print(f"after:  perp/withdrawable ${perp_usd:.2f} · spot {PERP_COIN} {hold} · perp szi {szi}")
    net = hold + szi  # same coin, opposite signs -> ~0 when delta-neutral
    print(f"DELTA CHECK: spot {hold} + perp {szi} = net {net} {PERP_COIN} "
          f"({'~NEUTRAL OK' if abs(net) < 0.02 else 'MISMATCH'})")


if __name__ == "__main__":
    main()