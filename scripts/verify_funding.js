const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const deployed = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
async function main() {
  const E = hre.ethers;
  const usdc = (await E.getContractFactory("MockUSDC")).attach(deployed.mock_usdc);
  const delta = (await E.getContractFactory("DeltaNeutralStrategy")).attach(deployed.delta_neutral);
  const vault = (await E.getContractFactory("ProYieldVault")).attach(deployed.pro_yield_vault);
  const oracle = (await E.getContractFactory("MockFundingOracle")).attach(deployed.funding_oracle);
  const fmt = (v) => E.formatUnits(v, 18);
  console.log("oracle rate:", (await oracle.getFundingRate()).toString(), "bps =", (await oracle.getFundingRate()).toString() / 100 + "% APR");
  console.log("delta position:", fmt(await delta.delta()), "USDC notional");
  console.log("fundingRate on strategy:", (await delta.fundingRate()).toString());
  console.log("accruedFunding:", fmt(await delta.accruedFunding()), "USDC");
  console.log("strategy USDC balance:", fmt(await usdc.balanceOf(deployed.delta_neutral)));
  const fd = await vault.feeDistributor();
  console.log("FeeDistributor USDC:", fmt(await usdc.balanceOf(fd)));
  console.log("vault idle USDC:", fmt(await usdc.balanceOf(deployed.pro_yield_vault)));
}
main().catch(e => { console.error(String(e.message || e).slice(0, 150)); process.exit(1); });
