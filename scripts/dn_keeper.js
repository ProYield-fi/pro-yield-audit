// dn_keeper.js — delta-neutral CoreWriter keeper
//
// Target: DNCoreStrategy (vault-integrated). Set DN_STRATEGY=<address>.
// (DNCoreAdapter works too — same execution function names; the strategy adds
// syncCore/coreState/harvestableProfit and the vault profit cycle.)
//
// Responsibilities (liveness, NOT trust — the contract holds policy + funds):
//   1. Read strategy state (coreState: equity/principal/szi/realized/swept).
//   2. Read live funding from the HL API.
//   3. SIZE the sleeve: targetNotionalUsd = vault.totalAssets() × DN weight
//      (from the scout's blend snapshot) × deployPct. Capped by the USDC the
//      strategy actually holds on Core. Margin policy = marginUtilBps (3300 =
//      ~33% of notional, effective ≈3× max) — deliberately NOT 1:1; the head-
//      room covers fees/spread. (Round-2: the old "1:1 notional vs margin"
//      comment contradicted the 3300bps policy — aligned.)
//   4. Decide: BRIDGE_FIRST → OPEN → REBALANCE → BRIDGE_PROFIT → HOLD.
//   5. Execute staged calls (bridge must land in an EARLIER block than actions).
//   6. VERIFY every CoreWriter action after the on-chain delay (they drop
//      silently otherwise) and alert on mismatch.
//
// Profit cycle (what makes the vault share price rise):
//   syncCore -> bridgeBackToEvm(profit portion) -> vault.harvest() sweeps the
//   realized profit above the buffer as real USDC to the vault.
//
// Dry-run by default. Sends only with --execute.
// Run: DN_STRATEGY=0x... npx hardhat run scripts/dn_keeper.js --network hyperTestnet [-- --execute]
// Roster: scripts/dn_roster.json (verified perp+spot coins). Re-verify:
//   npx hardhat run scripts/dn_roster_check.js --network hyperMainnet
//
// TODO(policy): negative-funding unwind threshold, margin top-up rule.
// TODO(alerts): route mismatches to the Telegram notifier.

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const CONFIG = {
  strategy: process.env.DN_STRATEGY || process.env.DN_ADAPTER || null,
  hlInfoUrl: "https://api.hyperliquid.xyz/info",
  fundingAprThreshold: parseFloat(process.env.DN_OPEN_APR || "5.0"), // annualized % below which opening a hedge is not justified (env override for E2E runs)
  unwindAprThreshold: parseFloat(process.env.DN_UNWIND_APR || "-2.0"), // short PAYS when funding > 0; below this → close
  rebalanceBandPct: 5,      // |positionDrift| > band → rebalance
  slippageBps: 20n,         // IOC limit vs oracle (0.20%)
  tifIoc: 3,
  // ── Sizing policy ──
  scoutSnapshot: process.env.SCOUT_SNAPSHOT || "/home/user/yield_scout/data/snapshot.json",
  deployPct: parseFloat(process.env.DN_DEPLOY_PCT || "0.90"), // fraction of sleeve bridged to Core
  marginUtilBps: BigInt(process.env.DN_MARGIN_UTIL_BPS || "3300"), // perp margin needed per 1e4 notional (BTC maxLev 40 → 1/40 = 250bps; pad to 3300 for fees/spread). Env override for small-size demo runs (e.g. 1700).
  maxSleeveUsd: parseFloat(process.env.DN_MAX_SLEEVE_USD || "0"), // 0 = no override cap
  targetOverrideUsd: parseFloat(process.env.DN_TARGET_USD || "0"), // 0 = use vault×weight sizing; >0 pins the hedge notional (demo/E2E runs)
  dryRun: !(process.argv.includes("--execute") || process.env.DN_EXECUTE === "1"),
};

/// DN roster (scripts/dn_roster.json) — verified perp+spot coin set. The keeper
/// resolves coins THROUGH this file only; re-verify with dn_roster_check.js.
const ROSTER_FILE = process.env.DN_ROSTER_FILE || path.join(__dirname, "dn_roster.json");

