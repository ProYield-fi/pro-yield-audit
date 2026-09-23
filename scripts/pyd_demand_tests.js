// PYDFeeDiscount + PYDFunder tests — the PYD demand layer, on mocked anvil.
// Run: npx hardhat run scripts/pyd_demand_tests.js --network hyperTestnet
//
// PYDFeeDiscount covers: stake → tier → snapshot accrual from REAL fee deltas
// → claim (budget-bounded) → unstake/exit. PYDFunder covers: USDC in →
// convert via mock swapper → fund a REAL PYDStaking stream → staker claims.
const hre = require("hardhat");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}

const CUSTOM_ERRORS = {
  // keccak256("ErrorName()")[:4] — verified against live revert data
  ZeroAmount: "0x5c35484f", ExceedsStake: "0x37beefad", BadTier: "0x510b38a9",
  NothingAccrued: "0x156e9c2a", InsufficientBudget: "0x67b7a953",
  FunderZeroAmount: "0xb1768a99", BelowDust: "0xad829d3d", Cap: "0xeed0970e",
  Paused: "0xc3d88e80", ZeroSwapper: "0x5b6e44d5", NoOutput: "0x0901431d",
};
async function expectRevert(promise, expect, name) {
  // `expect` = custom-error NAME ("Cap") — staticCall reverts surface the raw selector.
  try {
    const tx = await promise;
    if (tx && tx.wait) await tx.wait();
    report(name, false, "did not revert");
  } catch (e) {
    const raw = (e.shortMessage || "") + " " + (e.message || "");
    const data = e.data || (e.info && e.info.error && e.info.error.data) || "";
    const selector = typeof data === "string" ? data.slice(0, 10) : "";
    const wanted = CUSTOM_ERRORS[expect] || "no-selector";
    const match = selector === wanted || raw.includes(expect);
    report(name, match, match ? "" : `wrong reason: ${raw.slice(0, 120)} (selector=${selector})`);
  }
}

