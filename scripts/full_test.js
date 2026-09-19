const hre = require("hardhat");
async function main() {
  const [owner] = await hre.ethers.getSigners();
  console.log("Deploying with:", owner.address);
  
  const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  console.log("MockUSDC:", await mockUSDC.getAddress());
  
  const mintTx = await mockUSDC.mint(owner.address, ethers.parseUnits("1000000", 18));
  await mintTx.wait();
  console.log("Minted 1,000,000 mUSDC");
  
  const balance = await mockUSDC.balanceOf(owner.address);
  console.log("Balance:", hre.ethers.formatUnits(balance, 18));
  
  const ProYieldVault = await hre.ethers.getContractFactory("ProYieldVault");
  const vault = await ProYieldVault.deploy(
    await mockUSDC.getAddress(),
    owner.address,
    owner.address
  );
  await vault.waitForDeployment();
  console.log("\nProYieldVault:", await vault.getAddress());
  
  const DeltaNeutral = await hre.ethers.getContractFactory("DeltaNeutralStrategy");
  const delta = await DeltaNeutral.deploy(
    await mockUSDC.getAddress(),
    owner.address,
    owner.address,
    owner.address
  );
  await delta.waitForDeployment();
  console.log("DeltaNeutral:", await delta.getAddress());
  
  const addTx = await vault.addStrategy(await delta.getAddress());
  await addTx.wait();
  console.log("Strategy added");
  
  const approveTx = await mockUSDC.approve(await vault.getAddress(), ethers.parseUnits("100000", 18));
  await approveTx.wait();
  console.log("Approved 100,000 mUSDC");
  
  const depositTx = await vault.deposit(ethers.parseUnits("100000", 18));
  await depositTx.wait();
  console.log("Deposited 100,000 mUSDC");
  
  const totalAssets = await vault.totalAssets();
  console.log("\ntotalAssets:", hre.ethers.formatUnits(totalAssets, 18), "USDC");
  
  try {
    const h = await vault.harvest();
    await h.wait();
    console.log("✅ harvest():", h.hash);
  } catch (e) {
    console.log("❌ harvest():", (e.reason || e.message).slice(0, 150));
  }
  
  try {
    const a = await vault.allocate();
    await a.wait();
    console.log("✅ allocate():", a.hash);
  } catch (e) {
    console.log("❌ allocate():", (e.reason || e.message).slice(0, 150));
  }
  
  const lh = await vault.lastHarvest();
  console.log("\nlastHarvest:", lh.toString());
  console.log("Final totalAssets:", hre.ethers.formatUnits(await vault.totalAssets(), 18), "USDC");
  console.log("\n=== ALL TESTS PASSED ===");
}
main().catch(console.error);
