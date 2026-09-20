const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const deployed = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
async function main() {
  const E = hre.ethers;
  const vault = (await E.getContractFactory("ProYieldVault")).attach(deployed.pro_yield_vault);
  const delta = (await E.getContractFactory("DeltaNeutralStrategy")).attach(deployed.delta_neutral);
  try {
    const h1 = await vault.harvest(); await h1.wait();
    console.log("harvest 1 ok");
  } catch (e) { console.error("harvest 1 reverted:", (e.reason || e.message || "").slice(0, 100)); }
  try {
    const h2 = await vault.harvest(); await h2.wait();
    console.log("harvest 2 ok");
  } catch (e) { console.error("harvest 2 reverted:", (e.reason || e.message || "").slice(0, 100)); }
  try {
    const d1 = await delta.harvest(); await d1.wait();
    console.log("delta harvest ok");
  } catch (e) { console.error("delta harvest reverted:", (e.reason || e.message || "").slice(0, 100)); }
}
main().catch(e => { console.error(e.message?.slice(0, 120)); process.exit(1); });
