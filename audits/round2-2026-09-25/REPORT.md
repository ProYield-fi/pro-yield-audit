# ProYield /hypervault — ROUND-2 Audit Report
## Executable verification of manual findings (H1/H3/M1/M2/L1) · DN stack deep-dive · Slither re-run

- **Date:** 2026-09-25 (started 10:04 EDT, finished ~10:40 EDT)
- **Workspace (all artifacts):** `/home/user/.hermes/cache/scratch/audit-round2-20260925-100000`
- **Snapshot:** `/home/user/hypervault` @ HEAD `dbfce3e1` (contracts unchanged since `17e890df`). Copy contract tree verified **byte-identical** to the original (`diff -r --brief` → identical).
- **Isolation:** fresh rsync copy (excluding `node_modules/out/.git/cache/artifacts/coverage`), `node_modules` symlinked to the original for read-only dependency use. **Original repo untouched** (`git status` unchanged before/after; writes only inside the scratch copy). No live RPC, no keys, no anvil, no ports 8545/8547.
- **Toolchain:** forge 1.8.3, solc 0.8.28, optimizer on/200, slither 0.11.5.

---

## 0. Bottom line

| # | Item | Result |
|---|---|---|
| Part A | H1, H3, M1, L1 | **CONFIRMED (PASS)** with executable exact-value repros |
| Part A | M2 | **PASS\* (mechanism confirmed; stated vector corrected)** — vault-held donations are NOT counted (sub-claim REFUTED, test_M2a); unaccounted *in-flight* inflows during a harvest ARE (test_M2b). See §2.4. |
| Part B | **NEW HIGH-1**: keeper profit-bridge books profit as principal → profit never realizes, vault harvest sweeps 0, alert misleads (executable evidence, §3.2) |
| Part B | **NEW HIGH-2**: DN stack cannot construct the documented long leg (spot) — as coded it is a levered naked perp short, not delta-neutral (§3.3) |
| Part B | H1 loss-propagation to the vault: confirmed for DN path; combined reserve+buffer ≈ 25% instantly liquid, rest relies on delayed keeper unwinds, no write-down, no partial redemption (§3.4) |
| Part C | Slither 75 findings, **composition identical to round-1 run (0 added / 0 removed)**; FeeDistributor zero findings; no new code findings (§4) |
| Health | copy builds clean; baseline suite **50/50**; full suite after adding repros **60/60**; audit suite **10/10** |

**Deploy-gate read:** the round-1 H1/H3/M1/L1 gaps are real and now execute in tests; the DN sleeve (currently NOT deployed — mainnet manifest has vault+FeeDistributor only) has two additional blocking issues (HIGH-1 accounting, HIGH-2 leg design) plus the general loss-accounting gap. Recommend: fix HIGH-1/HIGH-2 and ship a loss write-down + partial-redemption path before any strategy is deployed against real TVL.

---

## 1. Environment / health evidence

| Check | Command (in copy) | Result | Log |
|---|---|---|---|
| Build | `forge build --force` | **exit 0**, solc 0.8.28, no errors (1 benign warning) | `report/forge_build.log` |
| Baseline suite | `forge test` | **50 passed / 0 failed** (6 suites, ~3.5s) | `report/forge_baseline.log` |
| Audit repros | `forge test --match-path 'test/audit/*' -vv` | **10 passed / 0 failed** | `report/forge_repros.log` |
| Audit repros (verbose) | same, `-vvv` (logs) | all PASS + numeric evidence lines | `report/forge_repros_verbose.log` |
| Full suite incl. repros | `forge test` | **60 passed / 0 failed** (8 suites) | `report/forge_full_after.log` |
| Slither | `/usr/local/bin/slither . --json report/slither.json` | 75 results, 49 contracts / 101 detectors (exit 255 = findings present, expected) | `report/slither.json`, `report/slither.stderr.txt` |

