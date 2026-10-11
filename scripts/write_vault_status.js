// scripts/write_vault_status.js — render vault_status.json for the web app
// from the CURRENT chain state (manifest-driven). Mirrors the shape the
// keeper publishes in production (vault_keeper.py); used by the local web
// smoke (scripts/web_smoke.sh) so the UI can be exercised against a local
// anvil. SMOKE_TAG, when set, is embedded in `network` so the smoke proves
// the page served THIS generation of the file.
//
// Chain identity: when the manifest declares a chain (`chain.id` + `chain.rpc`)
// this writer reads the provider's ACTUAL chain id and REFUSES to publish on a
// mismatch — the class of bug where a local anvil spoofing 998 served numbers
// labelled "on-chain". A manifest without a chain block keeps the sandbox/smoke
// label (the battery's cold-start manifests have no chain block).
//
// Run: npx hardhat run scripts/write_vault_status.js --network hyperTestnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const schema = require("./vault_status_schema");

const WEB = "/home/user/websites/pro-yield-web";

async function readTotalShares(addr) {
  // Vault generations differ: the audited repo vault exposes totalShares(),
  // the newer ERC-4626-style deployment exposes totalSupply(). Raw
  // human-readable ABI — the repo artifact lacks totalSupply(), and an
  // ABI-gated call would throw "function not found" and mask the real revert.
  const c = new hre.ethers.Contract(addr, [
    "function totalShares() view returns (uint256)",
    "function totalSupply() view returns (uint256)",
  ], hre.ethers.provider);
  try { return await c.totalShares(); } catch { /* fall through */ }
  try { return await c.totalSupply(); } catch { /* fall through */ }
  throw new Error("vault exposes neither totalShares() nor totalSupply()");
}

async function readScales(vaultAddr, hints = []) {
  // [assetDecimals, shareDecimals]; both default to 18 (repo generation).
  let assetDec = 18;
  let shareDec = 18;
  const tryDecimals = async (addr) => {
    const ac = new hre.ethers.Contract(addr, ["function decimals() view returns (uint8)"], hre.ethers.provider);
    return Number(await ac.decimals());
  };
  try {
    const vc = new hre.ethers.Contract(vaultAddr, [
      "function asset() view returns (address)",
      "function decimals() view returns (uint8)",
    ], hre.ethers.provider);
    try { shareDec = Number(await vc.decimals()); } catch { /* repo gen */ }
    try {
      const assetAddr = await vc.asset();
      assetDec = await tryDecimals(assetAddr);
    } catch {
      // Lean vaults expose no asset()/decimals() (user-facing fns only — the
      // mainnet ProYieldVault is one). Fall back to the manifest's vault_asset,
      // then the known HyperEVM USDC, so 6dp balances are never shown as 18dp.
      for (const h of [...hints, "0xb88339CB7199b77E23DB6E890353E22632Ba630f"]) {
        if (!h) continue;
        try { assetDec = await tryDecimals(h); break; } catch { /* next hint */ }
      }
    }
  } catch { /* not an ERC-4626-style vault */ }
  return [assetDec, shareDec];
}

