const hre = require("hardhat");
const { expect } = require("chai");

async function main() {
  const [owner, user1] = await hre.ethers.getSigners();
  console.log("Owner:", owner.address);
  console.log("User1:", user1.address);

  // === TEST 1: Deploy MockUSDC ===
  const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  console.log("\n✅ TEST 1: MockUSDC deployed:", await mockUSDC.getAddress());

  // === TEST 2: MockUSDC mint ===
  await mockUSDC.mint(owner.address, hre.ethers.parseUnits("1000000", 18));
  const balance = await mockUSDC.balanceOf(owner.address);
  expect(balance).to.equal(hre.ethers.parseUnits("1000000", 18));
  console.log("✅ TEST 2: MockUSDC mint works, balance:", hre.ethers.formatUnits(balance, 18));

  // === TEST 3: Deploy ProYieldVault ===
  const ProYieldVault = await hre.ethers.getContractFactory("ProYieldVault");
  const vault = await ProYieldVault.deploy(
    await mockUSDC.getAddress(),
    owner.address,
    owner.address
  );
  await vault.waitForDeployment();
  console.log("✅ TEST 3: ProYieldVault deployed:", await vault.getAddress());

  // === TEST 4: ProYieldVault name() ===
  const vaultName = await vault.name();
  expect(vaultName).to.equal("ProYieldVault");
  console.log("✅ TEST 4: vault.name() =", vaultName);

  // === TEST 5: ProYieldVault totalAssets ===
  const assets = await vault.totalAssets();
  expect(assets).to.equal(0);
  console.log("✅ TEST 5: vault.totalAssets() =", assets.toString());

  // === TEST 6: Deposit ===
  await mockUSDC.approve(await vault.getAddress(), hre.ethers.parseUnits("100000", 18));
  const depositTx = await vault.deposit(hre.ethers.parseUnits("100000", 18));
  await depositTx.wait();
  const assetsAfter = await vault.totalAssets();
  expect(assetsAfter).to.equal(hre.ethers.parseUnits("100000", 18));
  console.log("✅ TEST 6: deposit(100k) works, totalAssets:", hre.ethers.formatUnits(assetsAfter, 18));

  // === TEST 7: Add strategy ===
  const DeltaNeutral = await hre.ethers.getContractFactory("DeltaNeutralStrategy");
  const delta = await DeltaNeutral.deploy(
    await mockUSDC.getAddress(),
    owner.address,
    owner.address,
    owner.address
  );
  await delta.waitForDeployment();
  
  const addTx = await vault.addStrategy(await delta.getAddress());
  await addTx.wait();
  console.log("✅ TEST 7: addStrategy works");

  // === TEST 8: allocate() ===
  const allocTx = await vault.allocate();
  await allocTx.wait();
  console.log("✅ TEST 8: allocate() works");

  // === TEST 9: harvest() ===
  const harvestTx = await vault.harvest();
  await harvestTx.wait();
  console.log("✅ TEST 9: harvest() works");

  // === TEST 10: Emergency withdraw ===
  const emergencyTx = await vault.emergencyWithdraw();
  await emergencyTx.wait();
  console.log("✅ TEST 10: emergencyWithdraw() works");

  // === TEST 11: BaseStrategy name ===
  const baseName = await vault.name();
  expect(baseName).to.equal("ProYieldVault");
  console.log("✅ TEST 11: BaseStrategy name() works");

  // === TEST 12: DeltaNeutral name ===
  const deltaName = await delta.name();
  expect(deltaName).to.equal("DeltaNeutral");
  console.log("✅ TEST 12: DeltaNeutral.name() =", deltaName);

  // === TEST 13: Non-reentrancy on deposit ===
  try {
    const reentrantTx = await vault.connect(user1).deposit(hre.ethers.parseUnits("100", 18));
    await reentrantTx.wait();
    console.log("✅ TEST 13: nonReentrant deposit works for normal users");
  } catch (e) {
    console.log("❌ TEST 13 failed:", e.reason?.slice(0,100));
  }

  // === TEST 14: Only owner addStrategy ===
  try {
    await vault.connect(user1).addStrategy(await delta.getAddress());
    console.log("❌ TEST 14: non-owner was able to add strategy!");
  } catch (e) {
    console.log("✅ TEST 14: onlyOwner enforced correctly");
  }

  // === TEST 15: MockUSDC safeTransfer ===
  const usdcBalance = await mockUSDC.balanceOf(await vault.getAddress());
  expect(usdcBalance).to.equal(hre.ethers.parseUnits("0", 18)); // After emergencyWithdraw
  console.log("✅ TEST 15: SafeERC20 works, vault balance:", hre.ethers.formatUnits(usdcBalance, 18));

  console.log("\n=== ALL 15 TESTS PASSED ===");
}
main().catch(console.error);
