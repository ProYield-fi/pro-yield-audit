#!/usr/bin/env python3
"""vault_keeper — chain guard module (repo-canonical).

The OPS keeper lives at /home/user/yield_scout/vault_keeper.py (cron-driven);
this repo-root module is the canonical, importable guard the battery's
chainid_guard_test.js exercises ("never mainnet enforced by CODE, not
convention"). Keep this function byte-identical in both places — a drift here
is exactly the class of bug the guard exists to prevent (found drifting
2026-09-25 by the isolated audit round 1: the ops copy had lost the guard).

Rules (money-mover discipline):
  - Reads the RPC the hardhat network would resolve (HYPEREVM_RPC_URL).
  - REFUSES an implicit localhost RPC unless ALLOW_IMPLICIT_RPC=1 (a local
    anvil spoofs chain-id 998 — chain-id alone cannot prove identity).
  - REFUSES any chain not in the allowed set (default {998} — ops chain).
  - Fail-closed: unreadable chain-id => refuse.
"""
import json as _json
import os as _os
import urllib.request as _urllib

ALLOWED_CHAINS = {998}
DEFAULT_LOCAL_RPC = "http://localhost:8545"


def check_chain(allowed=None, rpc=None, timeout=8):
    """Return True only if the resolved RPC serves an allowed chain id."""
    if allowed is None:
        allowed = ALLOWED_CHAINS
    if rpc is None:
        rpc = _os.environ.get("HYPEREVM_RPC_URL")
        if not rpc:
            if _os.environ.get("ALLOW_IMPLICIT_RPC") == "1":
                rpc = DEFAULT_LOCAL_RPC
            else:
                print("REFUSED: HYPEREVM_RPC_URL unset (implicit localhost would be used)")
                return False
    try:
        req = _urllib.Request(
            rpc,
            data=_json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}
            ).encode(),
            headers={"Content-Type": "application/json"},
        )
        chain = int(_json.loads(_urllib.urlopen(req, timeout=timeout).read())["result"], 16)
    except Exception as e:
        print(f"REFUSED: chain-id read failed ({e})")
        return False
    if chain not in allowed:
        print(f"REFUSED: chain {chain} not in allowed set {sorted(allowed)}")
        return False
    print(f"chain guard OK: chain {chain} via {rpc}")
    return True


if __name__ == "__main__":
    import sys
    sys.exit(0 if check_chain() else 2)
