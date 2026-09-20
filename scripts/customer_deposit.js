
// Customer journey phase 1: a fresh wallet deposits into the LIVE vault.
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const deployed = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
  const customer = (await hre.ethers.getSigners())[3]; // separate wallet = "customer"
  for (const s of await hre.ethers.getSigners()) {
    const origSend = s.sendTransaction.bind(s);
    s.sendTransaction = async (tx) => {
      if (tx.gasLimit == null) {
        try {
          const est = await hre.ethers.provider.estimateGas({ ...tx, from: s.address });
          tx = { ...tx, gasLimit: (est * 3n) + 21000n };
        } catch {}
      }
      return origSend(tx);
    };
  }

  const usdc = await hre.ethers.getContractAt("MockUSDC", deployed.mock_usdc);
  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);

  const AMOUNT = hre.ethers.parseUnits("5000", 18);
  await (await usdc.mint(customer.address, AMOUNT)).wait();
  await (await usdc.connect(customer).approve(await vault.getAddress(), AMOUNT)).wait();
  const tx = await vault.connect(customer).deposit(AMOUNT);
  await tx.wait();

  const shares = await vault.shares(customer.address);
  const price = await vault.convertToAssets(hre.ethers.parseUnits("1", 18));
  console.log(`CUSTOMER DEPOSIT: ${hre.ethers.formatUnits(AMOUNT, 18)} USDC -> ${hre.ethers.formatUnits(shares, 18)} shares @ price ${hre.ethers.formatUnits(price, 18)}`);
  console.log(`customer: ${customer.address}`);
}
main().catch(e => { console.error(e); process.exit(1); });
