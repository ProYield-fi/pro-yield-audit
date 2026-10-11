// scripts/vault_watch_mainnet.js — mainnet vault sentinel.
//
// Reads the LIVE mainnet vault every run; alerts to the ops Telegram channel
// (TELEGRAM_BOT_TOKEN + TELEGRAM_HOME_CHANNEL from ~/.hermes/.env) when:
//   · a deposit or withdrawal lands (amount + counterparty + new TVL)
//   · owner / caps / depositsPaused change (admin surface moved)
//   · the vault's totalAssets moves without a matching event (should be impossible — says so)
// Silent when nothing happened. State: ~/.proyield/vault_watch_mainnet.json.
//
// Dry by default (prints); RUN=1 to send. Cron: every 10 min (see crontab).
//   cd ~/hypervault && RUN=1 npx hardhat run scripts/vault_watch_mainnet.js --network hyperMainnet
//
// RPC HARDENING (t_f524148a, 2026-10-05): the official HyperEVM RPC began
// throttling reads (-32005), DNS-failing (getaddrinfo EAI_AGAIN) and timing out
// on rpc.hyperliquid.xyz, which crashed this sentinel at the top-level catch
// BEFORE it could write state — the watchdog went stale with no alert. All of
// the sentinel's OWN reads (getNetwork, getBlockNumber, getLogs, vault contract
// reads) now run over the shared HyperEVM failover pool in rebate_trigger.js
// (official -> drpc, rotate on failure, healthy endpoint first). Alert paths and
// fail-closed behaviour are unchanged: if every endpoint fails, the run still
// throws and exits without a state write.
const hre = require("hardhat");
const fs = require("fs");
const os = require("os");
const path = require("path");

const RUN = process.env.RUN === "1";
const STATE = path.join(os.homedir(), ".proyield", "vault_watch_mainnet.json");
const MANIFEST = path.join(__dirname, "..", "deployed_addresses.mainnet.json");

