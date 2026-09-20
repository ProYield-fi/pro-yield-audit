// dn_keeper.js — delta-neutral CoreWriter keeper (SKELETON)
//
// Responsibilities (liveness, NOT trust — the contract holds policy + funds):
//   1. Read adapter state (position, margin, account existence) from HyperEVM.
//   2. Read live funding from the HL API.
//   3. Decide: INIT/BRIDGE → OPEN → REBALANCE → UNWIND/HOLD.
//   4. Execute staged calls (bridge must land in an EARLIER block than actions).
//   5. VERIFY every CoreWriter action after the on-chain delay (they drop silently
//      otherwise) and alert on mismatch.
//
// Dry-run by default. Sends only with --execute.
// Run: DN_ADAPTER=0x... npx hardhat run scripts/dn_keeper.js --network hyperTestnet [-- --execute]
//
// TODO(vault wiring): sleeve size source = vault allocation × DN weight (once the
// strategy contract composes this adapter). TODO(policy): negative-funding unwind
// threshold, rebalance band, margin top-up rule. TODO(alerts): route mismatches
// to the Telegram notifier (same pattern as yield_scout).

const hre = require("hardhat");

const CONFIG = {
  adapter: process.env.DN_ADAPTER || null,
  hlInfoUrl: "https://api.hyperliquid.xyz/info",
  fundingAprThreshold: 5.0, // annualized % below which opening a hedge is not justified
  rebalanceBandPct: 5,      // |positionDrift| > band → rebalance
  slippageBps: 20n,         // IOC limit vs oracle (0.20%)
  tifIoc: 3,
  dryRun: !process.argv.includes("--execute"),
};

async function hlInfo(body) {
  const res = await fetch(CONFIG.hlInfoUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return res.json();
}

/// @returns annualized funding % for the adapter's perp asset (BTC=0, ETH=1)
async function fetchFundingApr(assetIndex) {
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

async function main() {
  const [signer] = await hre.ethers.getSigners();
  if (!CONFIG.adapter) {
    console.log("DN_ADAPTER unset — nothing to do (dry plan only).");
    console.log("Set DN_ADAPTER=<deployed adapter> after the vault wiring lands.");
    process.exit(0);
  }
  const adapter = await hre.ethers.getContractAt("DNCoreAdapter", CONFIG.adapter, signer);
  const asset = Number(await adapter.perpAsset());
  const szDec = Number(await adapter.perpSzDecimals());

  // ── 1. State ──
  const exists = await adapter.coreAccountExists();
  const pos = exists ? await adapter.position() : { szi: 0n };
  const margin = exists ? await adapter.marginSummary() : null;
  const oracle = await adapter.oraclePx();
  console.log(`state: exists=${exists} szi=${pos.szi} oracle=${oracle} szDecimals=${szDec}`);
  if (margin) console.log(`margin: accountValue=${margin.accountValue} marginUsed=${margin.marginUsed} ntlPos=${margin.ntlPos}`);

  // ── 2. Funding ──
  const apr = await fetchFundingApr(asset);
  console.log(`funding: ${apr.toFixed(2)}% annualized (HlPerp, ${asset === 0 ? "BTC" : "ETH"})`);

  // ── 3. Decide ──
  const targetNotionalUsd = 0; // TODO: sleeve size from vault allocation
  const driftPct = 0;          // TODO: (current − target) / target × 100
  let action = "HOLD";
  if (!exists) action = "BRIDGE_FIRST";
  else if (pos.szi === 0n && apr >= CONFIG.fundingAprThreshold && targetNotionalUsd > 0) action = "OPEN";
  else if (pos.szi !== 0n && Math.abs(driftPct) > CONFIG.rebalanceBandPct) action = "REBALANCE";
  else if (pos.szi !== 0n && apr < 0) action = "UNWIND_REVIEW"; // policy TODO
  console.log(`decision: ${action} (dryRun=${CONFIG.dryRun})`);

  // ── 4. Act (staged; each step verified before the next) ──
  if (CONFIG.dryRun || action === "HOLD" || action === "BRIDGE_FIRST") {
    console.log("no sends (dry-run or nothing to do)");
    return;
  }

  if (action === "OPEN" && targetNotionalUsd > 0) {
    // size = targetNotional / price, rounded DOWN to szDecimals, scaled 1e8
    const px = BigInt(oracle);
    const szFloat = targetNotionalUsd / (Number(px) / 1e8);
    const factor = 10 ** szDec;
    const sz = BigInt(Math.floor(szFloat * factor)) * 10n ** 8n / BigInt(factor);
    const limitPx = (px * (10000n + CONFIG.slippageBps)) / 10000n;
    console.log(`opening short: sz=${sz} @ IOC ${limitPx}`);
    const tx = await adapter.openShort(asset, limitPx, sz, CONFIG.tifIoc);
    await tx.wait();
    // ── 5. VERIFY (CoreWriter drops silently — always re-read after a delay) ──
    await new Promise((r) => setTimeout(r, 8000)); // ~1 L1 block + action delay
    const after = await adapter.position();
    if (after.szi === 0n) {
      console.error("MISMATCH: order not visible after delay — investigate (drop?)");
      process.exit(3);
    }
    console.log(`verified: szi=${after.szi}`);
  }

  // REBALANCE / UNWIND_REVIEW flows: same pattern — act, wait, verify, alert.
  // TODO: implement once vault wiring provides target sizing + policy sign-off.
}

main().catch((e) => {
  console.error("keeper error:", e.message?.slice(0, 300));
  process.exit(2);
});
