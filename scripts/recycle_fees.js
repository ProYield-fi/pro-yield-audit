
// Fee recycling executor: splits USDC sitting in the FeeDistributor per policy
// (depositor boost -> vault.creditYield, treasury, insurance) and records the
// result. Policy file: /home/user/yield_scout/data/recycle_policy.json
//
// Usage:  npx hardhat run scripts/recycle_fees.js --network hyperTestnet
//         (add --no-apply via env DRY_RUN=1 for a dry run)
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const POLICY_PATH = "/home/user/yield_scout/data/recycle_policy.json";
const LEDGER_PATH = "/home/user/yield_scout/data/recycling.jsonl";

async function main() {
  const { HardhatEthersSigner } = require("@nomicfoundation/hardhat-ethers/signers");
  const origSend = HardhatEthersSigner.prototype.sendTransaction;
  HardhatEthersSigner.prototype.sendTransaction = async function (tx) {
    if (tx.gasLimit == null) {
      try {
        const est = await hre.ethers.provider.estimateGas({ ...tx, from: this.address });
        tx = { ...tx, gasLimit: (est * 3n) + 21000n };
      } catch {
        tx = { ...tx, gasLimit: 1_000_000n };
      }
    }
    return origSend.call(this, tx);
  };

  const deployed = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
  const policy = JSON.parse(fs.readFileSync(POLICY_PATH, "utf8"));
  const [owner] = await hre.ethers.getSigners();

  const usdc = await hre.ethers.getContractAt("MockUSDC", deployed.mock_usdc);
  const fd = await hre.ethers.getContractAt("FeeDistributor", deployed.fee_distributor);
  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);

  const dryRun = process.env.DRY_RUN === "1";

  // 1) reconcile FD accounting, then read the recyclable balance
  if (!dryRun) {
    await (await fd.receiveFees()).wait();
  }
  const bal = await usdc.balanceOf(await fd.getAddress());
  const minAmt = hre.ethers.parseUnits(String(policy.min_amount_usdc ?? 10), 18);
  console.log("FD balance:", hre.ethers.formatUnits(bal, 18), "USDC | min:", hre.ethers.formatUnits(minAmt, 18));
  if (bal < minAmt) {
    console.log("below policy minimum — nothing to recycle");
    return;
  }

  // 2) split per policy
  const boostPct = BigInt(policy.depositor_boost_pct ?? 60);
  const treasuryPct = BigInt(policy.treasury_pct ?? 20);
  const insurancePct = BigInt(policy.insurance_pct ?? 20);
  const total = boostPct + treasuryPct + insurancePct;
  if (total !== 100n) throw new Error(`policy pcts sum to ${total}, must be 100`);

  const boost = (bal * boostPct) / 100n;
  const treasury = (bal * treasuryPct) / 100n;
  const insurance = bal - boost - treasury; // remainder keeps integer exactness

  const treasuryAddr = policy.treasury || owner.address;
  const insuranceAddr = policy.insurance || owner.address;
  console.log(`split: boost=${hre.ethers.formatUnits(boost, 18)} -> depositors | treasury=${hre.ethers.formatUnits(treasury, 18)} -> ${treasuryAddr} | insurance=${hre.ethers.formatUnits(insurance, 18)} -> ${insuranceAddr}`);

  if (dryRun) {
    console.log("DRY RUN — no transactions sent");
    return;
  }

  // 3) execute: route all three parts; credit the boost to depositors
  const ts = Math.floor(Date.now() / 1000);
  if (boost > 0n) {
    await (await fd.route(await vault.getAddress(), boost)).wait();
    const taPre = await vault.totalAssets();
    const rc = await (await vault.creditYield(boost)).wait();
    const taPost = await vault.totalAssets();
    if (taPost - taPre !== boost) throw new Error("credit did not raise totalAssets exactly");
    console.log("credited boost to depositors:", hre.ethers.formatUnits(boost, 18), "USDC");
  }
  if (treasury > 0n) await (await fd.route(treasuryAddr, treasury)).wait();
  if (insurance > 0n) await (await fd.route(insuranceAddr, insurance)).wait();

  const remainder = await usdc.balanceOf(await fd.getAddress());
  console.log("FD remainder after recycle:", hre.ethers.formatUnits(remainder, 18), "USDC (rounding dust only)");

  // 4) ledger
  const entry = {
    ts, iso: new Date(ts * 1000).toISOString(),
    source: process.env.RECYCLE_SOURCE || "fees",
    total: hre.ethers.formatUnits(bal, 18),
    boost: hre.ethers.formatUnits(boost, 18),
    treasury: hre.ethers.formatUnits(treasury, 18),
    insurance: hre.ethers.formatUnits(insurance, 18),
    remainder: hre.ethers.formatUnits(remainder, 18),
  };
  fs.appendFileSync(LEDGER_PATH, JSON.stringify(entry) + "\n");
  console.log("ledger appended ->", LEDGER_PATH);
  console.log("RECYCLE DONE:", JSON.stringify(entry));
}
main().catch(e => { console.error(e); process.exit(1); });