function loadEnv() {
  const env = {};
  const p = path.join(os.homedir(), ".hermes", ".env");
  if (fs.existsSync(p)) {
    for (const line of fs.readFileSync(p, "utf8").split("\n")) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const i = t.indexOf("=");
      if (i > 0) env[t.slice(0, i).trim()] = t.slice(i + 1).trim().replace(/^["']|["']$/g, "");
    }
  }
  return env;
}

async function notify(text) {
  // Telegram HTML mode rejects an unescaped "<" as an unsupported start tag
  // (HTTP 400) — the 2026-10-05 keeper-health audit fix. Escape the payload so
  // a real alert can never be silently dropped.
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const safe = esc(text);
  if (!RUN) {
    console.log(`[dry] alert would send:\n${text}`);
    return { ok: false, status: null, reason: "dry run" };
  }
  // ALSO start an agent session via the gateway webhook (kanban t_d307f4b3).
  // Fire-and-forget — never gates the Telegram send below (primary channel).
  try { require("./alert_webhook").notifyWebhookFor("vault-watch", text); } catch { /* best effort */ }
  const env = loadEnv();
  const tok = process.env.TELEGRAM_BOT_TOKEN || env.TELEGRAM_BOT_TOKEN;
  const chat = process.env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_HOME_CHANNEL || env.TELEGRAM_HOME_CHANNEL || env.TELEGRAM_CHAT_ID;
  if (!tok || !chat) {
    console.error("no telegram creds — alert NOT sent:", text);
    return { ok: false, status: null, reason: "no telegram creds" };
  }
  try {
    const r = await fetch(`https://api.telegram.org/bot${tok}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text: safe, parse_mode: "HTML", disable_web_page_preview: true }),
    });
    if (!r.ok) {
      console.error("telegram send failed:", r.status, await r.text());
      return { ok: false, status: r.status };
    }
    console.log("alert sent");
    return { ok: true, status: r.status };
  } catch (e) {
    console.error("telegram send error:", e.message);
    return { ok: false, status: null, reason: e.message };
  }
}

async function main() {
  // Alert-path self-test (ops, t_bc5c7ff8): send ONE escaped test alert and
  // exit with the HTTP status — proves the alert path (escaping included)
  // reaches Telegram. Reads no chain state, touches no state file.
  //   WATCH_ALERT_TEST=1 RUN=1 npx hardhat run scripts/vault_watch_mainnet.js --network hyperMainnet
  if (process.env.WATCH_ALERT_TEST === "1") {
    const r = await notify(
      "ProYield vault watch — alert-path test\n" +
      "Escaping check: 2 < 3 && totalAssets() - (idle + realBacking) > $1 — status returned.",
    );
    console.log(`alert-path test: ${JSON.stringify(r)}`);
    process.exit(r && r.ok ? 0 : 1);
  }

  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  const V = manifest.pro_yield_vault;
  // Shared HyperEVM failover pool (t_f524148a): the sentinel's own reads rotate
  // official -> drpc instead of crashing on the official endpoint's throttle.
  const RT = require("./rebate_trigger");
  const scanPool = RT.makeScanPool(hre.ethers);
  const heProvider = RT.makeFailoverProvider(hre.ethers, scanPool);
  const net = await heProvider.getNetwork();
  if (Number(net.chainId) !== 999) {
    console.error(`wrong chain ${net.chainId} — refusing to watch`);
    process.exit(3);
  }

  const artifact = await hre.artifacts.readArtifact("ProYieldVault");
  const vault = new hre.ethers.Contract(V, artifact.abi, heProvider);
  const block = await heProvider.getBlockNumber();

  const [totalAssets, totalShares, owner, tvlCap, perUserCap, paused] = await Promise.all([
    vault.totalAssets(),
    vault.totalShares(),
    vault.owner(),
    vault.tvlCap(),
    vault.perUserCap(),
    vault.depositsPaused(),
  ]);

  const cur = {
    block,
    totalAssets: totalAssets.toString(),
    totalShares: totalShares.toString(),
    owner,
    tvlCap: tvlCap.toString(),
    perUserCap: perUserCap.toString(),
    paused,
  };

  const prev = fs.existsSync(STATE) ? JSON.parse(fs.readFileSync(STATE, "utf8")) : null;
  const alerts = [];

  if (!prev) {
    alerts.push(
      `🛡️ Vault sentinel armed (mainnet)\n` +
        `vault ${V}\nTVL ${hre.ethers.formatUnits(totalAssets, 6)} USDC · owner ${owner}\n` +
        `caps: tvl ${hre.ethers.formatUnits(tvlCap, 6)} / user ${hre.ethers.formatUnits(perUserCap, 6)} · paused: ${paused}\n` +
        `block ${block}`,
    );
  } else {
    // Events since last run
    const fromBlock = Number(prev.block) + 1;
    let scanTo = block;
    if (block >= fromBlock) {
      const iface = new hre.ethers.Interface(artifact.abi);
      let topics = null;
      try {
        topics = [[iface.getEvent("Deposit").topicHash, iface.getEvent("Withdraw").topicHash]];
      } catch (e) {
        alerts.push(`⚠️ event topics unavailable: ${e.message.slice(0, 100)}`);
      }
      try {
        const r = topics
          ? await RT.scanLogsChunked(scanPool, { address: V, fromBlock, toBlock: block, topics })
          : { logs: [], lastScanned: block, degraded: null };
        for (const log of r.logs) {
          try {
            const ev = iface.parseLog(log);
            const who = ev.args[0];
            const amt = hre.ethers.formatUnits(ev.args[1], 6);
            alerts.push(`${ev.name === "Deposit" ? "💰 Deposit" : "📤 Withdraw"}: ${amt} USDC · ${who}\nblock ${log.blockNumber} · tx ${log.transactionHash}`);
          } catch {
            alerts.push(`vault event (undecoded) in block ${log.blockNumber} · tx ${log.transactionHash}`);
          }
        }
        if (r.degraded) {
          scanTo = r.lastScanned;
          alerts.push(`⚠️ event scan degraded: ${r.degraded} (cursor held at ${scanTo}; retrying next tick)`);
        }
      } catch (e) {
        alerts.push(`⚠️ event scan failed: ${e.message.slice(0, 120)} (reads still checked)`);
      }
      cur.block = scanTo;
    }
    if (prev.owner !== cur.owner) alerts.push(`⚠️ VAULT OWNER CHANGED\n${prev.owner} → ${owner}`);
    if (prev.tvlCap !== cur.tvlCap || prev.perUserCap !== cur.perUserCap) {
      alerts.push(`⚠️ CAPS CHANGED\nTVL ${hre.ethers.formatUnits(prev.tvlCap, 6)} → ${hre.ethers.formatUnits(tvlCap, 6)} · per-user ${hre.ethers.formatUnits(prev.perUserCap, 6)} → ${hre.ethers.formatUnits(perUserCap, 6)}`);
    }
    if (prev.paused !== cur.paused) alerts.push(`⚠️ depositsPaused ${prev.paused} → ${paused}`);
    // sUSD3 (Frontier) gate: USD3 enforces a $1,000 minimum FIRST deposit per
    // depositor, and the strategy's immutable cap is 15% of book — so the
    // sleeve can only place ≥$1,000 once book ≥ $6,667. Latched alert (fires
    // once per crossing; state flag cleared only if the book falls back below).
    const SUSD3_BOOK_GATE_USD6 = 6667000000n; // $6,667 (1e9 minDeposit / 0.15)
    cur.susd3GateAlerted = prev.susd3GateAlerted === true; // carry the latch across runs
    if (BigInt(totalAssets) >= SUSD3_BOOK_GATE_USD6 && !cur.susd3GateAlerted) {
      alerts.push(
        `🚪 sUSD3 door REACHABLE — book ${hre.ethers.formatUnits(totalAssets, 6)} ≥ $6,667 ` +
        `(USD3's $1,000 first-deposit min now fits under the 15% cap).\n` +
        `Run: SUSD3_CYCLE_OK=1 MAX_FIRST_CYCLE_USD6=1000000000 bash scripts/susd3_first_cycle.sh\n` +
        `(dry first: bash scripts/susd3_first_cycle.sh; see docs/CREDIT_POOL_DD.md §9)`
      );
      cur.susd3GateAlerted = true;
    } else if (BigInt(totalAssets) < SUSD3_BOOK_GATE_USD6 && cur.susd3GateAlerted) {
      cur.susd3GateAlerted = false; // re-arm if the book falls back below the mark
    }
    // TVL moved with NO event. Legitimate no-event moves: harvest() sweeps +
    // creditYield()/reportLoss() (owner ops). Small harvest deltas used to fire
    // this on every sweep — alert only when the move is materially large; log
    // the small ones quietly so real anomalies still stand out.
    if (prev.totalAssets !== cur.totalAssets && !alerts.some((a) => a.includes("Deposit") || a.includes("Withdraw"))) {
      const delta = BigInt(totalAssets) - BigInt(prev.totalAssets);
      const abs = delta < 0n ? -delta : delta;
      if (abs >= 500000n) { // ≥ 0.50 USDC
        alerts.push(`⚠️ totalAssets moved ${hre.ethers.formatUnits(prev.totalAssets, 6)} → ${hre.ethers.formatUnits(totalAssets, 6)} USDC with NO matching event (investigate)`);
      } else {
        console.log(`quiet move (likely harvest/accrual): ${hre.ethers.formatUnits(prev.totalAssets, 6)} → ${hre.ethers.formatUnits(totalAssets, 6)} USDC`);
      }
    }
  }

  // ── PT-phantom watchdog (kanban t_bc5c7ff8) ───────────────────────────────
  // Independent of the deposit/event diff — runs every tick (10 min). PT is
  // FUNDED and PT-Arb matures ~Oct 15, and PTSleeveStrategy.completeInbound
  // does not consume inFlight6 (full fix = owner-gated redeploy t_698f42c2),
  // so a skipped keeper ackArrival double-counts the return and inflates the
  // sleeve's totalAssets(). See scripts/pt_phantom_check.js for the two checks.
  // Findings are LATCHED per (lane, kind) so a persisting phantom alerts once
  // per crossing, not every 10 minutes.
  cur.ptPhantom = (prev && prev.ptPhantom) || {};
  cur.ptPhantomGapStreak = (prev && prev.ptPhantomGapStreak) || {};
  try {
    const { checkPtPhantom } = require("./pt_phantom_check");
    const res = await checkPtPhantom({ ethers: hre.ethers, heProvider });
    const activeKeys = new Set();
    for (const f of res.findings) {
      const key = `${f.lane}:${f.kind}`;
      activeKeys.add(key);
      if (!cur.ptPhantom[key]) {
        cur.ptPhantom[key] = true;
        alerts.push(f.text);
      }
    }
    for (const k of Object.keys(cur.ptPhantom)) if (!activeKeys.has(k)) delete cur.ptPhantom[k];
    // A lane we cannot read for 6 straight runs (~1h) is itself worth a latched
    // alert — "found nothing" is not "absent" (degraded data burned us before).
    const gapLanes = new Set();
    for (const g of res.gaps) {
      if (!g.critical) { console.log(`pt-phantom venue gap (${g.lane}): ${g.reason}`); continue; }
      gapLanes.add(g.lane);
      cur.ptPhantomGapStreak[g.lane] = (cur.ptPhantomGapStreak[g.lane] || 0) + 1;
      if (cur.ptPhantomGapStreak[g.lane] === 6) {
        alerts.push(`⚠️ PT-phantom watchdog DEGRADED — ${g.lane} lane unreadable ${cur.ptPhantomGapStreak[g.lane]} runs (~1h): ${g.reason}`);
      }
    }
    for (const lane of Object.keys(cur.ptPhantomGapStreak)) if (!gapLanes.has(lane)) cur.ptPhantomGapStreak[lane] = 0;
    console.log(`pt-phantom: ${res.findings.length} finding(s), ${res.gaps.length} gap(s)`);
  } catch (e) {
    console.error("pt-phantom check failed (sentinel continues):", (e && e.message) || e);
  }

  // ── strategyList ↔ manifest drift guard (kanban t_ed8b04aa) ───────────────
  // The live vault's on-chain `strategyList` is the source of truth; the
  // manifest is only a record and silently fell behind once (flagged by the
  // 2026-09-30 audit, still true 2026-10-10 — 7 registered, manifest named 5).
  // Read-only; latched per strategy address so a drift alerts once per crossing,
  // not every 10 minutes. Never enumerates strategies FROM the manifest.
  cur.strategyManifestDrift = (prev && prev.strategyManifestDrift) || {};
  cur.strategyManifestGapStreak = (prev && prev.strategyManifestGapStreak) || 0;
  try {
    const { checkStrategyManifestDrift } = require("./strategy_manifest_guard");
    const g = await checkStrategyManifestDrift({ ethers: hre.ethers, heProvider });
    if (g.degraded || g.empty) {
      // "found nothing" is not "absent": a failed/empty read means drift CANNOT
      // be assessed. Never report OK on it — alert after ~1h of degradation.
      cur.strategyManifestGapStreak += 1;
      console.error(`strategy-manifest guard DEGRADED (${cur.strategyManifestGapStreak} runs): ${g.degraded ? g.reason : "strategyList read returned empty"}`);
      if (cur.strategyManifestGapStreak === 6) {
        alerts.push(`⚠️ strategy-manifest guard DEGRADED — the vault strategyList has been unreadable ${cur.strategyManifestGapStreak} runs (~1h): ${g.degraded ? g.reason : "empty read"}. Manifest drift CANNOT be checked (degraded data is not absent data).`);
      }
    } else {
      cur.strategyManifestGapStreak = 0;
      const seen = new Set();
      for (const m of g.missing) {
        const key = m.address.toLowerCase();
        seen.add(key);
        if (!cur.strategyManifestDrift[key]) {
          cur.strategyManifestDrift[key] = true;
          alerts.push(
            `⚠️ MANIFEST DRIFT — strategy ${m.address} (strategyList index ${m.index}, active=${m.active}) ` +
            `is REGISTERED in the live vault but NAMED in no deployed_addresses.mainnet.json entry. ` +
            `Reconcile the manifest (read-only record fix) — do NOT enumerate strategies from the manifest.`,
          );
        }
      }
      for (const k of Object.keys(cur.strategyManifestDrift)) if (!seen.has(k)) delete cur.strategyManifestDrift[k];
      console.log(`strategy-manifest guard: ${g.live.length} registered, ${g.missing.length} unmanifested`);
    }
  } catch (e) {
    console.error("strategy-manifest guard failed (sentinel continues):", (e && e.message) || e);
  }

  // ── per-venue concentration monitors, M1–M5 (kanban t_94578f70) ────────────
  // Closes the 2026-10-11 review's strongest finding (§4.2): the 15% per-venue
  // cap had NO production monitor. Read-only, additive — it reads the live
  // strategyList of BOTH books and groups adapters by REAL VENUE
  // (scripts/venue_keys.json), independent of the deposit/event diff above.
  //   M1 projectedShareBps()>maxShareBps() · M2 per-venue aggregate >15% of the
  //   two-book total (cap-governed venues only) · M3 both books · M4 addStrategy
  //   / setVenueCleared(true) watch · M5 allocate() concentration · M6 STUB (R7
  //   PROPOSED, not ratified). Findings are LATCHED per key (alert once per
  //   crossing). Full rules + scope notes: scripts/venue_concentration.js.
  cur.venueConc = (prev && prev.venueConc) || null;
  cur.venueConcGapStreak = (prev && prev.venueConcGapStreak) || 0;
  try {
    const { checkVenueConcentration } = require("./venue_concentration");
    const res = await checkVenueConcentration({
      ethers: hre.ethers,
      heProvider,
      prevState: (prev && prev.venueConc) || null,
    });
    const latched = (prev && prev.venueConc && prev.venueConc.latched) || {};
    const active = new Set();
    for (const f of res.findings) {
      active.add(f.key);
      if (!latched[f.key]) { latched[f.key] = true; alerts.push(f.text); }
    }
    for (const k of Object.keys(latched)) if (!active.has(k)) delete latched[k];
    cur.venueConc = Object.assign({}, res.state || {}, { latched });
    if (res.degraded) {
      // "found nothing" is not "absent": a failed/empty book read means the
      // aggregate CANNOT be assessed — never report OK on it; alert after ~1h.
      cur.venueConcGapStreak += 1;
      console.error(`venue-concentration DEGRADED (${cur.venueConcGapStreak} runs): ${res.gaps.map((g) => g.reason).join(" | ")}`);
      if (cur.venueConcGapStreak === 6) {
        alerts.push(`⚠️ per-venue concentration monitor DEGRADED — a book's strategyList/totalAssets has been unreadable ${cur.venueConcGapStreak} runs (~1h): ${res.gaps.map((g) => g.reason).join(" | ")}. Venue concentration CANNOT be checked (degraded data is not absent data).`);
      }
    } else {
      cur.venueConcGapStreak = 0;
      console.log(`venue-concentration: ${res.venues.length} venue group(s), ${res.findings.length} finding(s), 15% @ ${hre.ethers.formatUnits(res.summary.cap6, 6)} USDC`);
    }
  } catch (e) {
    console.error("venue-concentration check failed (sentinel continues):", (e && e.message) || e);
  }

  // ── First Deposit On Us — rebate auto-trigger (kanban t_67f20335) ─────────
  // Detects a NEW first deposit on the vault and calls the hardened
  // first_deposit_rebate.js with the wallet + deposit tx exactly as the manual
  // invocation does. Runs on THIS sentinel's 10-min cadence (reuse), keeping
  // its own cursor/latch so a wallet is attempted at most once ever (a failed
  // send is never retried — the rebate script's pending-before-pay ledger
  // handles recovery). LIVE only with REBATE_TRIGGER_LIVE=1 (set on the cron);
  // otherwise the child rebate script runs DRY and pays nothing. Wrapped so a
  // trigger fault can never take the sentinel down. Logs every run to
  // ~/.proyield/rebate_trigger_log.jsonl (fired / skipped / refused / dry).
  try {
    const { runRebateTrigger } = require("./rebate_trigger");
    const rt = await runRebateTrigger({
      ethers: hre.ethers,
      heProvider,
      scanPool,
      dry: process.env.REBATE_TRIGGER_LIVE !== "1",
    });
    console.log(`rebate-trigger: ${JSON.stringify(rt.summary)}`);
    if (rt.summary.fired > 0) alerts.push(`🎁 First Deposit rebate AUTO-PAID — ${rt.summary.fired} payout(s) this tick (see ~/.proyield/rebate_trigger_log.jsonl)`);
  } catch (e) {
    console.error("rebate-trigger failed (sentinel continues):", (e && e.message) || e);
  }

  if (RUN) {
    fs.mkdirSync(path.dirname(STATE), { recursive: true });
    fs.writeFileSync(STATE, JSON.stringify(cur, null, 1), { mode: 0o600 });
  } else {
    console.log("(dry run — state not persisted)");
  }

  if (alerts.length) {
    await notify(`ProYield vault watch — ${new Date().toISOString()}\n\n${alerts.join("\n\n")}`);
  } else {
    console.log(`no change (block ${block}, TVL ${hre.ethers.formatUnits(totalAssets, 6)})`);
  }
}

main().catch((e) => {
  console.error("vault_watch error:", (e && e.message) || e);
  process.exit(1);
});
