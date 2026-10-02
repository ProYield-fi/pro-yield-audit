# Round 2 — review scope (2026-10-02)

## What this snapshot contains

`contracts/` and `test/forge/` are synced from the dev repo's `main` at the
state of this commit. This is the code the **next contract deploy** ships —
reviewing it reviews the delta the guarded beta is waiting on.

## The delta since round 1 (2026-09-30)

| Area | Change |
|---|---|
| Vault | Arrival-bound credit: `creditYield` can only credit `uncreditedArrivals()` (real USDC physically present, never re-counted idle) — idempotent by construction |
| Vault | F-14: harvests emit the honest **net** (`HarvestBooked(net, fee)`) alongside the gross `Harvest`; the dashboard reads the net |
| DN strategy | `hedgeTransferOut` per-action USDC bound (community finding, Firlinata — issue #2): live-spot-mark valuation, `DNCore__Cap` over `maxActionUsd6`, refuses through a price blackout. Regression: `test/forge/DNCoreHedgeBound.t.sol` (4/4) |
| DN strategy | `totalAssets()` counts the Core spot hedge + (pending r3 item: plain Core spot cash — operator-side fix shipped in the feed writer meanwhile) |
| Morpho | Buffer sizing fix |
| FeeDistributor | Cumulative accounting fix |
| PTSleeve | Domain-0 (Ethereum lane) sentinel fix |
| F-1 | Arb executor ownership fix |

## New off-chain surface (requesting review)

One-signature auto-earn (Layer 2, live on the site but passive until the first
user signs):

- `scripts/autoearn_sweep.js` — the sweep keeper: submits stored EIP-2612
  permits, then `transferFrom` + `vault.deposit(amount, receiver=user)`.
  DRY by default. Amount = min(balance, allowance, remaining per-user cap).
- Web `/api/autoearn` + `AutoEarnCard.tsx` — stores the signed permit (the
  spender is FIXED in code = the ops EOA; the signature is verified by the
  chain, not the API — a junk row fails at sweep time and is logged).
- Threat model: a leaked permit signature can only ever pull the signer's own
  wallet into the signer's own vault position, within the signer's own cap,
  by the fixed spender. The sweep pays gas from the ops EOA.

## Deploy status

The guarded beta runs the 2026-09-26 rev. This snapshot ships with the next
gated deploy (r3). Cap raises stay gated on external review regardless.

## Known remaining items (disclosed)

- DN `totalAssets()` still omits plain Core spot USDC cash on-chain (the
  $12.99 read-blindness found 2026-10-02); the operator-side feed correction
  is live, the contract fix is in the r3 queue.
- The recycler script is testnet-locked by design; mainnet fee splits run via
  the 2-of-3 Safe (`safe_exec_mainnet.js`), dry-verified 2026-10-02.
