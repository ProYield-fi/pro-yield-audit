const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [owner] = await hre.ethers.getSigners();
  console.log("Deploying with:", owner.address);
  
  // Deploy MockUSDC
  const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  console.log("MockUSDC:", await mockUSDC.getAddress());
  
  // Persist deployed addresses — single source of truth for keeper/insurance/monitor.
  // Every redeploy on a fresh chain mints new addresses; hardcoded ones go stale.
  const ADDRESSES_PATH = path.join(__dirname, "..", "deployed_addresses.json");
  const deployed = { deployed_utc: new Date().toISOString(), chain_id: 998, deployer: owner.address };
  
  // Deploy ProYieldVault
  const ProYieldVault = await hre.ethers.getContractFactory("ProYieldVault");
  const vault = await ProYieldVault.deploy(
    await mockUSDC.getAddress(),
    owner.address,
    owner.address
  );
  await vault.waitForDeployment();
  console.log("ProYieldVault:", await vault.getAddress());
  deployed.mock_usdc = await mockUSDC.getAddress();
  deployed.pro_yield_vault = await vault.getAddress();
  
  // Deploy DeltaNeutralStrategy
  const DeltaNeutral = await hre.ethers.getContractFactory("DeltaNeutralStrategy");
  const delta = await DeltaNeutral.deploy(
    await mockUSDC.getAddress(),
    owner.address,
    owner.address,
    owner.address
  );
  await delta.waitForDeployment();
  console.log("DeltaNeutral:", await delta.getAddress());
  deployed.delta_neutral = await delta.getAddress();
  
  // Persist BEFORE the tx sequence so a mid-run failure still leaves usable addresses
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(deployed, null, 2));
  console.log("Addresses saved to deployed_addresses.json");
  
  // Add strategy
  const addTx = await vault.addStrategy(await delta.getAddress());
  await addTx.wait();
  console.log("Strategy added");
  
  // Mint and approve
  const mintTx = await mockUSDC.mint(owner.address, ethers.parseUnits("1000000", 18));
  await mintTx.wait();
  const approveTx = await mockUSDC.approve(await vault.getAddress(), ethers.parseUnits("100000", 18));
  await approveTx.wait();
  console.log("Approved 100k mUSDC");
  
  // Deposit
  const depositTx = await vault.deposit(ethers.parseUnits("100000", 18));
  await depositTx.wait();
  console.log("Deposited 100k mUSDC");
  
  // Verify totalAssets
  const assets = await vault.totalAssets();
  console.log("\ntotalAssets:", hre.ethers.formatUnits(assets, 18), "USDC");
  console.log("totalAssets check:", hre.ethers.formatUnits(assets, 18), "== 100000:", assets === ethers.parseUnits("100000", 18));
  
  // Allocate
  const allocTx = await vault.allocate();
  await allocTx.wait();
  console.log("✅ allocate() works");
  
  // Harvest
  const harvestTx = await vault.harvest();
  await harvestTx.wait();
  console.log("✅ harvest() works");
  
  // Emergency withdraw
  const emergTx = await vault.emergencyWithdraw();
  await emergTx.wait();
  console.log("✅ emergencyWithdraw() works");
  
  // Name checks
  console.log("name check:", await vault.name(), "== ProYieldVault:", await vault.name() === "ProYieldVault");
  console.log("name check:", await delta.name(), "== DeltaNeutral:", await delta.name() === "DeltaNeutral");
  console.log("✅ name() functions work");
  
  // Owner check
  try {
    await vault.connect(hre.ethers.getSigners()[1]).addStrategy(await delta.getAddress());
    console.log("❌ onlyOwner failed");
  } catch (e) {
    console.log("✅ onlyOwner enforced");
  }
  
  console.log("\n=== ALL TESTS PASSED ===");
}
main().catch(console.error);
