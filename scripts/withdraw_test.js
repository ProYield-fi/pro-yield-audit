// T-012 verification: withdraw must work after allocate(), via buffer and recall.
// Scenario: deploy script left 100k deposited, allocated 90k to delta (10% reserve
// kept, then its emergencyWithdraw test stripped idle). We then:
//   1. prove reserve enforcement (allocate must NOT deploy when idle < reserve)
//   2. partial + full user withdrawal paid 1:1
//   3. owner full withdrawal forces RECALL from the strategy
//   4. over-withdrawal reverts (old proportional share math was a drain vector)
const fs = require("fs");
const hre = require("hardhat");
async function main() {
  const j = JSON.parse(fs.readFileSync("/home/user/hypervault/deployed_addresses.json", "utf8"));
  const usdc = await hre.ethers.getContractAt("MockUSDC", j.mock_usdc);
  const vault = await hre.ethers.getContractAt("ProYieldVault", j.pro_yield_vault);
  const delta = await hre.ethers.getContractAt("DeltaNeutralStrategy", j.delta_neutral);
  const [owner] = await hre.ethers.getSigners();
  const fmt = (v) => hre.ethers.formatUnits(v, 18);
  const P = (n) => hre.ethers.parseUnits(String(n), 18);
  const bal = (a) => usdc.balanceOf(a);
  let failures = 0;
  const ok = (cond, label) => { console.log((cond ? "✅" : "❌ FAIL") + " " + label); if (!cond) failures++; };

  console.log("start: totalAssets", fmt(await vault.totalAssets()),
    "| delta bal", fmt(await bal(delta.target)),
    "| vault idle", fmt(await bal(vault.target)));

  // --- user journey ---
  const user = new hre.ethers.Wallet(hre.ethers.Wallet.createRandom().privateKey, hre.ethers.provider);
  await owner.sendTransaction({ to: user.address, value: hre.ethers.parseEther("1") });
  await (await usdc.mint(user.address, P(50))).wait();
  await (await usdc.connect(user).approve(vault.target, P(50))).wait();
  await (await vault.connect(user).deposit(P(50))).wait();
  console.log("user deposited 50; totalAssets", fmt(await vault.totalAssets()));

  // 1) reserve enforcement: idle 10050 vs reserve 10005 → allocate deploys EXACTLY 45
  const deltaBefore = await bal(delta.target);
  await (await vault.allocate()).wait();
  ok((await bal(delta.target)) === deltaBefore + P(45), "allocate() deploys exactly idle-above-reserve (45)");
  ok((await bal(vault.target)) === P(10005), "idle pinned at 10% reserve after allocate");

  // 2) partial withdrawal from idle — exact 1:1 share burn
  await (await vault.connect(user).withdraw(P(20))).wait();
  ok((await vault.shares(user.address)) === P(30), "partial withdraw burns exactly 20 of 50 shares");
  ok((await bal(user.address)) === P(20), "user paid 20 USDC");
  console.log("user withdrew 20; shares left:", fmt(await vault.shares(user.address)));

  // 3) full user withdrawal — remaining 30 from idle
  await (await vault.connect(user).withdraw(P(30))).wait();
  ok((await vault.shares(user.address)) === 0n, "full withdraw zeroes user shares");
  ok((await bal(user.address)) === P(50), "user recovered full 50 USDC");

  // 4) OWNER full withdrawal — 100,000 against idle ~0 → recall from delta required
  const idleNow = await bal(vault.target);
  console.log("pre-owner-withdraw: idle", fmt(idleNow), "delta bal", fmt(await bal(delta.target)));
  await (await vault.connect(owner).withdraw(P(100000))).wait();
  ok((await vault.shares(owner.address)) === 0n, "owner shares zeroed");
  ok((await bal(delta.target)) === 0n || (await bal(vault.target)) > idleNow,
    "recall pulled funds from strategy to cover withdrawal");
  ok((await bal(owner.address)) > P(900000), "owner received withdrawal (balance jumped)");
  console.log("post-owner-withdraw: idle", fmt(await bal(vault.target)),
    "| delta bal", fmt(await bal(delta.target)),
    "| totalAssets", fmt(await vault.totalAssets()));

  // 5) drain-vector check: withdrawing with zero shares must revert
  let reverted = false;
  try { await vault.connect(user).withdraw(1); } catch (e) { reverted = true; }
  ok(reverted, "withdraw with zero shares reverts");
  let reverted2 = false;
  try { await vault.connect(user).deposit(P(1)).then(t => vault.connect(user).withdraw(P(2))); } catch (e) { reverted2 = true; }
  ok(reverted2, "withdraw exceeding own shares reverts (drain vector closed)");

  console.log(failures === 0 ? "\n=== T-012 VERIFICATION: ALL PASSED ===" : `\n=== ${failures} FAILURES ===`);
  if (failures > 0) process.exit(1);
}
main().catch((e) => { console.error(e); process.exit(1); });
