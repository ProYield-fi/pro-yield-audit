# Attack-surface reduction plan — ProYield contracts

Owner's stated concern (2026-09-23): *"we might have too many smart contracts or
attack surfaces for hackers or anyone else to abuse."* This answers with a
measured inventory, the cost model, and a staged reduction to the smallest set
that still ships the product.

## 1. What exists today (measured, not estimated)

| Where | Contracts | Notes |
|---|---|---|
| **Real HyperEVM testnet (998)** | 3 of ours: vault `0x42237e98` ("ProYield Vault Share"), its asset `0x8954a73B…`, strategy `0xB5922693` | The only LIVE stack. The keeper drives it. |
| **Local anvil :8545** (chain-id spoofed as 998) | 8: `pro_yield_vault 0xa3f4338B`, `fee_distributor`, `pyd_token`, `pyd_staking`, `mock_usdc`, `delta_neutral`, `funding_oracle`, `funding_source` | Sandbox. Every "on-chain" number the ops artifacts published (feed TVL, insurance deposits, recycling) came from HERE — see the chain-identity fix (`ecosystem_audit.js` §8). |
| **Source tree `contracts/`** | 21 files = 14 in-house + 7 mocks | Includes adapters for Morpho, Pendle, Sky, a DN core-writer stack, a decode verifier, and the PYD token suite. |

Privileged entry points (`onlyOwner`) today: ProYieldVault **7**, FeeDistributor 1,
PYDStaking 1, PYDFeeDiscount 1, PYDFunder 4, DeltaNeutralStrategy 6, DNCoreStrategy 1
= **21 privileged functions across 8 contracts**, + 3 live on the testnet.

## 2. Why fewer contracts is strictly safer

Each contract adds four liabilities:
1. **Audit surface** — code must be read line by line; 8 contracts ≈ 8 audits (or one audit that gets shallower per contract).
2. **Privileged keys** — every `onlyOwner` function is a "leaked key / operator mistake" path. 21 today.
3. **Composition bugs** — N contracts create up to N² interaction paths; the bugs that hurt DeFi are cross-contract (approvals, reentrancy, accounting drift), not single-function bugs.
4. **Redeploy risk** — we are non-upgradeable (good: no proxy admin), so every fix is a redeploy, a new address, and a fresh trust re-establishment.

Rule adopted: **a contract earns its way into the live set only if a shipped
user-facing feature cannot work without it.**

## 3. The reduction plan

### Cut 1 — launch set = 2 in-house contracts (the product doesn't need the rest)
The product — sign up, deposit, earn, withdraw — needs `ProYieldVault` +
`FeeDistributor` (+ external USDC + one venue). Everything else is a *feature*,
and features ship with their own audits:
- **PYD token suite** (PYDToken, PYDStaking, PYDFeeDiscount, PYDFunder) — defer until the demand/rebate program is greenlit. 4 contracts out of the launch set and the launch audit.
- **Delta-neutral stack** (DeltaNeutralStrategy, DNCoreStrategy, funding oracle/source, decode verifier) — defer unless the DN sleeve is actually funded at launch. 4–5 contracts out.
- **Venue adapters** (Morpho, Pendle, Sky) — deploy only the one venue actually used, at the moment it is used. Each adapter is a one-venue audit, not a platform.

Target: **2 in-house contracts live + 1 strategy + external dependencies.**

### Cut 2 — one venue, one adapter
Lending-first mandate: the strategy surface stays at the audited lending market.
No adapter farm. Adding a venue becomes a deliberate, budgeted, audited decision.