New test files (in the copy only):
- `test/audit/Round2.repros.t.sol` — H1, H3, M1, M2, L1 repros (8 tests).
- `test/audit/Round2.dn_accounting.t.sol` — DN keeper↔contract accounting repro (2 tests, Part B evidence).

---

## 2. PART A — executable verdicts (round-1 findings)

### Verdict table

| Finding | Round-1 claim | Verdict | Test(s) | Key executed evidence |
|---|---|---|---|---|
| **H1** | No strategy-loss accounting; `totalAssets()` phantom; `withdraw()` reverts on phantom value | **PASS** | `test_H1_strategyLoss_phantomTotalAssets_withdrawReverts` | after an 1800e18 venue loss: `totalAssets()==2000e18` vs real backing `200e18`; full withdrawal reverts; first user salvages 200e18; second user trapped at phantom 1800e18; no write-down anywhere |
| **H3** | `creditYield(X)` re-raises `_totalAssets` on idle already counted | **PASS** | `test_H3_creditYield_doubleCountsPreExistingIdle`, `test_H3b_repeatedCreditYield_sameIdle_inflates` | `creditYield(2000)` on 2000 idle → `totalAssets()==4000`; bob exits with **1999.999…e18** for a 1000e18 deposit; alice trapped; repeat-credit: 1000 idle × 3 credits → `totalAssets()==3000` vs backing 1000 |
| **M1** | `recall()` clamps at strategy balance, not deployed debt | **PASS** | `test_M1_unit_recall_capsAtBalance_notDeployedDebt`, `test_M1_integration_recallDrainsStrategy_toZero_inclDonation` | recall(1000e18) on 500e18 balance → transfers 500 silently, no debt ledger; integration: one 1500e18 withdrawal drains strategy 500e18→**0** (incl. 300e18 unaccounted donation), vault left with phantom `totalAssets()==8500e18` vs backing 0 |
| **M2** | donation→harvest becomes profit + FD fee | **PASS\*** (vector corrected; sub-claim REFUTED) | `test_M2a_donationToVault_notCountedAtHarvest`, `test_M2b_donationToStrategy_sweptAsProfit_withFDFee` | M2a: donation parked at the vault is **excluded** (profit 0, fee 0) — literal vector refuted. M2b: unaccounted inflow *during* harvest (strategy-side sweep) → FD takes 10e18, `totalAssets` +90e18 — mechanism confirmed |
| **L1** | `FeeDistributor.route()` silently clamps; routed can exceed received | **PASS** | `test_L1_route_silentlyClamps_routedExceedsReceived` | `route(treasury, 999e18)` on 100e18 balance → sends 100, **no revert**; `totalFeesRouted==100e18` vs `totalFeesReceived==0`; drift stays negative (−100 → −50 after re-sync); clamp-to-zero reverts `"nothing to route"` |

\* M2 footnote — two sub-claims, tested separately: **(a) vault-held donation** (`test_M2a`): REFUTED — `idleBefore` is snapshot at harvest entry, so a donation sitting in the vault is *not* counted; it also never reaches depositors on its own (`maxWithdraw(alice)==1000e18`). **(b) mechanism** (`test_M2b`): CONFIRMED — the vault books *any* balance increase that lands during the harvest call as profit with no provenance check, skims `performanceFee` (10%) and credits the net to `_totalAssets`. Production reachability: none of the shipped strategies sweep balance-based (`YieldStrategy` sweeps only `pendingYield`; `DeltaNeutralStrategy` only `accruedFunding`; `DNCoreStrategy` only `profitRealized`), so this vector is **not currently reachable** → informational severity, but the pattern is a latent trap for any future strategy that sweeps `balance − principal`.

