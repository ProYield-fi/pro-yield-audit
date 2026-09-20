// dn_keeper.js — delta-neutral CoreWriter keeper (SKELETON)
//
// Target: DNCoreStrategy (vault-integrated). Set DN_STRATEGY=<address>.
// (DNCoreAdapter works too — same execution function names; the strategy adds
// syncCore/coreState/harvestableProfit and the vault profit cycle.)
//
// Responsibilities (liveness, NOT trust — the contract holds policy + funds):
//   1. Read strategy state (coreState: equity/principal/szi/realized/swept).
//   2. Read live funding from the HL API.
//   3. Decide: BRIDGE_FIRST → OPEN → REBALANCE → BRIDGE_PROFIT → HOLD.
//   4. Execute staged calls (bridge must land in an EARLIER block than actions).
//   5. VERIFY every CoreWriter action after the on-chain delay (they drop
//      silently otherwise) and alert on mismatch.
//
// Profit cycle (what makes the vault share price rise):
//   syncCore -> bridgeBackToEvm(profit portion) -> vault.harvest() sweeps the
//   realized profit above the buffer as real USDC to the vault.
//
// Dry-run by default. Sends only with --execute.
// Run: DN_STRATEGY=0x... npx hardhat run scripts/dn_keeper.js --network hyperTestnet [-- --execute]
//
// TODO(vault sizing): target notional = vault allocation × DN weight (needs
// the allocation policy wired to read vault totalAssets + DN share).
// TODO(policy): negative-funding unwind threshold, rebalance band, margin
// top-up rule. TODO(alerts): route mismatches to the Telegram notifier.

const hre = require("hardhat");

const CONFIG = {
  strategy: process.env.DN_STRATEGY || process.env.DN_ADAPTER || null,
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

/// @returns annualized funding % for the strategy's perp asset (BTC=0, ETH=1)
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

  // ── 3. Decide ──
  const targetNotionalUsd = 0; // TODO: sleeve size from vault allocation
  const driftPct = 0;          // TODO: (current − target) / target × 100
  const coreProfit6 = equity6 > principal6 ? equity6 - principal6 : 0n;
  let action = "HOLD";
  if (!exists) action = "BRIDGE_FIRST";
  else if (coreProfit6 > 0n && harvestable === 0n) action = "BRIDGE_PROFIT";
  else if (szi === 0n && apr >= CONFIG.fundingAprThreshold && targetNotionalUsd > 0) action = "OPEN";
  else if (szi !== 0n && Math.abs(driftPct) > CONFIG.rebalanceBandPct) action = "REBALANCE";
  else if (szi !== 0n && apr < 0) action = "UNWIND_REVIEW"; // policy TODO
  console.log(`decision: ${action} (dryRun=${CONFIG.dryRun})`);

  if (CONFIG.dryRun || action === "HOLD" || action === "BRIDGE_FIRST") {
    console.log("no sends (dry-run or nothing to do)");
    return;
  }

  // ── 4. Act (staged; each step verified before the next) ──
  if (action === "BRIDGE_PROFIT") {
    // Return the profit portion Core→EVM (needs HYPE on Core for transfer gas).
    // NOTE: if the hedge margin must stay sized, unwind extra margin first —
    // amount below only takes the excess above principal. TODO(policy).
    const amount6 = coreProfit6;
    console.log(`bridging profit back: ${amount6} (6dp)`);
    const tx = await strategy.bridgeBackToEvm(amount6);
    await tx.wait();
    // ── 5. VERIFY (CoreWriter drops silently — re-read after the delay) ──
    await new Promise((r) => setTimeout(r, 8000)); // ~1 L1 block + action delay
    const [eq2, pr2, , realized2] = await strategy.coreState();
    console.log(`verified: equity6=${eq2} principal6=${pr2} realized=${realized2}`);
    // Sweep to the vault (vault.harvest is permissionless):
    const vaultAddr = await strategy.vault();
    if (vaultAddr !== hre.ethers.ZeroAddress) {
      const vault = await hre.ethers.getContractAt("ProYieldVault", vaultAddr, signer);
      const htx = await vault.harvest();
      await htx.wait();
      console.log("vault.harvest() done — realized profit swept above buffer");
    }
  }

  if (action === "OPEN" && targetNotionalUsd > 0) {
    // size = targetNotional / price, rounded DOWN to szDecimals, scaled 1e8
    const px = BigInt(await strategy.oraclePx());
    const szFloat = targetNotionalUsd / (Number(px) / 1e8);
    const factor = 10 ** szDec;
    const sz = BigInt(Math.floor(szFloat * factor)) * 10n ** 8n / BigInt(factor);
    const limitPx = (px * (10000n + CONFIG.slippageBps)) / 10000n;
    console.log(`opening short: sz=${sz} @ IOC ${limitPx}`);
    const tx = await strategy.openShort(asset, limitPx, sz, CONFIG.tifIoc);
    await tx.wait();
    await new Promise((r) => setTimeout(r, 8000));
    const after = await strategy.position();
    if (after.szi === 0n) {
      console.error("MISMATCH: order not visible after delay — investigate (drop?)");
      process.exit(3);
    }
    console.log(`verified: szi=${after.szi}`);
  }

  // REBALANCE / UNWIND_REVIEW flows: same pattern — act, wait, verify, alert.
  // TODO: implement once vault sizing + policy sign-off land.
}

main().catch((e) => {
  console.error("keeper error:", e.message?.slice(0, 300));
  process.exit(2);
});
