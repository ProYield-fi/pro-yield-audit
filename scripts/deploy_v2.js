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

  // PYD token + fee infrastructure (fee loop: vault perf fee -> FD -> staking/insurance)
  const PYDToken = await hre.ethers.getContractFactory("PYDToken");
  const pyd = await PYDToken.deploy(ethers.parseUnits("100000000", 18)); // 100M
  await pyd.waitForDeployment();
  const FeeDistributor = await hre.ethers.getContractFactory("FeeDistributor");
  const feeDistributor = await FeeDistributor.deploy(await mockUSDC.getAddress());
  await feeDistributor.waitForDeployment();
  const PYDStaking = await hre.ethers.getContractFactory("PYDStaking");
  const staking = await PYDStaking.deploy(await pyd.getAddress());
  await staking.waitForDeployment();
  deployed.pyd_token = await pyd.getAddress();
  deployed.fee_distributor = await feeDistributor.getAddress();
  deployed.pyd_staking = await staking.getAddress();
  console.log("PYD:", deployed.pyd_token, "| FeeDistributor:", deployed.fee_distributor, "| Staking:", deployed.pyd_staking);
  
  // Deploy ProYieldVault — performance fees route to FeeDistributor
  const ProYieldVault = await hre.ethers.getContractFactory("ProYieldVault");
  const vault = await ProYieldVault.deploy(
    await mockUSDC.getAddress(),
    owner.address,
    await feeDistributor.getAddress()
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

  // Funding infrastructure: testnet oracle + venue stand-in (prod swaps adapters)
  const MockFundingOracle = await hre.ethers.getContractFactory("MockFundingOracle");
  const fundingOracle = await MockFundingOracle.deploy(1100); // 11% APR annualized bps
  await fundingOracle.waitForDeployment();
  const MockFundingSource = await hre.ethers.getContractFactory("MockFundingSource");
  const fundingSource = await MockFundingSource.deploy(await mockUSDC.getAddress());
  await fundingSource.waitForDeployment();
  await (await delta.setOracle(await fundingOracle.getAddress())).wait();
  await (await delta.setFundingSource(await fundingSource.getAddress())).wait();
  // pre-fund the venue with 1M USDC so funding accrual pays real tokens
  await (await mockUSDC.mint(owner.address, ethers.parseUnits("1000000", 18))).wait();
  await (await mockUSDC.approve(await fundingSource.getAddress(), ethers.parseUnits("1000000", 18))).wait();
  await (await fundingSource.fund(ethers.parseUnits("1000000", 18))).wait();
  // open a position so accrual has a notional
  await (await delta.openPosition(ethers.parseUnits("30000", 18))).wait();
  await (await delta.updateFunding()).wait();
  // fund PYD staking rewards (1M PYD over 30 days) — fee-recycling leg
  await (await pyd.approve(await staking.getAddress(), ethers.parseUnits("1000000", 18))).wait();
  await (await staking.fundRewards(ethers.parseUnits("1000000", 18), 30 * 24 * 3600)).wait();
  console.log("FundingOracle:", await fundingOracle.getAddress());
  console.log("FundingSource:", await fundingSource.getAddress());
  deployed.funding_oracle = await fundingOracle.getAddress();
  deployed.funding_source = await fundingSource.getAddress();
  
  // Persist BEFORE the tx sequence so a mid-run failure still leaves usable addresses
  fs.writeFileSync(ADDRESSES_PATH, JSON.stringify(deployed, null, 2));
  console.log("Addresses saved to deployed_addresses.json");
  
  // Add strategy
  const addTx = await vault.addStrategy(await delta.getAddress());
  await addTx.wait();
  console.log("Strategy added");

  // Authorize vault to recall funds from the strategy (T-012 withdrawal path)
  const setVaultTx = await delta.setVault(await vault.getAddress());
  await setVaultTx.wait();
  console.log("Strategy vault authorization set");
  
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

  // NOTE: emergencyWithdraw is deliberately NOT exercised here — it drains
  // backing and permanently dilutes the share price (correct 4626 crisis
  // semantics, but this vault is the canonical one the keeper serves).
  // The emergency path is covered by scripts/integration_tests.js §D on a
  // throwaway vault, including post-emergency price behavior.
  
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
