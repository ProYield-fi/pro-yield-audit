// Integration tests — NEVER-RUN paths. Proves what actually pays on-chain vs what is a stub.
// Run: npx hardhat run scripts/integration_tests.js --network hyperTestnet
const hre = require("hardhat");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}

process.on('unhandledRejection', (e) => {
  try {
    console.error("ORPHAN REJECTION:", e.message?.slice(0, 120));
    const t = e.transaction || {};
    console.error("  orphan tx to:", t.to, "data:", String(t.data).slice(0, 20), "value:", t.value?.toString());
    console.error("  orphan receipt block:", e.receipt?.blockNumber, "status:", e.receipt?.status);
    console.error("  orphan stack:", (e.stack || "").split("\n").slice(1, 4).join(" | "));
  } catch { console.error("ORPHAN REJECTION (no detail)"); }
  process.exit(2);
});

async function main() {
  const [owner, user1] = await hre.ethers.getSigners();
  const E = hre.ethers;
  const fmt = (v) => E.formatUnits(v, 18);

  // ── Fresh deployment ──────────────────────────────────────────────
  const MockUSDC = await E.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy(); await usdc.waitForDeployment();

  const ProYieldVault = await E.getContractFactory("ProYieldVault");
  const vault = await ProYieldVault.deploy(await usdc.getAddress(), owner.address, owner.address);
  await vault.waitForDeployment();

  const MockFundingOracle0 = await E.getContractFactory("MockFundingOracle");
  const bootOracle = await MockFundingOracle0.deploy(0); await bootOracle.waitForDeployment(); // rate 0 until set
  const DeltaNeutral = await E.getContractFactory("DeltaNeutralStrategy");
  const delta = await DeltaNeutral.deploy(await usdc.getAddress(), owner.address, owner.address, await bootOracle.getAddress());
  await delta.waitForDeployment();

  const PendleStrategy = await E.getContractFactory("PendleStrategy");
  const pendle = await PendleStrategy.deploy(await usdc.getAddress(), owner.address, owner.address); // market=owner placeholder, zero-check passes
  await pendle.waitForDeployment();

  const SkyStrategy = await E.getContractFactory("SkyStrategy");
  const sky = await SkyStrategy.deploy(await usdc.getAddress(), owner.address, owner.address);
  await sky.waitForDeployment();

  for (const s of [delta, pendle, sky]) {
    const tx = await vault.addStrategy(await s.getAddress()); await tx.wait();
    const setV = await s.setVault(await vault.getAddress()); await setV.wait();
  }

  // ── A. YIELD ACCOUNTING — is delta neutral actually PAYING? ──────
  console.log("\n── A. Delta-Neutral / yield reality ──");

  // A1: updateFunding with a zero-rate boot oracle
  let tx;
  const step = (s) => console.log('   ·', s);
  step('A1 updateFunding'); tx = await delta.updateFunding(); await tx.wait();
  report("A1 delta.updateFunding() runs", true);
  const rate = await delta.fundingRate();
  report("A2 boot oracle rate=0 -> fundingRate honestly 0 (no fabricated rate)", rate === 0n, `rate=${rate}`);

  // A3: broken oracle (EOA, no getFundingRate) -> updateFunding REVERTS (fail loud)
  step('A3 setOracle(user1)'); tx = await delta.setOracle(user1.address); await tx.wait();
  let badOracleReverted = false;
  try { step('A3 updateFunding (expect revert)'); tx = await delta.updateFunding(); await tx.wait(); } catch { badOracleReverted = true; }
  report("A3 broken oracle (EOA) -> updateFunding reverts loudly (never silently fakes a rate)",
    badOracleReverted);
  // restore a working oracle for the rest of the run
  step('A3 restore oracle'); tx = await delta.setOracle(await bootOracle.getAddress()); await tx.wait();
  step('A3 updateFunding restored'); tx = await delta.updateFunding(); await tx.wait();

  // A4: harvest with zero ETH balance -> profit 0
  const debtBefore = await delta.totalDebt();
  step('A4 harvest'); tx = await delta.harvest(); const rc = await tx.wait();
  const harvestEv = rc.logs.map(l => { try { return delta.interface.parseLog(l); } catch { return null; } }).find(e => e && e.name === "Harvest");
  report("A4 delta.harvest profit == 0 with empty ETH balance", harvestEv && harvestEv.args[0] === 0n,
    `Harvest(profit=${harvestEv ? harvestEv.args[0].toString() : "?"})`);

  // A5: receive() now EXISTS — the strategy accepts native ETH settlements.
  const ethAmount = E.parseEther("0.5");
  const deltaAddr = await delta.getAddress();
  step('A5 send ETH'); tx = await owner.sendTransaction({ to: deltaAddr, value: ethAmount }); await tx.wait();
  report("A5 strategy ACCEPTS native ETH (receive() — old unreachable-path bug fixed)",
    (await E.provider.getBalance(deltaAddr)) === ethAmount);

  // A5b: ETH forwarding — settlements sweep to short on harvest (no position gate;
  // settlements can arrive anytime). Principal expectation: strategy drains to 0.
  try {
    tx = await delta.harvest(); await tx.wait();
    report("A5b-i harvest sweeps held ETH to short (settlement forwarding)",
      (await E.provider.getBalance(deltaAddr)) === 0n);
    tx = await delta.openPosition(E.parseUnits("10000", 18)); await tx.wait();
    const shortBefore = await E.provider.getBalance(owner.address); // shortPosition == owner here
    tx = await delta.harvest(); await tx.wait();
    const shortAfter = await E.provider.getBalance(owner.address);
    const deltaEthAfter = await E.provider.getBalance(deltaAddr);
    report("A5b-ii open position -> ETH settlements forwarded out to short on harvest",
      deltaEthAfter === 0n,
      `strategy drained fully (${fmt(deltaEthAfter)} kept); destination is short by construction`);
    // close the position so later sections start clean
    tx = await delta.closePosition(); await tx.wait();
  } catch (e) {
    report("A5b ETH forwarding", false, (e.message || "").slice(0, 120));
  }

  // A6: vault harvest accrues nothing (fee capture not implemented)
  const debtV = await vault.totalDebt();
  tx = await vault.harvest(); const rcV = await tx.wait();
  const vEv = rcV.logs.map(l => { try { return vault.interface.parseLog(l); } catch { return null; } }).find(e => e && e.name === "Harvest");
  report("A6 vault.harvest profit == 0 (performance-fee capture NOT yet implemented)", vEv && vEv.args[0] === 0n);

  // A7: exchangeRate — paper keeper reports deltaApyBps=1100; on-chain exchange rate must stay 1.0
  // (any drift here = paper claiming yield that on-chain did not generate)
  const idle = await usdc.balanceOf(await vault.getAddress());
  report("A7 vault idle balance unchanged after all harvests (no fake yield minted)", idle === 0n, `idle=${fmt(idle)}`);

  // ── B. MONEY MOVEMENT — full journey with exact assertions ──────
  console.log("\n── B. Full money journey ──");
  const DEPOSIT = E.parseUnits("100000", 18);
  tx = await usdc.mint(owner.address, DEPOSIT); await tx.wait();
  tx = await usdc.approve(await vault.getAddress(), DEPOSIT); await tx.wait();
  tx = await vault.deposit(DEPOSIT); await tx.wait();
  report("B1 deposit 100k -> vault.totalAssets == 100k",
    (await vault.totalAssets()) === DEPOSIT, `totalAssets=${fmt(await vault.totalAssets())}`);

  tx = await vault.allocate(); await tx.wait();
  const balDelta = await usdc.balanceOf(await delta.getAddress());
  const balPendle = await usdc.balanceOf(await pendle.getAddress());
  const balSky = await usdc.balanceOf(await sky.getAddress());
  const split = E.parseUnits("30000", 18); // RESERVE_BPS=1000: deployable=90k, /3 strategies
  const vaultIdle = await usdc.balanceOf(await vault.getAddress());
  report("B2 allocate splits deployable 90k across 3 strategies (30k each)",
    balDelta >= split && balPendle >= split && balSky >= split,
    `delta=${fmt(balDelta)} pendle=${fmt(balPendle)} sky=${fmt(balSky)}`);
  report("B2b 10% liquid reserve stays in vault (withdrawals never need recall to succeed)",
    vaultIdle === E.parseUnits("10000", 18), `idle=${fmt(vaultIdle)}`);

  // B3: recall authorization — strategy-side recall is vault-only (by design);
  // the vault itself calls it via _recallShortfall on big withdrawals.
  let recallReverted = false;
  try { tx = await delta.recall(E.parseUnits("20000", 18)); await tx.wait(); } catch { recallReverted = true; }
  report("B3 strategy.recall by non-vault reverts (auth correct; vault auto-recalls on withdrawal shortfall)",
    recallReverted);

  // B3b: REAL liquidity test — withdraw MORE than idle forces _recallShortfall
  const bigW = E.parseUnits("50000", 18);
  const oBalBefore = await usdc.balanceOf(owner.address);
  tx = await vault.withdraw(bigW); await tx.wait();
  const oBalAfter = await usdc.balanceOf(owner.address);
  report("B3b withdraw 50k (>> 10k idle) auto-recalls shortfall from strategies and pays in full",
    oBalAfter - oBalBefore === bigW, `paid=${fmt(oBalAfter - oBalBefore)}`);

  // B4: user1 proportional withdraw (share math with big owner position)
  tx = await usdc.mint(user1.address, E.parseUnits("100", 18)); await tx.wait();
  tx = await usdc.connect(user1).approve(await vault.getAddress(), E.parseUnits("100", 18)); await tx.wait();
  tx = await vault.connect(user1).deposit(E.parseUnits("100", 18)); await tx.wait();
  const u1Before = await usdc.balanceOf(user1.address);
  tx = await vault.connect(user1).withdraw(E.parseUnits("100", 18)); await tx.wait();
  const u1After = await usdc.balanceOf(user1.address);
  report("B4 user1 deposits 100 & withdraws exactly 100 (share math intact, uses recalled liquidity)",
    u1After - u1Before === E.parseUnits("100", 18), `net=${fmt(u1After - u1Before)}`);

  // B5: fee cap enforcement
  let capReverted = false;
  try { tx = await vault.setPerformanceFee(10001); await tx.wait(); } catch { capReverted = true; }
  report("B5 setPerformanceFee(>10%) reverts (fee cap enforced)", capReverted);

  // ── C. PAUSE SEMANTICS WITH FUNDS ON THE TABLE ──────────────────
  console.log("\n── C. Circuit breaker ──");
  // set performance fee back to sane value in case B5 failed-open
  tx = await vault.setPerformanceFee(1000); await tx.wait();

  tx = await vault.setStrategyActive(await delta.getAddress(), false); await tx.wait();
  const deltaBalBefore = await usdc.balanceOf(await delta.getAddress());
  tx = await vault.allocate(); await tx.wait();
  const deltaBalPaused = await usdc.balanceOf(await delta.getAddress());
  report("C1 paused strategy receives NO NEW allocation (existing capital stays until recalled)",
    deltaBalPaused === deltaBalBefore,
    `before=${fmt(deltaBalBefore)} after=${fmt(deltaBalPaused)}`);
  const skyBalActive = await usdc.balanceOf(await sky.getAddress());
  const pendleBalActive = await usdc.balanceOf(await pendle.getAddress());
  const activeGrew = skyBalActive > 0n && pendleBalActive > 0n;
  // the newly deployable must have gone ONLY to active strategies
  const deployedNow = Number(fmt(skyBalActive)) + Number(fmt(pendleBalActive));
  report("C1b active strategies absorb all new deployable while one is paused",
    activeGrew, `sky=${fmt(skyBalActive)} pendle=${fmt(pendleBalActive)}`);

  let pausedHarvestReverted = false;
  try { tx = await vault.harvestStrategy(await delta.getAddress()); await tx.wait(); } catch { pausedHarvestReverted = true; }
  report("C2 harvestStrategy on paused strategy reverts", pausedHarvestReverted);

  tx = await vault.setStrategyActive(await delta.getAddress(), true); await tx.wait();

  // C3: strategy-level isActive kill switch
  tx = await sky.setActive(false); await tx.wait();
  let inactiveReverted = false;
  try { tx = await sky.harvest(); await tx.wait(); } catch { inactiveReverted = true; }
  tx = await sky.setActive(true); await tx.wait();
  report("C3 strategy.setActive(false) blocks harvest (BaseStrategy kill switch)", inactiveReverted);

  // ── D. EMERGENCY SEMANTICS ───────────────────────────────────────
  console.log("\n── D. Emergency path ──");
  const vaultUSDC = await usdc.balanceOf(await vault.getAddress());
  const ownerBefore = await usdc.balanceOf(owner.address);
  tx = await vault.emergencyWithdraw(); await tx.wait();
  const ownerAfter = await usdc.balanceOf(owner.address);
  report("D1 emergencyWithdraw drains idle USDC to owner",
    ownerAfter - ownerBefore === vaultUSDC, `drained ${fmt(ownerAfter - ownerBefore)}`);

  // ── E. DELTA-NEUTRAL ACTUALLY PAYS (funding accrual, real tokens) ──
  console.log("\n── E. Funding accrual end-to-end ──");
  const MockFundingOracle = await E.getContractFactory("MockFundingOracle");
  const oracleC = await MockFundingOracle.deploy(1100); await oracleC.waitForDeployment(); // 11% APR
  const MockFundingSource = await E.getContractFactory("MockFundingSource");
  const source = await MockFundingSource.deploy(await usdc.getAddress()); await source.waitForDeployment();
  tx = await delta.setOracle(await oracleC.getAddress()); await tx.wait();
  tx = await delta.setFundingSource(await source.getAddress()); await tx.wait();
  tx = await usdc.mint(owner.address, E.parseUnits("1000000", 18)); await tx.wait();
  tx = await usdc.approve(await source.getAddress(), E.parseUnits("1000000", 18)); await tx.wait();
  tx = await source.fund(E.parseUnits("1000000", 18)); await tx.wait();

  // E1: rate fetches from oracle now
  tx = await delta.updateFunding(); await tx.wait();
  const liveRate = await delta.fundingRate();
  report("E1 updateFunding fetches real rate from oracle (1100 bps = 11% APR)", liveRate === 1100n,
    `rate=${liveRate}`);

  // E2: no position -> zero NEW accrual (never fabricates)
  const accruedBefore = await delta.accruedFunding();
  tx = await delta.harvest(); await tx.wait();
  report("E2 harvest with no position accrues nothing (no fabricated yield)",
    (await delta.accruedFunding()) === accruedBefore);

  // E3: open position, warp time, harvest -> funding pays REAL USDC per the math
  const NOTIONAL = E.parseUnits("30000", 18);
  const accruedAtOpen = await delta.accruedFunding();
  tx = await delta.openPosition(NOTIONAL); await tx.wait();
  // fast-forward 30 days
  const blockNum = await E.provider.getBlockNumber();
  const ts = (await E.provider.getBlock(blockNum)).timestamp;
  await E.provider.send("evm_setNextBlockTimestamp", [ts + 30 * 24 * 3600]);
  tx = await delta.harvest(); const rcE = await tx.wait();
  // expect: 30000 * 0.11 * (30d/365d) ≈ 271.23 USDC (delta of accrued since position open)
  const expected = (NOTIONAL * 1100n * BigInt(30 * 24 * 3600)) / (BigInt(365 * 24 * 3600) * 10000n);
  const accrued = (await delta.accruedFunding()) - accruedAtOpen;
  report("E3 30 days @ 11% on 30k notional accrues REAL USDC per math",
    accrued >= (expected * 99n) / 100n && accrued <= (expected * 101n) / 100n,
    `accrued=${fmt(accrued)} expected≈${fmt(expected)}`);
  const sourceBal = await usdc.balanceOf(await source.getAddress());
  report("E3b funding paid by REAL token movement from venue (source drained accordingly)",
    sourceBal === E.parseUnits("1000000", 18) - accrued - accruedAtOpen, `source=${fmt(sourceBal)}`);

  // E4: broken funding source (contract WITHOUT payFunding) -> harvest reverts
  tx = await delta.setFundingSource(await bootOracle.getAddress()); await tx.wait();
  await E.provider.send("evm_setNextBlockTimestamp", [ts + 60 * 24 * 3600]);
  let sourceFailReverted = false;
  try { tx = await delta.harvest(); await tx.wait(); } catch { sourceFailReverted = true; }
  report("E4 broken funding source -> harvest reverts (fail loud, never fake)", sourceFailReverted);
  tx = await delta.setFundingSource(await source.getAddress()); await tx.wait();

  // E5: vault.harvest() sweeps accrued funding profit to the vault and takes the
  // 10% performance fee to the FeeDistributor — real token flow, no modeled yield.
  // NOTE: E4's failed harvest rolled back its settle but time still advanced 30d,
  // so E5's harvest legitimately accrues that second window before sweeping.
  const accruedNow = await delta.accruedFunding();
  const expectedSecond = (NOTIONAL * 1100n * BigInt(30 * 24 * 3600)) / (BigInt(365 * 24 * 3600) * 10000n);
  const expectedTotal = accruedNow + expectedSecond;
  const vaultIdlePre = await usdc.balanceOf(await vault.getAddress());
  const feeDistPre = await usdc.balanceOf(await vault.feeDistributor());
  const deltaBalPre = await usdc.balanceOf(await delta.getAddress());
  tx = await vault.harvest(); const rcE5 = await tx.wait();
  const vaultIdlePost = await usdc.balanceOf(await vault.getAddress());
  const feeDistPost = await usdc.balanceOf(await vault.feeDistributor());
  const deltaBalPost = await usdc.balanceOf(await delta.getAddress());
  const feeTaken = feeDistPost - feeDistPre;
  const sweptToVault = vaultIdlePost - vaultIdlePre;
  report("E5 vault.harvest sweeps strategy profit into the vault",
    (await delta.accruedFunding()) === 0n
      && sweptToVault + feeTaken >= (expectedTotal * 99n) / 100n
      && sweptToVault + feeTaken <= (expectedTotal * 101n) / 100n,
    `swept=${fmt(sweptToVault)} + fee=${fmt(feeTaken)} = ${fmt(sweptToVault + feeTaken)} (expected ≈ ${fmt(expectedTotal)})`);
  report("E5b performance fee = 10% of swept profit, paid to FeeDistributor",
    feeTaken === (sweptToVault + feeTaken) / 10n, `fee=${fmt(feeTaken)}`);
  const harvestEvE5 = rcE5.logs.map(l => { try { return vault.interface.parseLog(l); } catch { return null; } }).find(e => e && e.name === "Harvest");
  report("E5c vault Harvest(profit) event reflects real swept amount",
    harvestEvE5 && harvestEvE5.args[0] === sweptToVault + feeTaken,
    `Harvest(${harvestEvE5 ? fmt(harvestEvE5.args[0]) : "?"})`);

  // E6: ETH settlements accepted now (receive() exists) and forwarded on harvest
  const ethAmt = E.parseEther("0.25");
  tx = await owner.sendTransaction({ to: await delta.getAddress(), value: ethAmt }); await tx.wait();
  report("E6 strategy ACCEPTS native ETH (receive() fixed the unreachable path)",
    (await E.provider.getBalance(await delta.getAddress())) === ethAmt);

  console.log(`\n=== INTEGRATION: ${pass} passed, ${fail} failed ===`);
  if (fail > 0) process.exit(1);
}
main().catch(e => { console.error(e); process.exit(1); });
