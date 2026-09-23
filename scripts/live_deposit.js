// scripts/live_deposit.js — a REAL deposit into the ops vault on the declared
// chain: approve the vault's own asset, deposit, verify wallet/TVL/share deltas.
// No mints, no mocks — the live product path, exercised on the testnet by the
// ops wallet. (customer_deposit.js stays a sandbox tool: it mints test USDC.)
//
// Run: AMOUNT_USDC=100 HYPEREVM_RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm \
//      npx hardhat run scripts/live_deposit.js --network hyperTestnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const deployed = JSON.parse(fs.readFileSync(process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
  const amount = BigInt(Math.round(Number(process.env.AMOUNT_USDC || 100) * 1e6));
  const [signer] = await hre.ethers.getSigners();
  const net = await hre.ethers.provider.getNetwork();
  const declared = deployed.chain || null;
  if (declared?.id && Number(declared.id) !== Number(net.chainId)) {
    console.error(`REFUSING: manifest declares chain ${declared.id} but the RPC answers ${net.chainId}.`);
    process.exit(3);
  }

  const usdcAddr = deployed.vault_asset || deployed.mock_usdc;
  const vaultAddr = deployed.pro_yield_vault;
  const usdc = new hre.ethers.Contract(usdcAddr, [
    "function balanceOf(address) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function approve(address,uint256) returns (bool)",
    "function allowance(address,address) view returns (uint256)",
  ], signer);
  const vault = new hre.ethers.Contract(vaultAddr, [
    "function totalAssets() view returns (uint256)",
    "function deposit(uint256,address) returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
  ], signer);

  const dec = Number(await usdc.decimals());
  const F = (x) => `${hre.ethers.formatUnits(x, dec)} USDC`;
  const wallet = hre.ethers.getAddress(signer.address);
  const before = { wallet: await usdc.balanceOf(wallet), tvl: await vault.totalAssets(), shares: await vault.balanceOf(wallet) };
  console.log(`chain ${net.chainId} · vault ${vaultAddr}`);
  console.log(`before: wallet ${F(before.wallet)} | TVL ${F(before.tvl)} | my shares ${F(before.shares)}`);

  const allowance = await usdc.allowance(wallet, vaultAddr);
  if (allowance < amount) {
    console.log("approving", F(amount), "->", vaultAddr);
    const at = await usdc.approve(vaultAddr, amount);
    await at.wait();
    console.log("  approve tx:", at.hash);
  }
  const dt = await vault.deposit(amount, wallet);
  const rc = await dt.wait();
  console.log("deposit tx:", rc.hash, "| gas:", rc.gasUsed.toString());

  const after = { wallet: await usdc.balanceOf(wallet), tvl: await vault.totalAssets(), shares: await vault.balanceOf(wallet) };
  console.log(`after:  wallet ${F(after.wallet)} | TVL ${F(after.tvl)} | my shares ${F(after.shares)}`);
  const ok = before.wallet - after.wallet === amount && after.tvl - before.tvl === amount && after.shares > before.shares;
  console.log(ok ? "LIVE DEPOSIT ✓ (wallet -amount · TVL +amount · shares minted)" : "LIVE DEPOSIT ✗ — deltas do not match, investigate before trusting");
  process.exit(ok ? 0 : 4);
}
main().catch((e) => { console.error("live_deposit error:", (e && e.message) || e); process.exit(2); });