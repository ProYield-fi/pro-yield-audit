// Read vault state via hardhat — used by insurance_fund.py and any Python consumer.
// Usage: npx hardhat run scripts/read_vault.js --network hyperTestnet
// Prints: totalAssets in USDC on stdout, plain.
//
// Scale comes from the vault's OWN underlying asset, never an assumption: the
// sandbox MockUSDC is 18dp, the testnet USDC is 6dp. Hardcoding 18 once printed
// a real 30.60 USDC vault as "0.0000000306".
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ADDRESSES_PATH = process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json");
const deployed = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf8"));

async function main() {
  const V = await hre.ethers.getContractFactory("ProYieldVault");
  const v = V.attach(deployed.pro_yield_vault);
  const assets = await v.totalAssets();
  let dec = 18;
  try {
    // Raw human-readable ABIs: the repo vault artifact has no asset()/decimals(),
    // so attaching the generation's ABI would throw and silently leave 18.
    const vc = new hre.ethers.Contract(deployed.pro_yield_vault, ["function asset() view returns (address)"], hre.ethers.provider);
    const assetAddr = await vc.asset();
    const ac = new hre.ethers.Contract(assetAddr, ["function decimals() view returns (uint8)"], hre.ethers.provider);
    dec = Number(await ac.decimals());
  } catch { /* no asset() — repo generation: 18dp mock accounting */ }
  console.log(hre.ethers.formatUnits(assets, dec));
}
main().catch(e => { console.error(String(e.message || e).slice(0, 150)); process.exit(1); });
