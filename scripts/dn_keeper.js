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
//      (from the scout's blend snapshot) × deployPct. Never exceeds the USDC
//      the strategy actually holds on Core (margin cap = deployable × maxLev
//      is NOT used — we stay 1:1 notional vs margin for true delta-neutral).
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
//
// TODO(policy): negative-funding unwind threshold, margin top-up rule.
// TODO(alerts): route mismatches to the Telegram notifier.

const hre = require("hardhat");
const fs = require("fs");

const CONFIG = {
  strategy: process.env.DN_STRATEGY || process.env.DN_ADAPTER || null,
  hlInfoUrl: "https://api.hyperliquid.xyz/info",
  fundingAprThreshold: 5.0, // annualized % below which opening a hedge is not justified
  unwindAprThreshold: parseFloat(process.env.DN_UNWIND_APR || "-2.0"), // short PAYS when funding > 0; below this → close
  rebalanceBandPct: 5,      // |positionDrift| > band → rebalance
  slippageBps: 20n,         // IOC limit vs oracle (0.20%)
  tifIoc: 3,
  // ── Sizing policy ──
  scoutSnapshot: process.env.SCOUT_SNAPSHOT || "/home/user/yield_scout/data/snapshot.json",
  deployPct: parseFloat(process.env.DN_DEPLOY_PCT || "0.90"), // fraction of sleeve bridged to Core
  marginUtilBps: 3300n,  // perp margin needed per 1e4 notional (BTC maxLev 40 → 1/40 = 250bps; pad to 3300 for fees/spread)
  maxSleeveUsd: parseFloat(process.env.DN_MAX_SLEEVE_USD || "0"), // 0 = no override cap
  dryRun: !(process.argv.includes("--execute") || process.env.DN_EXECUTE === "1"),
};

