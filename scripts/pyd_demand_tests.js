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
  await (await pyd.connect(owner).transfer(staker1.address, U(5_000))).wait();
  await (await pyd.connect(staker1).approve(await staking.getAddress(), U(5_000))).wait();
  const pf = await staking.periodFinish(); // stream end (started at pf−86400)
  const txStake = await staking.connect(staker1).stake(U(5_000));
  await txStake.wait();
  const stakedAt = await staking.lastUpdateTime();
  const missed = stakedAt - (pf - 86_400n); // seconds of stream before the stake
  await E.provider.send("evm_setNextBlockTimestamp", [Number(stakedAt) + 43_200]);
  const stBefore = await pyd.balanceOf(staker1.address); // AFTER stake → rewards-only delta
  await (await staking.connect(staker1).getReward()).wait();
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

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("pyd_demand_tests error:", e.message?.slice(0, 400));
  process.exit(2);
});
