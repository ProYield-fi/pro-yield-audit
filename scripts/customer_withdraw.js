
// Customer journey phase 2: the customer withdraws everything and we assert
// the payout exceeded their deposit (real funding yield earned via the keeper).
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const deployed = JSON.parse(fs.readFileSync(process.env.DEPLOY_MANIFEST || process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
  const customer = (await hre.ethers.getSigners())[3];
  // OOG-flake killer (prototype-level): pad every signer's gas 3x — getSigners()
  // returns fresh instances per call, so per-instance patches miss factory calls.
  {
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
  }


  const usdc = await hre.ethers.getContractAt("MockUSDC", deployed.mock_usdc);
  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);

  const balBefore = await usdc.balanceOf(customer.address);
  const maxW = await vault.maxWithdraw(customer.address);
  const tx = await vault.connect(customer).withdraw(maxW);
  await tx.wait();
  const balAfter = await usdc.balanceOf(customer.address);
  const payout = balAfter - balBefore;

  const DEPOSIT = hre.ethers.parseUnits("5000", 18);
  const profit = payout - DEPOSIT;
  console.log(`CUSTOMER WITHDRAW: payout=${hre.ethers.formatUnits(payout, 18)} USDC (deposited 5000.0)`);
  console.log(`PROFIT: ${hre.ethers.formatUnits(profit, 18)} USDC`);
  if (profit > 0n) {
    console.log("JOURNEY PASS: customer earned real yield (payout > deposit)");
  } else {
    console.log("JOURNEY FAIL: payout <= deposit");
    process.exit(1);
  }
}
main().catch(e => { console.error(e); process.exit(1); });
