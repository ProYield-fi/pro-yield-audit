// dn_rotate_prep.js — rotation pre-flight + exact Safe calldata to switch the
// DN strategy to another roster coin. READ-ONLY: prints only; never signs.
//
// Rotation flow (operator-gated):
//   1. position must be FLAT (keeper UNWIND cycle, or funding-decay close)
//   2. this script verifies the target live and prints the two Safe txs
//   3. execute them (the safe executor dry-simulates via callStatic first):
//        MAINNET_OK=1 TO=<strategy> CALLDATA=<cd1> npx hardhat run scripts/safe_exec_mainnet.js --network hyperMainnet
//        MAINNET_OK=1 TO=<strategy> CALLDATA=<cd2> npx hardhat run scripts/safe_exec_mainnet.js --network hyperMainnet
//   4. next keeper cycle OPENS on the new coin (roster config guard checks it)
//
// Run: DN_STRATEGY=0x... TARGET=ZEC npx hardhat run scripts/dn_rotate_prep.js --network hyperMainnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ROSTER_FILE = process.env.DN_ROSTER_FILE || path.join(__dirname, "dn_roster.json");
const HL_INFO = "https://api.hyperliquid.xyz/info";

async function hl(body) {
  const res = await fetch(HL_INFO, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return res.json();
}

async function main() {
  const { ethers } = hre;
  const roster = JSON.parse(fs.readFileSync(ROSTER_FILE, "utf8"));
  const strategyAddr = process.env.DN_STRATEGY;
  const target = (process.env.TARGET || "").toUpperCase();
  if (!strategyAddr) { console.error("DN_STRATEGY unset — set it to the deployed DNCoreStrategy."); process.exit(3); }
  if (!target) {
    console.log("TARGET unset — roster coins:");
    for (const [c, e] of Object.entries(roster.coins)) console.log(`  ${c.padEnd(5)} asset=${e.asset} spot=@${e.spotPair}/${e.spotToken} pxScale=${e.pxScale}  (${e.note || ""})`);
    process.exit(0);
  }
  const entry = roster.coins[target];
  if (!entry) { console.error(`TARGET ${target} not in roster (${ROSTER_FILE})`); process.exit(3); }

  const strategy = await ethers.getContractAt("DNCoreStrategy", strategyAddr);
  const curAsset = Number(await strategy.perpAsset());
  const szi = (await strategy.position()).szi;
  const onPair = Number(await strategy.spotPairIndex());
  const onTok = Number(await strategy.spotTokenIndex());
  const onScale = await strategy.spotPxScale();
  console.log(`strategy ${strategyAddr}`);
  console.log(`current: asset=${curAsset} spot=@${onPair}/${onTok}/${onScale} position szi=${szi}`);

  if (curAsset === entry.asset) {
    const cfgMatch = onPair === entry.spotPair && onTok === entry.spotToken && Number(onScale) === Number(entry.pxScale);
    console.log(`already on ${target} — spot config ${cfgMatch ? "matches roster ✓" : "MISMATCH — setSpotConfig still needed"}`);
    process.exit(cfgMatch ? 0 : 3);
  }
  if (szi !== 0n) {
    console.error(`REFUSING: position open (szi=${szi}). Unwind first (keeper UNWIND cycle), then re-run.`);
    process.exit(3);
  }

  // live checks for the target hedge pair
  const [meta, smac, mids] = await Promise.all([
    hl({ type: "meta" }), hl({ type: "spotMetaAndAssetCtxs" }), hl({ type: "allMids" }),
  ]);
  const sm = smac[0];
  const pair = sm.universe.find((p) => p.index === entry.spotPair);
  const tok = sm.tokens.find((t) => t.index === entry.spotToken);
  const pu = meta.universe[entry.asset];
  const problems = [];
  if (!pu || pu.name !== target) problems.push(`perp[${entry.asset}] ≠ ${target}`);
  if (!pair || pair.tokens[0] !== entry.spotToken) problems.push(`pair @${entry.spotPair} base ≠ ${entry.spotToken}`);
  if (!tok || tok.szDecimals !== entry.szDec) problems.push(`token szDec ≠ ${entry.szDec}`);
  const ctx = smac[1].find((c) => c.coin === `@${entry.spotPair}`);
  const vol = ctx ? parseFloat(ctx.dayNtlVlm || "0") : 0;
  const mid = parseFloat(mids[`@${entry.spotPair}`] || "0");
  const mark = parseFloat(pu?.markPx || "0");
  const basis = mid && mark ? (mid / mark - 1) * 100 : null;
  console.log(`target ${target}: asset=${entry.asset} spot=@${entry.spotPair}/${entry.spotToken} pxScale=${entry.pxScale} ` +
    `vol=$${(vol / 1e6).toFixed(2)}M basis=${basis === null ? "?" : basis.toFixed(2)}%`);
  if (basis !== null && Math.abs(basis) > 2) problems.push(`basis ${basis.toFixed(2)}% > 2%`);
  if (!vol) problems.push("spot volume 0");
  if (problems.length) { console.error(`REFUSING: ${problems.join(" | ")}`); process.exit(3); }

  const iface = new ethers.Interface([
    "function setPerpAsset(uint32)",
    "function setSpotConfig(uint64,uint64,uint256)",
  ]);
  const cd1 = iface.encodeFunctionData("setPerpAsset", [entry.asset]);
  const cd2 = iface.encodeFunctionData("setSpotConfig", [entry.spotPair, entry.spotToken, BigInt(entry.pxScale)]);
  console.log(`\n── rotation plan: asset ${curAsset} → ${target} (two Safe txs, in order) ──`);
  console.log(`1) setPerpAsset(${entry.asset}) — calldata ${cd1}`);
  console.log(`2) setSpotConfig(${entry.spotPair}, ${entry.spotToken}, ${entry.pxScale}) — calldata ${cd2}`);
  console.log(`\nExecute (dry-simulates via callStatic first):`);
  console.log(`  cd /home/user/hypervault`);
  console.log(`  MAINNET_OK=1 TO=${strategyAddr} CALLDATA=${cd1} npx hardhat run scripts/safe_exec_mainnet.js --network hyperMainnet`);
  console.log(`  MAINNET_OK=1 TO=${strategyAddr} CALLDATA=${cd2} npx hardhat run scripts/safe_exec_mainnet.js --network hyperMainnet`);
  console.log(`\nPost-rotation: npx hardhat run scripts/dn_roster_check.js --network hyperMainnet`);
  console.log(`Then let the next keeper cycle open (funding >= ${process.env.DN_OPEN_APR || "5"}%/yr).`);
}

main().catch((e) => {
  console.error("rotate prep error:", e.message?.slice(0, 300));
  process.exit(2);
});
