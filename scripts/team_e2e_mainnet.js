/**
 * Team E2E on MAINNET — deposit / withdraw against the live ProYieldVault.
 * Signs from the team test wallet (~/.proyield/onramp_usertest.json, 0x8377…).
 * DRY by default; sending requires MAINNET_OK=1 + chain 999.
 *
 *   PHASE=deposit   (default) approve + deposit AMOUNT USDC
 *   PHASE=withdraw  withdraw AMOUNT USDC (asset units; cap = maxWithdraw)
 *   AMOUNT=10       whole USDC
 *
 *   HYPEREVM_MAINNET_RPC_URL overrides the RPC (hardhat network hyperMainnet).
 */
const hre = require("hardhat");
const fs = require("fs");
const os = require("os");
const path = require("path");

const MANIFEST = process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.mainnet.json");
const KEY_FILE = process.env.TEAM_KEY_FILE || path.join(os.homedir(), ".proyield", "onramp_usertest.json");
const EXPECTED_WALLET = "0x8377870974df41DB4aaa67a842781227390167a9";

const SEND = process.env.MAINNET_OK === "1";
const PHASE = process.env.PHASE || "deposit";
const AMOUNT = hre.ethers.parseUnits(process.env.AMOUNT || "10", 6);

function fail(msg) {
  console.error(`REFUSING: ${msg}`);
  process.exit(3);
}

async function main() {
  const { ethers } = hre;
  if (!["deposit", "withdraw"].includes(PHASE)) fail(`unknown PHASE ${PHASE}`);

  const net = await ethers.provider.getNetwork();
  if (Number(net.chainId) !== 999) fail(`chainId ${net.chainId} is not 999`);
  console.log(`chain 999 ✓ · ${SEND ? "SEND MODE" : "DRY MODE"} · phase=${PHASE} · amount=${ethers.formatUnits(AMOUNT, 6)} USDC`);

  const m = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  if (Number(m.chain_id) !== 999 || !m.pro_yield_vault || !m.vault_asset) fail(`manifest not a mainnet manifest (${MANIFEST})`);
  const vaultAddr = m.pro_yield_vault;
  const usdcAddr = m.vault_asset;
  if ((await ethers.provider.getCode(vaultAddr)) === "0x") fail(`no vault code at ${vaultAddr}`);

  const key = JSON.parse(fs.readFileSync(KEY_FILE, "utf8")).private_key;
  const signer = new ethers.Wallet(key, ethers.provider);
  if (signer.address.toLowerCase() !== EXPECTED_WALLET.toLowerCase()) fail(`wallet ${signer.address} != expected ${EXPECTED_WALLET}`);

  const usdc = new ethers.Contract(usdcAddr, [
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address,address) view returns (uint256)",
    "function approve(address,uint256) returns (bool)",
  ], signer);
  const vault = new ethers.Contract(vaultAddr, [
    "function deposit(uint256)",
    "function withdraw(uint256)",
    "function shares(address) view returns (uint256)",
    "function maxWithdraw(address) view returns (uint256)",
    "function convertToAssets(uint256) view returns (uint256)",
    "function totalAssets() view returns (uint256)",
  ], signer);

  const [usdcBal, hypeBal, shares, maxW, price] = await Promise.all([
    usdc.balanceOf(signer.address),
    ethers.provider.getBalance(signer.address),
    vault.shares(signer.address),
    vault.maxWithdraw(signer.address),
    vault.convertToAssets(10n ** 6n),
  ]);
  console.log(`wallet ${signer.address}`);
  console.log(`  USDC ${ethers.formatUnits(usdcBal, 6)} · HYPE ${ethers.formatEther(hypeBal)} (gas) · shares ${shares} · maxWithdraw ${ethers.formatUnits(maxW, 6)} · price ${ethers.formatUnits(price, 6)}`);

  if (PHASE === "deposit") {
    if (usdcBal < AMOUNT) fail(`USDC balance ${ethers.formatUnits(usdcBal, 6)} < ${ethers.formatUnits(AMOUNT, 6)}`);
    if (hypeBal < 10n ** 15n) fail(`HYPE gas balance too low (${ethers.formatEther(hypeBal)})`);
    const allowance = await usdc.allowance(signer.address, vaultAddr);
    console.log(`  allowance ${ethers.formatUnits(allowance, 6)}`);
    if (!SEND) {
      console.log(`\nDRY — would: ${allowance < AMOUNT ? (allowance > 0n ? "approve(0) → approve(" : "approve(") + ethers.formatUnits(AMOUNT, 6) + ") → " : ""}vault.deposit(${ethers.formatUnits(AMOUNT, 6)})`);
      return;
    }
    if (allowance > 0n && allowance < AMOUNT) {
      const t0 = await usdc.approve(vaultAddr, 0, { gasLimit: 120000 });
      await t0.wait();
      console.log(`  approve(0) reset: ${t0.hash}`);
    }
    if (allowance < AMOUNT) {
      const t1 = await usdc.approve(vaultAddr, AMOUNT, { gasLimit: 120000 });
      await t1.wait();
      console.log(`  approve(${ethers.formatUnits(AMOUNT, 6)}): ${t1.hash}`);
    }
    const tx = await vault.deposit(AMOUNT, { gasLimit: 400000 });
    const rc = await tx.wait();
    console.log(`  deposit: ${tx.hash} (gasUsed ${rc.gasUsed}, status ${rc.status})`);
  } else {
    if (maxW < AMOUNT) fail(`maxWithdraw ${ethers.formatUnits(maxW, 6)} < ${ethers.formatUnits(AMOUNT, 6)}`);
    if (hypeBal < 10n ** 15n) fail(`HYPE gas balance too low (${ethers.formatEther(hypeBal)})`);
    if (!SEND) {
      console.log(`\nDRY — would: vault.withdraw(${ethers.formatUnits(AMOUNT, 6)})`);
      return;
    }
    const tx = await vault.withdraw(AMOUNT, { gasLimit: 400000 });
    const rc = await tx.wait();
    console.log(`  withdraw: ${tx.hash} (gasUsed ${rc.gasUsed}, status ${rc.status})`);
  }

  // Post-state
  const [usdcBal2, shares2, total2, vaultUsdc] = await Promise.all([
    usdc.balanceOf(signer.address),
    vault.shares(signer.address),
    vault.totalAssets(),
    usdc.balanceOf(vaultAddr),
  ]);
  console.log(`\nAFTER:`);
  console.log(`  wallet USDC ${ethers.formatUnits(usdcBal2, 6)} · shares ${shares2}`);
  console.log(`  vault totalAssets ${ethers.formatUnits(total2, 6)} · vault USDC balance ${ethers.formatUnits(vaultUsdc, 6)}`);
}

main().catch((e) => {
  console.error("team_e2e failed:", e.message || e);
  process.exit(4);
});
