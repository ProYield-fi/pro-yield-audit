# ProYield Vault — Community Audit Scope

> Status: **pre-mainnet**. The audited mainnet deployment is the launch gate;
> this document is the package auditors and community reviewers should read
> first. Last updated: 2026-09-20.

## 1. What is in scope

Primary (holds or routes user funds):

| Contract | Lines | Role |
|---|---|---|
| `contracts/ProYieldVault.sol` | 245 | ERC-4626-style vault: deposits, withdrawals, allocation, harvest, share price |
| `contracts/BaseStrategy.sol` | 99 | Strategy base: recall, harvest booking, keeper/vault auth |
| `contracts/DNCoreStrategy.sol` | 199 | Delta-neutral sleeve: honest Core accounting + vault wiring |
| `contracts/adapters/DNCoreBase.sol` | ~290 | Shared HyperCore execution: CoreWriter sends, read precompiles, gates |
| `contracts/adapters/DNCoreAdapter.sol` | 77 | Standalone DN execution wrapper (same surface, no vault) |
| `contracts/FeeDistributor.sol` | 60 | Fee routing (60/20/20 recycle policy) |
| `contracts/PYDStaking.sol` | 161 | PYD reward streaming (Synthetix-style) |
| `contracts/PYDToken.sol` | 39 | Fixed-supply PYD, transfer caps |

Legacy/secondary (deployed but pending migration review):
`DeltaNeutralStrategy.sol`, `SkyStrategy.sol`, `MorphoStrategy.sol`,
`PendleStrategy.sol` — reentrancy-hardened 2026-09-18 (23 findings fixed).