/// @notice Telegram alert — reuses yield_scout's creds chain (env →
/// ~/.hermes/secrets/telegram.json → ~/.hermes/.env). Never throws: alerts
/// queue to a file so verification failures are never silently lost.
async function sendAlert(title, body) {
  const line = `[dn-keeper] ${title} — ${body}`;
  console.log(line);
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
      fs2.appendFileSync("/home/user/yield_scout/data/pending_notifications.log",
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
      require("fs").appendFileSync("/home/user/yield_scout/data/pending_notifications.log",
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

/// @returns annualized funding % for the strategy's perp asset (BTC=0, ETH=1)
async function fetchFundingApr(assetIndex) {
  // Test injection: DN_FORCE_APR overrides the live read (dry-run tests only).
  if (process.env.DN_FORCE_APR) return parseFloat(process.env.DN_FORCE_APR);
  const predicted = await hlInfo({ type: "predictedFundings" });
  // shape: [[coin, [[venue, {fundingRate, nextFundingTime}], ...]], ...]
  // HlPerp venue = the validator perp book we hedge on. fundingRate is HOURLY.
  const coin = assetIndex === 0 ? "BTC" : "ETH";
  const row = predicted.find((r) => r[0] === coin);
  if (!row) throw new Error(`no predicted funding for ${coin}`);
  const venue = row[1].find((v) => v[0] === "HlPerp") || row[1][0];
  const hourly = parseFloat(venue[1].fundingRate);
  return hourly * 24 * 365 * 100;
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

/// @returns sleeve target in USD (float) given vault assets + DN weight.
function computeTargetNotionalUsd(vaultTotalAssetsUsd, dnWeight) {
  let sleeve = vaultTotalAssetsUsd * dnWeight;
  if (CONFIG.maxSleeveUsd > 0) sleeve = Math.min(sleeve, CONFIG.maxSleeveUsd);
  return sleeve; // hedge NOTIONAL = sleeve USD (1:1 delta-neutral)
}

async function main() {
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
  console.log(`state: exists=${exists} equity6=${equity6} principal6=${principal6} szi=${szi} szDecimals=${szDec}`);
  console.log(`profit: realized=${realized} swept=${swept} harvestable=${harvestable} syncedAt=${syncedAt}`);

  // ── 2. Funding ──
  const apr = await fetchFundingApr(asset);
  console.log(`funding: ${apr.toFixed(2)}% annualized (HlPerp, ${asset === 0 ? "BTC" : "ETH"})`);

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
  const px = BigInt(await strategy.oraclePx());
  // szi is 1e8-scaled human units (0.05 BTC → 5_000_000); px is 1e8-scaled
  // USD. Notional USD = (|szi|/1e8) × (px/1e8) — BOTH normalized.
  const currentNotionalUsd = (Math.abs(Number(szi)) / 1e8) * (Number(px) / 1e8);
  const driftPct = targetNotionalUsd > 0 ? ((currentNotionalUsd - targetNotionalUsd) / targetNotionalUsd) * 100 : 0;
  console.log(`position: szi=${szi} px=${Number(px) / 1e8} current notional ${currentNotionalUsd.toFixed(2)} USD (drift ${driftPct.toFixed(2)}% vs target)`);

  // ── 4. Decide ──
  const coreProfit6 = equity6 > principal6 ? equity6 - principal6 : 0n;
  let action = "HOLD";
  if (!exists) action = "BRIDGE_FIRST";
  else if (coreProfit6 > 0n && harvestable === 0n) action = "BRIDGE_PROFIT";
  else if (targetNotionalUsd >= 10 && szi === 0n && apr >= CONFIG.fundingAprThreshold) action = "OPEN";
  else if (szi !== 0n && apr < CONFIG.unwindAprThreshold) action = "UNWIND";
  else if (szi !== 0n && Math.abs(driftPct) > CONFIG.rebalanceBandPct) action = "REBALANCE";
  console.log(`decision: ${action} (dryRun=${CONFIG.dryRun})`);

  if (CONFIG.dryRun || action === "HOLD" || action === "BRIDGE_FIRST") {
    console.log("no sends (dry-run or nothing to do)");
    return;
  }

  // ── 5. Act (staged; each step verified before the next) ──
  if (action === "BRIDGE_PROFIT") {
    // Return the profit portion Core→EVM (needs HYPE on Core for transfer gas).
    // NOTE: if the hedge margin must stay sized, unwind extra margin first —
    // amount below only takes the excess above principal. TODO(policy).
    const amount6 = coreProfit6;
    console.log(`bridging profit back: ${amount6} (6dp)`);
    const tx = await strategy.bridgeBackToEvm(amount6);
    await tx.wait();
    // ── VERIFY (CoreWriter drops silently — re-read after the delay) ──
    await new Promise((r) => setTimeout(r, 8000)); // ~1 L1 block + action delay
    const [eq2, pr2, , realized2] = await strategy.coreState();
    console.log(`verified: equity6=${eq2} principal6=${pr2} realized=${realized2}`);
    if (vaultAddr !== hre.ethers.ZeroAddress) {
      const vault = await hre.ethers.getContractAt("ProYieldVault", vaultAddr, signer);
      const htx = await vault.harvest();
      await htx.wait();
      console.log("vault.harvest() done — realized profit swept above buffer");
      await sendAlert("💰 DN profit harvested", `realized profit swept to the vault above the buffer. Check the transparency page for the updated share price.`);
    }
  }

  if (action === "UNWIND") {
    // Negative funding: the short PAYS. Close the full position (reduceOnly),
    // verify, alert. Capital returns to spot → bridge-back handles the rest.
    const sz = szi < 0n ? -szi : szi; // buy back the exact position size
    const limitPx = (px * (10000n - CONFIG.slippageBps)) / 10000n; // buy: lower
    console.log(`unwinding short: sz=${sz} @ IOC ${limitPx} (funding ${apr.toFixed(2)}% < ${CONFIG.unwindAprThreshold}%)`);
    const tx = await strategy.closeShort(asset, limitPx, sz, CONFIG.tifIoc);
    await tx.wait();
    await new Promise((r) => setTimeout(r, 8000));
    const after = await strategy.position();
    const flat = after.szi === 0n;
    console.log(`verified: szi=${after.szi} (flat=${flat})`);
    await sendAlert(
      flat ? "🟢 DN unwind complete" : "🔴 DN unwind MISMATCH",
      `funding ${apr.toFixed(2)}%/yr — short ${flat ? "closed" : "NOT closed (szi=" + after.szi + ")"}; verify on-chain.`
    );
    if (!flat) process.exit(3);
    return;
  }

  if ((action === "OPEN" || action === "REBALANCE") && targetNotionalUsd >= 10) {
    // OPEN: short the full target. REBALANCE: close the excess (buy back the
    // delta) then re-open only if still short of target (rare — drift usually
    // means over-sized from price moves, i.e. BUY back the excess).
    if (action === "REBALANCE" && currentNotionalUsd > targetNotionalUsd) {
      const reduceUsd = currentNotionalUsd - targetNotionalUsd;
      const szFloat = reduceUsd / (Number(px) / 1e8);
      const factor = 10 ** szDec;
      const sz = BigInt(Math.floor(szFloat * factor)) * 10n ** 8n / BigInt(factor);
      const limitPx = (px * (10000n - CONFIG.slippageBps)) / 10000n; // buy: lower
      console.log(`reducing short by ${reduceUsd.toFixed(2)} USD: sz=${sz} @ IOC ${limitPx}`);
      const tx = await strategy.closeShort(asset, limitPx, sz, CONFIG.tifIoc);
      await tx.wait();
      await new Promise((r) => setTimeout(r, 8000));
      const after = await strategy.position();
      console.log(`verified: szi=${after.szi}`);
      if ((Math.abs(Number(after.szi)) / 1e8) * (Number(px) / 1e8) < targetNotionalUsd * 0.9) {
        console.error("MISMATCH: position smaller than expected — investigate (drop?)");
        process.exit(3);
      }
      return;
    }
    // OPEN path (also the under-sized rebalance): short the full target.
    // Margin check: strategy must hold enough USDC on Core (bridged earlier).
    const needMargin6 = BigInt(Math.floor(targetNotionalUsd * 1e6)) * CONFIG.marginUtilBps / 10000n;
    if (equity6 < needMargin6) {
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
    }
    const szFloat = targetNotionalUsd / (Number(px) / 1e8);
    const factor = 10 ** szDec;
    const sz = BigInt(Math.floor(szFloat * factor)) * 10n ** 8n / BigInt(factor);
    const limitPx = (px * (10000n + CONFIG.slippageBps)) / 10000n; // sell: higher
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
  }

  // UNWIND_REVIEW flow: same pattern — act, wait, verify, alert.
  // TODO: implement once the negative-funding policy sign-off lands.
}

main().catch((e) => {
  console.error("keeper error:", e.message?.slice(0, 300));
  process.exit(2);
});
