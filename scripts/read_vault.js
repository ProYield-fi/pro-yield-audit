// Read vault state via hardhat — used by insurance_fund.py and any Python consumer.
// Usage: npx hardhat run scripts/read_vault.js --network hyperTestnet
// Prints: totalAssets in USDC (18 decimals) on stdout, plain.
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ADDRESSES_PATH = path.join(__dirname, "..", "deployed_addresses.json");
const deployed = JSON.parse(fs.readFileSync(ADDRESSES_PATH, "utf8"));

async function main() {
  const V = await hre.ethers.getContractFactory("ProYieldVault");
  const v = V.attach(deployed.pro_yield_vault);
  const assets = await v.totalAssets();
  console.log(hre.ethers.formatUnits(assets, 18));
}
main().catch(e => { console.error(String(e.message || e).slice(0, 150)); process.exit(1); });
