// Ecosystem journey test — the ENTIRE ProYield product in one continuous
// customer-visible path, with exact-value assertions at every leg:
//
//   on-ramp -> deposit -> fee income -> FD reconcile
//   -> recycle (spawns the REAL scripts/recycle_fees.js against this chain)
//   -> PYD demand (funder converts USDC -> swapper -> stream -> staking)
//   -> tier + rebate accrual/claim -> redemption -> conservation ledger.
//
// Self-deploying on a fresh chain (no manifest needed). The recycle leg runs
// the production script in cold-start mode (DEPLOY_MANIFEST set), which by
// design must NOT append to the shared recycling ledger — asserted here.
const hre = require("hardhat");
const { execSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) pass++; else fail++;
  console.log(`${ok ? "  ✓" : "  ✗"} ${name}${detail ? " — " + detail : ""}`);
}
const U = (n) => hre.ethers.parseUnits(String(n), 18);
const U6 = (n) => hre.ethers.parseUnits(String(n), 6);
const F = (v) => hre.ethers.formatUnits(v, 18);
const F6 = (v) => hre.ethers.formatUnits(v, 6);
const addr = (c) => c.getAddress();

async function main() {
  const E = hre.ethers;
  const [owner, alice, bob] = await E.getSigners();

  console.log("── deployment (fresh, self-contained) ──");
  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  const pyd = await (await E.getContractFactory("PYDToken")).deploy(100_000_000n);
  await pyd.waitForDeployment();
  const fd = await (await E.getContractFactory("FeeDistributor")).deploy(await addr(usdc));
  await fd.waitForDeployment();
  const vault = await (await E.getContractFactory("ProYieldVault")).deploy(
    await addr(usdc), owner.address, await addr(fd));
  await vault.waitForDeployment();
  const staking = await (await E.getContractFactory("PYDStaking")).deploy(await addr(pyd));
  await staking.waitForDeployment();
  const discount = await (await E.getContractFactory("PYDFeeDiscount")).deploy(
    await addr(pyd), await addr(usdc), await addr(fd), await addr(vault), owner.address);
  await discount.waitForDeployment();
  const funder = await (await E.getContractFactory("PYDFunder")).deploy(
    await addr(usdc), await addr(staking), owner.address);
  await funder.waitForDeployment();
  const swapper = await (await E.getContractFactory("MockSwapper")).deploy(await addr(pyd), await addr(usdc));
  await swapper.waitForDeployment();
  console.log("  stack deployed");

  // ═══ LEG 1 — on-ramp → deposit (exact share accounting) ═══
  console.log("\n── leg 1: customer on-ramp + deposits ──");
  await (await usdc.connect(owner).mint(alice.address, U(60_000))).wait();
  await (await usdc.connect(owner).mint(bob.address, U(40_000))).wait();

  await (await usdc.connect(alice).approve(await addr(vault), U(50_000))).wait();
  await (await vault.connect(alice).deposit(U(50_000))).wait();
  const aliceShares = await vault.shares(alice.address);
  const sp1 = await vault.convertToAssets(U(1)); // assets per 1 share
  report("alice deposit mints shares 1:1 on an empty vault",
    aliceShares === U(50_000) && sp1 === U(1) && (await vault.totalShares()) === U(50_000),
    `shares=${F(aliceShares)} price/share=${F(sp1)}`);

  await (await usdc.connect(bob).approve(await addr(vault), U(30_000))).wait();
  const vaultUsdcBeforeBob = await usdc.balanceOf(await addr(vault));
  await (await vault.connect(bob).deposit(U(30_000))).wait();
  const bobShares = await vault.shares(bob.address);
  report("bob deposit mints at current share price (no dilution of alice)",
    bobShares === U(30_000) && (await vault.convertToAssets(U(1))) === U(1),
    `bobShares=${F(bobShares)}`);
  report("vault holds both deposits",
    (await usdc.balanceOf(await addr(vault))) - vaultUsdcBeforeBob === U(30_000) &&
    (await vault.totalAssets()) === U(80_000),
    `totalAssets=${F(await vault.totalAssets())}`);

  // ═══ LEG 2 — fee income lands in the FeeDistributor, reconcile proves it ═══
  console.log("\n── leg 2: fee income + FD reconcile ──");
  // A harvest would sweep strategy profit and route the perf fee to the FD.
  // Here the harvested fee arrives as real USDC into the FD (same on-chain
  // effect the strategy harvest produces): 1,000 USDC of performance fees.
  await (await usdc.connect(owner).mint(await addr(fd), U(1_000))).wait();
  await (await fd.receiveFees()).wait();
  report("fd.receiveFees() books the full fee delta",
    (await fd.totalFeesReceived()) === U(1_000),
    `totalFeesReceived=${F(await fd.totalFeesReceived())}`);
  report("fee income has NOT touched depositor assets yet",
    (await vault.totalAssets()) === U(80_000),
    `totalAssets=${F(await vault.totalAssets())}`);

  // ═══ LEG 3 — recycle: the REAL production script against this chain ═══
  console.log("\n── leg 3: fee recycling (production script, cold-start) ──");
  // Hermetic: the journey supplies its own policy + ledger so it runs on any
  // host (CI has no ~/yield_scout). The host's real ledger, when present, must
  // still come out untouched — cold-start must never append to shared state.
  const scratchDir = process.env.BATTERY_LOGS || os.tmpdir();
  const policyPath = path.join(scratchDir, `journey_policy_${process.pid}.json`);
  const scratchLedger = path.join(scratchDir, `journey_ledger_${process.pid}.jsonl`);
  fs.writeFileSync(policyPath, JSON.stringify({
    depositor_boost_pct: 60, treasury_pct: 20, insurance_pct: 20, min_amount: 1,
  }, null, 2));
  const countLines = (p) => (fs.existsSync(p)
    ? fs.readFileSync(p, "utf8").split("\n").filter(Boolean).length : 0);
  const sharedLedger = "/home/user/yield_scout/data/recycling.jsonl";
  const sharedBefore = countLines(sharedLedger);
  const manifestPath = path.join(os.tmpdir(), `journey_manifest_${process.pid}.json`);
  fs.writeFileSync(manifestPath, JSON.stringify({
    mock_usdc: await addr(usdc),
    fee_distributor: await addr(fd),
    pro_yield_vault: await addr(vault),
    pyd_staking: await addr(staking),
    pyd_token: await addr(pyd),
    pyd_fee_discount: await addr(discount),
  }, null, 2));

  const ownerBefore = await usdc.balanceOf(owner.address);
  const vaultBeforeRecycle = await vault.totalAssets();
  let recycleOut = "", recycleRc = 0;
  try {
    recycleOut = execSync("npx hardhat run scripts/recycle_fees.js --network hyperTestnet", {
      cwd: path.join(__dirname, ".."),
      encoding: "utf8",
      timeout: 180000,
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        DEPLOY_MANIFEST: manifestPath,
        RECYCLE_POLICY: policyPath,
        RECYCLE_LEDGER: scratchLedger,
        HYPEREVM_RPC_URL: `http://localhost:${process.env.BATTERY_PORT || 8547}`,
        DEPLOYER_PRIVATE_KEY: process.env.DEPLOYER_PRIVATE_KEY || "",
      },
    });
  } catch (e) {
    recycleOut = (e.stdout || "") + (e.stderr || "");
    recycleRc = e.status ?? -1;
  }
  report("production recycle script exits 0", recycleRc === 0,
    recycleRc === 0 ? "" : `rc=${recycleRc} tail=${String(recycleOut).slice(-300)}`);

  const boost = (U(1_000) * 60n) / 100n;             // policy: 60/20/20
  const treasuryPlusInsurance = U(1_000) - boost;      // remainder stays exact
  const vaultAfterRecycle = await vault.totalAssets();
  report("boost leg: 60% credited to depositors exactly",
    vaultAfterRecycle - vaultBeforeRecycle === boost,
    `delta=${F(vaultAfterRecycle - vaultBeforeRecycle)} expected=${F(boost)}`);
  report("treasury+insurance legs: 40% routed out of the FD exactly",
    (await usdc.balanceOf(owner.address)) - ownerBefore === treasuryPlusInsurance,
    `delta=${F((await usdc.balanceOf(owner.address)) - ownerBefore)} expected=${F(treasuryPlusInsurance)}`);
  report("FD fully drained (nothing stranded)",
    (await usdc.balanceOf(await addr(fd))) === 0n,
    `fdBalance=${F(await usdc.balanceOf(await addr(fd)))}`);
  report("cold-start recycle writes NO ledger (scratch ledger stays empty)",
    countLines(scratchLedger) === 0, `scratch lines=${countLines(scratchLedger)}`);
  report("host recycling ledger untouched by the journey",
    countLines(sharedLedger) === sharedBefore,
    `shared lines ${sharedBefore} -> ${countLines(sharedLedger)}`);

  const sp2 = await vault.convertToAssets(U(1));
  report("depositors' share price rose from the boost (profit reached users)",
    sp2 > sp1, `price/share ${F(sp1)} -> ${F(sp2)}`);

  try { fs.unlinkSync(manifestPath); fs.unlinkSync(policyPath); fs.unlinkSync(scratchLedger); } catch { /* best effort */ }

  // ═══ LEG 4 — PYD demand: funder converts routed USDC → PYD → real stream ═══
  console.log("\n── leg 4: PYD demand (funder → swapper → staking stream) ──");
  const near = (a, b, tol) => (a > b ? a - b : b - a) <= tol;
  await (await funder.connect(owner).setSwapper(await addr(swapper))).wait();
  await (await funder.connect(owner).setMaxConvertUsd6(25_000n * 10n ** 6n)).wait();
  await (await staking.connect(owner).transferOwnership(await addr(funder))).wait();
  await (await pyd.connect(owner).transfer(await addr(swapper), U(50_000_000))).wait();
  // Owner holds no USDC of its own (on-ramp mints went to users/FD) — mint the
  // routed demand-side USDC first; counted in the conservation ledger below.
  await (await usdc.connect(owner).mint(owner.address, U(25_000))).wait();
  await (await usdc.connect(owner).transfer(await addr(funder), U(25_000))).wait();

  const pydInSwapperBefore = await pyd.balanceOf(await addr(swapper));
  await (await funder.connect(owner).topUp(25_000n * 10n ** 6n, 86_400n)).wait();
  // NOTE (ecosystem divergence found by this journey): the funder's `amount6`
  // is raw 6dp units. Real USDC is 6dp so 25,000e6 == 25,000 USDC there; the
  // battery's MockUSDC is 18dp, so the raw amount moved is only 2.5e-8 tokens
  // while the documented 1:1 mock swapper still credits 25,000 PYD. Assert the
  // contract's actual behavior, not the production-token illusion.
  const consumedRaw = U(25_000) - (await funder.pendingUsdc());
  report("funder consumes the routed amount in amount6 raw units (6dp semantics)",
    consumedRaw === 25_000n * 10n ** 6n,
    `consumedRaw=${consumedRaw} pendingLeft=${F(await funder.pendingUsdc())}`);
  report("swapper delivered PYD for the conversion",
    pydInSwapperBefore - (await pyd.balanceOf(await addr(swapper))) >= U(25_000) - U(1),
    `pyd out=${F(pydInSwapperBefore - (await pyd.balanceOf(await addr(swapper))))}`);

  // A real staker enters the PYD stream, then time advances mid-stream.
  const staker = bob;
  await (await pyd.connect(owner).transfer(staker.address, U(10_000))).wait();
  await (await pyd.connect(staker).approve(await addr(staking), U(10_000))).wait();
  await (await staking.connect(staker).stake(U(10_000))).wait();
  const earnedStart = await staking.earned(staker.address);
  await hre.network.provider.send("evm_increaseTime", [43_200]); // half the stream
  await hre.network.provider.send("evm_mine", []);
  const earnedHalf = await staking.earned(staker.address);
  report("PYD stream pays the staker over time (half-duration ≈ half the stream)",
    earnedHalf > earnedStart && earnedHalf > U(25_000) / 4n && earnedHalf < U(25_000) * 3n / 4n,
    `earned ${F(earnedStart)} -> ${F(earnedHalf)}`);
  await hre.network.provider.send("evm_increaseTime", [43_200]); // stream complete
  await hre.network.provider.send("evm_mine", []);
  const earnedFull = await staking.earned(staker.address);
  report("stream completes to ≈ the funded amount (25,000 PYD)",
    near(earnedFull, U(25_000), U(2)),
    `earned full=${F(earnedFull)}`);
  const pydBeforeClaim = await pyd.balanceOf(staker.address);
  await (await staking.connect(staker).getReward()).wait();
  const paid = (await pyd.balanceOf(staker.address)) - pydBeforeClaim;
  report("getReward() transfers real PYD (stream → wallet)",
    paid > 0n && near(paid, earnedFull, 2n),
    `paid=${F(paid)}`);

  // ═══ LEG 5 — fee rebate: tier, real-delta snapshot, claim ═══
  console.log("\n── leg 5: fee rebate (discount) ──");
  await (await usdc.connect(owner).mint(await addr(fd), U(500))).wait();
  await (await fd.receiveFees()).wait();
  await (await pyd.connect(owner).transfer(alice.address, U(5_000))).wait();
  const discountAddr = await addr(discount);
  await (await pyd.connect(alice).approve(discountAddr, U(5_000))).wait();
  await (await discount.connect(alice).stake(U(2_000))).wait();
  const tierBps = await discount.tierBpsOf(alice.address);
  report("depositor staking 2,000 PYD gets the real tier (5%)",
    tierBps === 500n, `tierBps=${tierBps}`);

  const snapTx = await (await discount.connect(owner).snapshotHarvest()).wait();
  const snap = snapTx.logs
    .map((l) => { try { return discount.interface.parseLog(l); } catch { return null; } })
    .find((p) => p && p.name === "SnapshotHarvested");
  report("snapshotHarvest captures the real fee delta (event-verified)",
    !!snap && snap.args[0] === U(500),
    snap ? `feeDelta=${F(snap.args[0])} totalShares=${F(snap.args[1])} stakersAccrued=${snap.args[2]}` : "no SnapshotHarvested event");

  // Budget the rebate pool, then claim.
  await (await fd.route(discountAddr, (await usdc.balanceOf(await addr(fd))))).wait();
  await (await discount.connect(owner).receiveBudget()).wait();
  const usdcBeforeClaim = await usdc.balanceOf(alice.address);
  const pydBeforeRebate = await pyd.balanceOf(alice.address);
  let rebateAmt = 0n, rebateErr = "";
  try {
    const claimTx = await (await discount.connect(alice).claimRebate()).wait();
    const ev = claimTx.logs
      .map((l) => { try { return discount.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === "RebateClaimed");
    rebateAmt = ev ? ev.args[1] : 0n;
  } catch (e) { rebateErr = e.shortMessage || e.message; }
  const usdcPaid = (await usdc.balanceOf(alice.address)) - usdcBeforeClaim;
  const pydPaid = (await pyd.balanceOf(alice.address)) - pydBeforeRebate;
  // Documented formula: rebate = shares_i × feeDelta × tierBps / (totalShares × 1e4)
  const expectedRebate = (aliceShares * U(500) * 500n) / (U(80_000) * 10_000n);
  report("claimRebate pays exactly the documented rebate formula",
    rebateAmt === expectedRebate && rebateAmt > 0n &&
    (usdcPaid === rebateAmt || pydPaid === rebateAmt),
    rebateAmt > 0n
      ? `paid=${F(rebateAmt)} formula=${F(expectedRebate)} usdcPaid=${F(usdcPaid)}`
      : `error: ${rebateErr}`);

  // ═══ LEG 6 — redemption: the depositor exits with principal + boost ═══
  console.log("\n── leg 6: redemption ──");
  const sharesBefore = await vault.shares(alice.address);
  const claim = await vault.maxWithdraw(alice.address);   // max ASSET amount
  const aliceUsdcBefore = await usdc.balanceOf(alice.address);
  const totalAssetsBefore = await vault.totalAssets();
  const totalSharesBefore = await vault.totalShares();
  report("depositor's claim exceeds principal before exit (boost captured)",
    claim > U(50_000),
    `claim=${F(claim)} vs principal=50,000`);

  await (await vault.connect(alice).withdraw(claim)).wait();
  const aliceOut = (await usdc.balanceOf(alice.address)) - aliceUsdcBefore;
  report("withdraw() pays the requested asset amount exactly",
    aliceOut === claim, `out=${F(aliceOut)} requested=${F(claim)}`);
  const aliceDust = await vault.shares(alice.address);
  const assetsAfter = await vault.totalAssets();
  report("vault accounting unwinds exactly (assets out, shares burned)",
    totalAssetsBefore - assetsAfter === aliceOut &&
    totalSharesBefore - (await vault.totalShares()) === sharesBefore - aliceDust &&
    aliceDust < sharesBefore / 1_000_000n,
    `assets -${F(totalAssetsBefore - assetsAfter)} burned=${F(sharesBefore - aliceDust)} dust=${aliceDust}`);
  const bobClaim = await vault.maxWithdraw(bob.address);
  const dustClaim = await vault.convertToAssets(aliceDust);
  report("remaining holder keeps their pro-rata claim (floor dust bounded)",
    bobClaim === (await vault.convertToAssets(bobShares)) &&
    bobClaim + dustClaim <= assetsAfter && assetsAfter - (bobClaim + dustClaim) < 10n,
    `bob=${F(bobClaim)} + dust=${F(dustClaim)} vault=${F(assetsAfter)} gap=${F(assetsAfter - bobClaim - dustClaim)}`);

  // ═══ LEG 7 — conservation ledger: no USDC evaporates anywhere ═══
  console.log("\n── leg 7: conservation ledger ──");
  // Minted across the whole journey: 60,000 + 40,000 (on-ramps) + 1,000 + 500
  // (fees) + 25,000 (demand-side routing to the funder)
  const totalMinted = U(60_000) + U(40_000) + U(1_000) + U(500) + U(25_000);
  const holders = {
    vault: await addr(vault), fd: await addr(fd), funder: await addr(funder),
    swapper: await addr(swapper), discount: await addr(discount), staking: await addr(staking),
    alice: alice.address, bob: bob.address, owner: owner.address,
  };
  let sum = 0n; const lines = [];
  for (const [name, a] of Object.entries(holders)) {
    const b = await usdc.balanceOf(a);
    sum += b;
    if (b > 0n) lines.push(`${name}=${F(b)}`);
  }
  report("Σ all ecosystem USDC == Σ minted (conservation, exact wei)",
    sum === totalMinted,
    `sum=${F(sum)} minted=${F(totalMinted)} | ${lines.join(" · ")}`);

  // Ledger snapshot for the report
  console.log("\n── journey ledger ──");
  console.log(`  deposits 80,000 | fees 1,500 | boost 600 | recycled 400 | PYD streamed 25,000 | redeemed ${F(aliceOut)}`);

  // ⟪JOURNEY-APPEND-HERE⟫
}

main().then(() => {
  console.log(`\n══════ JOURNEY: ${pass} passed, ${fail} failed ══════`);
  process.exit(fail === 0 ? 0 : 1);
}).catch((e) => { console.error("journey error:", e); process.exit(2); });
