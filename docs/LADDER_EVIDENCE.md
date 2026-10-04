# Ladder evidence — S3a live pause-path drill (2026-10-04)

The S3a gate required the pause path to be drilled for real on mainnet
(suite-tested only until now). DRILLED 2026-10-04 ~04:31–04:32 UTC, watched,
reversible, zero money movement.

## Chain evidence (mainnet 999, vault `0x8954…D1C1`)

| Step | Tx / check | Result |
|---|---|---|
| Owner Safe pauses deposits | `setDepositsPaused(true)` tx `0xfb105afd391fa2c13a1290df901b81c2022f8ac3e136a1d5dc21e8ae1f03a999` | `depositsPaused=true` verified on-chain |
| Deposit blocked | `eth_call` `deposit(1000)` from a fresh address | reverts exactly `"ProYieldVault: deposits paused"` |
| Withdrawals stay open (product promise) | `eth_call` `withdraw(1e6 shares)` + `withdrawUpTo(~90% of idle)` from the owner wallet | both SUCCESS — no pause gate on the withdrawal path |
| Books stable during pause | `totalAssets` / `totalShares` before vs during vs after | identical: 158,692,010 / 154,362,850 (no drift, no loss) |
| Owner Safe restores | `setDepositsPaused(false)` tx `0xd6d13f21481c49915a3f55df8804b97c97fe63c6403dfd447235045942e5d41b` | `depositsPaused=false` verified on-chain |
| Deposit path re-opened | `eth_call` `deposit(1000)` post-restore | reverts on ERC20 allowance (not pause) — gate fully lifted |

Notes: the larger simulated withdraw (77 shares) reverted for a LIQUIDITY
reason (idle USDC ~$15.87 vs PT sleeves not yet matured), not a pause gate —
documented as the known async-recall shape, not a drill failure. Drill runner:
`hypervault/scripts/pause_drill.sh` (read-only preflight by default,
interactive DRILL confirm, chainid 999 gate, evidence marker →
`.proyield/pause_drill.state.done.*`). Full log:
`~/.hermes/logs/pause_drill.log`.

## Ladder position after this drill

- **S3a evidence COMPLETE**: insurance first-loss live ✓ + live pause-path
  drill ✓ (this record). Cap raise to S3a levels ($1K/user, $10K TVL) is a
  one-Safe-tx `setCaps` decision for the owner.
- S3b clock: daily attestations, 10/30 on 2026-10-04 → 30 by ~Oct 23.
- S4/T1 audit gate after S3a/S3b headroom.