### Cut 3 — no new contracts for treasury/insurance (answers the insurance question)
Insurance is a BACKUP PLAN: safety first, yield second. Therefore:
- **Destination**: a dedicated multisig address (Safe when available on HyperEVM; 2-of-3 minimum, hardware keys), **not** the operator EOA. Today's policy fix made the address *explicit* (currently the ops wallet `0xaDD8f2678…`) — acceptable only as a testnet placeholder.
- **Venue**: idle USDC, or the SAME audited external lending market the vault uses — entered by a plain transaction from the multisig. **No bespoke fund contract, no strategy contract, and never a vault deposit** (depositors must not be the insurance's counterparty).
- **Accounting**: the recycling ledger records the insurance slice separately (and now records recipient + tx hash per run); `insurance_fund.py` reads that ledger. Co-location with treasury is fine short-term *provided* the ledger accounting stays separate.
- **Yield later**: when reserves are material (>$100k), a T-bill-style or stablecoin pool — same lending-first criteria, entered directly, zero in-house code.

### Cut 4 — shrink the privileged surface on the two survivors
- **Owner of vault + FD → multisig.** Today one deployer key signs fee routing, strategy changes, `creditYield` and recycler runs — the single biggest "what if".
- **Vault (7 privileged fns)**: keep strategy management + harvest/allocate; review `creditYield` (owner-only, balance-guarded, mints share value — the one to watch) and `emergencyWithdraw` (pulls everything to owner).
- **FD (1 privileged fn)**: keep — `route()` can only move funds to the named `to`, and it is owner-gated.
- Do **not** add pausing/upgrade machinery for launch; non-upgradeable + redeploy is the smaller surface.

### Cut 5 — operating surface (non-contract, same risk class)
- **One chain for ops.** Declare the testnet stack as the real one; the local sandbox must not be a source of published numbers (feed/insurance/recycling must name the chain they read — the audit now enforces this).
- **Pin every RPC** (done for the recycler + insurance module; keep it a rule).
- **Dedupe tooling** (done: two recyclers → one; implicit-RPC defaults → fail closed).
- Retire dev chains not in use (stale `anvil` on :8546 and :8550; :8545 is the sandbox).
- Test scaffolding (7 mocks) never enters a live manifest.

## 4. Sequencing

| Phase | Action | Exit criteria |
|---|---|---|
| now → audit | Freeze the launch set at Vault + FD + 1 venue; keep PYD/DN/adapters out; insurance address explicit (done) | Manifest holds only the launch set, on ONE declared chain |
| audit | Scope the audit to the frozen set | 0 critical/high; findings triaged |
| launch | Deploy testnet → mainnet with the same frozen set | Verified code; multisig owner |
| features | PYD suite, DN sleeve, extra venues each ship independently | Per-feature audit before deployment |

## 5. What this buys

- Audit scope: ~8 contracts → **2 (+1 venue)**.
- Privileged entry points: 21 → **8** (7 vault + 1 FD), further reduced by the multisig.
- Far fewer cross-contract approval/accounting edges to reason about.
- Insurance stops being either an unaccounted slice or a new contract: it is a multisig + a ledger.

## 6. Why the DN stack is a strategy, not part of ProYieldVault (asked 2026-09-23)

**1. EIP-170 makes it physically impossible (measured today).**
Runtime bytecode: `ProYieldVault` 8,415 B · `DeltaNeutralStrategy` 6,680 B ·
`DNCoreStrategy` 12,471 B · `DNCoreAdapter` 8,353 B (a helper the DN path already
needs). Merged: 8,415 + 12,471 + 8,353 = **29,239 B vs the 24,576 B limit** — the
deploy fails outright. The only ways to force it in (proxy, diamond, delegatecall
libraries) *add* the admin/delegatecall surface this plan exists to remove; a
diamond is more attack surface than three separate contracts, not less.

**2. Failure isolation is the point of a strategy.**
DN holds perp shorts on HyperCore. Pause/unwind/brick one strategy and the vault
keeps operating — the vault's `setStrategyActive` circuit breaker plus the
paused-strategy-not-swept invariant (mutation-tested) is exactly that mechanism.
Embedded DN would make a HyperCore-side problem a vault problem, i.e. a depositor
problem.

**3. Valuation must not live in the core.**
The vault's accounting is deliberately dumb: `totalAssets = idle + Σ strategy
balances`. DN's value is the exchange rate of a leveraged basis position (perp
marks, funding accrual, oracle). Mark-to-market math belongs as far from the
share-minting core as possible.

**4. Swappable without migration.**
Strategies are added/removed by owner call; depositor funds never migrate. When
funding flips (the keeper already has unwind alerts; the test suite forces −5%/yr
to prove the unwind path), one strategy unwinds and the vault is untouched.

**On "it brings the highest APY":** the ~11%/yr figure is the funding APR *on
notional*. The productized DN tier is **5.74%** (scout `tier_apys`) — below fixed
(9.73%) and satellite (10.67%), and the satellite tier is the unverified-protocol
sleeve the advisor recommended cutting. Funding is also two-sided: it pays today,
it can flip. So DN is neither the highest-yielding nor the lowest-complexity tier —
it is the highest complexity per unit of yield. It ships as ONE audited strategy
when the sleeve is funded (the "sleeve" line in Cut 1) — not as the vault.

## 7. Decisions

- **(2) Insurance destination — DECIDED 2026-09-23: dedicated multisig.** Wired as
  `policy.insurance` when the address exists; until then it remains the ops wallet
  and the audit prints a standing WARN (`insurance destination is dedicated…`).
  No new contract; accounting via the recycling ledger (recipient + tx hash/run).
- **(3) Ops chain — DECIDED 2026-09-23: HyperEVM testnet.** Executed: the manifest
  declares `chain 998` + RPC, vault/asset/strategy repointed to the testnet stack,
  the feed publishes real testnet numbers (`hyperevm-testnet (chain 998, verified)`),
  the sandbox stack moved under `manifest.sandbox`, and the audit verifies code on
  the DECLARED chain.
- **(1) Launch set — still open:** confirm Vault + FeeDistributor + ONE venue, and
  which venue (lending-first mandate points at the audited lending market; DN is
  the alternative if the sleeve is funded at launch).
