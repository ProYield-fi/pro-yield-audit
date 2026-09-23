// scripts/write_vault_status.js — render vault_status.json for the web app
// from the CURRENT chain state (manifest-driven). Mirrors the shape the
// keeper publishes in production (vault_keeper.py); used by the local web
// smoke (scripts/web_smoke.sh) so the UI can be exercised against a local
// anvil. SMOKE_TAG, when set, is embedded in `network` so the smoke proves
// the page served THIS generation of the file.
//
// Run: npx hardhat run scripts/write_vault_status.js --network hyperTestnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const WEB = "/home/user/websites/pro-yield-web";

async function main() {
  const deployed = JSON.parse(
    fs.readFileSync(process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json"), "utf8"),
  );
  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);
  const totalAssets = await vault.totalAssets();
  const totalShares = await vault.totalShares();
  const price18 = totalShares > 0n ? (totalAssets * 10n ** 18n) / totalShares : 10n ** 18n;
  const F = (x, unit) => `${hre.ethers.formatUnits(x, 18)} ${unit}`;

  const tag = process.env.SMOKE_TAG;
  const status = {
    vault: deployed.pro_yield_vault,
    sharePrice: F(price18, "USDC"),
    totalAssets: F(totalAssets, "USDC"),
    totalShares: F(totalShares, "shares"),
    targetApyBps: null,
    recycling: { total: 0, boost: 0, runs: 0, last: null },
    ts: new Date().toISOString(),
    network: `local smoke${tag ? " " + tag : ""} (anvil, chain 998)`,
    source: "scripts/write_vault_status.js",
  };

  const outs = [process.env.VAULT_STATUS_OUT || path.join(WEB, "public", "vault_status.json")];
  const dist = path.join(WEB, "dist", "vault_status.json");
  if (fs.existsSync(path.dirname(dist))) outs.push(dist);
  for (const o of outs) {
    fs.writeFileSync(o, JSON.stringify(status, null, 1));
    console.log("wrote", o);
  }
  console.log(`totalAssets=${status.totalAssets} sharePrice=${status.sharePrice}`);
}

main().catch((e) => {
  console.error("write_vault_status error:", (e && e.stack) || e);
  process.exit(2);
});