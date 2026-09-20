const hre = require("hardhat");
async function main() {
  const [owner, user1] = await hre.ethers.getSigners();
  const E = hre.ethers;
  const usdc = await (await E.getContractFactory("MockUSDC")).deploy(); await usdc.waitForDeployment();
  const vault = await (await E.getContractFactory("ProYieldVault")).deploy(await usdc.getAddress(), owner.address, owner.address);
  await vault.waitForDeployment();
  const oracle = await (await E.getContractFactory("MockFundingOracle")).deploy(0); await oracle.waitForDeployment();
  const delta = await (await E.getContractFactory("DeltaNeutralStrategy")).deploy(await usdc.getAddress(), owner.address, owner.address, await oracle.getAddress());
  await delta.waitForDeployment();
  const pendle = await (await E.getContractFactory("PendleStrategy")).deploy(await usdc.getAddress(), owner.address, owner.address);
  await pendle.waitForDeployment();
  const sky = await (await E.getContractFactory("SkyStrategy")).deploy(await usdc.getAddress(), owner.address, owner.address);
  await sky.waitForDeployment();
  for (const s of [delta, pendle, sky]) {
    await (await vault.addStrategy(await s.getAddress())).wait();
    await (await s.setVault(await vault.getAddress())).wait();
  }
  // A4: empty harvest
  await (await delta.harvest()).wait();
  console.log("A4 ok");
  // A5: fund ETH
  await (await owner.sendTransaction({ to: await delta.getAddress(), value: E.parseEther("0.5") })).wait();
  console.log("A5 ok, eth:", E.formatEther(await E.provider.getBalance(await delta.getAddress())));
  // A5b-i: harvest (no position)
  await (await delta.harvest()).wait();
  console.log("A5b-i ok, eth after:", E.formatEther(await E.provider.getBalance(await delta.getAddress())));
  // A5b openPosition
  try {
    await (await delta.openPosition(E.parseUnits("10000", 18))).wait();
    console.log("openPosition ok, delta:", (await delta.delta()).toString());
    const sb = await E.provider.getBalance(owner.address);
    await (await delta.harvest()).wait();
    console.log("2nd harvest ok, forwarded:", E.formatEther((await E.provider.getBalance(owner.address)) - sb));
  } catch (e) {
    console.error("REVERT:", (e.reason || e.message || "").slice(0, 250));
  }
}
main().catch(e => { console.error(e); process.exit(1); });