async function main() {
  const manifestFile = process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json");
  const deployed = JSON.parse(fs.readFileSync(manifestFile, "utf8"));

  // ── Primary-book guard (defense-in-depth, 2026-10-10) ────────────────────
  // The feed's top-level (vault/sharePrice/totalAssets) and the events basis are
  // ALWAYS book #1 (core). DEPLOY_MANIFEST selects that primary composition, so a
  // non-core manifest would republish Core's slot with another book's numbers and
  // diff the events ledger against the wrong baseline (the false "loss posted"
  // class). Refuse here, before ANY chain read or file write. Per-book data rides
  // books[] (extend deployedRow) — never another primary. Override ONLY for a
  // deliberate, non-public feed: VAULT_STATUS_ALLOW_NONCORE=1.
  try {
    schema.assertPrimaryIsCore(manifestFile, {
      allowNonCore: process.env.VAULT_STATUS_ALLOW_NONCORE === "1",
    });
  } catch (e) {
    console.error(`REFUSING: ${(e && e.message) || e} — not publishing a mislabelled feed.`);
    process.exit(3);
  }

  const declared = deployed.chain || null;
  const net = await hre.ethers.provider.getNetwork();
  const actual = Number(net.chainId);

  if (declared?.id && Number(declared.id) !== actual) {
    console.error(`REFUSING: manifest declares chain ${declared.id} but the RPC answers ${actual} — not publishing a mislabelled feed.`);
    process.exit(3);
  }
  if (!deployed.pro_yield_vault) {
    console.error("REFUSING: manifest declares no pro_yield_vault.");
    process.exit(3);
  }
  const code = await hre.ethers.provider.getCode(deployed.pro_yield_vault);
  if (code === "0x") {
    console.error(`REFUSING: no code at vault ${deployed.pro_yield_vault} on chain ${actual}.`);
    process.exit(3);
  }

  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);
  const totalAssets = await vault.totalAssets();
  const totalShares = await readTotalShares(deployed.pro_yield_vault);
  const [assetDec, shareDec] = await readScales(deployed.pro_yield_vault, [deployed.vault_asset]);
  // Shares below one whole unit at their declared scale are a unit mismatch,
  // not a fact (the testnet vault declares 18 but counts in the asset's 6).
  const shownShareDec = totalShares > 0n && totalShares < 10n ** BigInt(shareDec) ? assetDec : shareDec;
  const price18 = totalShares > 0n ? (totalAssets * 10n ** 18n) / totalShares : 10n ** 18n;
  const F = (x, dec, unit) => `${hre.ethers.formatUnits(x, dec)} ${unit}`;

  // ── Live deployment: where the vault's assets actually sit ─────────────
  // All reads guarded; failures stay null (honest gaps), never zero-filled.
  const assetAddr = deployed.vault_asset || "0xb88339CB7199b77E23DB6E890353E22632Ba630f";
  const erc20 = new hre.ethers.Contract(
    assetAddr,
    ["function balanceOf(address) view returns (uint256)"],
    hre.ethers.provider,
  );
  let idle = null;
  try { idle = await erc20.balanceOf(deployed.pro_yield_vault); } catch { /* gap */ }

  const stratAbi = ["function totalAssets() view returns (uint256)"];
  const readStrat = async (addr) => {
    if (!addr) return null;
    try {
      const c = new hre.ethers.Contract(addr, stratAbi, hre.ethers.provider);
      return await c.totalAssets();
    } catch { return null; }
  };

  // Live rates for the sleeves — floating, so they ship with the feed.
  // 2026-10-04: lane-aware — resolved in the DN composition below (the
  // strategy's live perp position is the lane; no hardcode survives a rotation).
  let fundingAprPct = null;
  let lendingApyPct = null;
  try {
    const marketId = deployed.morpho_market && deployed.morpho_market.market_id;
    if (marketId) {
      const r = await fetch("https://blue-api.morpho.org/graphql", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: `{ markets(first: 1, where: { uniqueKey_in: ["${marketId}"] }) { items { state { supplyApy } } } }`,
        }),
      });
      const j = await r.json();
      const apy = j && j.data && j.data.markets && j.data.markets.items && j.data.markets.items[0]
        ? j.data.markets.items[0].state.supplyApy
        : null;
      if (apy != null) lendingApyPct = Number((apy * 100).toFixed(2));
    }
  } catch { /* gap */ }

  const fmt6 = (x) => (x == null ? null : hre.ethers.formatUnits(x, assetDec));
  const strategies = [];
  const morphoAssets = await readStrat(deployed.morpho_strategy);
  if (morphoAssets != null) {
    strategies.push({
      kind: "lending",
      name: "Morpho Blue",
      address: deployed.morpho_strategy,
      assets: fmt6(morphoAssets),
      apyPct: lendingApyPct,
    });
  }
  // ── DN sleeve — FULL self-composed value (2026-10-04 rotation lesson):
  // strategy.totalAssets() is an EVM view that goes stale the moment the lane
  // moves on HyperCore (it read $1.28 while $30 sat on Core). Compose from HL
  // directly: perp accountValue + EVERY Core spot balance priced at its pair.
  let dnUsd = null;
  let dnSzi = null;
  let laneCoin = null;
  let dnTrue6 = null;
  // HL info fetch with one retry — the info API rate-limits bursts, and a
  // silent empty read here zeroes the sleeve in the reconcile (seen 2026-10-05).
  const hlInfo = async (body) => {
    for (let i = 0; i < 3; i++) {
      try {
        const r = await fetch("https://api.hyperliquid.xyz/info", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        });
        if (r.ok) return await r.json();
      } catch { /* retry */ }
      await new Promise((r) => setTimeout(r, 2500 * (i + 1)));
    }
    return null;
  };
  try {
    const [sPerp, sSpot, smAc] = await Promise.all([
      hlInfo({ type: "clearinghouseState", user: deployed.dn_core_strategy }),
      hlInfo({ type: "spotClearinghouseState", user: deployed.dn_core_strategy }),
      hlInfo({ type: "spotMetaAndAssetCtxs" }),
    ]);
    if (!sPerp || !sSpot || !smAc) throw new Error("HL info unavailable (rate-limited) — DN value skipped this run");
    const perpAv = Number(sPerp?.marginSummary?.accountValue ?? 0);
    const pos = (sPerp?.assetPositions || []).find((p) => Number(p?.position?.szi ?? 0) !== 0);
    laneCoin = pos ? pos.position.coin : null;
    dnSzi = pos ? Number(pos.position.szi) : 0;
    // the lane's LIVE funding rate + PERP marks (metaAndAssetCtxs). 2026-10-05:
    // the SPOT ctxs endpoint serves DEGRADED marks to throttled clients (HYPE
    // at $0.082, ONEAR at $0.56, all dayNtlVlm 0) while this endpoint stays
    // healthy — so the hedge is priced at the PERP mark of its roster coin
    // (the hedge tracks the perp within ~0.2% by design).
    const perpPx = {};
    try {
      const r2 = await fetch("https://api.hyperliquid.xyz/info", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ type: "metaAndAssetCtxs" }),
      });
      const j2 = await r2.json();
      (j2?.[0]?.universe || []).forEach((u, i) => {
        perpPx[u.name] = parseFloat(j2[1][i]?.markPx ?? "0");
      });
      const pi = (j2?.[0]?.universe || []).findIndex((u) => u.name === laneCoin);
      if (laneCoin && pi >= 0) {
        fundingAprPct = Number((parseFloat(j2[1][pi].funding) * 24 * 365 * 100).toFixed(2));
      }
    } catch { /* gap */ }
    // structure from the spot snapshot: token names → pair numbers (names and
    // pair topology stay correct even when marks are degraded)
    const tokName = {};
    (smAc?.[0]?.tokens || []).forEach((t) => { tokName[t.index] = t.name; });
    const name2pairNum = {};
    (smAc?.[0]?.universe || []).forEach((u) => {
      const base = tokName[u.tokens[0]];
      if (base && !(base in name2pairNum)) name2pairNum[base] = String(u.name).replace("@", "");
    });
    // roster: pair number ↔ perp coin (ONEAR→NEAR, UBTC→BTC, HYPE→HYPE, …)
    let coinByPairNum = {};
    try {
      const roster = JSON.parse(fs.readFileSync(path.join(__dirname, "dn_roster.json"), "utf8"));
      Object.entries(roster.coins).forEach(([nm, e]) => { coinByPairNum[String(e.spotPair)] = nm; });
    } catch { /* roster missing — hedge falls back to spot marks */ }
    // the hedge token = the strategy's CONFIGURED spot token
    let stratTokIdx = null;
    try {
      const sel = hre.ethers.id("spotTokenIndex()").slice(0, 10);
      const rTok = await hre.ethers.provider.call({ to: deployed.dn_core_strategy, data: sel });
      stratTokIdx = Number(BigInt(rTok));
    } catch { /* gap — fall back to the name map */ }
    const hedgeTokName = stratTokIdx != null ? tokName[stratTokIdx] : null;
    let spotUsd = 0;
    for (const b of sSpot?.balances || []) {
      if (b.coin === "USDC") { spotUsd += Number(b.total); continue; }
      let px = 0;
      if (b.coin === hedgeTokName && laneCoin && perpPx[laneCoin]) {
        px = perpPx[laneCoin]; // THE hedge: its own lane's perp mark
      } else {
        const rosterCoin = coinByPairNum[name2pairNum[b.coin]];
        if (rosterCoin && perpPx[rosterCoin]) px = perpPx[rosterCoin]; // tracked dust
      }
      if (!px) px = 0; // unknown token with no perp mark — left at $0, disclosed in the debug line
      spotUsd += Number(b.total) * px;
    }
    dnUsd = perpAv + spotUsd;
    dnTrue6 = BigInt(Math.round(dnUsd * 1e6));
    if (process.env.RECONCILE_DEBUG === "1") {
      console.log(`[dn-debug] lane=${laneCoin} hedge=${hedgeTokName}@${perpPx[laneCoin]} spotUsd=${spotUsd.toFixed(4)} perpAv=${perpAv.toFixed(4)} dnUsd=${dnUsd.toFixed(4)}`);
    }
  } catch (e) {
    console.warn("DN composition gap:", String(e.message || e).slice(0, 120));
  }
  if (dnUsd != null) {
    strategies.push({
      kind: "funding",
      name: "Funding sleeve",
      address: deployed.dn_core_strategy,
      assets: fmt6(dnTrue6),
      apyPct: fundingAprPct,
      lane: laneCoin || undefined,
      // Below HL's $10 order minimums the sleeve cannot trade — say so
      // instead of implying the rate is being earned. Funded but flat is a
      // DIFFERENT state: the keeper opens when funding clears the bar.
      ...(dnUsd < 11
        ? { note: "idle — below venue minimums until TVL grows" }
        : dnSzi === 0
          ? { note: "funded — opens when funding clears the bar" }
          : laneCoin
            ? { note: `${laneCoin} lane` }
            : {}),
    });
  }
  // PT fixed-rate sleeve — entry rate from Pendle's public API; the rate is
  // LOCKED at purchase, so the note labels it as the current entry rate + maturity.
  const ptAssets = await readStrat(deployed.pt_sleeve_strategy);
  if (ptAssets != null) {
    let ptApyPct = null;
    let ptExpiry = null;
    try {
      const mk = process.env.PT_MARKET || "0xa8a0dea40174cfc30fea9e3a77f182ab33f46e25";
      const r = await fetch(`https://api-v2.pendle.finance/core/v1/42161/markets/${mk}`);
      const j = await r.json();
      if (j && j.impliedApy != null) ptApyPct = Number((j.impliedApy * 100).toFixed(2));
      if (j && j.expiry) ptExpiry = String(j.expiry).slice(0, 10);
    } catch { /* gap */ }
    strategies.push({
      kind: "fixed",
      name: "Fixed-rate sleeve (PT)",
      address: deployed.pt_sleeve_strategy,
      assets: fmt6(ptAssets),
      apyPct: ptApyPct,
      note: `fixed-rate sleeve — locked at purchase; rate above is the current entry rate${ptExpiry ? ` · matures ${ptExpiry}` : ""}`,
    });
  }
  // PT ETH lane (CCTP → Ethereum executor → Pendle PT): holds its allocation
  // as USDC until the lane's executor flow ships it (the lane is not wired
  // into pt_keeper's HE/ARB passes yet). Show it honestly rather than hiding
  // $18.95 of vault money from the deployment card.
  const ptEthAssets = await readStrat(deployed.pt_sleeve_eth_strategy);
  if (ptEthAssets != null && ptEthAssets > 0n) {
    strategies.push({
      kind: "fixed",
      name: "Fixed-rate sleeve (PT, ETH lane)",
      address: deployed.pt_sleeve_eth_strategy,
      assets: fmt6(ptEthAssets),
      apyPct: null,
      note: "ETH lane — allocation held until the executor flow ships it to Pendle",
    });
  }
  // HL Earn idle-cash sleeve (CoreWriter action 15): policy-gated — NOT
  // scheduled until one watched proof cycle completes. Funds held as USDC.
  const hlearnAssets = await readStrat(deployed.hlearn_strategy);
  if (hlearnAssets != null && hlearnAssets > 0n) {
    strategies.push({
      kind: "lending",
      name: "HL Earn (idle-cash)",
      address: deployed.hlearn_strategy,
      assets: fmt6(hlearnAssets),
      apyPct: null,
      note: "awaiting watched proof cycle — funds held",
    });
  }
  // ── Reconcile: venue reads vs vault book ────────────────────────────────
  // Venue reads (idle + each sleeve's totalAssets()) include facts the vault
  // book settles LATER: sleeve P&L not yet harvested/settled, and non-user
  // floats that passed through the vault's ops payouts. Publish both sides +
  // the delta, and flag drift beyond a band loudly in the cron log so a
  // silent divergence can never accumulate unnoticed again.
  // (Full worked example: docs/RECONCILE_2026-09-30.md — signed off at +$1.43.)
  // dnTrue6 (spot cash included) — using raw dnAssets here re-created the
  // −$12.68 phantom reconcile delta on 2026-10-02.
  const venuesSum6 =
    (idle || 0n) + (morphoAssets || 0n) + (dnTrue6 ?? 0n) + (ptAssets || 0n) +
    (ptEthAssets || 0n) + (hlearnAssets || 0n);
  if (process.env.RECONCILE_DEBUG === "1") {
    const f = (x) => (x == null ? "null" : Number(hre.ethers.formatUnits(x, assetDec)).toFixed(2));
    console.log(`[debug] idle=${f(idle)} morpho=${f(morphoAssets)} dnTrue=${f(dnTrue6)} pt=${f(ptAssets)} ptEth=${f(ptEthAssets)} hlearn=${f(hlearnAssets)}`);
  }
  const delta6 = venuesSum6 - totalAssets;
  const absDelta6 = delta6 < 0n ? -delta6 : delta6;
  const deltaSign = delta6 < 0n ? "-" : "+";
  const bandUsd = Math.max(1.5, 0.03 * Number(hre.ethers.formatUnits(totalAssets, assetDec)));
  const reconcile = {
    venuesSumUsdc: fmt6(venuesSum6),
    navUsdc: fmt6(totalAssets),
    deltaUsdc: `${deltaSign}${fmt6(absDelta6)}`,
    bandUsdc: bandUsd.toFixed(2),
    note: "venue live reads vs vault book — interim differences settle at harvest/recall; both sides published",
  };
  if (Number(hre.ethers.formatUnits(absDelta6, assetDec)) > bandUsd) {
    console.log(
      `RECONCILE ALERT: venues ${reconcile.venuesSumUsdc} vs book ${reconcile.navUsdc} — ` +
        `delta ${reconcile.deltaUsdc} exceeds band $${reconcile.bandUsdc}. Investigate before cap-raise comms.`,
    );
  }

  // ── Pulse: when did each sleeve last post profit to the vault book? ──────
  // (2026-10-04, owner ask: the ~6h harvest cadence was invisible — the
  // activity tile only shows USER events. The feed's own ts ticks at harvest,
  // and per-sleeve lastHarvest makes it explicit. Guarded reads; honest gaps.)
  const lastHarvestAbi = ["function lastHarvest() view returns (uint256)"];
  const readLastHarvest = async (addr) => {
    if (!addr) return null;
    try {
      const c = new hre.ethers.Contract(addr, lastHarvestAbi, hre.ethers.provider);
      const t = Number(await c.lastHarvest());
      if (!t) return null;
      return {
        at: new Date(t * 1000).toISOString(),
        hoursAgo: Number(((Date.now() / 1000 - t) / 3600).toFixed(1)),
      };
    } catch { return null; }
  };
  const pulse = {
    lending_morpho: await readLastHarvest(deployed.morpho_strategy),
    funding_dn: await readLastHarvest(deployed.dn_core_strategy),
    fixed_pt: await readLastHarvest(deployed.pt_sleeve_strategy),
    lending_hlearn: await readLastHarvest(deployed.hlearn_strategy),
    note: "last profit-harvest per sleeve (on-chain lastHarvest). The funding keeper runs ~every 6h — each run posts accrued funding profit into the vault book (share price). Fixed-rate posts at maturity; HL Earn posts on kink sweeps.",
  };

  const deployment = {
    idleUsdc: fmt6(idle),
    strategies,
    assetsTotalUsdc: fmt6(venuesSum6),
    note: "live chain reads; strategies report totalAssets(); rates float with the market",
    // Display gate (owner-checked marker): the Boost card shows its LIVE figure
    // only after the funding sleeve completes its first full watched cycle.
    // Flip: create ~/.proyield/boost_loop_watched — next refresh publishes it.
    flags: { boostLive: fs.existsSync(require("path").join(require("os").homedir(), ".proyield", "boost_loop_watched")) },
    reconcile,
  };

  const tag = process.env.SMOKE_TAG;
  const status = {
    vault: deployed.pro_yield_vault,
    sharePrice: F(price18, 18, "USDC"),
    totalAssets: F(totalAssets, assetDec, "USDC"),
    totalShares: F(totalShares, shownShareDec, "shares"),
    targetApyBps: null,
    deployment,
    pulse,
    recycling: { total: 0, boost: 0, runs: 0, last: null },
    ts: new Date().toISOString(),
    // Honest label: the declared chain when the manifest names one, otherwise
    // the local smoke path (the web smoke runs against the battery's anvil).
    network: declared
      ? `${declared.name || "chain " + declared.id} (chain ${declared.id}, verified)${tag ? " " + tag : ""}`
      : `local smoke${tag ? " " + tag : ""} (anvil, chain 998)`,
    chainId: actual,
    source: "scripts/write_vault_status.js",
  };

  // ── Multi-book schema v2 (Way A / W3a) — ADDITIVE ────────────────────────
  // Every v1 top-level field above stays in place; books[0] MUST reproduce them
  // and the canary below refuses to publish if it drifts. A book that is not yet
  // deployed (book #2 / Boost, and any other registry book) publishes an HONEST
  // GAP (null + deployed:false) — never a fabricated 0, never core's numbers.
  try {
    const core = {
      vault: status.vault,
      feeDistributor: deployed.fee_distributor || null,
      sharePrice: status.sharePrice,
      totalAssets: status.totalAssets,
      totalShares: status.totalShares,
      deployment: status.deployment,
      pulse: status.pulse,
      ts: status.ts,
    };
    // Per-book live reads for ACTIONABLE books (registry deployed:true + manifest
    // present). Empty today — book #2 is on-chain but not yet actionable, so the
    // loop no-ops; it lights up the moment the W2 actionability flip lands.
    const bookReads = {};
    for (const b of schema.deployedBooks()) {
      const V = b.manifest.pro_yield_vault;
      if (!V) continue;
      try {
        const bc = new hre.ethers.Contract(V, ["function totalAssets() view returns (uint256)"], hre.ethers.provider);
        const ta = await bc.totalAssets();
        const ts = await readTotalShares(V);
        const [assetDecB] = await readScales(V, [b.manifest.vault_asset]);
        const priceB = ts > 0n ? (ta * 10n ** 18n) / ts : 10n ** 18n;
        bookReads[b.id] = {
          totalAssets: hre.ethers.formatUnits(ta, assetDecB) + " USDC",
          totalShares: hre.ethers.formatUnits(ts, assetDecB) + " shares",
          sharePrice: hre.ethers.formatUnits(priceB, 18) + " USDC",
        };
      } catch { /* honest gap — leave the number null, never a fabricated 0 */ }
    }
    const books = schema.buildBooks({ core, reads: bookReads });
    schema.assertCoreCanary({ core, books }); // throws on drift
    status.books = books;
  } catch (e) {
    console.error(`REFUSING: multi-book schema canary failed — ${(e && e.message) || e}; not publishing a drifted feed.`);
    process.exit(3);
  }

  const outs = [process.env.VAULT_STATUS_OUT || path.join(WEB, "public", "vault_status.json")];
  const dist = path.join(WEB, "dist", "vault_status.json");
  if (fs.existsSync(path.dirname(dist))) outs.push(dist);
  for (const o of outs) {
    fs.writeFileSync(o, JSON.stringify(status, null, 1));
    console.log("wrote", o);
  }
  console.log(`totalAssets=${status.totalAssets} sharePrice=${status.sharePrice}`);

  // ── System events feed (2026-10-04) ───────────────────────────────────────
  // The activity tile froze after Oct 1-2: CF-side chain scans get rate-limited
  // by Hyperliquid (shared CF egress IPs, -32005), so vault-ops scans returned
  // empty and the tile had no fresh harvest rows. Architectural fix: the KEEPER
  // (this machine — reliable RPC, one call per 6h) owns the system-event feed.
  // Each run diffs share price vs the previous stored state: profit posted =
  // (priceNow − pricePrev) × totalShares — deposits/withdrawals don't move the
  // price, so the delta isolates the harvest. Real measured number, no estimate.
  // Published as /vault_events.json (last 30) — the tile merges it client-side.
  // Gate on the CHAIN-IDENTITY (a declared chain = real network). Cold-start
  // manifests have no chain block; the mainnet cron runs WITH a manifest.
  if (!declared) {
    console.log("smoke mode (no chain declared): events feed not written");
  } else {
    const EVENTS_LED = "/home/user/yield_scout/data/vault_events.jsonl";
    const eventsDir = path.dirname(EVENTS_LED);
    if (!fs.existsSync(eventsDir)) fs.mkdirSync(eventsDir, { recursive: true });
    let prev = null;
    // 2026-10-04 fix: this read used `eventsDir` (the DIRECTORY — EISDIR →
    // catch → prev stayed null → every run emitted a fresh "baseline" with no
    // delta). Read the LEDGER file.
    try { prev = JSON.parse(fs.readFileSync(EVENTS_LED, "utf8").trim().split("\n").filter(Boolean).pop()); } catch { /* first run */ }
    // 2026-10-04 (rotation visibility): the trades happen on HyperCore — no
    // EVM logs — so the worker's chain scan never sees a lane change. The
    // writer resolves the lane anyway: when it differs from the last published
    // lane, emit a rotation event so the tile tells the story.
    let lanePrev = "HYPE";
    try {
      const laneLines = fs.readFileSync(EVENTS_LED, "utf8").trim().split("\n").filter(Boolean);
      for (let i = laneLines.length - 1; i >= 0; i--) {
        const e = JSON.parse(laneLines[i]);
        if (e.lane) { lanePrev = e.lane; break; }
      }
    } catch { /* first run */ }
    const laneChanged = laneCoin && lanePrev !== laneCoin;
    const priceNow = Number(price18) / 1e18;
    const sharesNow = Number(totalShares) / 10 ** shownShareDec;
    let profitPosted = null;
    if (prev && prev.share_price) {
      profitPosted = (priceNow - Number(prev.share_price)) * sharesNow;
    }
    // No-noise rule: no share-price movement since the last run = no harvest
    // posted = no event (the tile shows what HAPPENED, not that a read ran) —
    // a lane CHANGE always publishes (it is what happened).
    if (prev && !laneChanged && Math.abs(profitPosted ?? 0) < 5e-7) {
      console.log("vault_events: no profit movement since last run — no event appended");
    } else {
    const ev = laneChanged
      ? {
          ts: status.ts,
          kind: "vault_rotation",
          title: `Funding lane rotated: ${lanePrev} → ${laneCoin}`,
          profit_posted_usd: null,
          share_price: priceNow,
          total_assets: Number(hre.ethers.formatUnits(totalAssets, assetDec)),
          lane: laneCoin,
          tx: null,
        }
      : {
          ts: status.ts,
          kind: "vault_harvest",
          title: profitPosted == null
            ? "Keeper harvest (baseline event)"
            : profitPosted >= 0
              ? `Harvest — profit posted: +$${profitPosted.toFixed(4)}`
              : `Harvest — loss posted: −$${Math.abs(profitPosted).toFixed(4)}`,
          profit_posted_usd: profitPosted == null ? null : Number(profitPosted.toFixed(6)),
          share_price: priceNow,
          total_assets: Number(hre.ethers.formatUnits(totalAssets, assetDec)),
          lane: laneCoin || undefined,
          tx: null, // the keeper's harvest tx lands in the pulse/log; the writer is a read pass
        };
    fs.appendFileSync(EVENTS_LED, JSON.stringify(ev) + "\n");
    // publish last 30 (cap the file at 200 lines)
    let lines = fs.readFileSync(EVENTS_LED, "utf8").trim().split("\n").filter(Boolean);
    if (lines.length > 200) {
      lines = lines.slice(-200);
      fs.writeFileSync(EVENTS_LED, lines.join("\n") + "\n");
    }
    const feed = lines.slice(-30).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    const evOuts = [
      path.join(WEB, "public", "vault_events.json"),
      path.join(WEB, "dist", "vault_events.json"),
    ];
    for (const o of evOuts) {
      if (fs.existsSync(path.dirname(o))) fs.writeFileSync(o, JSON.stringify({ events: feed }, null, 1));
    }
    console.log(`vault_events: ${feed.length} published (latest: ${ev.title})`);
    } // inner else (zero-delta skip)
  }
}

main().catch((e) => {
  console.error("write_vault_status error:", (e && e.stack) || e);
  process.exit(2);
});