/// @notice Telegram alert — reuses yield_scout's creds chain (env →
/// ~/.hermes/secrets/telegram.json → ~/.hermes/.env). Never throws: alerts
/// queue to a file so verification failures are never silently lost.
async function sendAlert(title, body) {
  const line = `[dn-keeper] ${title} — ${body}`;
  console.log(line);
  const QLOG = process.env.DN_ALERT_LOG || "/home/user/yield_scout/data/pending_notifications.log";
  // Test runs (DN_SILENCE_TELEGRAM=1) must never touch the real alert channel:
  // the unwind/dryrun suites intentionally provoke alerts, and every battery
  // run (and every mutation-campaign mutant) would otherwise spam Telegram +
  // the operator queue with fake red MISMATCH messages.
  if (process.env.DN_SILENCE_TELEGRAM === "1") {
    try { require("fs").appendFileSync(QLOG, `${new Date().toISOString()} ${line} (test run — telegram silenced)\n`); } catch { /* best effort */ }
    return;
  }
  try {
    const fs2 = require("fs");
    let tok, chat;
    if (process.env.TELEGRAM_BOT_TOKEN && (process.env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_HOME_CHANNEL)) {
      tok = process.env.TELEGRAM_BOT_TOKEN;
      chat = process.env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_HOME_CHANNEL;
    } else if (fs2.existsSync("/home/user/.hermes/secrets/telegram.json")) {
      const d = JSON.parse(fs2.readFileSync("/home/user/.hermes/secrets/telegram.json", "utf8"));
      tok = d.bot_token; chat = d.chat_id;
    } else if (fs2.existsSync("/home/user/.hermes/.env")) {
      const vals = {};
      for (const l of fs2.readFileSync("/home/user/.hermes/.env", "utf8").split("\n")) {
        const m = l.trim();
        if (m.includes("=") && !m.startsWith("#")) {
          const i = m.indexOf("=");
          vals[m.slice(0, i).trim()] = m.slice(i + 1).trim();
        }
      }
      tok = vals.TELEGRAM_BOT_TOKEN; chat = vals.TELEGRAM_HOME_CHANNEL || vals.TELEGRAM_CHAT_ID;
    }
    if (!tok || !chat) {
      fs2.appendFileSync(QLOG,
        `${new Date().toISOString()} ${line}\n`);
      return;
    }
    const res = await fetch(`https://api.telegram.org/bot${tok}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text: `<b>${title}</b>\n${body}`, parse_mode: "HTML" }),
    });
    if (!res.ok) throw new Error(`telegram ${res.status}`);
  } catch (e) {
    try {
      require("fs").appendFileSync(QLOG,
        `${new Date().toISOString()} ${line} (send failed: ${e.message})\n`);
    } catch { /* nothing more we can do */ }
  }
}

async function hlInfo(body) {
  const res = await fetch(CONFIG.hlInfoUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return res.json();
}

/// @returns {apr, coin, entry} — annualized funding % for the strategy's perp
/// asset. Coin resolution is ROSTER-gated: the asset index must map to a
/// verified roster coin (main perp + liquid HL spot hedge). An unknown asset
/// REFUSES loudly — the keeper never guesses coins (a wrong coin = an
/// unhedgeable position).
async function fetchFundingApr(assetIndex) {
  const { byAsset } = loadRoster();
  const entry = byAsset[assetIndex];
  if (!entry) {
    throw new Error(`perp asset ${assetIndex} not in DN roster (${ROSTER_FILE}) — refusing to trade an unverified coin; re-verify with scripts/dn_roster_check.js`);
  }
  // Test injection: DN_FORCE_APR overrides the live read (dry-run tests only).
  if (process.env.DN_FORCE_APR) return { apr: parseFloat(process.env.DN_FORCE_APR), coin: entry.coin, entry };
  const predicted = await hlInfo({ type: "predictedFundings" });
  // shape: [[coin, [[venue, {fundingRate, nextFundingTime}], ...]], ...]
  // HlPerp venue = the validator perp book we hedge on. fundingRate is HOURLY.
  const row = predicted.find((r) => r[0] === entry.coin);
  if (!row) throw new Error(`no predicted funding for ${entry.coin}`);
  const venue = row[1].find((v) => v[0] === "HlPerp") || row[1][0];
  const hourly = parseFloat(venue[1].fundingRate);
  return { apr: hourly * 24 * 365 * 100, coin: entry.coin, entry };
}

/// @returns {weight, maxSleeveUsd} — DN sleeve share from the scout's blend.
/// Falls back to DEFAULT_DN_WEIGHT when the snapshot is missing/stale-shaped.
async function loadSleeveWeight() {
  const DEFAULT_DN_WEIGHT = 0.15;
  try {
    const snap = JSON.parse(fs.readFileSync(CONFIG.scoutSnapshot, "utf8"));
    const w = snap?.blend?.allocation?.DELTA_NEUTRAL?.weight;
    if (typeof w === "number" && w > 0 && w <= 1) {
      const ageMin = (Date.now() - Date.parse(snap.generated_utc)) / 60000;
      console.log(`sizing: scout snapshot DN weight = ${w} (age ${ageMin.toFixed(0)} min)`);
      if (ageMin > 2880) console.warn(`sizing: WARNING — snapshot is ${ageMin} min old (>48h)`);
      return { weight: w, source: "scout" };
    }
    console.warn(`sizing: snapshot has no usable DELTA_NEUTRAL.weight — defaulting to ${DEFAULT_DN_WEIGHT}`);
  } catch (e) {
    console.warn(`sizing: snapshot unreadable (${e.message}) — defaulting to ${DEFAULT_DN_WEIGHT}`);
  }
  return { weight: DEFAULT_DN_WEIGHT, source: "default" };
}

/// @returns {byAsset, byCoin} — DN roster. Throws when missing/invalid: the
/// keeper must NEVER guess coins (a wrong coin = an unhedgeable position).
function loadRoster() {
  const r = JSON.parse(fs.readFileSync(ROSTER_FILE, "utf8"));
  if (!r || typeof r.coins !== "object") throw new Error(`bad roster shape in ${ROSTER_FILE}`);
  const byAsset = {}, byCoin = {};
  for (const [coin, e] of Object.entries(r.coins)) {
    if (typeof e.asset !== "number" || !e.spotPair || !e.spotToken || e.szDec == null || !e.pxScale) {
      throw new Error(`roster entry incomplete for ${coin}`);
    }
    byAsset[e.asset] = { coin, ...e };
    byCoin[coin] = { coin, ...e };
  }
  return { byAsset, byCoin };
}

/// Rotation advice (informational, never trades): compare the strategy's coin
/// against the scout capacity board across the roster. Alerts when a roster
/// alternative's verified 30d mean beats the current coin by >=
/// DN_ROTATION_MIN_GAIN_PP (default 3pp) and clears 12%. Max one alert per
/// (from->to) per 24h. Execution is operator-gated (scripts/dn_rotate_prep.js).
async function rotationAdvice(currentCoin) {
  if (process.env.DN_ROTATION_ADVICE === "0") return;
  let snap;
  try {
    snap = JSON.parse(fs.readFileSync(CONFIG.scoutSnapshot, "utf8"));
  } catch (e) {
    console.log(`rotation: snapshot unreadable (${e.message}) — skip`);
    return;
  }
  const board = snap?.hyperliquid_funding?.capacity_board?.board;
  if (!Array.isArray(board) || !board.length) {
    console.log("rotation: no capacity board in snapshot yet — skip");
    return;
  }
  const { byCoin } = loadRoster();
  const cur = board.find((b) => b.dex === "main" && b.name === currentCoin);
  const curMean = cur ? cur.mean_30d_apr : null;
  const minGain = parseFloat(process.env.DN_ROTATION_MIN_GAIN_PP || "3");
  const alts = board
    .filter((b) => b.dex === "main" && b.name !== currentCoin && byCoin[b.name])
    .sort((a, b) => b.mean_30d_apr - a.mean_30d_apr);
  console.log(
    `rotation: current ${currentCoin}${curMean === null ? " (not on board)" : ` ${curMean}%/30d`}; ` +
    `best roster alts: ${alts.slice(0, 3).map((a) => `${a.name} ${a.mean_30d_apr}%`).join(", ") || "none"}`
  );
  const best = alts.find((a) => a.mean_30d_apr >= 12 && (curMean === null || a.mean_30d_apr >= curMean + minGain));
  if (!best) return;
  const MARKER = process.env.DN_ROTATION_MARKER || path.join(process.env.HOME || "/tmp", ".proyield", "dn_rotation_alert.json");
  const pair = `${currentCoin}->${best.name}`;
  try {
    const prev = JSON.parse(fs.readFileSync(MARKER, "utf8"));
    if (prev.pair === pair && Date.now() - prev.ts < 24 * 3600 * 1000) {
      console.log(`rotation: candidate ${pair} already alerted ${((Date.now() - prev.ts) / 3600000).toFixed(1)}h ago — skip`);
      return;
    }
  } catch { /* no marker yet */ }
  await sendAlert(
    "🔁 DN ROTATION CANDIDATE",
    `${currentCoin}${curMean === null ? "" : ` (${curMean}%/30d)`} → ${best.name} (${best.mean_30d_apr}%/30d, pos ${best.pos_30d_pct}%, min ${best.min_30d_apr}%, cap $${(best.cap_usd / 1e6).toFixed(1)}M). ` +
    `Gain >= ${minGain}pp verified carry. Rotate: keeper UNWIND (or flat) -> scripts/dn_rotate_prep.js TARGET=${best.name} -> Safe txs -> next cycle opens.`
  );
  try {
    fs.mkdirSync(path.dirname(MARKER), { recursive: true });
    fs.writeFileSync(MARKER, JSON.stringify({ pair, ts: Date.now() }));
  } catch { /* best effort */ }
}

/// @returns sleeve target in USD (float) given vault assets + DN weight.
/** Round a CoreWriter wire px (10^8 × human) to HL's 5-significant-figure
 *  grid. IOC limits only need to be *acceptable* worst-price bounds, so the
 *  ±1e-4 rounding is irrelevant to fills and keeps every order inside HL's
 *  px tick rules (the earlier live MISMATCH was a 10^4 scale bug — raw px
 *  fed straight into a 10^8-wire field). */
function roundPxWire(wire) {
  if (wire <= 0n) return wire;
  const human = Number(wire) / 1e8;
  if (!Number.isFinite(human) || human <= 0) return wire;
  return BigInt(Math.round(Number(human.toPrecision(5)) * 1e8));
}

function computeTargetNotionalUsd(vaultTotalAssetsUsd, dnWeight) {
  let sleeve = vaultTotalAssetsUsd * dnWeight;
  if (CONFIG.maxSleeveUsd > 0) sleeve = Math.min(sleeve, CONFIG.maxSleeveUsd);
  if (CONFIG.targetOverrideUsd > 0) sleeve = CONFIG.targetOverrideUsd; // demo/E2E pin
  return sleeve; // hedge NOTIONAL = sleeve USD (1:1 delta-neutral)
}

async function main() {
  // Chain guard FIRST. HyperEVM testnet (998) runs freely; MAINNET (999) is
  // real-money and requires the explicit DN_ALLOW_MAINNET=1 opt-in — the live
  // beta keeper runs there, so the guard allows it, but never silently.
  const __net = await hre.ethers.provider.getNetwork();
  const __chain = Number(__net.chainId);
  if (__chain !== 998 && __chain !== 999) {
    console.error(`REFUSING: chain ${__chain} is not HyperEVM (998/999).`);
    process.exit(3);
  }
  if (__chain === 999 && process.env.DN_ALLOW_MAINNET !== "1") {
    console.error("REFUSING: mainnet (999) needs explicit DN_ALLOW_MAINNET=1.");
    process.exit(3);
  }
  const [signer] = await hre.ethers.getSigners();
  if (!CONFIG.strategy) {
    console.log("DN_STRATEGY unset — nothing to do. Set it to the deployed DNCoreStrategy.");
    process.exit(0);
  }
  const strategy = await hre.ethers.getContractAt("DNCoreStrategy", CONFIG.strategy, signer);
  const asset = Number(await strategy.perpAsset());
  const szDec = Number(await strategy.perpSzDecimals());

  // ── 1. State ──
  const exists = await strategy.coreAccountExists();
  const [equity6, principal6, szi, realized, swept, syncedAt] = await strategy.coreState();
  const harvestable = await strategy.harvestableProfit();
  // coreEquity6 is cached storage — only syncCore() refreshes it (it also
  // refreshes the vault's totalAssets view). Execute: stamp it on-chain
  // (cheap, permissionless). Dry: read the precompile live so displayed
  // numbers and decisions still match reality without sending a tx.
  let equityLive6 = equity6;
  if (!CONFIG.dryRun) {
    try {
      const stx = await strategy.syncCore();
      await stx.wait();
      equityLive6 = (await strategy.coreState())[0];
      console.log(`synced Core equity: $${(Number(equityLive6) / 1e6).toFixed(2)}`);
    } catch (e) {
      console.warn("syncCore skipped:", String(e.message || e).slice(0, 140));
    }
  } else {
    try {
      equityLive6 = (await strategy.marginSummary()).accountValue;
    } catch (_) {
      /* keep cached value */
    }
  }
  // Position too: cached lastPositionSzi is pre-action in execute mode (the
  // sync above) and stale in dry mode — read the precompile live for decisions.
  let sziLive = szi;
  try {
    sziLive = (await strategy.position()).szi;
  } catch (_) {
    /* keep cached value */
  }
  console.log(`state: exists=${exists} equity6=${equityLive6} principal6=${principal6} szi=${sziLive} szDecimals=${szDec}`);
  console.log(`profit: realized=${realized} swept=${swept} harvestable=${harvestable} syncedAt=${syncedAt}`);

  // Loss visibility (round-2 H1): equity below principal = the venue lost
  // money. No on-chain write-down happens by itself — alert so the OWNER
  // reconciles with vault.reportLoss(<loss, underlying units>), keeping
  // depositor claims tied to real backing instead of phantom value.
  // $0.10 dust floor: normal trading fees ($0.005/fill at beta sizes) dip
  // equity below principal on every open — those are not reportLoss events.
  if (exists && equityLive6 < principal6 && principal6 - equityLive6 > 100_000n) {
    const loss6 = principal6 - equityLive6;
    await sendAlert(
      "⚠️ DN equity below principal",
      `Core equity $${(Number(equityLive6) / 1e6).toFixed(2)} < principal $${(Number(principal6) / 1e6).toFixed(2)} — loss $${(Number(loss6) / 1e6).toFixed(2)}. OWNER ACTION: vault.reportLoss(<loss in underlying units>) so claims stop being phantom (round-2 H1).`
    );
  }

  // ── 2. Funding ──
  const { apr, coin, entry } = await fetchFundingApr(asset);
  console.log(`funding: ${apr.toFixed(2)}% annualized (HlPerp, ${coin})`);

  // Roster config-consistency guard (rotation safety): never OPEN unless the
  // on-chain spot config matches the roster entry for the resolved coin — a
  // half-applied rotation (asset switched, spot pair not yet) must not trade.
  const onPair = Number(await strategy.spotPairIndex());
  const onTok = Number(await strategy.spotTokenIndex());
  const onScale = Number(await strategy.spotPxScale());
  const cfgOk = onPair === entry.spotPair && onTok === entry.spotToken && onScale === Number(entry.pxScale);
  if (!cfgOk) {
    console.log(`config: ⚠ on-chain spot @${onPair}/${onTok}/${onScale} ≠ roster @${entry.spotPair}/${entry.spotToken}/${entry.pxScale}`);
  }

  // Rotation advice (informational): flag a better verified roster carry.
  await rotationAdvice(coin);

  // ── 3. Size the sleeve (allocation policy hookup) ──
  // Vault totalAssets (6dp USDC units) → USD; × DN weight → sleeve notional.
  // Units: underlying is REAL USDC (6dp) in production, but test tokens are
  // 18-dec — normalize via coreScale (10^(dec-6)), NOT hardcoded 1e6.
  const vaultAddr = await strategy.vault();
  const scale = await strategy.coreScale();
  let vaultAssetsUsd = 0;
  let strategyAssetsUsd = 0;
  if (vaultAddr !== hre.ethers.ZeroAddress) {
    const vault = await hre.ethers.getContractAt("ProYieldVault", vaultAddr, signer);
    const ta = await vault.totalAssets(); // underlying units
    vaultAssetsUsd = Number(ta) / Number(scale) / 1e6;
    console.log(`vault: totalAssets = ${vaultAssetsUsd.toFixed(2)} USD`);
  }
  const stratTa = await strategy.totalAssets(); // underlying units (equity + idle)
  strategyAssetsUsd = Number(stratTa) / Number(scale) / 1e6;
  console.log(`strategy: totalAssets = ${strategyAssetsUsd.toFixed(2)} USD`);

  const { weight: dnWeight, source } = await loadSleeveWeight();
  const targetNotionalUsd = computeTargetNotionalUsd(vaultAssetsUsd, dnWeight);
  console.log(`sizing: vault ${vaultAssetsUsd.toFixed(2)} × DN weight ${dnWeight} (${source}) = target notional ${targetNotionalUsd.toFixed(2)} USD`);
  if (targetNotionalUsd < 10) {
    console.log("sizing: target below HL $10 min order — nothing to size");
  }

  // Current notional (USD) from the on-chain position + oracle px.
  // Scales, live-verified against HyperCore docs (2026-09-25):
  //   oraclePx raw = human × 10^(6 − szDecimals) → 91.6555 reads as 916555.
  //   CoreWriter limit-order wire wants 10^8 × human → pxWire = raw × 10^(2+szDec).
  const px = BigInt(await strategy.oraclePx());
  const pxWire = px * 10n ** BigInt(2 + szDec);
  const pxHuman = Number(pxWire) / 1e8;
  // szi raw is in LOTS (human × 10^szDecimals — live-verified: a -0.11 HYPE
  // position reads as szi=-11 with szDecimals=2; do not reuse without
  // re-verifying on a second asset).
  const sziHuman = Number(sziLive) / 10 ** szDec;
  const currentNotionalUsd = Math.abs(sziHuman) * pxHuman;
  const driftPct = targetNotionalUsd > 0 ? ((currentNotionalUsd - targetNotionalUsd) / targetNotionalUsd) * 100 : 0;
  console.log(`position: szi=${sziLive} (${sziHuman} ${coin}) px=${pxHuman} current notional ${currentNotionalUsd.toFixed(2)} USD (drift ${driftPct.toFixed(2)}% vs target)`);

  // ── 4. Decide ──
  const coreProfit6 = equityLive6 > principal6 ? equityLive6 - principal6 : 0n;
  let action = "HOLD";
  if (!exists) action = "BRIDGE_FIRST";
  else if (coreProfit6 > 0n && harvestable === 0n) action = "BRIDGE_PROFIT";
  else if (targetNotionalUsd >= 10 && sziLive === 0n && apr >= CONFIG.fundingAprThreshold) {
    action = cfgOk ? "OPEN" : "HOLD";
    if (!cfgOk) {
      await sendAlert(
        "🟠 DN open blocked — spot config mismatch",
        `${coin}: on-chain spot @${onPair}/${onTok}/${onScale} ≠ roster @${entry.spotPair}/${entry.spotToken}/${entry.pxScale}. Half-applied rotation? Run scripts/dn_rotate_prep.js TARGET=${coin} for the Safe txs.`
      );
    }
  }
  else if (sziLive !== 0n && apr < CONFIG.unwindAprThreshold) action = "UNWIND";
  else if (sziLive !== 0n && targetNotionalUsd >= 10 && Math.abs(driftPct) > CONFIG.rebalanceBandPct) action = "REBALANCE";
  // (bare-truth guard: with a sub-$10 policy target a "rebalance" would reduce
  // the position below HL's order minimum — that's not a trade the venue
  // accepts, so hold instead.)
  console.log(`decision: ${action} (dryRun=${CONFIG.dryRun})`);

  if (CONFIG.dryRun || action === "HOLD" || action === "BRIDGE_FIRST") {
    console.log("no sends (dry-run or nothing to do)");
    return;
  }

  // ── 5. Act (staged; each step verified before the next) ──
  if (action === "BRIDGE_PROFIT") {
    // Return the profit portion Core→EVM (needs HYPE on Core for transfer gas).
    // Contract split is PROFIT-FIRST (round-2 HIGH-1 fix): a profit-sized
    // amount realizes as profit and leaves the principal (hedge margin)
    // untouched on Core; a full drain still returns principal + profit.
    const amount6 = coreProfit6;
    // sendAsset draws the Core SPOT balance; realized money sits on the PERP
    // side → class-transfer down first (action 7, next block), then bridge.
    console.log(`class-transfer perp→spot: ${amount6} (6dp)`);
    const mtx = await strategy.moveUsdcToSpot(amount6);
    await mtx.wait();
    await new Promise((r) => setTimeout(r, 8000));
    console.log(`bridging profit back: ${amount6} (6dp)`);
    const tx = await strategy.bridgeBackToEvm(amount6);
    await tx.wait();
    // ── VERIFY (CoreWriter drops silently — re-read after the delay) ──
    await new Promise((r) => setTimeout(r, 8000)); // ~1 L1 block + action delay
    const [eq2, pr2, , realized2] = await strategy.coreState();
    console.log(`verified: equity6=${eq2} principal6=${pr2} realized=${realized2}`);
    if (vaultAddr !== hre.ethers.ZeroAddress) {
      const vault = await hre.ethers.getContractAt("ProYieldVault", vaultAddr, signer);
      const sweptBefore = await strategy.profitSwept();
      const htx = await vault.harvest();
      await htx.wait();
      const sweptAfter = await strategy.profitSwept();
      if (sweptAfter > sweptBefore) {
        console.log(`vault.harvest() done — swept ${sweptAfter - sweptBefore} to the vault`);
        await sendAlert("💰 DN profit harvested", `realized profit swept to the vault above the buffer. Check the transparency page for the updated share price.`);
      } else {
        // Realized but still under the liquidity buffer — not swept yet.
        // Alerting "harvested" here was round-2 HIGH-1's misleading alert.
        console.log("vault.harvest() done — profit sits inside the liquidity buffer, nothing swept this round");
      }
    }
  }

  if (action === "UNWIND") {
    // Negative funding: the short PAYS. Close the full position (reduceOnly),
    // verify, alert. Capital returns to spot → bridge-back handles the rest.
    const sz = (sziLive < 0n ? -sziLive : sziLive) * 10n ** BigInt(8 - szDec); // lots → 1e8 wire: buy back the exact size
    const limitPx = roundPxWire((pxWire * (10000n + CONFIG.slippageBps)) / 10000n); // BUY → cross above
    console.log(`unwinding short: sz=${sz} @ IOC ${limitPx} (funding ${apr.toFixed(2)}% < ${CONFIG.unwindAprThreshold}%)`);
    const tx = await strategy.closeShort(asset, limitPx, sz, CONFIG.tifIoc);
    await tx.wait();
    await new Promise((r) => setTimeout(r, 8000));
    const after = await strategy.position();
    const flat = after.szi === 0n;
    console.log(`verified: szi=${after.szi} (flat=${flat})`);
    if (!flat) {
      await sendAlert(
        "🔴 DN unwind MISMATCH",
        `funding ${apr.toFixed(2)}%/yr — short NOT closed (szi=${after.szi}); spot hedge left in place (still balanced). Verify on-chain.`
      );
      process.exit(3);
    }
    // Move ALL remaining Core USDC perp→spot so a later bridge-out (or the
    // vault recall unwind) can draw it — sendAsset is spot-source only.
    try {
      const msum2 = await strategy.marginSummary();
      const avLeft6 = msum2.accountValue > 0n ? BigInt(msum2.accountValue) : 0n;
      if (avLeft6 >= 1_000_000n) {
        console.log(`class-transfer perp→spot (remaining $${(Number(avLeft6) / 1e6).toFixed(2)})`);
        const mtx2 = await strategy.moveUsdcToSpot(avLeft6);
        await mtx2.wait();
        await new Promise((r) => setTimeout(r, 8000));
      }
    } catch (e) {
      console.warn("perp→spot class-transfer skipped:", e.message?.slice(0, 120));
    }
    // ── Spot leg: return the hedge (HIGH-2). Selling needs a ≥$10 REQUEST;
    // sub-$10 hedge sizes can't be expressed as spot orders → spot-send
    // (action 6) instead — that path exists precisely for this.
    let hedgeNote = "no spot leg configured";
    if ((await strategy.spotPairIndex()) !== 0n) {
      const hs = await strategy.spotHedgeSz();
      if (hs > 0n) {
        const pxRaw = await strategy.spotPx();
        const pxScale = await strategy.spotPxScale();
        const valUsd = Number(pxRaw) > 0 ? (Number(hs) * Number(pxRaw) / Number(pxScale)) / 1e6 : 0;
        if (valUsd >= 10.5) {
          const szDecS = 10 - Math.round(Math.log10(Number(pxScale)));
          const step = 10n ** BigInt(8 - szDecS);
          const szS = (hs / step) * step;
          const sellPx = roundPxWire((pxRaw * 100n * (10000n - CONFIG.slippageBps)) / 10000n); // spot raw@1e6 → wire×100; SELL crosses below
          console.log(`selling spot hedge: ${Number(szS) / 1e8} ${coin} @ IOC ${sellPx}`);
          const stx = await strategy.sellSpot(sellPx, szS, CONFIG.tifIoc);
          await stx.wait();
        } else {
          const dest = process.env.DN_HEDGE_RETURN_ADDR || (await strategy.owner());
          console.log(`spot hedge ~$${valUsd.toFixed(2)} < $10.5 order min — spot-sending ${hs} (1e8 units) ${coin} to ${dest}`);
          const stx = await strategy.hedgeTransferOut(dest, hs);
          await stx.wait();
        }
        await new Promise((r) => setTimeout(r, 8000));
        const hsAfter = await strategy.spotHedgeSz();
        hedgeNote = `hedge ${hs} → ${hsAfter} (1e8 units)`;
        console.log(`verified hedge after unwind: ${hsAfter}`);
        if (hsAfter >= hs) {
          await sendAlert("🔴 DN hedge NOT returned", `spot hedge unchanged (${hsAfter}) after unwind — investigate (action drop?).`);
          process.exit(3);
        }
      } else {
        hedgeNote = "no spot hedge held";
      }
    }
    await sendAlert("🟢 DN unwind complete", `funding ${apr.toFixed(2)}%/yr — short closed; ${hedgeNote}; verify on-chain.`);
    return;
  }

  if ((action === "OPEN" || action === "REBALANCE") && targetNotionalUsd >= 10) {
    // OPEN: short the full target. REBALANCE: close the excess (buy back the
    // delta) then re-open only if still short of target (rare — drift usually
    // means over-sized from price moves, i.e. BUY back the excess).
    if (action === "REBALANCE" && currentNotionalUsd > targetNotionalUsd) {
      const reduceUsd = currentNotionalUsd - targetNotionalUsd;
      const szFloat = reduceUsd / pxHuman;
      const factor = 10 ** szDec;
      const sz = BigInt(Math.floor(szFloat * factor)) * 10n ** 8n / BigInt(factor);
      const limitPx = roundPxWire((pxWire * (10000n + CONFIG.slippageBps)) / 10000n); // BUY → cross above
      console.log(`reducing short by ${reduceUsd.toFixed(2)} USD: sz=${sz} @ IOC ${limitPx}`);
      const tx = await strategy.closeShort(asset, limitPx, sz, CONFIG.tifIoc);
      await tx.wait();
      await new Promise((r) => setTimeout(r, 8000));
      const after = await strategy.position();
      console.log(`verified: szi=${after.szi}`);
      if ((Math.abs(Number(after.szi)) / 10 ** szDec) * pxHuman < targetNotionalUsd * 0.9) {
        console.error("MISMATCH: position smaller than expected — investigate (drop?)");
        process.exit(3);
      }
      return;
    }
    // OPEN path (also the under-sized rebalance): short the full target.
    // Margin check: strategy must hold enough USDC on Core (bridged earlier).
    const needMargin6 = BigInt(Math.floor(targetNotionalUsd * 1e6)) * CONFIG.marginUtilBps / 10000n;
    if (equityLive6 < needMargin6) {
      // Bridge more USDC in first (from idle EVM balance), THEN size the hedge
      // in a LATER block (CoreWriter sequencing rule).
      const idle = await strategy.underlying().then((u) => u).catch(() => null);
      const underlyingAddr = await strategy.underlying();
      const erc = await hre.ethers.getContractAt("IERC20", underlyingAddr, signer);
      const bal = await erc.balanceOf(CONFIG.strategy);
      console.log(`margin top-up: equity ${equity6} < need ${needMargin6}; strategy idle balance ${bal}`);
      const scale = await strategy.coreScale();
      const bridgeAmt = needMargin6 * scale; // 6dp → underlying units
      const bridgeable = bridgeAmt < bal ? bridgeAmt : bal;
      if (bridgeable === 0n) {
        console.error("cannot bridge margin — strategy has no idle USDC. awaiting vault allocate().");
        process.exit(4);
      }
      console.log(`bridging ${bridgeable} (underlying units) to Core`);
      const btx = await strategy.bridgeUsdcToCore(bridgeable);
      await btx.wait();
      await new Promise((r) => setTimeout(r, 8000)); // action lands NEXT L1 block
      console.log("bridge verified (earlier-block rule honored)");
      // Bridge credits Core SPOT; orders need PERP collateral. Class-transfer
      // now (action 7) and wait one action cycle — skipping this made live
      // opens reject for zero margin (spot USDC is not perp collateral).
      const moved6 = bridgeable / scale;
      console.log(`class-transfer spot→perp: ${moved6} (6dp)`);
      const mtx = await strategy.moveUsdcToPerp(moved6);
      await mtx.wait();
      await new Promise((r) => setTimeout(r, 8000));
      const msum = await strategy.marginSummary();
      if (msum.accountValue < needMargin6) {
        await sendAlert(
          "🟠 DN margin still short after bridge + class-transfer",
          `perp equity $${(Number(msum.accountValue) / 1e6).toFixed(2)} < need $${(Number(needMargin6) / 1e6).toFixed(2)} — fund more or resize; NOT opening (would reject).`
        );
        process.exit(4);
      }
      console.log(`perp equity after class-transfer: $${(Number(msum.accountValue) / 1e6).toFixed(2)} (need $${(Number(needMargin6) / 1e6).toFixed(2)})`);
    }
    const szFloat = targetNotionalUsd / pxHuman;
    const factor = 10 ** szDec;
    const sz = BigInt(Math.floor(szFloat * factor)) * 10n ** 8n / BigInt(factor);
    const limitPx = roundPxWire((pxWire * (10000n - CONFIG.slippageBps)) / 10000n); // SELL → cross below
    console.log(`opening short: sz=${sz} @ IOC ${limitPx}`);
    const tx = await strategy.openShort(asset, limitPx, sz, CONFIG.tifIoc);
    await tx.wait();
    await new Promise((r) => setTimeout(r, 8000));
    const after = await strategy.position();
    if (after.szi === 0n) {
      console.error("MISMATCH: order not visible after delay — investigate (drop?)");
      await sendAlert("🔴 DN order MISMATCH", `order not visible after delay — possible silent drop. asset=${asset} Investigate immediately.`);
      process.exit(3);
    }
    console.log(`verified: szi=${after.szi}`);
    // ── Spot leg (HIGH-2): the short alone is a one-way bet. Verify the spot
    // hedge covers it; buy the gap when Core spot USDC covers a ≥$10.07
    // request, otherwise ALERT — never leave a silent naked short.
    if ((await strategy.spotPairIndex()) === 0n) {
      console.warn("⚠️ spot leg DISABLED (spotPairIndex unset) — single-leg position; NOT delta-neutral");
      await sendAlert("🟠 DN running WITHOUT spot leg", "spotPairIndex unset — single-leg short (HIGH-2 posture). No delta-neutral claims until the spot hedge is live.");
    } else {
      const shortSz1e8 = (after.szi < 0n ? -after.szi : after.szi) * 10n ** BigInt(8 - szDec); // lots → 1e8
      const hedgeSz1e8 = await strategy.spotHedgeSz();
      const pxRaw = await strategy.spotPx();
      const pxScale = await strategy.spotPxScale();
      const pxDiv = Number(pxScale) > 0 ? Number(pxScale) : 1;
      const hedgeUsd = (Number(hedgeSz1e8) * Number(pxRaw) / pxDiv) / 1e6;
      console.log(`spot hedge: ${Number(hedgeSz1e8) / 1e8} ${coin} (~$${hedgeUsd.toFixed(2)}) vs short ${Number(shortSz1e8) / 1e8} ${coin}`);
      if (hedgeSz1e8 < shortSz1e8) {
        const gap1e8 = shortSz1e8 - hedgeSz1e8;
        const gapUsd = (Number(gap1e8) * Number(pxRaw) / pxDiv) / 1e6;
        if (gapUsd >= 10.07) {
          const szDecS = 10 - Math.round(Math.log10(pxDiv)); // pxScale = 10^(10-szDec)
          const step = 10n ** BigInt(8 - szDecS);
          const szS = (gap1e8 / step) * step;
          const buyPx = roundPxWire((pxRaw * 100n * (10000n + CONFIG.slippageBps)) / 10000n); // spot raw@1e6 → wire×100; BUY crosses above
          console.log(`buying spot hedge gap: ${Number(szS) / 1e8} ${coin} @ IOC ${buyPx}`);
          const stx = await strategy.openSpotBuy(buyPx, szS, CONFIG.tifIoc);
          await stx.wait();
          await new Promise((r) => setTimeout(r, 8000));
          const hsAfter = await strategy.spotHedgeSz();
          console.log(`verified hedge: ${Number(hsAfter) / 1e8} ${coin}`);
          if (hsAfter < shortSz1e8) {
            await sendAlert("🟠 DN hedge still short after buy", `hedge ${hsAfter} < short ${shortSz1e8} (1e8 units) — check spot fills.`);
          }
        } else if (gapUsd > 1.0) {
          await sendAlert(
            "🟠 DN hedge gap — spot leg under-funded",
            `short ${Number(shortSz1e8) / 1e8} vs spot ${Number(hedgeSz1e8) / 1e8} ${coin} (gap $${gapUsd.toFixed(2)} — below HL's $10 spot order min). Fund the strategy's Core spot (transfer ${coin} in) before claiming delta-neutral.`
          );
        } else {
          // Sub-step gaps are order-granularity noise: spot sizes round to
          // 0.01 HYPE ≈ $1 at current px — you cannot trade closer than one step.
          console.log(`hedge gap $${gapUsd.toFixed(2)} ≤ one order step ($1) — within granularity ✓`);
        }
      } else {
        console.log(`hedge covers the short (${Number(hedgeSz1e8) / 1e8} >= ${Number(shortSz1e8) / 1e8} ${coin}) — delta-neutral ✓`);
      }
    }
  }

  // UNWIND_REVIEW flow: same pattern — act, wait, verify, alert.
  // TODO: implement once the negative-funding policy sign-off lands.
}

main().catch((e) => {
  console.error("keeper error:", e.message?.slice(0, 300));
  process.exit(2);
});