### 2.1 H1 — no strategy-loss accounting (CONFIRMED)
Refs: `contracts/ProYieldVault.sol:26` (private `_totalAssets`), `:198-212` (withdraw), `:171-192` (`_recallShortfall`), `contracts/BaseStrategy.sol:83-89` (recall clamp), `contracts/IStrategy.sol` (no loss path).
Executed sequence (18-dec MockUSDC, two users 1000e18 each): `allocate()` deploys 1800e18 (10% reserve kept). Strategy loses 1800e18 to a sink. `totalAssets()` still 2000e18; real backing 200e18. `withdraw(1000e18)` reverts (phantom check `amount <= totalAssets()` passes; transfer fails). Alice withdraws the 200e18 scrap (first-come-first-served); bob's `withdraw(100e18)` reverts; books still claim 1800e18. Strategy has no deployed-debt ledger either (`totalDebt` is a harvest-profit counter, not principal). **Losses are invisible to the vault; no socialisation, no partial redemption, no write-down.**

### 2.2 H3 — creditYield double-counts pre-existing idle (CONFIRMED)
Refs: `ProYieldVault.sol:260-265` (balance check only), `:232-244` (harvest), `:73-81` (share math).
- Single credit on deposits: 2000e18 deposited → `creditYield(2000e18)` passes (balance ≥ amount) → `totalAssets()==4000e18` while vault balance is 2000e18. Bob exits at the inflated price with **1,999,999,999,999,999,999,500 wei** (≈2× his deposit); alice's remaining claim is unbacked and her withdrawal reverts. This is the cleanest exploit shape: phantom credit → price inflation → bank run.
- Repeat credit on one donation: 1000e18 donated, `creditYield(1000e18)` ×3 → `totalAssets()==3000e18` vs backing 1000e18; the balance check never blocks re-crediting the same idle.

### 2.3 M1 — recall clamp / no debt accounting (CONFIRMED)
Refs: `BaseStrategy.sol:83-89` (`if (amount > bal) amount = bal;`), `ProYieldVault.sol:171-192` (`perStrategy = missing/activeCount + 1`).
- Unit: strategy holds 500e18 with **zero** deployed debt; `recall(1000e18)` delivers 500e18 silently (clamp), no revert, no debt to compare against.
- Integration: 10000e18 deposit → 9000e18 deployed; strategy loses 8800e18 and receives a 300e18 unswept donation → balance 500e18. `withdraw(10000e18)` reverts (recall(9001e18) clamped to 500e18 first). `withdraw(1500e18)` **succeeds** and drains the strategy to **0** — one vault withdrawal pulls the entire strategy balance including the unaccounted donation — leaving `totalAssets()==8500e18` phantom vs backing 0; next withdrawal reverts. No accounting change records the shortfall.

### 2.4 M2 — donation→harvest (PASS\* — see footnote above)
Refs: `ProYieldVault.sol:232-241` (`totalProfit = balanceOf(this) − idleBefore`), `:234-235` (fee), `:239-241` (net credit).
Evidence numbers: M2a — donation 500e18 to the vault: after `harvest()`, `totalAssets()==1000e18`, FD balance 0, donation sits unaccounted at 1500e18 vault balance. M2b — 100e18 donated to a balance-sweep strategy during a vault harvest: FD receives 10e18 (10%), `_totalAssets` +90e18, strategy's principal ledger absorbs the donation.

### 2.5 L1 — FeeDistributor silent clamp / routed > received (CONFIRMED)
Refs: `contracts/FeeDistributor.sol:50-59` (clamp at `:52-53`, no `received` guard), `:39-45` (`receiveFees` re-sync).
Evidence: 100e18 sitting at the FD, `receiveFees()` not called: `route(treasury, 999e18)` sends the whole 100e18 with no revert (a router typo over-routes everything); `totalFeesRouted==100e18` while `totalFeesReceived==0` (drift −100e18). `receiveFees()` (empty balance) can't repair it retroactively; after new fees + re-sync the drift is still −50e18. Routing from an empty FD reverts `"FeeDistributor: nothing to route"` (clamp-to-zero path).

**Raw logs:** `report/forge_repros.log` (-vv), `report/forge_repros_verbose.log` (-vvv, includes numeric evidence lines).

---

## 3. PART B — DN stack deep-dive

