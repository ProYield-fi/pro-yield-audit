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
//   4. Decide: OPEN → REBALANCE → BRIDGE_PROFIT → HOLD. A fresh strategy
//      (its Core account not yet created) also reaches OPEN — that path
//      bridges USDC to Core first (initializing the account) before any act.
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
  // Slippage buffer for perp limits, in bps of the oracle px.
    // ENV-OVERRIDABLE (added 2026-10-01). Hardcoding this at 20bps left the DN
    // sleeve UNCLOSEABLE when its notional drifted under the contract's $10
    // minimum: _order() computes notional6 from limitPx, so a $9.82 position
    // only clears MIN_ORDER_USD6 if the limit is pushed ABOVE the market — and
    // at 20bps the limit sat at $89.34 => notional $9.83 => revert
    // DNCore__BelowMinNotional, forever. Raising the limit is safe for an IOC
    // (it caps the fill, it does not set it), so the escape is a wider buffer.
    slippageBps: BigInt(process.env.DN_SLIPPAGE_BPS || "20"),
  tifIoc: 3,
  // ── Sizing policy ──
  scoutSnapshot: process.env.SCOUT_SNAPSHOT || "/home/user/yield_scout/data/snapshot.json",
  deployPct: parseFloat(process.env.DN_DEPLOY_PCT || "0.90"), // fraction of sleeve bridged to Core
  marginUtilBps: BigInt(process.env.DN_MARGIN_UTIL_BPS || "3300"), // perp margin needed per 1e4 notional (BTC maxLev 40 → 1/40 = 250bps; pad to 3300 for fees/spread). Env override for small-size demo runs (e.g. 1700).
  maxSleeveUsd: parseFloat(process.env.DN_MAX_SLEEVE_USD || "0"), // 0 = no override cap
  maxSleevePct: parseFloat(process.env.DN_MAX_SLEEVE_PCT || "0"), // 0.15 = cap at 15% of vault TVL (launch mandate: "DN sleeve = TVL×0.15"); the scout weight (0.25 observed 2026-10-03) can exceed the mandate — this clamps it
  targetOverrideUsd: parseFloat(process.env.DN_TARGET_USD || "0"), // 0 = use vault×weight sizing; >0 pins the hedge notional (demo/E2E runs)
  dryRun: !(process.argv.includes("--execute") || process.env.DN_EXECUTE === "1"),
  // ── Safety guards (security review t_3a89fe76) ──
  // A3: realize hedged funding profit on the ALL-LEGS basis ONLY when this flag
  // is set AND the deployed contract advertises coreProfitUsesAllLegs(). Default
  // off → the live path keeps its legacy perp-only basis and BRIDGE_PROFIT stays
  // inert while hedged (firing it against the pre-fix contract would shave the
  // principal ledger — see the coordinated-change note on the card).
  allLegsProfit: String(process.env.DN_ALL_LEGS_PROFIT || "0") === "1",
  // A1: the HL spot fee is charged in the BASE asset, so an exact-size hedge
  // order always under-fills by the fee. Size the request up by this buffer
  // (observed ~7 bps; 15 bps default) before rounding up to a lot step.
  spotFeeBps: BigInt(process.env.DN_SPOT_FEE_BPS || "15"),
  // A2: equity-vs-principal loss floor, 6dp units. Default $2.00; env-overridable
  // (DN_LOSS_FLOOR6) so a small book can tighten it without a code change.
  lossAlertFloor6: BigInt(process.env.DN_LOSS_FLOOR6 || "2000000"),
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
  // ALSO start an agent session via the gateway webhook (kanban t_d307f4b3).
  // Fire-and-forget: a down/slow gateway can never affect the Telegram alert
  // below (the primary channel). Honours DN_SILENCE_TELEGRAM so test batteries
  // that deliberately provoke alerts never spawn agent sessions.
  try { require("./alert_webhook").notifyWebhookFor(title, line); } catch { /* best effort */ }
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
    // Telegram HTML mode rejects an unescaped "<" as an unsupported start tag
    // (HTTP 400) — alert bodies carry operator math like "$5.10 < need $5.11".
    // Escape the interpolated content so a real alert can never be silently dropped.
    const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const res = await fetch(`https://api.telegram.org/bot${tok}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text: `<b>${esc(title)}</b>\n${esc(body)}`, parse_mode: "HTML" }),
    });
    if (!res.ok) throw new Error(`telegram ${res.status}`);
  } catch (e) {
    try {
      require("fs").appendFileSync(QLOG,
        `${new Date().toISOString()} ${line} (send failed: ${e.message})\n`);
    } catch { /* nothing more we can do */ }
  }
}

/// Alert at most once per `windowMs` per key (marker in the DN state dir).
/// A standing condition (e.g. an un-trimmable drift) must be visible in EVERY
/// run's log but must not page the operator every 6h. Test runs
/// (DN_SILENCE_TELEGRAM=1) never write the marker — a battery run must not
/// suppress the next live alert.
async function sendAlertThrottled(key, title, body, windowMs = 24 * 3600 * 1000) {
  const dir = process.env.DN_STATE_DIR || path.join(__dirname, "..", "cache");
  const mark = path.join(dir, `dn_alert_${key}.json`);
  const silenced = process.env.DN_SILENCE_TELEGRAM === "1";
  try {
    const prev = JSON.parse(fs.readFileSync(mark, "utf8"));
    if (Date.now() - Number(prev.ts) < windowMs) {
      console.log(`[throttled] ${title} — already alerted ${((Date.now() - Number(prev.ts)) / 3600000).toFixed(1)}h ago`);
      return;
    }
  } catch { /* no marker yet */ }
  await sendAlert(title, body);
  if (silenced) return;
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(mark, JSON.stringify({ ts: Date.now(), title }));
  } catch { /* best effort */ }
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
  const DEFAULT_DN_WEIGHT = 0.25;
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

/// ── Order-feasibility mirrors of DNCoreBase._order (t_c8427d27) ───────────
/// The contract computes `notional6 = limitPx × sz / 1e10` (both wire fields
/// are 10^8 × human) and reverts DNCore__BelowMinNotional / DNCore__Cap when
/// that lands outside [MIN_ORDER_USD6, maxActionUsd6]. The keeper must plan
/// with the SAME math: a $5.31 reduce against a $10 minimum is a guaranteed
/// revert that aborts the whole cycle (chronic REBALANCE reverts — the sleeve
/// sat ~31% over target for days emitting doomed orders every 6h).
const ORDER_NOTIONAL_DIV = 10000000000n; // 1e10

/// Corrective-order limit price, crossing the mark by the slippage buffer
/// (BUY above / SELL below) — identical to both act paths.
function correctionLimitPx(pxWire, slippageBps, isBuy) {
  const b = BigInt(slippageBps);
  return roundPxWire(isBuy ? (pxWire * (10000n + b)) / 10000n : (pxWire * (10000n - b)) / 10000n);
}

/// Size in CoreWriter wire units (10^8 × human), floored to the asset's lot
/// step — identical to both act paths.
function sizeToLot(notionalUsd, pxHuman, szDec) {
  const factor = 10 ** szDec;
  return BigInt(Math.floor((notionalUsd / pxHuman) * factor)) * 10n ** 8n / BigInt(factor);
}

/// @returns {sz, limitPx, notional6, ok, reason} — would DNCoreBase._order
/// accept this corrective order? ok=false ⇒ the contract reverts; the keeper
/// must not send it (and must say why, in dollars).
function planCorrection(notionalUsd, pxWire, szDec, slippageBps, isBuy, minOrder6, maxAction6) {
  const limitPx = correctionLimitPx(pxWire, slippageBps, isBuy);
  const pxHuman = Number(pxWire) / 1e8;
  const sz = sizeToLot(notionalUsd, pxHuman, szDec);
  if (sz === 0n) {
    return { sz, limitPx, notional6: 0n, ok: false, reason: "rounds below one lot" };
  }
  const notional6 = (limitPx * sz) / ORDER_NOTIONAL_DIV;
  if (notional6 < minOrder6) {
    return {
      sz, limitPx, notional6, ok: false,
      reason: `order notional $${(Number(notional6) / 1e6).toFixed(2)} < minimum order value $${(Number(minOrder6) / 1e6).toFixed(2)} (HL minimum; the contract mirrors it as MIN_ORDER_USD6)`,
    };
  }
  if (maxAction6 > 0n && notional6 > maxAction6) {
    return {
      sz, limitPx, notional6, ok: false,
      reason: `order notional $${(Number(notional6) / 1e6).toFixed(2)} > per-action cap $${(Number(maxAction6) / 1e6).toFixed(2)}`,
    };
  }
  return { sz, limitPx, notional6, ok: true, reason: "" };
}

function computeTargetNotionalUsd(vaultTotalAssetsUsd, dnWeight, sleeveCapitalUsd = null) {
  let sleeve = vaultTotalAssetsUsd * dnWeight;
  if (CONFIG.maxSleeveUsd > 0) sleeve = Math.min(sleeve, CONFIG.maxSleeveUsd);
  if (CONFIG.maxSleevePct > 0) sleeve = Math.min(sleeve, vaultTotalAssetsUsd * CONFIG.maxSleevePct);
  if (CONFIG.targetOverrideUsd > 0) sleeve = CONFIG.targetOverrideUsd; // demo/E2E pin
  // CAPITAL-AWARE CAP (2026-09-29): a fully-funded delta-neutral position needs
  // hedge cash + perp margin ≈ notional × (1 + marginUtil) + fees — the weighted
  // notional alone was NOT covered by the sleeve's own capital, so the first
  // live open at real size half-opened an unhedgeable short. Cap the notional
  // by the strategy's actual assets: the sleeve stays dormant until it can
  // open AND hedge in full, then reopens automatically as TVL grows.
  if (sleeveCapitalUsd !== null && sleeveCapitalUsd > 0) {
    const costMult = 1 + Number(CONFIG.marginUtilBps) / 10000 + 0.06; // margin util + fee/spread buffer
    sleeve = Math.min(sleeve, sleeveCapitalUsd / costMult);
  }
  return sleeve; // hedge NOTIONAL (1:1 delta-neutral), capital-capped
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
  // Order-policy bounds, read from the DEPLOYED contract (t_c8427d27) so the
  // keeper mirrors live policy instead of hardcoding it: MIN_ORDER_USD6 is the
  // $10 HL minimum order value, maxActionUsd6 the per-action cap. Every
  // corrective order is planned against both (planCorrection) — the contract
  // reverts below/above them and aborts the cycle.
  let minOrder6 = 10000000n; // $10 (HL minimum order value; contract default)
  let maxAction6 = 0n; // 0 = unknown → no upper bound applied
  try {
    minOrder6 = await strategy.MIN_ORDER_USD6();
  } catch (e) {
    console.warn(`order policy: MIN_ORDER_USD6 unreadable (${String(e.message || e).slice(0, 80)}) — assuming $10`);
  }
  try {
    maxAction6 = await strategy.maxActionUsd6();
  } catch (e) {
    console.warn(`order policy: maxActionUsd6 unreadable (${String(e.message || e).slice(0, 80)}) — no per-action cap applied`);
  }
  console.log(`order policy: min order $${(Number(minOrder6) / 1e6).toFixed(2)} · per-action cap ${maxAction6 > 0n ? "$" + (Number(maxAction6) / 1e6).toFixed(2) : "unset"}`);

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
  // Dust floor raised $0.10 → $2.00 (2026-09-29): real fills + venue fees at
  // beta sizes burned ~$1 in the first live round-trip; sub-$2 equity-vs-
  // principal gaps are normal fee noise, not reportLoss events. Keep the
  // alert for REAL losses only.
  //
  // 2026-10-01 — MUST count spot capital. equityLive6 is the CORE (perp)
  // account value only. An unwind moves margin perp→spot, so a flat, healthy,
  // fully-returned position reads equity $0.00 against principal $13.75 and
  // the old check fired "loss $13.75 → OWNER ACTION: vault.reportLoss(...)".
  // That capital was sitting in the strategy's spot account the whole time;
  // acting on the alert would have written off ~$13 that exists. The strategy
  // exposes no spot-USDC getter, so it is read from the HL spot API here.
  let spotUsdc6 = 0n;
  try {
    const sp = await hlInfo({ type: "spotClearinghouseState", user: CONFIG.strategy });
    const bal = (sp.balances || []).find((b) => b.coin === "USDC");
    if (bal && bal.total) spotUsdc6 = BigInt(Math.round(Number(bal.total) * 1e6));
  } catch (e) {
    console.warn("spot USDC read failed (loss check will understate capital):", String(e.message || e).slice(0, 100));
  }
  const equityWithSpot6 = equityLive6 + spotUsdc6;
  // 2026-10-03 — the hedge leg MUST count too. Read via the strategy's own
  // views (spotHedgeSz × spotPx / spotPxScale — the same formula the unwind
  // path uses): the long leg is a real asset. Ignoring it made a healthy
  // delta-neutral sleeve alarm as "REAL loss $11.38" through the 2026-10-03
  // HYPE pump (perp −$10.6, hedge +$10.6, net ≈ −$0.8 in fees/funding). The
  // owner caught it: "how the fuck did we get underwater — DN was never
  // supposed to lose". Same read-gap class as the two phantom alerts above.
  let hedgeVal6 = 0n;
  try {
    const hs = await strategy.spotHedgeSz();
    if (hs > 0n) {
      const pxRaw = await strategy.spotPx();
      const pxScaleS = await strategy.spotPxScale();
      if (Number(pxRaw) > 0 && Number(pxScaleS) > 0) {
        hedgeVal6 = BigInt(Math.floor((Number(hs) * Number(pxRaw)) / Number(pxScaleS)));
      }
    }
  } catch (e) {
    console.warn("spot hedge read failed (loss check will understate capital):", String(e.message || e).slice(0, 100));
  }
  const equityAllLegs6 = equityWithSpot6 + hedgeVal6;
  console.log(
    `equity: Core $${(Number(equityLive6) / 1e6).toFixed(2)} + spot $${(Number(spotUsdc6) / 1e6).toFixed(2)} + hedge $${(Number(hedgeVal6) / 1e6).toFixed(2)} = $${(Number(equityAllLegs6) / 1e6).toFixed(2)} (principal $${(Number(principal6) / 1e6).toFixed(2)})`
  );
  const lossFloor6 = CONFIG.lossAlertFloor6;
  if (exists && equityAllLegs6 < principal6 && principal6 - equityAllLegs6 > lossFloor6) {
    const loss6 = principal6 - equityAllLegs6;
    await sendAlert(
      "⚠️ DN equity below principal",
      `Core $${(Number(equityLive6) / 1e6).toFixed(2)} + spot $${(Number(spotUsdc6) / 1e6).toFixed(2)} + hedge $${(Number(hedgeVal6) / 1e6).toFixed(2)} = $${(Number(equityAllLegs6) / 1e6).toFixed(2)} < principal $${(Number(principal6) / 1e6).toFixed(2)} — REAL loss $${(Number(loss6) / 1e6).toFixed(2)} (perp + spot cash + hedge). OWNER ACTION: vault.reportLoss(<loss in underlying units>).`
    );
  }
  // A2 (security review t_3a89fe76): the $1.00 HL Core-account activation fee is
  // a real one-time cost, but the loss floor (calibrated for a larger book)
  // silently swallows it on a small one. Emit a DEDICATED one-time note per
  // strategy the FIRST cycle a sub-floor equity-vs-principal gap appears, so the
  // cost is surfaced — WITHOUT lowering the global floor (a lowered floor would
  // re-fire every cycle until funding earns the gap back). Owner can tighten the
  // floor per-book with DN_LOSS_FLOOR6.
  if (exists && equityAllLegs6 < principal6 && principal6 - equityAllLegs6 <= lossFloor6) {
    try {
      const markDir = process.env.DN_STATE_DIR || path.join(__dirname, "..", "cache");
      fs.mkdirSync(markDir, { recursive: true });
      const mark = path.join(markDir, `dn_activation_note_${String(CONFIG.strategy).toLowerCase()}`);
      if (!fs.existsSync(mark)) {
        const gap6 = principal6 - equityAllLegs6;
        await sendAlert(
          "ⓘ DN small equity-vs-principal gap (first-cycle cost?)",
          `all-legs $${(Number(equityAllLegs6) / 1e6).toFixed(2)} < principal $${(Number(principal6) / 1e6).toFixed(2)} by $${(Number(gap6) / 1e6).toFixed(2)} — below the $${(Number(lossFloor6) / 1e6).toFixed(2)} loss floor, so not alerted as a loss. On a FRESH Core account the one-time $1.00 HL activation fee is a REAL cost the vault NAV does not yet reflect: OWNER ACTION: vault.reportLoss(${gap6}) (underlying units) to keep NAV honest. (Notified once per strategy.)`
        );
        fs.writeFileSync(mark, `${new Date().toISOString()}\n`);
      }
    } catch (e) {
      console.warn("activation-fee note skipped:", String(e.message || e).slice(0, 100));
    }
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
  // Capital-aware sizing (2026-09-29): pass the sleeve's actual visible assets
  // so an under-funded sleeve sizes DOWN (or stays dormant below HL's $10 min)
  // instead of half-opening an unhedgeable short.
  //
  // 2026-10-01 — Core spot CASH is now INCLUDED. It was a known read gap,
  // deliberately left conservative, but "conservative" here meant "permanently
  // dormant": after the unwind the sleeve held $12.99 USDC in its Core spot
  // account while totalAssets() reported $2.91 (Core equity + spot HYPE only —
  // spotValue6() prices the HYPE hedge, it does not count spot USDC). The cap
  // then sized $2.30 of notional against a $10 venue minimum and the sleeve
  // refused to open with 26% MORE capital than it needed. Sizing against the
  // true figure ($12.99 -> $10.27 notional) clears the minimum and opens.
  // Same root cause as the phantom reportLoss alert fixed above: a read that
  // ignored where the money actually sits.
  const sleeveCapitalUsd = strategyAssetsUsd + Number(spotUsdc6) / 1e6;
  if (Number(spotUsdc6) > 0n) {
    console.log(
      `sizing: Core spot cash $${(Number(spotUsdc6) / 1e6).toFixed(2)} included (totalAssets() omits it) -> sleeve capital $${sleeveCapitalUsd.toFixed(2)}`
    );
  }
  const targetNotionalUsd = computeTargetNotionalUsd(vaultAssetsUsd, dnWeight, sleeveCapitalUsd);
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
  // Profit basis (A3, security review t_3a89fe76). LEGACY = perp-only
  // equityLive6 (the pre-fix basis: it reads 0 while a hedge is held, because
  // the bridged capital sits in the spot leg → BRIDGE_PROFIT never fires).
  // ALL-LEGS = equityAllLegs6 (perp + Core spot USDC + hedge) — the honest
  // basis, but SAFE to realize ONLY once the CONTRACT also splits on all-legs;
  // otherwise a correct profit amount is booked as a principal reduction and
  // shaves the principal ledger (proven in the review). Gated on the explicit
  // env flag AND the deployed contract's own feature marker, so a half-landed
  // change can never fire against the pre-fix build.
  let contractAllLegsSupported = false;
  if (CONFIG.allLegsProfit) {
    try {
      if (typeof strategy.coreProfitUsesAllLegs === "function") {
        contractAllLegsSupported = Boolean(await strategy.coreProfitUsesAllLegs());
      }
    } catch (_) {
      contractAllLegsSupported = false;
    }
    if (!contractAllLegsSupported) {
      await sendAlert(
        "🟠 DN all-legs profit requested but contract does not support it",
        "DN_ALL_LEGS_PROFIT=1 but the deployed strategy lacks coreProfitUsesAllLegs() (pre-fix build) — profit basis stays perp-only (inert). Do NOT fire BRIDGE_PROFIT until the re-audited all-legs contract is live; firing it would shave principal."
      );
    }
  }
  const profitBasisAllLegs = CONFIG.allLegsProfit && contractAllLegsSupported;
  const coreProfit6 = profitBasisAllLegs
    ? (equityAllLegs6 > principal6 ? equityAllLegs6 - principal6 : 0n)
    : (equityLive6 > principal6 ? equityLive6 - principal6 : 0n);
  console.log(`profit basis: ${profitBasisAllLegs ? "ALL-LEGS" : "perp-only (legacy/inert)"} → coreProfit6=${coreProfit6}`);
  let action = "HOLD";
  // A brand-new strategy (no Core account yet) must NOT short-circuit to a
  // no-op "BRIDGE_FIRST". The OPEN path below bridges USDC to Core first
  // (which initializes the account), waits ≥1 L1 block, then moves margin and
  // opens — exactly the sequencing rule in docs/DN_COREWRITER_ADAPTER.md.
  // (2026-10-09 fix: the old `if (!exists) action = "BRIDGE_FIRST"` pre-empted
  // that path, and BRIDGE_FIRST returned before bridging — so a fresh strategy
  // never created its Core account and never opened. Book #1 escaped it only
  // because its Core account already existed.)
  if (coreProfit6 > 0n && harvestable === 0n) action = "BRIDGE_PROFIT";
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
  else if (sziLive !== 0n && targetNotionalUsd >= 10 && Math.abs(driftPct) > CONFIG.rebalanceBandPct) {
    // (bare-truth guard: with a sub-$10 policy target a "rebalance" would reduce
    // the position below HL's order minimum — that's not a trade the venue
    // accepts, so hold instead.)
    //
    // t_c8427d27 — the band is a PERCENTAGE of the sleeve target, so on a small
    // book ($18.94) 5% is ~$0.95: far below HL's $10 minimum order value. Every
    // corrective order the keeper emitted was a guaranteed contract revert
    // (DNCore__BelowMinNotional → exit 2), chronic for days. Plan the order
    // BEFORE deciding: a correction the venue cannot express is not a
    // REBALANCE, it is a HOLD with an explanation.
    const overTarget = currentNotionalUsd > targetNotionalUsd;
    const gapUsd = Math.abs(currentNotionalUsd - targetNotionalUsd);
    const plan = planCorrection(gapUsd, pxWire, szDec, CONFIG.slippageBps, overTarget, minOrder6, maxAction6);
    if (plan.ok) {
      action = "REBALANCE";
    } else {
      action = "HOLD";
      console.log(
        `rebalance: drift ${driftPct.toFixed(2)}% exceeds the ${CONFIG.rebalanceBandPct}% band but the $${gapUsd.toFixed(2)} correction is NOT expressible as an order (${plan.reason}) — HOLD, no churn (both legs stay hedged)`
      );
      await sendAlertThrottled(
        `rebalance_infeasible_${String(CONFIG.strategy).toLowerCase()}`,
        "🟠 DN rebalance blocked — correction below the venue minimum",
        `${coin}: sleeve is ${overTarget ? "OVER" : "UNDER"} target by $${gapUsd.toFixed(2)} (position $${currentNotionalUsd.toFixed(2)} vs target $${targetNotionalUsd.toFixed(2)}, drift ${driftPct.toFixed(2)}%). The corrective order would be $${(Number(plan.notional6) / 1e6).toFixed(2)} at the IOC limit — below HL's $10 minimum order value, which the contract mirrors as MIN_ORDER_USD6 (revert DNCore__BelowMinNotional). Both legs stay hedged; the keeper HOLDs rather than emit an order the venue rejects, and trims automatically once the slice reaches $10. Options: raise DN_TARGET_USD (policy), or approve a supervised close+reopen. A sub-$10 reduce-only exemption is a CONTRACT change (audit + deploy) — not available to the keeper.`
      );
    }
  }
  console.log(`decision: ${action} (dryRun=${CONFIG.dryRun})`);

  if (CONFIG.dryRun || action === "HOLD") {
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
    // Pre-flight the full close against the same policy _order enforces
    // (t_c8427d27): a close below the $10 minimum or above the per-action cap
    // reverts. Surface that as a named, actionable alert instead of a bare
    // "execution reverted" from the gas estimator.
    {
      const closeNotional6 = (limitPx * sz) / ORDER_NOTIONAL_DIV;
      if (closeNotional6 < minOrder6 || (maxAction6 > 0n && closeNotional6 > maxAction6)) {
        await sendAlert(
          "🟠 DN unwind blocked by order policy",
          `full close of ${Number(sz) / 1e8} ${coin} = $${(Number(closeNotional6) / 1e6).toFixed(2)} at the IOC limit — outside [$${(Number(minOrder6) / 1e6).toFixed(2)} min order, ${maxAction6 > 0n ? "$" + (Number(maxAction6) / 1e6).toFixed(2) : "no"} per-action cap]. NOT sending (the contract would revert). Needs an owner decision (chunking / cap change).`
        );
        process.exit(4);
      }
    }
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
    let dustLeft = false;
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
        } else if (valUsd >= 2) {
          const dest = process.env.DN_HEDGE_RETURN_ADDR || (await strategy.owner());
          console.log(`spot hedge ~$${valUsd.toFixed(2)} < $10.5 order min — spot-sending ${hs} (1e8 units) ${coin} to ${dest}`);
          const stx = await strategy.hedgeTransferOut(dest, hs);
          await stx.wait();
        } else {
          // 2026-09-29: moving $0.03 of dust cost ~$1 in venue fees on the first
          // live unwind — never move sub-$2 dust; leave it in the hedge account.
          dustLeft = true;
          hedgeNote = `hedge dust $${valUsd.toFixed(2)} left in place (send fee would exceed value)`;
          console.log(hedgeNote);
        }
        await new Promise((r) => setTimeout(r, 8000));
        const hsAfter = await strategy.spotHedgeSz();
        if (!dustLeft) hedgeNote = `hedge ${hs} → ${hsAfter} (1e8 units)`;
        console.log(`verified hedge after unwind: ${hsAfter}`);
        if (!dustLeft && hsAfter >= hs) {
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
      // Venue-plan the order (t_c8427d27): the same math DNCoreBase._order
      // enforces, so a slice the contract would reject can never reach the wire
      // (this is where the chronic "execution reverted" came from).
      const plan = planCorrection(reduceUsd, pxWire, szDec, CONFIG.slippageBps, true, minOrder6, maxAction6);
      if (!plan.ok) {
        console.log(`rebalance reduce NOT expressible as an order (${plan.reason}) — HOLD, nothing sent`);
        await sendAlertThrottled(
          `rebalance_infeasible_${String(CONFIG.strategy).toLowerCase()}`,
          "🟠 DN rebalance blocked — correction below the venue minimum",
          `${coin}: a $${reduceUsd.toFixed(2)} reduce is not a legal order (${plan.reason}). HOLD; both legs stay hedged.`
        );
        return;
      }
      const { sz, limitPx } = plan;
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
    // OPEN path (also the under-sized rebalance): short the REMAINING gap to
    // target (2026-09-29 fix — this used to short the FULL target, doubling an
    // under-sized position whenever drift was slightly negative; observed live).
    const addNotionalUsd = action === "REBALANCE"
      ? Math.max(0, targetNotionalUsd - currentNotionalUsd)
      : targetNotionalUsd;
    // t_c8427d27: plan the ORDER before moving any money. The old flow bridged
    // and class-transferred margin first and only then discovered the order was
    // below the venue's minimum order value — aborting (exit 2) with the
    // sleeve's capital parked on the perp side and no hedge bought (observed
    // live: a $9.83 open reverted after the margin move). A plan the contract
    // would reject stops here, before the first transfer.
    const plan = planCorrection(addNotionalUsd, pxWire, szDec, CONFIG.slippageBps, false, minOrder6, maxAction6);
    if (!plan.ok) {
      console.log(`open/add NOT expressible as an order (${plan.reason}) — no money moved, HOLD`);
      await sendAlertThrottled(
        `rebalance_infeasible_${String(CONFIG.strategy).toLowerCase()}`,
        "🟠 DN open/add blocked — order below the venue minimum",
        `${coin}: a $${addNotionalUsd.toFixed(2)} ${action === "OPEN" ? "open" : "add"} is not a legal order (${plan.reason}). Nothing bridged, nothing moved; HOLD.`
      );
      return;
    }
    // Hedge cash budget (2026-09-29): the spot buy draws the strategy's Core
    // SPOT USDC; the short needs PERP margin. LEVEL the two accounts so BOTH
    // legs are provably funded before any order: bridge the shortfall (if
    // any), then set perp := margin need and leave EVERYTHING ELSE in spot
    // for the hedge buy. (The old flow bridged margin only and class-moved it
    // all to perp, leaving the hedge unfunded — observed live.)
    let hedgeNeed6 = (await strategy.spotPairIndex()) !== 0n
      ? BigInt(Math.floor(targetNotionalUsd * 1.01 * 1e6))
      : 0n;
    // 2026-10-03 — credit the hedge ALREADY on Core: a rebalance GROWS an
    // existing delta-neutral position, so the spot HYPE held covers the first
    // slice of the new hedge. Demanding the full hedge in fresh cash made every
    // post-allocation rebalance look under-funded ("need $31.17 … have
    // $2.00+$0.37+$19.48") and blocked the sleeve at exit 4 even though the
    // money was there — the hedge was held as HYPE, not cash.
    if (hedgeNeed6 > hedgeVal6) hedgeNeed6 = hedgeNeed6 - hedgeVal6; else hedgeNeed6 = 0n;
    const needMargin6 = BigInt(Math.floor(targetNotionalUsd * 1e6)) * CONFIG.marginUtilBps / 10000n;
    {
      const underlyingAddr = await strategy.underlying();
      const erc = await hre.ethers.getContractAt("IERC20", underlyingAddr, signer);
      const bal = await erc.balanceOf(CONFIG.strategy);
      const scale = await strategy.coreScale();
      const needTotal6 = needMargin6 + hedgeNeed6;
      // Core SPOT cash funds both legs (the hedge buys from spot; the margin
      // levels spot→perp). The 2026-10-02 block compared the need against perp
      // equity ALONE and kept a fully-funded sleeve permanently "under-funded"
      // (exit 4 + alert spam every 6h) — equityWithSpot6 is the honest basis.
      const shortfall6 = needTotal6 > equityWithSpot6 ? needTotal6 - equityWithSpot6 : 0n;
      if (shortfall6 > 0n) {
        const needBridge = shortfall6 * scale;
        if (bal < needBridge) {
          await sendAlert(
            "🟠 DN won't open — sleeve under-funded for both legs",
            `need $${(Number(needTotal6) / 1e6).toFixed(2)} on Core (margin+hedge) against $${(Number(equityLive6) / 1e6).toFixed(2)} perp + $${(Number(spotUsdc6) / 1e6).toFixed(2)} spot cash + $${(Number(bal) / Number(scale) / 1e6).toFixed(2)} idle — a half-funded open would leave a naked short. NOT opening; fund or resize.`
          );
          process.exit(4);
        }
        console.log(`bridging ${needBridge} (underlying units) — margin + hedge cash together`);
        const btx = await strategy.bridgeUsdcToCore(needBridge);
        await btx.wait();
        await new Promise((r) => setTimeout(r, 8000)); // action lands NEXT L1 block
        console.log("bridge verified (earlier-block rule honored)");
      }
      // Level the perp side to exactly the margin need — excess walks to spot
      // where the hedge buy can draw it; a deficit pulls back from spot.
      //
      // t_c8427d27 boundary: `accountValue` includes the OPEN short's unrealized
      // PnL, which moves with the mark between the leveling transfer and this
      // re-read — the sleeve was blocked at exit 4 five times on sub-cent
      // residuals ("perp equity $5.11 < need $5.11"). The policy need already
      // carries ~2x HL's actual initial-margin requirement (marginUtilBps vs the
      // asset's max leverage), so a residual inside this tolerance cannot cause
      // a venue rejection. Pad the pull by the tolerance so the normal case
      // lands above `need`, and accept a residual inside it.
      const marginTolerance6 = needMargin6 / 100n > 50000n ? needMargin6 / 100n : 50000n; // ≥ $0.05 or 1% of need
      let msum = await strategy.marginSummary();
      if (msum.accountValue > needMargin6) {
        const excess6 = msum.accountValue - needMargin6;
        console.log(`class-transfer perp→spot (hedge cash): ${excess6} (6dp)`);
        const mtx = await strategy.moveUsdcToSpot(excess6);
        await mtx.wait();
        await new Promise((r) => setTimeout(r, 8000));
        msum = await strategy.marginSummary();
      } else if (msum.accountValue < needMargin6) {
        const pull6 = needMargin6 - msum.accountValue + marginTolerance6; // pad: the re-read can undershoot on mark drift
        console.log(`class-transfer spot→perp (margin): ${pull6} (6dp, need ${needMargin6 - msum.accountValue} + $${(Number(marginTolerance6) / 1e6).toFixed(2)} pad)`);
        const mtx = await strategy.moveUsdcToPerp(pull6);
        await mtx.wait();
        await new Promise((r) => setTimeout(r, 8000));
        msum = await strategy.marginSummary();
      }
      if (msum.accountValue + marginTolerance6 < needMargin6) {
        const residual6 = needMargin6 - msum.accountValue;
        await sendAlert(
          "🟠 DN margin still short after bridge + class-transfer",
          `perp equity $${(Number(msum.accountValue) / 1e6).toFixed(2)} < need $${(Number(needMargin6) / 1e6).toFixed(2)} by $${(Number(residual6) / 1e6).toFixed(2)} — beyond the $${(Number(marginTolerance6) / 1e6).toFixed(2)} mark-drift tolerance. Fund more or resize; NOT opening (would reject).`
        );
        process.exit(4);
      }
      if (msum.accountValue < needMargin6) {
        console.log(`perp $${(Number(msum.accountValue) / 1e6).toFixed(2)} is $${(Number(needMargin6 - msum.accountValue) / 1e6).toFixed(2)} under need $${(Number(needMargin6) / 1e6).toFixed(2)} — within the $${(Number(marginTolerance6) / 1e6).toFixed(2)} tolerance (mark-to-market drift on the open leg); proceeding`);
      }
      console.log(`perp leveled to $${(Number(msum.accountValue) / 1e6).toFixed(2)} (need $${(Number(needMargin6) / 1e6).toFixed(2)}); hedge cash stays in spot`);
    }
    // plan (venue-planned above): sz/limitPx are exactly the wire fields
    // DNCoreBase._order will accept — plan.ok guarantees sz > 0.
    const { sz, limitPx } = plan;
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
        const logPx = Math.log10(pxDiv);
        const szDecS = Number.isFinite(logPx) ? 10 - Math.round(logPx) : 2; // pxScale = 10^(10-szDec)
        const step = szDecS >= 0 && szDecS <= 8 ? 10n ** BigInt(8 - szDecS) : 1n;
        const oneLotUsd = (Number(step) * Number(pxRaw) / pxDiv) / 1e6;
        if (gapUsd >= 10.07) {
          // A1 fix (security review t_3a89fe76): the HL spot fee is charged in
          // the BASE asset, so an exact-size order always under-fills by the fee
          // and leaves an un-closeable sub-$10 residual. Size the request to
          // cover the gap INCLUDING the fee, then round UP to a lot step — a
          // tiny net-LONG is the safe side for a funding sleeve.
          const target1e8 = (gap1e8 * (10000n + CONFIG.spotFeeBps)) / 10000n;
          const szS = ((target1e8 + step - 1n) / step) * step;
          const buyPx = roundPxWire((pxRaw * 100n * (10000n + CONFIG.slippageBps)) / 10000n); // spot raw@1e6 → wire×100; BUY crosses above
          console.log(`buying spot hedge gap: ${Number(szS) / 1e8} ${coin} @ IOC ${buyPx} (gap ${Number(gap1e8) / 1e8} + ${Number(CONFIG.spotFeeBps) / 100}% base-asset fee, rounded up to one lot)`);
          const stx = await strategy.openSpotBuy(buyPx, szS, CONFIG.tifIoc);
          await stx.wait();
          await new Promise((r) => setTimeout(r, 8000));
          const hsAfter = await strategy.spotHedgeSz();
          console.log(`verified hedge: ${Number(hsAfter) / 1e8} ${coin}`);
          if (hsAfter < shortSz1e8) {
            await sendAlert("🟠 DN hedge still short after buy", `hedge ${hsAfter} < short ${shortSz1e8} (1e8 units) — check spot fills.`);
          }
        } else if (gapUsd > oneLotUsd) {
          // A1: surface any residual ABOVE one lot — not a hard $1.00, which let
          // a $0.85 (7.1%) net-short read as "within granularity". Below HL's
          // $10 spot order min it is un-closeable by an order, so it needs eyes.
          await sendAlert(
            "🟠 DN hedge gap — spot leg under-funded",
            `short ${Number(shortSz1e8) / 1e8} vs spot ${Number(hedgeSz1e8) / 1e8} ${coin} (gap $${gapUsd.toFixed(2)} > one lot $${oneLotUsd.toFixed(2)}; below HL's $10 spot order min → un-closeable by an order). Fund the strategy's Core spot (transfer ${coin} in) before claiming even approximately delta-neutral.`
          );
        } else {
          // Sub-one-lot gaps are order-granularity noise: spot sizes round to
          // one lot (HYPE 0.01 ≈ $0.84 at $84) — you cannot trade closer.
          console.log(`hedge gap $${gapUsd.toFixed(2)} ≤ one lot ($${oneLotUsd.toFixed(2)}) — approximately delta-neutral ✓ (≤1-lot residual)`);
        }
      } else {
        console.log(`hedge covers the short (${Number(hedgeSz1e8) / 1e8} >= ${Number(shortSz1e8) / 1e8} ${coin}) — approximately delta-neutral ✓ (≤1-lot residual)`);
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
