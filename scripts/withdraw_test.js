// T-012 verification: withdraw must work after allocate(), via buffer and recall.
// PRECONDITION: run scripts/deploy_v2.js immediately BEFORE this script (it leaves
// exactly the state assumed below: 100k deposited, ~90k allocated, price 1:1).
// Point both at the same manifest with DEPLOY_MANIFEST=<path> to avoid touching
// the canonical deployment. We then:
//   1. prove reserve enforcement (allocate must NOT deploy when idle < reserve)
//   2. partial + full user withdrawal paid 1:1
//   3. owner full withdrawal forces RECALL from the strategy
//   4. over-withdrawal reverts (old proportional share math was a drain vector)
const fs = require("fs");
const hre = require("hardhat");
async function main() {
  const j = JSON.parse(fs.readFileSync(process.env.DEPLOY_MANIFEST || "/home/user/hypervault/deployed_addresses.json", "utf8"));
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

  // 1) reserve enforcement: allocate() must deploy EXACTLY idle-above-reserve.
  // Expected values are derived at runtime — the vault may carry wei-scale yield
  // from the deploy run (anvil +1s tick), so round numbers are not safe to hardcode.
  const totalA = await vault.totalAssets();
  const idleBeforeAlloc = await bal(vault.target);
  const reserve = totalA / 10n; // RESERVE_BPS = 1000 → 10%
  const expectedDeploy = idleBeforeAlloc > reserve ? idleBeforeAlloc - reserve : 0n;
  const deltaBefore = await bal(delta.target);
  await (await vault.allocate()).wait();
  ok((await bal(delta.target)) === deltaBefore + expectedDeploy,
    `allocate() deploys exactly idle-above-reserve (${fmt(expectedDeploy)})`);
  ok((await bal(vault.target)) === reserve, "idle pinned at 10% reserve after allocate");

  // 2) partial withdrawal from idle — shares burned must match the quote EXACTLY
  const sh0 = await vault.shares(user.address);
  const burnQuote = await vault.convertToShares(P(20));
  await (await vault.connect(user).withdraw(P(20))).wait();
  ok((await vault.shares(user.address)) === sh0 - burnQuote,
    "partial withdraw burns exactly the quoted shares for 20 USDC");
  ok((await bal(user.address)) === P(20), "user paid 20 USDC");
  console.log("user withdrew 20; shares left:", fmt(await vault.shares(user.address)));

  // 3) full user withdrawal — redeem ALL remaining shares' worth (quote-based;
  // leaves <= 1 wei of shares as price-rounding dust, not a claim)
  const remain = await vault.maxWithdraw(user.address);
  await (await vault.connect(user).withdraw(remain)).wait();
  ok((await vault.shares(user.address)) <= 1n, "full withdraw leaves <= 1 wei of shares (dust)");
  ok((await bal(user.address)) >= P(50) - 1000n && (await bal(user.address)) <= P(50) + 1000n,
    "user recovered their 50 USDC (± wei price-rounding)");

  // 4) OWNER full withdrawal — redeem all owner shares → recall from delta required
  const idleNow = await bal(vault.target);
  const deltaNow = await bal(delta.target);
  console.log("pre-owner-withdraw: idle", fmt(idleNow), "delta bal", fmt(deltaNow));
  const ownerRedeem = await vault.maxWithdraw(owner.address);
  await (await vault.connect(owner).withdraw(ownerRedeem)).wait();
  ok((await vault.shares(owner.address)) <= 1n, "owner shares zeroed (dust <= 1 wei)");
  ok((await bal(delta.target)) < deltaNow && (await bal(delta.target)) < 10000000000000000n,
    "recall drained the strategy to yield-dust (< 0.01 USDC residual)");
  ok((await bal(owner.address)) > P(900000), "owner received withdrawal (balance jumped)");
  console.log("post-owner-withdraw: idle", fmt(await bal(vault.target)),
    "| delta bal", fmt(await bal(delta.target)),
    "| totalAssets", fmt(await vault.totalAssets()));

  // 5) drain-vector checks: no claim → no extraction; over-withdrawal reverts
  const stranger = new hre.ethers.Wallet(hre.ethers.Wallet.createRandom().privateKey, hre.ethers.provider);
  await owner.sendTransaction({ to: stranger.address, value: hre.ethers.parseEther("1") });
  let reverted = false;
  try { await vault.connect(stranger).withdraw(1); } catch (e) { reverted = true; }
  ok(reverted, "withdraw with zero shares reverts");
  // user re-deposits 1 (fresh allowance — the original 50 was fully consumed)
  await (await usdc.connect(user).approve(vault.target, P(1))).wait();
  await (await vault.connect(user).deposit(P(1))).wait();
  // owner also deposits 1 → pool holds 2 while user's claim is 1: withdrawing 2
  // must revert on the SHARES check (not merely on idle liquidity / allowance)
  await (await usdc.connect(owner).approve(vault.target, P(1))).wait();
  await (await vault.connect(owner).deposit(P(1))).wait();
  let reverted2 = false;
  try { await vault.connect(user).withdraw(P(2)); } catch (e) { reverted2 = true; }
  ok(reverted2, "withdraw exceeding own shares reverts (drain vector closed)");

  console.log(failures === 0 ? "\n=== T-012 VERIFICATION: ALL PASSED ===" : `\n=== ${failures} FAILURES ===`);
  if (failures > 0) process.exit(1);
}
main().catch((e) => { console.error(e); process.exit(1); });
