
// Internal ops helper for rebate_recycler.py — selected via RECYCLER_OPS env.
//   "status"            -> print FD/vault/ops balances + share price
//   "transfer <amt>"    -> move <amt> USDC from ops wallet into the FeeDistributor
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const { HardhatEthersSigner } = require("@nomicfoundation/hardhat-ethers/signers");
  const origSend = HardhatEthersSigner.prototype.sendTransaction;
  HardhatEthersSigner.prototype.sendTransaction = async function (tx) {
    if (tx.gasLimit == null) {
      try {
        const est = await hre.ethers.provider.estimateGas({ ...tx, from: this.address });
        tx = { ...tx, gasLimit: est + 21000n };
      } catch {
        tx = { ...tx, gasLimit: 1_000_000n };
      }
    }
    return origSend.call(this, tx);
  };

  const deployed = JSON.parse(fs.readFileSync(process.env.DEPLOY_MANIFEST || process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
  const [owner] = await hre.ethers.getSigners();
  const usdc = await hre.ethers.getContractAt("MockUSDC", deployed.mock_usdc);
  const fd = await hre.ethers.getContractAt("FeeDistributor", deployed.fee_distributor);
  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);

  const ops = process.env.RECYCLER_OPS || "status";

  if (ops === "status") {
    console.log("ops wallet:", owner.address);
    console.log("ops USDC:", hre.ethers.formatUnits(await usdc.balanceOf(owner.address), 18));
    console.log("FD USDC:", hre.ethers.formatUnits(await usdc.balanceOf(await fd.getAddress()), 18));
    const ta = await vault.totalAssets();
    const ts = await vault.totalShares();
    console.log("vault share price:", hre.ethers.formatUnits((ta * 10n ** 18n) / ts, 18));
    return;
  }

  const m = ops.match(/^transfer\s+([\d.]+)$/);
  if (m) {
    const amt = hre.ethers.parseUnits(m[1], 18);
    const bal = await usdc.balanceOf(owner.address);
    if (bal < amt) {
      console.error(`ops wallet has ${hre.ethers.formatUnits(bal, 18)} USDC, need ${m[1]} — top up first (testnet: mint)`);
      process.exit(1);
    }
    await (await usdc.transfer(await fd.getAddress(), amt)).wait();
    console.log(`moved ${m[1]} USDC ops -> FeeDistributor`);
    return;
  }
  console.error("unknown RECYCLER_OPS:", ops);
  process.exit(1);
}
main().catch(e => { console.error(e); process.exit(1); });