Reviewed: `contracts/DNCoreStrategy.sol`, `contracts/adapters/DNCoreAdapter.sol`, `DNCoreBase.sol`, `HLConstants.sol`, `HLInterfaces.sol`, `scripts/dn_keeper.js`, `scripts/dn_keeper_{dryrun,unwind}_test.js`, `scripts/dn_strategy_tests.js`, `scripts/dn_adapter_tests.js`, `docs/DN_COREWRITER_ADAPTER.md`. Mainnet manifest (`deployed_addresses.mainnet.json`, 2026-09-24) contains **vault + FeeDistributor only — the DN stack is NOT deployed**; per `docs/ATTACK_SURFACE_PLAN.md` the DN sleeve is a per-feature audit item.

### 3.1 Authorization model (who can move funds)

| Actor | Can do | Cannot do | Refs |
|---|---|---|---|
| **Owner** (Safe; DN owner TBD) | setKeeper, setVault (instant), setBufferBps, setMaxActionUsd6, setPaused, setPerpAsset (flat-only guard), staking ops; also passes `onlyKeeper` (owner counts as keeper) | — | `BaseStrategy.sol:70-79`, `DNCoreStrategy.sol:81-85`, `DNCoreBase.sol:97-100,115-131` |
| **Keeper** (hot key, single EOA; tests use one signer) | `bridgeUsdcToCore` (all EVM idle → Core), `bridgeBackToEvm` (Core→EVM; destination is the contract's own EVM address — fixed), `moveUsdcToPerp/Spot` (≤ `maxActionUsd6` per action), `openShort/closeShort` (≤ cap per order, asset-locked to `perpAsset`), `cancelOrderByCloid`; `syncCore` is permissionless | change policy; send funds to third parties; exceed per-action caps | `DNCoreStrategy.sol:90-117`, `DNCoreBase.sol:136-174,204-227,264-276` |
| **Vault** (`setVault`, i.e. ProYieldVault) | `recall()` — EVM idle only, silently clamped at balance; `harvest()` — sweeps realized profit above buffer to vault | touch Core-side funds; bypass accounting | `BaseStrategy.sol:83-89`, `DNCoreStrategy.sol:155-172` |

Notable: `setVault` is **not** one-shot — the owner can repoint it to any address, whose `recall()` then drains the strategy's EVM balance (buffer included). That is standard-owner-trust, but it is a live rug surface on funds the vault believes it controls (`BaseStrategy.sol:76-79`).

### 3.2 NEW HIGH-1 — keeper profit-bridge is booked as principal; profit never realizes (executable evidence)
- Keeper passes **only the profit portion**: `amount6 = coreProfit6 = equity6 − principal6` (`scripts/dn_keeper.js:214,229-235`).
- Contract splits **principal-first**: `principalRed = min(amount6, corePrincipal6)`; `profitRed = amount6 − principalRed` (`DNCoreStrategy.sol:107-114`). For a profit-sized amount, `profitRed == 0`.
- Consequence: `corePrincipal6` shrinks by the profit amount (principal ledger corrupted: 500e6 → 495e6 while the Core account still holds 500e6 of principal), `profitRealized` stays 0 → `harvestableProfit()==0` → the `vault.harvest()` that follows **sweeps nothing** (no share-price rise, no FD fee), while the keeper logs `"💰 DN profit harvested"` (`dn_keeper.js:243-246`). Repeating BRIDGE_PROFIT shaves principal in slices without ever realizing profit.
- Executable proof (offline, repo's own mocks etched at real precompile addresses): `test/audit/Round2.dn_accounting.t.sol`
  - `test_PartB_keeperProfitOnlyBridge_realizesZeroProfit`: `principal 500e6→495e6`, `profitRealized==0`, `profitSwept==0`, vault receives 0. **PASS (bug reproduced)**
  - `test_PartB_fullAmountBridge_realizesProfit_sweepWorks`: bridging the **full** amount (500+5, as the repo's own DN suite does at `scripts/dn_strategy_tests.js:141`) → `principal==0`, `profitRealized==5e18`, vault sweeps 5e18. The bug is the keeper↔contract mismatch, not the split math per se.
- Fix direction: keeper must bridge `principal + profit` (or the contract must accept a profit-only intent flag / defer principal attribution); reconcile keeper and `dn_strategy_tests.js` so tests exercise the *keeper's* amount.

### 3.3 NEW HIGH-2 — no long leg: the DN sleeve as coded is a levered naked perp short, not delta-neutral
- Documented design: "delta-neutral (spot + offsetting perp short)" (`docs/APY_LEVERS.md:41`, `docs/MONEY_FLOW_UX.md:52`, `NEW_USER_JOURNEY_AUDIT.md:11`). `docs/DN_COREWRITER_ADAPTER.md` moves **only USDC** (bridge → class transfer → short).
- Code reality: the only order path is `_order(...)` gated to `asset == perpAsset` (0=BTC/1=ETH perp) (`DNCoreBase.sol:164-174`); vendored action IDs are perp limit-order/class-transfer/send-asset/staking only (`HLConstants.sol:29-36`); the keeper script never buys spot. **There is no way in this stack to hold the long spot leg.**
- Net delta of the strategy = short notional (against USDC cash). It harvests funding (short receives when funding > 0; opens only at funding ≥ 5%/yr, unwinds below −2%/yr — `dn_keeper.js:35-38,218-219`) but takes unhedged BTC/ETH price risk.
- Related mismatch: `dn_keeper.js:10-13` claims "1:1 notional vs margin for true delta-neutral", but `marginUtilBps: 3300` (`:43`, used at `:294`) bridges only ~33% margin vs notional ⇒ effective ≈3× leverage; a ~+33% adverse move (short) exhausts margin. (Comment vs code inconsistency; align before deploy.)
- Deploy-gate action: either add the spot/see leg (spot order support + keeper leg management) or formally re-scope/risk-size the product; do not label it delta-neutral on the site until the leg exists.

### 3.4 Loss propagation to the vault given H1 (DN-specific chain)
1. Core equity < principal (funding flips negative, price squeeze, venue issue). Nothing writes it down: no `reportLoss` on `DNCoreStrategy`/`BaseStrategy`; `corePrincipal6` unchanged (`DNCoreStrategy.sol:40-48,104-117`).
2. Vault `_totalAssets` is unconnected to strategy values (H1) → user claims stay full.
3. Withdrawn funds can only come from: vault reserve (10% of vault assets, `ProYieldVault.sol:146`) + the strategy's **EVM idle buffer** (15% default, `DNCoreStrategy.sol:37`; recall transfers idle only, `BaseStrategy.sol:83-89`). Core-side equity is unreachable synchronously (CoreWriter actions are delayed/fire-and-forget).
4. Beyond ~25% of assets, withdrawals **revert** (no partial redemption, no queue). First-come-first-served drain.
5. The keeper's UNWIND path closes the short but **stops there** — it never calls `moveUsdcToSpot`/`bridgeBackToEvm` (`dn_keeper.js:250-268` returns after `closeShort`), so restoring liquidity after an unwind is a manual ops task; the docs describe the full chain (`DN_COREWRITER_ADAPTER.md:145-153`) but the script doesn't implement it.
6. Even when funds are bridged back to the strategy's EVM balance, the vault only sees them through `recall()` during withdrawals — the last withdrawers absorb any residual shortfall (no write-down, ever).
7. Pause semantics are OK for exits: `paused`/`isActive=false` block keeper actions and harvests (try/catch) but do **not** block `recall()`, so exits are not bricked by a paused strategy.

### 3.5 Severity-ranked risk register (Part B)

| Sev | Risk | Refs |
|---|---|---|
| **HIGH** | Keeper BRIDGE_PROFIT books profit as principal → no realization, no fee, no price rise, misleading alert; principal ledger drifts (proven by forge tests) | `dn_keeper.js:214-235` vs `DNCoreStrategy.sol:104-117` |
| **HIGH** | No long leg exists (no spot path) → levered naked short marketed as delta-neutral; 1:1-vs-3300bps margin comment contradiction (~3×) | `docs/APY_LEVERS.md:41`, `DNCoreBase.sol:164-174`, `dn_keeper.js:10-13,43,294` |
| **HIGH** | Strategy losses invisible to vault; no write-down, no partial redemption; instant liquidity ≈ 10% vault reserve + 15% DN buffer; rest needs delayed keeper unwinds (post-unwind bridge not automated) | `ProYieldVault.sol:26,146,171-212`, `BaseStrategy.sol:83-89`, `dn_keeper.js:250-268` |
| **MED** | Bridge-back gate trusts margin-summary equity only; `withdrawable()` (0x803) unused in the bridge path; `sendAsset` can exceed the free balance and drop silently; spot-vs-perp coverage of the 0x80f read is unverified (must be validated on testnet) | `DNCoreStrategy.sol:104-117`, `DNCoreBase.sol:211-221` |
| **MED** | Keeper authority: hot single key can bridge all idle to Core and trade within per-action caps (cumulative unbounded, no sleeve-level cap, `maxSleeveUsd` defaults to 0 = off); owner can repoint `vault` and drain the EVM buffer via `recall()` | `DNCoreStrategy.sol:90,104`, `DNCoreBase.sol:136-174`, `dn_keeper.js:44` |
| **MED** | No on-chain price sanity on orders: `limitPx` and sizing trust the off-chain oracle read + HL funding API (single source, no cross-check, warn-only staleness); markPx (0x806) is available but unused on-chain | `DNCoreBase.sol:163-174`, `dn_keeper.js:112-124,198-211,316-321` |
| **LOW** | `cloid` hardcoded 0 on all orders and never tracked → `cancelOrderByCloid` cannot target them; no resting-order cleanup path; a stuck GTC/ALO has no keeper remedy | `DNCoreBase.sol:157-161,171` |
| **LOW** | Silent-drop residual: `sendAsset` needs HYPE on Core for gas; no HYPE-balance monitoring; drop-verification is an 8s heuristic that can mis-flag | `DNCoreBase.sol:262-276`, `dn_keeper.js:238,258,313,323` |
| **LOW** | Scripts are host-coupled: absolute `/home/user/yield_scout/...` paths, Telegram creds chain, chain guard hardcoded to 998 (good for safety, but mainnet operation needs a code change that must itself be audited) | `dn_keeper.js:41,54,69-82,154-159` |

---

## 4. PART C — Slither re-run + delta vs round-1 baseline

Command (from copy root): `/usr/local/bin/slither . --json report/slither.json` → `(. analyzed (49 contracts with 101 detectors), 75 result(s) found` (exit 255 = findings present).

### 4.1 Classification (identical to round-1's method)

| Group | Count | Composition |
|---|---|---|
| libs (OZ/forge-std in `node_modules`) | 16 | assembly 12 (SafeERC20 ×3, StorageSlot ×9), solc-version 4 (OZ pragmas) |
| mocks (`contracts/mocks/`) | 14 | unchecked-transfer 3, missing-zero-check 2, unused-return 1, missing-inheritance 2, naming-convention 6 |
| adapters (`contracts/adapters/`) | 7 | low-level-calls ×7 (Informational) — DNCoreBase precompile staticcall wrappers |
| production-core (`contracts/` top level) | 38 | reentrancy-balance 1, incorrect-equality 8, reentrancy-no-eth 3, calls-loop 4, reentrancy-benign 4, timestamp 7, pragma 1, low-level-calls 3, missing-inheritance 2, naming-convention 2, cache-array-length 2, constable-states 1 |
| **Total** | **75** | **FeeDistributor: ZERO findings** (unchanged) |

### 4.2 Delta vs round-1 run — ZERO

Exact set comparison of (detector, file, contract) tuples between this run and round-1's `report/slither.json` (`hypervault-audit-20260925-053357`): **0 added, 0 removed, 0 changed** (identical source, same toolchain). Artifacts: `report/slither_classified.json`, `report/slither_new_vs_baseline.json`.

### 4.3 NEW-vs-`security_baseline.json` findings — same set as round-1 (no new classes)

Round-2 adds nothing to the previously-triaged list. The items not directly present in `security_baseline.json` (all previously triaged; re-stated with triage notes):

| Finding | Location | Triage note |
|---|---|---|
| `solc-version` ×4 (incl. `draft-IERC6093`) | `node_modules/@openzeppelin/...` | OZ library pragmas (`^0.8.x`); compile-time only, project pins solc 0.8.28. Accept. |
| `incorrect-equality` on `PYDFeeDiscount`, `DNCoreStrategy` | `PYDFeeDiscount.sol:207-219`, `DNCoreStrategy.sol:155-172` | Intentional zero-guards (`available == 0`, balance checks) — same accepted class as `ProYieldVault`/`BaseStrategy`/`DeltaNeutralStrategy`. Accept / extend baseline entries. |
| `calls-loop` on `PYDFeeDiscount._vaultSharesOf` | `PYDFeeDiscount.sol:235-239` | Staticcall read loop over a bounded list; analogous to accepted `calls-loop:ProYieldVault`. Low/informational. |
| `missing-inheritance` on `MorphoStrategy` (and ProYieldVault/mocks) | `MorphoStrategy.sol:17` | `IStrategy` interface pattern Slither cannot see; accepted class. Informational. |
| `low-level-calls` on `DNCoreBase` ×7 | `DNCoreBase.sol:204-246` | Precompile `staticcall` reads — inherent to HyperEVM; informational. |

No new production finding requires a code fix from the Slither layer; the two HIGH items in Part B are **manual/executable** findings that Slither does not model (neither detector covers these accounting mismatches).

---

## 5. Recommendations (deploy-gate checklist)

1. **Fix HIGH-1** (keeper profit bridge): bridge `principal + profit` (or add a profit-only path); align `dn_keeper.js` with `dn_strategy_tests.js:141`; add a post-harvest assertion that `profitRealized == 0 && profitSwept > 0` after a BRIDGE_PROFIT cycle.
2. **Resolve HIGH-2** (missing long leg / leverage labeling): add spot-leg support or re-scope + re-risk the product; reconcile the "1:1 notional vs margin" comment with `marginUtilBps=3300`.
3. **Loss accounting (H1/H3/M1) before any strategy deploy:** NAV-aware `totalAssets()` (or `reportLoss` capability), partial redemption/queue semantics, and `creditYield` provenance binding (e.g. credit only `balance − accounted`); recall with debt tracking.
4. **DN liveness:** automate `closeShort → moveUsdcToSpot → bridgeBackToEvm` after unwinds; clamp bridge-backs to `withdrawable()`; monitor Core HYPE gas balance; validate the 0x80f spot/perp coverage assumption on testnet.
5. **Port the repros into the repo suite** (`test/audit/Round2.repros.t.sol` + `Round2.dn_accounting.t.sol` are self-contained; DN one uses `vm.etch` mocks — no anvil needed). They currently live only in the audit copy.

## 6. Artifact index (all absolute)

- Report: `/home/user/.hermes/cache/scratch/audit-round2-20260925-100000/REPORT.md`
- Repro tests: `.../test/audit/Round2.repros.t.sol`, `.../test/audit/Round2.dn_accounting.t.sol`
- Logs: `.../report/forge_build.log`, `forge_baseline.log`, `forge_full_after.log`, `forge_repros.log`, `forge_repros_verbose.log`
- Slither: `.../report/slither.json`, `slither.stderr.txt`, `slither.stdout.txt`, `slither_classified.json`, `slither_new_vs_baseline.json`

## 7. Constraints respected

- Original repo `/home/user/hypervault` NOT modified (git status identical before/after; contracts byte-verified via `diff -r`).
- No live RPC calls, no private keys, no anvil, no ports 8545/8547 (offline forge/etched-mock repros only).
- No network fetches beyond local tooling; no money-moving scripts run.
