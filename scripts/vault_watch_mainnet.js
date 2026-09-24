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
  if (!RUN) {
    console.log(`[dry] alert would send:\n${text}`);
    return;
  }
  const env = loadEnv();
  const tok = process.env.TELEGRAM_BOT_TOKEN || env.TELEGRAM_BOT_TOKEN;
  const chat = process.env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_HOME_CHANNEL || env.TELEGRAM_HOME_CHANNEL || env.TELEGRAM_CHAT_ID;
  if (!tok || !chat) {
    console.error("no telegram creds — alert NOT sent:", text);
    return;
  }
  try {
    const r = await fetch(`https://api.telegram.org/bot${tok}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
    });
    if (!r.ok) console.error("telegram send failed:", r.status, await r.text());
    else console.log("alert sent");
  } catch (e) {
    console.error("telegram send error:", e.message);
  }
}

async function main() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  const V = manifest.pro_yield_vault;
  const net = await hre.ethers.provider.getNetwork();
  if (Number(net.chainId) !== 999) {
    console.error(`wrong chain ${net.chainId} — refusing to watch`);
    process.exit(3);
  }

  const artifact = await hre.artifacts.readArtifact("ProYieldVault");
  const vault = new hre.ethers.Contract(V, artifact.abi, hre.ethers.provider);
  const block = await hre.ethers.provider.getBlockNumber();

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
    if (block >= fromBlock) {
      const iface = new hre.ethers.Interface(artifact.abi);
      let topics = null;
      try {
        topics = [[iface.getEvent("Deposit").topicHash, iface.getEvent("Withdraw").topicHash]];
      } catch (e) {
        alerts.push(`⚠️ event topics unavailable: ${e.message.slice(0, 100)}`);
      }
      try {
        const logs = topics
          ? await hre.ethers.provider.getLogs({ address: V, fromBlock, toBlock: block, topics })
          : [];
        for (const log of logs) {
          try {
            const ev = iface.parseLog(log);
            const who = ev.args[0];
            const amt = hre.ethers.formatUnits(ev.args[1], 6);
            alerts.push(`${ev.name === "Deposit" ? "💰 Deposit" : "📤 Withdraw"}: ${amt} USDC · ${who}\nblock ${log.blockNumber} · tx ${log.transactionHash}`);
          } catch {
            alerts.push(`vault event (undecoded) in block ${log.blockNumber} · tx ${log.transactionHash}`);
          }
        }
      } catch (e) {
        alerts.push(`⚠️ event scan failed: ${e.message.slice(0, 120)} (reads still checked)`);
      }
    }
    if (prev.owner !== cur.owner) alerts.push(`⚠️ VAULT OWNER CHANGED\n${prev.owner} → ${owner}`);
    if (prev.tvlCap !== cur.tvlCap || prev.perUserCap !== cur.perUserCap) {
      alerts.push(`⚠️ CAPS CHANGED\nTVL ${hre.ethers.formatUnits(prev.tvlCap, 6)} → ${hre.ethers.formatUnits(tvlCap, 6)} · per-user ${hre.ethers.formatUnits(prev.perUserCap, 6)} → ${hre.ethers.formatUnits(perUserCap, 6)}`);
    }
    if (prev.paused !== cur.paused) alerts.push(`⚠️ depositsPaused ${prev.paused} → ${paused}`);
    // TVL moved with NO event — should be impossible; say so rather than hide it
    if (prev.totalAssets !== cur.totalAssets && !alerts.some((a) => a.includes("Deposit") || a.includes("Withdraw"))) {
      alerts.push(`⚠️ totalAssets moved ${hre.ethers.formatUnits(prev.totalAssets, 6)} → ${hre.ethers.formatUnits(totalAssets, 6)} USDC with NO matching event (investigate)`);
    }
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