async function main() {
  const E = hre.ethers;
  const [owner, staker1, staker2, user1, dummy] = await E.getSigners();
  const U = (n) => E.parseUnits(String(n), 18);

  console.log("── deployment ──");
  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  const pyd = await (await E.getContractFactory("PYDToken")).deploy(100_000_000n);
  await pyd.waitForDeployment();
  const fd = await (await E.getContractFactory("FeeDistributor")).deploy(await usdc.getAddress());
  await fd.waitForDeployment();
  const vault = await (await E.getContractFactory("ProYieldVault")).deploy(
    await usdc.getAddress(), owner.address, await fd.getAddress()
  );
  await vault.waitForDeployment();
  const staking = await (await E.getContractFactory("PYDStaking")).deploy(await pyd.getAddress());
  await staking.waitForDeployment();
  const discount = await (await E.getContractFactory("PYDFeeDiscount")).deploy(
    await pyd.getAddress(), await usdc.getAddress(), await fd.getAddress(), await vault.getAddress(), owner.address
  );
  await discount.waitForDeployment();
  const funder = await (await E.getContractFactory("PYDFunder")).deploy(
    await usdc.getAddress(), await staking.getAddress(), owner.address
  );
  await funder.waitForDeployment();
  const d = discount.connect(owner);
  const pydAddr = await pyd.getAddress();
  const fdAddr = await fd.getAddress();

  // public uint256[][] generates a TWO-key getter: tiers(i, j) → scalar.
  report("default tiers: 1K/10K/100K/1M PYD → 5/10/15/20%",
    (await discount.tiers(0, 0)) === U(1000) && (await discount.tiers(3, 1)) === 2000n,
    `tier0 threshold=${E.formatUnits(await discount.tiers(0, 0), 0)}, tier3 bps=${await discount.tiers(3, 1)}`);

  // ── PYDFunder: convert USDC → PYD → REAL stream ──
  console.log("\n── PYDFunder (conversion + stream) ──");
  // Mock swapper: exchange any USDC for PYD 1:1 (test stand-in, documented)
  const swapper = await (await E.getContractFactory("MockSwapper")).deploy(pydAddr, await usdc.getAddress());
  await swapper.waitForDeployment();
  console.log("  [t1] swapper deployed");
  // Seed the swapper with PYD (PYDToken has no public mint — constructor
  // mints the full supply to the deployer; the swapper needs inventory).
  await (await pyd.connect(owner).transfer(await swapper.getAddress(), U(50_000_000))).wait();
  console.log("  [t2] swapper seeded");
  await (await funder.setSwapper(await swapper.getAddress())).wait();
  // Cap in USDC 6dp (production semantics): 25,000 USDC per call.
  await (await funder.setMaxConvertUsd6(25_000n * 10n ** 6n)).wait();
  console.log("  [t3] setSwapper done");

  // 2-step ownership handoff: staking owner → funder, then funder accepts.
  // Without this, staking.fundRewards (onlyOwner) reverts for the funder
  // (OwnableUnauthorizedAccount 0x118cdaa7 — found by this test).
  await (await staking.connect(owner).transferOwnership(await funder.getAddress())).wait();
  console.log("  [t4] transferOwnership done (OZ v5 = one-step, final)");
  report("funder owns PYDStaking", (await staking.owner()) === await funder.getAddress());

  // Route fees into the funder (simulating the FD recycle)
  await (await usdc.mint(owner.address, U(50_000))).wait();
  await (await usdc.connect(owner).transfer(await funder.getAddress(), U(50_000))).wait();
  report("funder holds routed USDC", (await funder.pendingUsdc()) === U(50_000));

  // topUp: convert 25,000 USDC (6dp units) → 25,000 PYD → stream over 86400s
  await (await funder.topUp(25_000n * 10n ** 6n, 86_400n)).wait();
  report("converted 25K USDC(6dp) → 25K PYD(18dec) — decimals handled",
    (await pyd.balanceOf(await staking.getAddress())) === U(25_000),
    `staking PYD=${E.formatUnits(await pyd.balanceOf(await staking.getAddress()), 18)}`);
  report("funder USDC drained by exactly the converted amount",
    (await funder.pendingUsdc()) === U(50_000) - 25_000n * 10n ** 6n,
    `pending=${E.formatUnits(await funder.pendingUsdc(), 18)}`);

  // Staker stakes PYD and claims from the REAL stream (25K PYD over 86400s).
  // Deterministic: stake lands (T5−Tf) seconds after stream start; measure
  // timestamps (same off-by-one discipline as integration R5/R6).
  console.log("  [s0] pre-window state:", JSON.stringify({
    staker1Pyd: (await pyd.balanceOf(staker1.address)).toString(),
    allowance: (await pyd.allowance(staker1.address, await staking.getAddress())).toString(),
    totalSupply: (await staking.totalSupply()).toString(),
    lastUpdateTime: (await staking.lastUpdateTime()).toString(),
    periodFinish: (await staking.periodFinish()).toString(),
    blockTime: Number((await E.provider.getBlock("latest")).timestamp),
  }));
  await (await pyd.connect(owner).transfer(staker1.address, U(5_000))).wait();
  console.log("  [s1] transfer ok");
  await (await pyd.connect(staker1).approve(await staking.getAddress(), U(5_000))).wait();
  console.log("  [s2] approve ok");
  const pf = await staking.periodFinish(); // stream end (started at pf−86400)
  const txStake = await staking.connect(staker1).stake(U(5_000));
  console.log("  [s3] stake sent");
  await txStake.wait();
  console.log("  [s4] stake mined");
  const stakedAt = await staking.lastUpdateTime();
  const missed = stakedAt - (pf - 86_400n); // seconds of stream before the stake
  await E.provider.send("evm_setNextBlockTimestamp", [Number(stakedAt) + 43_200]);
  console.log("  [s5] warped to", stakedAt + 43_200n, "(stakedAt", stakedAt.toString() + ")");
  const stBefore = await pyd.balanceOf(staker1.address); // AFTER stake → rewards-only delta
  console.log("  [s6] pre-claim state:", JSON.stringify({
    stakingPyd: (await pyd.balanceOf(await staking.getAddress())).toString(),
    earned: (await staking.earned(staker1.address)).toString(),
    blockTime: Number((await E.provider.getBlock("latest")).timestamp),
  }));
  await (await staking.connect(staker1).getReward()).wait();
  console.log("  [s7] getReward ok");
  const got = (await pyd.balanceOf(staker1.address)) - stBefore;
  const perSec = U(25_000) / 86_400n;
  // Timeline: fund at T0 (periodFinish = T0+86400); stake at T0+k (anvil
  // automine ticks +1s). The stake block STARTS accrual — the k seconds before
  // it are not lost (nobody staked). Claim at stakedAt+43200 → exactly 43200
  // in-stream seconds regardless of k. (missed is displayed for provenance.)
  const expected = BigInt(43_200) * perSec;
  // rPT chains floor divisions — wei-level gap vs linear is expected; exact
  // per-second claims are proven by integration R5/R6. Sane bounds here.
  const gap = expected > got ? expected - got : got - expected;
  report("REAL stream pays staker (full 43200s window, within rPT rounding)",
    got > 0n && gap <= 1_000_000_000_000n,
    `got ${E.formatUnits(got, 18)} PYD (linear ${E.formatUnits(expected, 18)}, gap ${gap}, stake ${missed}s after start)`);

  // ── PYDFeeDiscount: tier + accrual + claim ──
  console.log("\n── PYDFeeDiscount (tier + accrual + claim) ──");
  // staker1 has 5,000 PYD staked in PYDStaking, but the discount contract
  // tracks ITS OWN stake ledger — stake via the discount contract:
  await (await pyd.connect(owner).transfer(staker1.address, U(2_000))).wait();
  await (await pyd.connect(staker1).approve(await discount.getAddress(), U(2_000))).wait();
  await (await d.connect(staker1).stake(U(2_000))).wait();
  report("staked 2K → tier 5%", (await discount.tierBpsOf(staker1.address)) === 500n);

  // Vault needs shares for accrual: user1 deposits 1M USDC into the vault
  await (await usdc.mint(user1.address, U(1_000_000))).wait();
  await (await usdc.connect(user1).approve(await vault.getAddress(), U(1_000_000))).wait();
  await (await vault.connect(user1).deposit(U(1_000_000))).wait();
  // staker1's vault shares: zero (they never deposited) — accrual must skip them.
  // Give staker1 vault shares via a deposit too (mint USDC first):
  await (await usdc.mint(staker1.address, U(10_000))).wait();
  await (await usdc.connect(staker1).approve(await vault.getAddress(), U(10_000))).wait();
  await (await vault.connect(staker1).deposit(U(10_000))).wait();
  report("staker has vault shares", (await vault.shares(staker1.address)) > 0n);

  // Simulate a harvest: fees land in FD, then vault.harvest takes its cut.
  await (await usdc.mint(await fd.getAddress(), U(1_000))).wait();
  await (await fd.receiveFees()).wait();
  await (await vault.connect(owner).harvest()).wait();

  // Snapshot accrual (permissionless): reads FD balance delta + shares itself
  await (await discount.snapshotHarvest()).wait();
  const rebate = await discount.harvestableRebate(staker1.address);
  report("rebate accrued from real fee delta", rebate > 0n, `rebate=${E.formatUnits(rebate, 18)} USDC`);

  // Claim: budget must exist — route the discount budget into the contract
  await (await usdc.mint(await discount.getAddress(), U(500))).wait();
  const before = await usdc.balanceOf(staker1.address);
  await (await d.connect(staker1).claimRebate()).wait();
  const claimed = (await usdc.balanceOf(staker1.address)) - before;
  report("rebate claimed in USDC", claimed > 0n, `claimed ${E.formatUnits(claimed, 18)}`);

  // Zero-share staker accrues nothing
  await (await pyd.connect(owner).transfer(staker2.address, U(50_000))).wait();
  await (await pyd.connect(staker2).approve(await discount.getAddress(), U(50_000))).wait();
  await (await d.connect(staker2).stake(U(50_000))).wait();
  report("staker2 tier 10% (50K crosses 10K tier)", (await discount.tierBpsOf(staker2.address)) === 1000n);
  await (await usdc.mint(await fd.getAddress(), U(500))).wait();
  await (await fd.receiveFees()).wait();
  await (await vault.connect(owner).harvest()).wait();
  await (await discount.snapshotHarvest()).wait();
  report("zero-share staker accrues NOTHING", (await discount.harvestableRebate(staker2.address)) === 0n);

  // Second snapshot with no new fees = clean no-op
  const snap0 = await discount.lastFeeSnapshot();
  await (await discount.snapshotHarvest()).wait();
  report("no-new-fees snapshot is a no-op", (await discount.lastFeeSnapshot()) === snap0);

  // ── Gates ──
  console.log("\n── gates ──");
  await expectRevert(d.connect(staker1).stake(0), "ZeroAmount", "stake(0) reverts");
  await expectRevert(d.connect(staker1).unstake(U(99_000)), "ExceedsStake", "unstake > staked reverts");
  await expectRevert(d.connect(dummy).claimRebate(), "NothingAccrued", "claim with nothing accrued reverts");
  await expectRevert(funder.connect(user1).topUp(5n * 10n ** 6n, 86_400n), "BelowDust", "topUp below dust reverts");
  // Cap CLAMPS (min(amount, maxConvert, balance)) — converts the cap, never reverts.
  // Cap in USDC-6dp raw (production semantics): 25,000 USDC = 2.5e10 raw.
  // The 18-dec mock makes raw literals tiny — assert in RAW units (the cap
  // clamp is what matters, not the display).
  const cap = await funder.maxConvertUsd6();
  const balBefore = await funder.pendingUsdc();
  await (await usdc.mint(await funder.getAddress(), 200_000n * 10n ** 6n)).wait(); // 2e14 raw > cap
  await (await funder.topUp(400_000n * 10n ** 6n, 86_400n)).wait(); // > cap → clamps
  const balAfter = await funder.pendingUsdc();
  report("topUp above cap CLAMPS: converted exactly the cap, rest stays",
    balBefore + 200_000n * 10n ** 6n - balAfter === cap,
    `drained ${balBefore + 200_000n * 10n ** 6n - balAfter} raw (cap ${cap})`);
  // setTiers: non-ascending reverts
  const badTiers = [[U(10_000), 500], [U(1_000), 1000]];
  await expectRevert(d.setTiers(badTiers), "BadTier", "setTiers non-ascending reverts");

  /* ═══════ K: mutation-survivor regression ═══════
   * Targeted kills for the slither-mutate survivors (campaign 2026-09-23):
   * RR bodies in setTiers/unstake/exit/claim/loop-continues, AOR on the
   * snapshot/rebate math, ASOR on the accumulators. WHY these exist: a test
   * that ASSERTS a revert cannot kill a `body ==> revert()` mutant (the
   * mutant still reverts — same observable). Only SUCCESS-path execution
   * with exact-value assertions kills them, plus exact-formula checks for
   * the math mutants. Keep this section in lockstep with the campaign.
   */
  console.log("\n── K: mutation-survivor regression ──");
  const discountAddr = await discount.getAddress();

  const givePyd = async (to, amt) => {
    await (await pyd.connect(owner).transfer(to, amt)).wait();
  };
  const depositVault = async (who, amount18) => {
    const amount = U(amount18);
    await (await usdc.mint(who.address, amount)).wait();
    await (await usdc.connect(who).approve(await vault.getAddress(), amount)).wait();
    await (await vault.connect(who).deposit(amount)).wait();
  };

  // K1 — stall accumulation + partial unstake.
  // Kills: RR unstake body ['stakedBy -= amount' / safeTransfer / emit → revert]
  //        ASOR on 'stakedBy[msg.sender] += amount' ('=', '|=', '^='):
  //        2000+1000 must read 3000 (OR gives 2040, XOR gives 1080, '=' gives 1000).
  await givePyd(user1.address, U(3000));
  await (await pyd.connect(user1).approve(discountAddr, U(3000))).wait();
  await (await discount.connect(user1).stake(U(2000))).wait();
  await (await discount.connect(user1).stake(U(1000))).wait();
  report("K1 stakedBy accumulates across stakes (2000+1000=3000)",
    (await discount.stakedBy(user1.address)) === U(3000));
  const u1pydBefore = await pyd.balanceOf(user1.address);
  await (await discount.connect(user1).unstake(U(500))).wait();
  report("K1 unstake(500) decrements ledger + transfers exactly",
    (await discount.stakedBy(user1.address)) === U(2500) &&
      (await pyd.balanceOf(user1.address)) - u1pydBefore === U(500));

  // K2 — exit(): full return + zeroed ledger + idempotent repeat.
  // Kills: RR exit body [141-143 → revert]; ASOR 'stakedBy[msg.sender] = 0'.
  // user1 keeps VAULT SHARES (deposited below) so the snapshot loop reaches
  // his tierBps==0 branch — the second `continue` kill — in K3/K5.
  await depositVault(user1, 10_000);
  const u1pydBeforeExit = await pyd.balanceOf(user1.address);
  await (await discount.connect(user1).exit()).wait();
  report("K2 exit() zeros the stake and returns all PYD",
    (await discount.stakedBy(user1.address)) === 0n &&
      (await pyd.balanceOf(user1.address)) - u1pydBeforeExit === U(2500));
  await (await discount.connect(user1).exit()).wait();
  report("K2 exit() again is a clean no-op (staked==0 guard)", (await discount.stakedBy(user1.address)) === 0n);

  // K3 — snapshot accrual, EXACT formula value, with zero-entry stakers present.
  // Subject dummy: vault shares + stake above tier 1.
  await depositVault(dummy, 10_000);
  await givePyd(dummy.address, U(2000));
  await (await pyd.connect(dummy).approve(discountAddr, U(2000))).wait();
  await (await discount.connect(dummy).stake(U(2000))).wait();
  // staker2 = stake without vault shares → first `continue` (shares_i == 0) kill.
  if ((await vault.shares(staker2.address)) > 0n) {
    const w = await vault.maxWithdraw(staker2.address);
    if (w > 0n) await (await vault.connect(staker2).withdraw(w)).wait();
  }
  if ((await discount.stakedBy(staker2.address)) === 0n) {
    await givePyd(staker2.address, U(2));
    await (await pyd.connect(staker2).approve(discountAddr, U(2))).wait();
    await (await discount.connect(staker2).stake(U(2))).wait();
  }
  // Kills: AOR feeDelta '+' [177]; rebate formula AORs [195] ('+', '*', '-', '%');
  //        RR loop `continue` [194]; RR SnapshotHarvested emit [183];
  //        RR 'return 0' no-op [220]-class via exact non-zero expectations.
  const kSnap0 = await discount.lastFeeSnapshot();
  await (await usdc.mint(fdAddr, U(3_000_000))).wait(); // fresh fees for THIS snapshot (large, so K4's budget cap is forced: owed > any prior discount balance)
  const fdBal1 = await usdc.balanceOf(fdAddr);
  const totalSh1 = await vault.totalShares();
  const dSh = await vault.shares(dummy.address);
  const dBps = await discount.tierBpsOf(dummy.address);
  const dPrev = await discount.rebateOf(dummy.address);
  await (await d.snapshotHarvest()).wait();
  const expRebate1 = (dSh * (fdBal1 - kSnap0) * dBps) / (totalSh1 * 10000n);
  report("K3 snapshot accrues the EXACT rebate formula + records the snapshot",
    expRebate1 > 0n &&
      (await discount.rebateOf(dummy.address)) === dPrev + expRebate1 &&
      (await discount.lastFeeSnapshot()) === fdBal1,
    `delta=${E.formatUnits(fdBal1 - snap0, 0)} expected=${E.formatUnits(expRebate1, 0)}`);

  // K4 — claim bounded by the budget actually held; remainder stays accrued.
  // Kills: RR 'amount = budget' [213]; RR claim body [216] (both the pay and
  //        the ledger decrement are exact-asserted).
  const owed1 = await discount.rebateOf(dummy.address);
  const dBudget0 = await usdc.balanceOf(discountAddr);
  const targetBudget = owed1 / 2n;
  if (dBudget0 < targetBudget) await (await usdc.mint(discountAddr, targetBudget - dBudget0)).wait();
  const budgetNow = await usdc.balanceOf(discountAddr);
  const expectPaid = owed1 < budgetNow ? owed1 : budgetNow;
  const dUsdcBefore = await usdc.balanceOf(dummy.address);
  await (await discount.connect(dummy).claimRebate()).wait();
  report("K4 claimRebate pays min(owed, budget) exactly, keeps the remainder",
    (await usdc.balanceOf(dummy.address)) - dUsdcBefore === expectPaid &&
      (await discount.rebateOf(dummy.address)) === owed1 - expectPaid,
    `owed=${E.formatUnits(owed1, 0)} budget=${E.formatUnits(budgetNow, 0)} paid=${E.formatUnits(expectPaid, 0)}`);

  // K5 — second snapshot: delta = ONLY the new fees; accrual ADDS to remainder.
  // Kills: feeDelta '+' thoroughly (both the ledger assert and lastFeeSnapshot);
  //        ASOR 'rebateOf[staker] = rebate' (remainder must survive the add).
  const snapAfterK4 = await discount.lastFeeSnapshot();
  await (await usdc.mint(fdAddr, U(50_000))).wait();
  const fdBal2 = await usdc.balanceOf(fdAddr);
  const owedBeforeK5 = await discount.rebateOf(dummy.address);
  const totalSh2 = await vault.totalShares();
  await (await d.snapshotHarvest()).wait();
  const expRebate2 = (dSh * (fdBal2 - snapAfterK4) * dBps) / (totalSh2 * 10000n);
  report("K5 second snapshot: only NEW fees, rebate ADDS to the remainder",
    expRebate2 > 0n &&
      (await discount.rebateOf(dummy.address)) === owedBeforeK5 + expRebate2 &&
      (await discount.lastFeeSnapshot()) === fdBal2);

  // K6 — full claim with adequate budget drains the ledger exactly.
  const owed2 = await discount.rebateOf(dummy.address);
  const dBudget2 = await usdc.balanceOf(discountAddr);
  if (dBudget2 < owed2) await (await usdc.mint(discountAddr, owed2 - dBudget2)).wait();
  const dUsdc2 = await usdc.balanceOf(dummy.address);
  await (await discount.connect(dummy).claimRebate()).wait();
  report("K6 full claim pays owed exactly and zeroes rebateOf",
    (await usdc.balanceOf(dummy.address)) - dUsdc2 === owed2 &&
      (await discount.rebateOf(dummy.address)) === 0n);

  // K7 — setTiers SUCCESS path (kills RR bodies [107-112 → revert]); then
  // restore the default schedule so any later run state is unchanged.
  await (await d.setTiers([[U(500), 100], [U(5_000), 500], [U(50_000), 1000]])).wait();
  report("K7 setTiers replaces the schedule (success path)",
    (await discount.tiers(0, 0)) === U(500) && (await discount.tiers(2, 1)) === 1000n);
  await (await d.setTiers([[U(1000), 500], [U(10_000), 1000], [U(100_000), 1500], [U(1_000_000), 2000]])).wait();
  report("K7 default schedule restored", (await discount.tiers(3, 1)) === 2000n);

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  const stack = (e && e.stack) || String(e);
  let done = false;
  const bail = () => {
    if (done) return;
    done = true;
    // stderr writes are synchronous for files → this survives the exit
    console.error("pyd_demand_tests error (full stack):\n" + stack);
    process.exit(2);
  };
  // process.exit() DROPS buffered stdout — flush it first, otherwise the CI
  // log loses the step markers written just before the failure and the last
  // visible line is NOT the failing one (cost a multi-hour blind debug).
  setTimeout(bail, 1500).unref();
  process.stdout.write("", bail);
});
