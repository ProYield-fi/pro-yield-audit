// scripts/live_withdraw.js — the exit half of the live product path: withdraw
// assets from the ops vault on the declared chain and verify shares burned /
// TVL decreased / wallet received exactly the requested amount.
//
// Run: AMOUNT_USDC=30 HYPEREVM_RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm \
//      npx hardhat run scripts/live_withdraw.js --network hyperTestnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const deployed = JSON.parse(fs.readFileSync(process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
  const amount = BigInt(Math.round(Number(process.env.AMOUNT_USDC || 30) * 1e6));
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
  ], signer);
  const vault = new hre.ethers.Contract(vaultAddr, [
    "function totalAssets() view returns (uint256)",
    "function withdraw(uint256,address,address) returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function withdrawFeeBps() view returns (uint256)",
  ], signer);

  // This vault generation is NOT the repo vault: `withdraw(a, r, o)` burns `a`
  // as SHARES (redeem-like — measured: exactly a raw units leave totalSupply)
  // and pays assets net of `withdrawFeeBps()` (50 = 0.5%), fee routed to a fee
  // collector contract. Assert against that reality, don't assume ERC-4626.
  let feeBps = 0n;
  try { feeBps = await vault.withdrawFeeBps(); } catch { /* fee-free generation */ }
  const priceE18 = (t) => (t.shares > 0n ? (t.tvl * 10n ** 18n) / t.shares : 10n ** 18n);

  const dec = Number(await usdc.decimals());
  const F = (x) => `${hre.ethers.formatUnits(x, dec)} USDC`;
  const wallet = hre.ethers.getAddress(signer.address);
  const before = { wallet: await usdc.balanceOf(wallet), tvl: await vault.totalAssets(), shares: await vault.balanceOf(wallet) };
  console.log(`chain ${net.chainId} · vault ${vaultAddr} · withdrawFeeBps ${feeBps}`);
  console.log(`before: wallet ${F(before.wallet)} | TVL ${F(before.tvl)} | my shares ${F(before.shares)}`);

  const wt = await vault.withdraw(amount, wallet, wallet);
  const rc = await wt.wait();
  console.log("withdraw tx:", rc.hash, "| gas:", rc.gasUsed.toString());

  const after = { wallet: await usdc.balanceOf(wallet), tvl: await vault.totalAssets(), shares: await vault.balanceOf(wallet) };
  console.log(`after:  wallet ${F(after.wallet)} | TVL ${F(after.tvl)} | my shares ${F(after.shares)}`);

  const burned = before.shares - after.shares;
  const gross = (priceE18(before) * burned) / 10n ** 18n; // shares × pre-price
  const fee = (gross * feeBps) / 10000n;
  const netOut = gross - fee;
  const got = after.wallet - before.wallet;
  const tvlDrop = before.tvl - after.tvl;
  const within1 = (a, b) => (a > b ? a - b : b - a) <= 1n;
  const ok = burned === amount && within1(got, netOut) && within1(tvlDrop, gross);
  console.log(`shares burned ${F(burned)} → gross ${F(gross)} · fee ${F(fee)} (${feeBps} bps) · net expected ${F(netOut)} · received ${F(got)}`);
  console.log(ok ? "LIVE WITHDRAW ✓ (burn==requested · received==gross-fee · TVL -gross)" : "LIVE WITHDRAW ✗ — deltas do not match, investigate before trusting");
  process.exit(ok ? 0 : 4);
}
main().catch((e) => { console.error("live_withdraw error:", (e && e.message) || e); process.exit(2); });