const hre = require("hardhat");
async function main() {
  const [owner] = await hre.ethers.getSigners();
  const E = hre.ethers;
  const usdc = await (await E.getContractFactory("MockUSDC")).deploy(); await usdc.waitForDeployment();
  const oracle = await (await E.getContractFactory("MockFundingOracle")).deploy(0); await oracle.waitForDeployment();
  const delta = await (await E.getContractFactory("DeltaNeutralStrategy")).deploy(await usdc.getAddress(), owner.address, owner.address, await oracle.getAddress());
  await delta.waitForDeployment();
  // send ETH then harvest (like A5b-i)
  await (await owner.sendTransaction({ to: await delta.getAddress(), value: E.parseEther("0.5") })).wait();
  const h = await delta.harvest(); await h.wait();
  console.log("harvest ok, eth forwarded. balance:", E.formatEther(await E.provider.getBalance(await delta.getAddress())));
  try {
    const o = await delta.openPosition(E.parseUnits("10000", 18));
    await o.wait();
    console.log("openPosition ok, delta =", (await delta.delta()).toString());
  } catch (e) {
    console.error("openPosition REVERT:", (e.reason || e.message || "").slice(0, 200));
    // try staticCall to get the revert reason
    try { await delta.openPosition.staticCall(E.parseUnits("10000", 18)); } catch (e2) { console.error("staticCall reason:", (e2.reason || e2.message || "").slice(0, 200)); }
  }
}
main().catch(e => { console.error(e); process.exit(1); });
