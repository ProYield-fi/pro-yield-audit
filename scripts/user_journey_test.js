
const fs = require("fs");
const hre = require("hardhat");
async function main() {
  const j = JSON.parse(fs.readFileSync("/home/user/hypervault/deployed_addresses.json", "utf8"));
  const usdc = await hre.ethers.getContractAt("MockUSDC", j.mock_usdc);
  const vault = await hre.ethers.getContractAt("ProYieldVault", j.pro_yield_vault);
  // Simulated second user — fresh wallet like a real on-ramped user
  const user = await hre.ethers.getSigners().then(s => s[1]) || (await hre.ethers.getSigners())[0];
  const [,, userKey] = process.argv;
  let userWallet;
  if (userKey) { userWallet = new hre.ethers.Wallet(userKey, hre.ethers.provider); }
  else { userWallet = user; }
  console.log("user:", userWallet.address);
  const before = await vault.totalAssets();
  // fund gas + mint fake USDC (the on-ramp equivalent)
  const [owner] = await hre.ethers.getSigners();
  await owner.sendTransaction({ to: userWallet.address, value: hre.ethers.parseEther("1") });
  await (await usdc.connect(owner).mint(userWallet.address, hre.ethers.parseUnits("50", 18))).wait();
  await (await usdc.connect(userWallet).approve(vault.target, hre.ethers.parseUnits("50", 18))).wait();
  const tx = await (await vault.connect(userWallet).deposit(hre.ethers.parseUnits("50", 18))).wait();
  console.log("deposit tx", tx.hash);
  const after = await vault.totalAssets();
  console.log("totalAssets before", hre.ethers.formatUnits(before,18), "after", hre.ethers.formatUnits(after,18));
  const shares = await vault.shares(userWallet.address);
  console.log("user shares", hre.ethers.formatUnits(shares,18));
  // withdrawal path — user pulls out
  const wtx = await (await vault.connect(userWallet).withdraw(shares)).wait();
  console.log("withdraw tx", wtx.hash);
  const userBal = await usdc.balanceOf(userWallet.address);
  const endTotal = await vault.totalAssets();
  console.log("user USDC after withdraw", hre.ethers.formatUnits(userBal,18), "| totalAssets", hre.ethers.formatUnits(endTotal,18));
}
main().catch(e => { console.error(e); process.exit(1); });
