#!/usr/bin/env python3
"""Mint a Coinbase Onramp session for a real test buy — through the PRODUCTION
site endpoint (pyd.fi/api/coinbase-session), i.e. the exact flow a new user hits.

- Creates (once) a fresh "new user" wallet, key stored 0600 at
  ~/.proyield/onramp_usertest.json. NEVER prints key material.
- Requests the session token for that address on the given chain.
- Opens the widget URL straight in the desktop browser (xdg-open) — the token is
  single-use + ~5 min TTL, and must never be pasted into chat (the desktop
  preview pane would consume it). The URL is also saved 0600 for manual retry.

Usage: python3 scripts/onramp_test_buy.py [--chain arbitrum] [--no-open]
"""
import json
import os
import subprocess
import sys
import urllib.request

WALLET = os.path.expanduser("~/.proyield/onramp_usertest.json")
URL_CACHE = os.path.expanduser("~/.proyield/onramp_last_url.txt")
SITE = "https://pyd.fi/api/coinbase-session"


def load_or_create_wallet():
    if os.path.exists(WALLET):
        j = json.load(open(WALLET))
        return j["address"]
    from eth_account import Account

    acct = Account.create()
    os.makedirs(os.path.dirname(WALLET), mode=0o700, exist_ok=True)
    with open(WALLET, "w") as f:
        json.dump(
            {
                "label": "onramp test user wallet (fresh, 2026-09)",
                "note": "test-buy destination; key stays on this box (0600)",
                "address": acct.address,
                "private_key": acct.key.hex(),
            },
            f,
            indent=1,
        )
    os.chmod(WALLET, 0o600)
    return acct.address


def main():
    chain = "arbitrum"
    if "--chain" in sys.argv:
        chain = sys.argv[sys.argv.index("--chain") + 1]
    no_open = "--no-open" in sys.argv

    address = load_or_create_wallet()
    print("new-user wallet:", address)

    body = json.dumps({"addresses": [{"address": address, "blockchains": [chain]}]}).encode()
    req = urllib.request.Request(
        SITE,
        data=body,
        headers={
            "Content-Type": "application/json",
            # CF WAF blocks scripted UAs (403 for Python-urllib) — present a normal one.
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    token = data.get("token")
    if not token:
        print("mint FAILED:", json.dumps(data)[:300])
        sys.exit(1)

    url = f"https://pay.coinbase.com/buy/select-asset?sessionToken={token}"
    with open(URL_CACHE, "w") as f:
        f.write(url)
    os.chmod(URL_CACHE, 0o600)
    print(f"session minted via prod endpoint ✓ (token len {len(token)}; url cached 0600, not echoed)")

    if no_open:
        print("--no-open: open it yourself within ~5 min:", URL_CACHE)
        return
    rc = subprocess.run(["xdg-open", url], capture_output=True).returncode
    if rc != 0:
        print("xdg-open FAILED — retrieve the url from", URL_CACHE, "and open within ~5 min")
        sys.exit(2)
    print("opened in the default browser ✓ — complete the buy there (single-use token)")


if __name__ == "__main__":
    main()