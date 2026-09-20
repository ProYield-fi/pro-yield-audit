// Debug: where does the 10000 USDC go between deposit and allocate?
const hre = require("hardhat");
async function main() {
  const [owner] = await hre.ethers.getSigners();
  const E = hre.ethers;
  const fmt = (v) => E.formatUnits(v, 18);

  const MockUSDC = await E.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy(); await usdc.waitForDeployment();
  const ProYieldVault = await E.getContractFactory("ProYieldVault");
  const vault = await ProYieldVault.deploy(await usdc.getAddress(), owner.address, owner.address);
  await vault.waitForDeployment();
  const DeltaNeutral = await E.getContractFactory("DeltaNeutralStrategy");
  const delta = await DeltaNeutral.deploy(await usdc.getAddress(), owner.address, owner.address, owner.address);
  await delta.waitForDeployment();

  let tx = await vault.addStrategy(await delta.getAddress()); await tx.wait();
  tx = await delta.setVault(await vault.getAddress()); await tx.wait();

  const D = E.parseUnits("100000", 18);
  tx = await usdc.mint(owner.address, D); await tx.wait();
  tx = await usdc.approve(await vault.getAddress(), D); await tx.wait();

  const oBefore = await usdc.balanceOf(owner.address);
  tx = await vault.deposit(D); const rc = await tx.wait();
  const oAfter = await usdc.balanceOf(owner.address);

  console.log("owner delta (paid in):", fmt(oBefore - oAfter));
  console.log("vault USDC balance:  ", fmt(await usdc.balanceOf(await vault.getAddress())));
  console.log("vault totalAssets:   ", fmt(await vault.totalAssets()));
  console.log("strategy[0]:", await vault.strategyList(0));
  console.log("delta registered:    ", await vault.strategies(await delta.getAddress()));
  console.log("delta active:        ", await vault.strategyActive(await delta.getAddress()));

  tx = await vault.allocate(); await tx.wait();
  console.log("post-allocate delta: ", fmt(await usdc.balanceOf(await delta.getAddress())));
  console.log("post-allocate vault: ", fmt(await usdc.balanceOf(await vault.getAddress())));

  // recall from the vault's perspective — vault CAN'T call it (no code path), owner can't (auth).
  // Verify who CAN: check delta.vault
  console.log("delta.vault:", await delta.vault());
}
main().catch(e => { console.error(e); process.exit(1); });