**Out of scope:** `contracts/mocks/*` (test-only), `contracts/mocks/DecodeVerifier.sol`
(read-verification harness), HyperCore itself (Hyperliquid's system), everything in
`scripts/` (keepers/tests are off-chain liveness, they hold no funds).

## 2. Architecture in one page

```
users → ProYieldVault (USDC) → allocate() → strategies
                                  │            ├─ Sky/Morpho/Pendle (lending, EVM)
                                  │            └─ DNCoreStrategy (HyperCore via CoreWriter)
                                  │                 ├─ bridge USDC in/out (CoreDepositWallet / sendAsset)
                                  │                 ├─ class-transfer → perp margin
                                  │                 ├─ short hedge (limit orders)
                                  │                 └─ syncCore() ← read precompiles (0x80f/0x813/…)
                                  └─ harvest() ← strategies sweep realized profit
        FeeDistributor ← vault fees → 60% depositors / 20% insurance / 20% treasury
        PYDStaking ← reward streams funded from the recycle loop
```

Target chain: **HyperEVM mainnet (chainId 999)**; test runs on local anvil 8545
(chainId 998) with mocked system contracts.

## 3. Core invariants (what we believe holds — try to break it)

1. **Principal is never counted as yield.** `DNCoreStrategy.corePrincipal6`
   tracks net USDC bridged to Core; `bridgeBackToEvm` splits principal-first
   at freshly-synced equity; equity below principal realizes NOTHING. No
   path books principal as profit.
2. **Share price cannot be inflated by a first depositor.** `SHARE_OFFSET = 1e3`
   virtual offset (OZ ERC4626 pattern); dust guard rejects zero-share deposits.
3. **Liabilities stay in sync with assets.** Withdrawals/emergency exits shrink
   `_totalAssets` by exactly what left (T-012 follow-up).
4. **Checks-effects-interactions everywhere.** Shares minted BEFORE
   `transferFrom`; every state update precedes every external call; events emit
   before external calls (tx atomicity keeps ordering equivalent).
5. **`nonReentrant` on every mutating entry point** — all strategies, vault,
   FD, staking, DN base.
6. **Vault withdrawals are honored by real assets.** `recall` is vault-only and
   capped at balance; the vault's reserve + each strategy's buffer keep
   liquidity ahead of claims. A withdrawal that cannot be backed reverts.
7. **No custody path.** The vault moves funds only by owner/keeper policy;
   strategies move only by keeper policy; CoreWriter actions are sent by the
   contracts AS THEMSELVES (no agent wallet, no delegated signer).
8. **Silent-drop prevention.** CoreWriter drops actions from accounts without a
   Core account, and applies actions after a delay — every action is gated on
   the 0x810 read, and keepers verify-after-delay (contract-level gate:
   `coreAccountRequired`).
9. **Fixed supply.** PYD has no mint path; staking rewards are transferred, not
   minted.
10. **Staking rewards never exceed the funded pool.** `PYDStaking` holds
   `balance ≥ totalSupply` at all times; claims are bounded by
   `balance − totalSupply` (funded minus already claimed); accrual stops at
   `periodFinish`. A rollover bug (a keeper top-up after a lapsed window with
   no user interaction double-banked the tail — rewards could be paid out of
   staked principal) was FOUND by the forge invariant suite and fixed;
   `test_rollover_without_interaction_no_double_accrual` pins it.
11. **Vault solvency + share-price floor.** The backing (vault plus every
   strategy's USDC) is ≥ `totalAssets` at all times, and
   `totalAssets ≥ totalShares` — the share price never falls below 1 except
   through the explicit `emergencyWithdraw()` loss path.

Items 2, 3, 5, 10, 11 have executable counterparts in `test/forge/`:
`Vault.invariants.t.sol` — `invariant_solvency`,
`invariant_price_never_below_one`, `invariant_user_shares_sum_to_total`,
`invariant_no_zero_valued_depositor`, `invariant_fd_bookkeeping`, plus
adversarial cases (donation attack neutralized by the offset, emergency-exit
dilution semantics, dust deposits, strategy recall, paused-strategy
containment, one broken strategy never bricks harvest).
`PYD.invariants.t.sol` — `invariant_principal_intact`,
`invariant_claims_bounded_by_pool`, `invariant_accrual_bounded_by_pool`,
`invariant_stake_sum_to_total`, plus tier boundaries, budget-capped claims,
zero-share/below-tier stakers, no accrual past the window, mid-period top-up,
and the rollover regression above.
`Vault.differential.t.sol` — an independent integer model (written from the
spec, no vault code) runs the same randomized op sequence as the contract
(deposit/withdraw/yield/harvest/recycle/warp; 1200 deterministic ops + fuzzed
seeds) and asserts EXACT equality after every op: totalAssets, totalShares,
per-user shares, cash conservation (vault + strategies == modeled assets +
unswept yield) and fee deltas, plus the share-price floor.

## 4. Threat model highlights

- **Reentrancy**: external calls are intrinsic to the design (ETH forwarding,
  ERC-4626 interactions, CoreDepositWallet deposits). All guarded; Slither's
  residual flags are the documented-benign class (see §6).
- **Share-price manipulation**: deposit → inflate → donate attacks blunted by
  SHARE_OFFSET; the vault tracks assets/shares atomically.
- **Keeper compromise**: keepers can execute the policy set (orders within
  caps, bridges within caps) but cannot change caps, fees, or ownership.
  Worst case is bounded by `maxActionUsd6` per action. Owner is an EOA today
  (multisig deferred — flagged).
- **Oracle/precompile trust**: reads come from HyperCore precompiles (verified
  against mainnet — `scripts/dn_realread_check.js`, 15/15). The read layer's
  encoding was validated against LIVE mainnet bytes through the contract's own
  struct decodes.
- **CoreWriter semantics**: actions are fire-and-forget; the strategy never
  assumes an immediate post-send read reflects the action. Async recall design:
  buffer covers ordinary recalls; larger ones need keeper unwind first.
- **Size limits**: EIP-170 (24,576 B) enforced on HyperEVM. Strategy is
  21,585 B, adapter 14,344 B (custom errors keep headroom).
- **Fee/first-depositor on harvest**: net profit raises share price pro-rata;
  fees leave accounting (never double-counted).

## 5. Test evidence (all green at last run)

| Suite | What it proves | Result |
|---|---|---|
| `scripts/run_battery.sh` | Every suite below on a FRESH isolated anvil (cold-start deploy, per-suite exit codes, disposable chain) | 7/7 suites |
| `scripts/integration_tests.js` | Full protocol: deposit→harvest→withdraw, fee→staker loop, token invariants | 120/120 |
| `scripts/dn_strategy_tests.js` | Vault DN money loop: allocate→bridge→sync→split→harvest→withdraw; loss case | 28/28 |
| `scripts/dn_adapter_tests.js` | Byte-exact CoreWriter encodings + all gates | 26/26 |
| `scripts/dn_realread_check.js` | Read layer vs LIVE mainnet precompiles (read-only, manual) | 15/15 |
| `scripts/dn_realread_replay.js` | Read-layer decoders (JS + real Solidity structs) vs FROZEN real mainnet bytes at block 46644202 — offline, in the battery + CI (`dn_realread_capture.js` refreshes the fixture) | 13/13 |
| `scripts/web_smoke.sh` + `pro-yield-web/web-smoke-local.mjs` | Web-app data path vs local chain: `vault_status.json` → rendered `/account` + `/transparency` (marker + TVL + share price + no console/page/request errors), with a real customer deposit→withdraw round-trip visibly updating the UI | PASS ($100k → $105k → $100k) |
| `scripts/dn_keeper_dryrun_test.js` | Keeper sizing policy end-to-end (subprocess) | 8/8 |
| `scripts/dn_keeper_unwind_test.js` | Keeper unwind policy end-to-end (subprocess) | 6/6 |
| `scripts/pyd_demand_tests.js` | PYD demand layer: discount tiers/accrual/claims + funder conversion → real staking stream + **K: mutation-survivor regression** (exact-value kills for the campaign survivors) | 29/29 |
| `scripts/test_all.js` | Unit suite | 16/16 |
| `forge test` (`test/forge/*.t.sol`) | Stateful invariants + adversarial/edge cases (mapping in §3) + independent-model differential sim (1200 ops, exact-equality after every op) + mutation-survivor coverage (`Vault.coverage.t.sol`, `PYD.coverage.t.sol`) | 37 tests + 10 invariants |
| Slither (vs `security_baseline.json`) | 0 critical, no NEW findings (22 accepted, each justified) | clean |
| CI (`.github/workflows/ci.yml`) | battery + slither + forge on a fresh runner, every push/PR | green |
| `slither-mutate` (RR,ROR,LOR,AOR,UOR,LIR,SBR,ASOR) | Mutation kill-rate on core contracts — tests must KILL injected bugs | running |

**Mutation triage (slither-mutate campaigns, 2026-09-23).** Campaign 1 (ProYieldVault, test-cmd = battery): every survivor was classified — real gaps (`name()`, the zero-supply `_toShares/_toAssets` branches, the `_feeOn` fee==0 branch, the `harvestStrategy` success path + message-asserted reverts, and the recall round-up math) are now covered by `test/forge/Vault.coverage.t.sol`. Core insight: failure-path assertions cannot kill `require/body ==> revert()` mutants — the mutant still reverts (same observable) — only success-path + `expectRevert(message)` kill them. One equivalent mutant documented: `strategy != address(0)` in `harvestStrategy` is unreachable (the `strategies[]` check fires first for 0x0). Campaign 2 (PYDStaking + PYDFeeDiscount, test-cmd = pyd suite + forge PYD invariants): the first pass exposed loose assertions (`claimed > 0` cannot kill a `-=`→`+=` flip) and missing success paths (setTiers/unstake/exit/claim exact values) — closed by the K regression section in `scripts/pyd_demand_tests.js` (10 exact-value checks). **Re-run complete (kill set = full battery + forge PYD invariants): 403 caught / 114 uncaught / 145 compile-fail — 82.7% of compile-able mutants killed.** Survivor classification: (a) *equivalent mutants* — unsigned `== 0 → <= 0`/`< 0`, `i < len → i != len`, `i++ → ++i`, `constant → immutable`/widening casts, `>=` flips differing only at exact-equality boundaries, emit-only and staticcall-fallback paths (no observable difference — not killable by construction); (b) *EOA-only test artifact* — the `msg.sender → tx.origin` family (differs only when a contract is the caller) — killed by `test_contract_callers` in `test/forge/PYD.coverage.t.sol`; (c) *real gaps, now covered* — PYDStaking `withdraw()` end-to-end (was entirely untested), the rollover `(amount + leftover)/duration` math, the rewards accumulator across two unclaimed accruals, constructor zero-guards, setTiers equality/cap boundaries, the snapshot-below-balance no-op, `name()`/`stakerCount()`/`receiveBudget()`/`lastSnapshotAt` — `PYD.coverage.t.sol`, 9 tests. Note found while writing the kills: `harvestStrategy()` is a bare sweep (no fee split, no `totalAssets` credit — that bookkeeping lives in `vault.harvest()`); operator-only, the keeper calls `harvest()`, so no yield strands in practice.

**Bug found by the new invariant suite and fixed** (commit `3111a6d6`):
`PYDStaking.fundRewards` double-banked an expired reward window on rollover
(keeper top-up after a lull with no user interaction in between) — rewards
became claimable beyond the funded pool and paid out of staked principal.
Fixed by ordering `_updatePeriod()` before the reward-per-token banking;
regression test `test_rollover_without_interaction_no_double_accrual`.

Mocks assert calldata shapes (a wrong precompile encoding reverts in tests
rather than silently passing — this exact trap was caught by real-chain
verification and fixed).

## 6. Known / accepted findings

See `security_baseline.json` — every accepted finding carries its reason.
Summary: OZ library assembly (library code), intentional zero-guards
(`incorrect-equality`), floating pragma pinned by config, timestamp-based
yield accrual (intentional DeFi pattern), benign reentrancy classes where
Slither cannot model `nonReentrant` guards, documented loops over the
owner-managed strategy list.

## 7. Deployment gates (what happens after audit)

1. Audit findings triaged; criticals fixed + re-tested, acceptances re-justified.
2. Mainnet deploy (deployer `0xaDD8…EA1D`; vault address published on
   `/transparency` + Dune dashboard params flip from placeholders).
3. Contracts submitted for Hyperliquid/Kinetiq decoding (~24h).
4. Dune dashboard flips private draft → public; `/transparency` panels fill.
5. On-chain DN rate must exceed the blended rate before the sleeve allocates
   (keeper-enforced sizing policy is live).

## 7b. Ecosystem-level testing (the whole product, not one module)

Beyond the per-module suites, three angles cover the ecosystem as a system:

| Angle | Artifact | What it proves |
|---|---|---|
| **Journey — one continuous customer path** | `scripts/ecosystem_journey_test.js` (24 checks) | on-ramp → deposit → fee income → FD reconcile → **the real `recycle_fees.js` run against the test chain** (60/20/20 split to the wei, FD fully drained, cold-start must not touch the shared ledger) → PYD demand (funder converts, documented swapper delivers, stream pays over time, `getReward` transfers) → tier + `snapshotHarvest` on a real fee delta → `claimRebate` equals the documented formula exactly → redemption (pays the exact quote, no cross-user leakage, floor dust bounded) → **USDC conservation to the wei summed over every ecosystem contract**. |
| **Cross-artifact integrity audit** | `scripts/ecosystem_audit.js` (22 checks, offline) | every artifact names the same canonical vault; no operating loop is silently stale; the deploy manifest is complete and non-zero; **every recycling ledger run matches the live policy split to the wei**; the web feed matches the reader's schema; website blend == scout's live blend; the operator alert queue carries no test-generated alerts. `AUDIT_MODE=strict` turns findings into a non-zero exit (CI gate); default info mode reports operator-state drift without failing contract-correctness suites. |
| **Chain guard — "never mainnet", enforced** | `scripts/chain_guard.js` + `scripts/chainid_guard_test.js` (10 checks) | a decoy anvil with **chain id 1 (mainnet's id)** is stood up and every money-mover is pointed at it: hardhat's own config chainId check refuses first (HH101), an explicit `REFUSING` guard is present in `dn_keeper.js` and `recycle_fees.js`, and `vault_keeper.check_chain()` (raw JSON-RPC path — no hardhat layer) refuses outright before any on-chain action. Positive control: chain 998 is still allowed, so the guard can never brick legitimate runs. |

All three run inside the default battery (`./scripts/run_battery.sh`,
11 suites / ~290 checks / ~91s).

## 8. How to review

- `git clone https://github.com/ProYield-fi/pro-yield-fi` (shared repo;
  `hypervault/` is the contracts root).
- `cd hypervault && npx hardhat compile && python3 scripts/security_monitor.py`
  reproduces the static-analysis gate.
- `cd hypervault && forge test` reproduces the stateful invariant suite
  (Foundry; `lib/forge-std` is vendored). `./scripts/run_battery.sh
  --with-deploy` reproduces the full isolated battery end-to-end.
- Questions/findings: open a GitHub issue with the `audit` label, or contact
  `proyield@pyd.fi` (see SECURITY.md).
