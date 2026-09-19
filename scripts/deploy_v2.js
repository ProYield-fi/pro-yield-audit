const hre = require("hardhat");
async function main() {
  const [owner] = await hre.ethers.getSigners();
  console.log("Deploying with:", owner.address);
  
  // Deploy ProYieldVault
  const ProYieldVault = await hre.ethers.getContractFactory("ProYieldVault");
  const vault = await ProYieldVault.deploy(
    ethers.ZeroAddress,
    owner.address,
    owner.address
  );
  await vault.waitForDeployment();
  console.log("ProYieldVault:", await vault.getAddress());
  
  // Deploy DeltaNeutralStrategy
  const DeltaNeutral = await hre.ethers.getContractFactory("DeltaNeutralStrategy");
  const delta = await DeltaNeutral.deploy(
    ethers.ZeroAddress,
    owner.address,
    ethers.ZeroAddress
  );
  await delta.waitForDeployment();
  console.log("DeltaNeutral:", await delta.getAddress());
  
  // Add strategy
  const tx = await vault.addStrategy(await delta.getAddress());
  await tx.wait();
  console.log("Strategy added");
  
  // Test harvest and allocate
  console.log("totalAssets:", hre.ethers.formatUnits(await vault.totalAssets(), 6), "USDC");
  
  try {
    const h = await v.harvest();
    await h.wait();
    console.log("harvest SUCCESS!");
  } catch (e) {
    console.log("harvest error:", (e.reason || e.message).slice(0, 120));
  }
  
  try {
    const a = await vault.allocate();
    await a.wait();
    console.log("allocate SUCCESS!");
  } catch (e) {
    console.log("allocate error:", (e.reason || e.message).slice(0, 120));
  }
}
main().catch(console.error);
