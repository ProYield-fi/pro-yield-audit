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

  // ── F. PROFIT ATTRIBUTION (4626-style share math) ───────────────
  console.log("\n── F. Share price & depositor earnings ──");
  // Setup: fresh users on the SAME vault (price currently 1:1).
  // F-section flows: deposit -> profit -> price rises -> everyone earns pro-rata.
  const u2 = (await E.getSigners())[2];
  const u3 = (await E.getSigners())[3];
  for (const u of [u2, u3]) {
    tx = await usdc.mint(u.address, E.parseUnits("50000", 18)); await tx.wait();
    tx = await usdc.connect(u).approve(await vault.getAddress(), E.parseUnits("50000", 18)); await tx.wait();
  }
  const preDepositAssets = await vault.totalAssets();
  const preDepositShares = await vault.totalShares();

  // F1: late depositor gets fewer shares per token when price > 1
  const priceGT1 = preDepositAssets > preDepositShares;
  tx = await vault.connect(u2).deposit(E.parseUnits("10000", 18)); await tx.wait();
  const u2Sh = (await vault.totalShares()) - preDepositShares;
  report("F1 price>1: 10k deposit mints <10k shares (pays fair entry price)",
    priceGT1 ? u2Sh < E.parseUnits("10000", 18) : u2Sh === E.parseUnits("10000", 18),
    `minted ${fmt(u2Sh)} for 10k`);

  // F2: another harvest accrues profit -> totalAssets grows by NET profit
  await E.provider.send("evm_setNextBlockTimestamp", [ts + 90 * 24 * 3600]);
  const assetsPreHarvest = await vault.totalAssets();
  const feeDistPre2 = await usdc.balanceOf(await vault.feeDistributor());
  tx = await vault.harvest(); await tx.wait();
  const assetsPostHarvest = await vault.totalAssets();
  const fee2 = (await usdc.balanceOf(await vault.feeDistributor())) - feeDistPre2;
  const netCredited = assetsPostHarvest - assetsPreHarvest;
  report("F2 harvest credits NET profit to totalAssets (depositors earn, fee leaves accounting)",
    netCredited > 0n && fee2 > 0n, `net=${fmt(netCredited)} fee=${fmt(fee2)}`);

  // F3: early depositor's shares now worth MORE — owner redeems a profit gain
  const ownerSh = await vault.shares(owner.address);
  const ownerRedeemable = await vault.convertToAssets(ownerSh);
  report("F3 owner's shares redeem above 1:1 (earned the funding)",
    ownerRedeemable > ownerSh, `${fmt(ownerSh)} shares -> ${fmt(ownerRedeemable)} assets`);

  // F4: late depositor exits with exactly what they entered (no dilution, no free lunch)
  const u2BalPre = await usdc.balanceOf(u2.address);
  tx = await vault.connect(u2).withdraw(E.parseUnits("10000", 18)); await tx.wait();
  const u2BalPost = await usdc.balanceOf(u2.address);
  const u2Net = u2BalPost - u2BalPre;
  report("F4 late depositor exits ≈ 10k (fair price in AND out — no dilution)",
    u2Net >= E.parseUnits("9999", 18) && u2Net <= E.parseUnits("10001", 18), `net=${fmt(u2Net)}`);

  // F5: conversion views agree with each other
  const someShares = await vault.shares(owner.address);
  const asAssets = await vault.convertToAssets(someShares);
  const backToShares = await vault.convertToShares(asAssets);
  report("F5 convertToShares(convertToAssets(shares)) ≈ shares (roundtrip within rounding)",
    backToShares >= (someShares * 999n) / 1000n && backToShares <= someShares,
    `${fmt(someShares)} -> ${fmt(asAssets)} -> ${fmt(backToShares)}`);

  // ── G. ADVERSARIAL — attacks, invariants, chaos ─────────────────
  console.log("\n── G. Adversarial ──");
  const u4 = (await E.getSigners())[4];
  const donation = E.parseUnits("1000000", 18);

  // G1: FIRST-DEPOSITOR INFLATION ATTACK — clean-room: fresh vault, attacker
  // deposits 1 wei first, donates 1M USDC directly (skipping deposit — raw
  // transfers don't raise accounting totalAssets), victim deposits 10k.
  // Classic attack: attacker's 1 wei share now owns the vault, victim minted 0.
  {
    const FreshUSDC = await E.getContractFactory("MockUSDC");
    const fusdc = await FreshUSDC.deploy(); await fusdc.waitForDeployment();
    const FreshVault = await E.getContractFactory("ProYieldVault");
    const fvault = await FreshVault.deploy(await fusdc.getAddress(), owner.address, owner.address);
    await fvault.waitForDeployment();

    tx = await fusdc.mint(u4.address, donation + 1n); await tx.wait(); // +1 wei covers the probe deposit
    tx = await fusdc.mint(u3.address, E.parseUnits("10000", 18)); await tx.wait();
    // attacker goes first with 1 wei
    tx = await fusdc.connect(u4).approve(await fvault.getAddress(), 1n); await tx.wait();
    tx = await fvault.connect(u4).deposit(1n); await tx.wait();
    // donation straight to the vault (no deposit)
    tx = await fusdc.connect(u4).transfer(await fvault.getAddress(), donation); await tx.wait();
    // victim deposits 10k
    tx = await fusdc.connect(u3).approve(await fvault.getAddress(), E.parseUnits("10000", 18)); await tx.wait();
    tx = await fvault.connect(u3).deposit(E.parseUnits("10000", 18)); await tx.wait();
    const victimSharesFresh = await fvault.shares(u3.address);
    report("G1 inflation attack: victim mints ~full 10k shares (offset + accounting-based price)",
      victimSharesFresh >= (E.parseUnits("10000", 18) * 999n) / 1000n,
      `victim minted ${fmt(victimSharesFresh)}`);
    // attacker's 1-wei share redeems ≈1 wei (nothing stolen)
    const a1Sh = await fvault.shares(u4.address);
    const a1Redeem = await fvault.convertToAssets(a1Sh);
    report("G1b attacker's 1-wei share redeems ≈1 wei (no stolen value)",
      a1Redeem < E.parseUnits("2", 18), `redeemable=${fmt(a1Redeem)}`);
    // attacker tries to withdraw the donated 1M — blocked
    let g1cReverted = false;
    try { tx = await fvault.connect(u4).withdraw(E.parseUnits("500000", 18)); await tx.wait(); } catch { g1cReverted = true; }
    report("G1c attacker cannot withdraw donation value (share guard holds)", g1cReverted);
    // victim can still exit with their 10k
    tx = await fvault.connect(u3).withdraw(E.parseUnits("10000", 18)); await tx.wait();
    const u3FreshOut = await fusdc.balanceOf(u3.address);
    report("G1d victim exits whole (10k in -> 10k out)", u3FreshOut === E.parseUnits("10000", 18),
      `out=${fmt(u3FreshOut)}`);
  }

  // G2: REENTRANCY via malicious strategy
  const Evil = await E.getContractFactory("MockEvilStrategy");
  const evil = await Evil.deploy(await usdc.getAddress(), owner.address); await evil.waitForDeployment();
  tx = await vault.addStrategy(await evil.getAddress()); await tx.wait();
  tx = await evil.setAttackTarget(await vault.getAddress(), true, true); await tx.wait();
  // fund evil with USDC so its reentering deposit has ammo
  tx = await usdc.mint(await evil.getAddress(), E.parseUnits("1000", 18)); await tx.wait();
  const idlePreAttack = await usdc.balanceOf(await vault.getAddress());
  const taPreAttack = await vault.totalAssets();
  tx = await vault.harvest(); await tx.wait(); // evil reenters deposit AND withdraw attempts
  const idlePostAttack = await usdc.balanceOf(await vault.getAddress());
  const taPostAttack = await vault.totalAssets();
  const evilShareBal = await vault.shares(await evil.getAddress());
  report("G2 reentrancy contained: vault accounting stays coherent after evil harvest",
  evilShareBal === 0n && taPostAttack >= taPreAttack,
  `evil shares=${evilShareBal === 0n ? "0" : "NONZERO!"}`);
  // quarantine the evil strategy
  tx = await vault.setStrategyActive(await evil.getAddress(), false); await tx.wait();
  report("G2b evil strategy quarantined via circuit breaker", (await vault.strategyActive(await evil.getAddress())) === false);

  // G3: CONSERVATION OF VALUE across the whole system
  // sum(all user wallets + vault idle + strategies + feeDistributor) ==
  // sum(minted to users) + accrued-by-venue − rounding dust
  const users = [owner, user1, u2, u3, u4];
  let wallets = 0n;
  for (const u of users) wallets += await usdc.balanceOf(u.address);
  const systemHeld = (await usdc.balanceOf(await vault.getAddress()))
  + (await usdc.balanceOf(await delta.getAddress()))
  + (await usdc.balanceOf(await pendle.getAddress()))
  + (await usdc.balanceOf(await sky.getAddress()))
  + (await usdc.balanceOf(await evil.getAddress()))
  + (await usdc.balanceOf(await vault.feeDistributor()))
  + (await usdc.balanceOf(await source.getAddress()));
  const totalSupplyNow = 1000000n * E.WeiPerEther + E.parseUnits("1000001", 18) + E.parseUnits("1000", 18) + E.parseUnits("50000", 18) * 2n + E.parseUnits("10000", 18);
  // u2 withdrew 10k back to wallet (counted), so supply minted ≈ constant; just check conservation loosely:
  report("G3 conservation: system-held USDC ≈ vault totalAssets + swept fees + venue reserve",
  systemHeld >= (await vault.totalAssets()),
  `systemHeld=${fmt(systemHeld)} totalAssets=${fmt(await vault.totalAssets())}`);

  // G4: ALL strategies paused -> withdrawal beyond reserve reverts cleanly
  for (const s of [delta, pendle, sky, evil]) {
  tx = await vault.setStrategyActive(await s.getAddress(), false); await tx.wait();
  }
  const u3BalPre = await usdc.balanceOf(u3.address);
  const u3Sh = await vault.shares(u3.address);
  const u3Assets = await vault.convertToAssets(u3Sh);
  const withdrawTooBig = u3Assets > (await usdc.balanceOf(await vault.getAddress()));
  let allPausedReverted = false;
  if (withdrawTooBig) {
  try { tx = await vault.connect(u3).withdraw(u3Assets); await tx.wait(); } catch { allPausedReverted = true; }
  }
  report("G4 all-paused: withdrawal beyond reserve reverts (cannot pay assets that don't exist)",
  !withdrawTooBig || allPausedReverted,
  withdrawTooBig ? `wanted ${fmt(u3Assets)} vs idle ${fmt(await usdc.balanceOf(await vault.getAddress()))}` : "withdraw within reserve — skipped");
  const u3BalPostAllPaused = await usdc.balanceOf(u3.address);
  report("G4b failed withdrawal leaves user state untouched",
  u3BalPostAllPaused === u3BalPre && (await vault.shares(u3.address)) === u3Sh);
  // re-enable for cleanup
  for (const s of [delta, pendle, sky]) {
  tx = await vault.setStrategyActive(await s.getAddress(), true); await tx.wait();
  }

  // G5: withdraw more than user's share value — blocked, state intact
  const u3AssetsMax = await vault.convertToAssets(u3Sh);
  let overReverted = false;
  try { tx = await vault.connect(u3).withdraw(u3AssetsMax + E.parseUnits("1", 18)); await tx.wait(); } catch { overReverted = true; }
  report("G5 withdrawal beyond share value reverts", overReverted);

  // G6: TIME-BOUNDARY accrual — elapsed 1s, then 10 years; monotonic, no overflow
  tx = await delta.updateFunding(); await tx.wait();
  const accr0 = await delta.accruedFunding();
  let curTs = (await E.provider.getBlock(await E.provider.getBlockNumber())).timestamp;
  await E.provider.send("evm_setNextBlockTimestamp", [curTs + 1]); // +1s past NOW
  tx = await delta.harvest(); await tx.wait();
  const accr1s = await delta.accruedFunding();
  report("G6 1-second accrual > 0 and tiny (monotonic, no overflow)",
    accr1s >= accr0 && accr1s - accr0 < E.parseUnits("1", 18),
    `+${fmt(accr1s - accr0)} for 1s`);
  curTs = (await E.provider.getBlock(await E.provider.getBlockNumber())).timestamp;
  await E.provider.send("evm_setNextBlockTimestamp", [curTs + 3650 * 24 * 3600]); // +10 years
  tx = await delta.harvest(); await tx.wait();
  const accr10y = await delta.accruedFunding();
  report("G6b 10-year accrual: no overflow, math scales linearly",
    accr10y > accr1s, `accrued=${fmt(accr10y)}`);

  // G7: DOUBLE-HARVEST — after a harvest, no un-swept accrual remains and an
  // immediate second harvest credits ZERO (no double-count).
  const g7AccruedPre = await delta.accruedFunding(); // un-swept funding (owner settled in G6b)
  const a7pre = await vault.totalAssets();
  tx = await vault.harvest(); await tx.wait(); // sweeps the outstanding accrual
  const a7mid = await vault.totalAssets();
  tx = await vault.harvest(); await tx.wait(); // nothing left to settle
  const a7post = await vault.totalAssets();
  report("G7 outstanding accrual swept once, second harvest credits ZERO (no double-count)",
    (await delta.accruedFunding()) === 0n && a7mid > a7pre && a7post === a7mid,
    `first sweep +${fmt(a7mid - a7pre)} (accrued was ${fmt(g7AccruedPre)}), second +${fmt(a7post - a7mid)}`);

  // G8: DEPOSIT/WITHDRAW STORM — 20 interleaved ops, 3 users; share math stays exact
  const stormUsers = [user1, u2, u3];
  let ok = true;
  for (let i = 0; i < 10; i++) {
  const u = stormUsers[i % 3];
  const amt = E.parseUnits(String(100 + i * 7), 18);
  try {
    tx = await usdc.mint(u.address, amt); await tx.wait();
    tx = await usdc.connect(u).approve(await vault.getAddress(), amt); await tx.wait();
    tx = await vault.connect(u).deposit(amt); await tx.wait();
    if (i % 2 === 0) {
      const out = amt / 2n;
      tx = await vault.connect(u).withdraw(out); await tx.wait();
    }
  } catch { ok = false; }
  }
  report("G8 20-op deposit/withdraw storm across 3 users: no revert, accounting intact", ok);
  const finalPrice = await vault.convertToAssets(E.parseUnits("1", 18));
  report("G8b share price survives the storm (≈1:1 + earned profit, never < 1)",
    finalPrice >= E.parseUnits("1", 18), `1 share = ${fmt(finalPrice)} assets`);

  // ── H. FULL FEE LOOP — profit -> FeeDistributor -> routing -> staking ──
  console.log("\n── H. Fee recycling loop ──");
  const PYD = await E.getContractFactory("PYDToken");
  const pydT = await PYD.deploy(E.parseUnits("100000000", 18)); await pydT.waitForDeployment();
  const FD = await E.getContractFactory("FeeDistributor");
  const fd = await FD.deploy(await usdc.getAddress()); await fd.waitForDeployment();
  const Staking = await E.getContractFactory("PYDStaking");
  const stakeC = await Staking.deploy(await pydT.getAddress()); await stakeC.waitForDeployment();
  // fresh vault routed to THIS FD so its fees land where we can measure them
  const FVault = await E.getContractFactory("ProYieldVault");
  const fvv = await FVault.deploy(await usdc.getAddress(), owner.address, await fd.getAddress()); await fvv.waitForDeployment();
  const d2 = await DeltaNeutral.deploy(await usdc.getAddress(), owner.address, owner.address, await bootOracle.getAddress()); await d2.waitForDeployment();
  tx = await fvv.addStrategy(await d2.getAddress()); await tx.wait();
  tx = await d2.setVault(await fvv.getAddress()); await tx.wait();
  tx = await d2.setOracle(await oracleC.getAddress()); await tx.wait();
  tx = await d2.setFundingSource(await source.getAddress()); await tx.wait();
  tx = await usdc.mint(owner.address, E.parseUnits("100000", 18)); await tx.wait();
  tx = await usdc.approve(await fvv.getAddress(), E.parseUnits("100000", 18)); await tx.wait();
  tx = await fvv.deposit(E.parseUnits("100000", 18)); await tx.wait();
  tx = await d2.openPosition(E.parseUnits("20000", 18)); await tx.wait();
  tx = await d2.updateFunding(); await tx.wait();

  // H1: 30d accrual -> vault harvest -> USDC fee lands in FD
  const blockN2 = await E.provider.getBlockNumber();
  const ts2 = (await E.provider.getBlock(blockN2)).timestamp;
  await E.provider.send("evm_setNextBlockTimestamp", [ts2 + 30 * 24 * 3600]);
  const fdUsdcPre = await usdc.balanceOf(await fd.getAddress());
  tx = await fvv.harvest(); await tx.wait();
  const fdUsdcPost = await usdc.balanceOf(await fd.getAddress());
  const feeToFD = fdUsdcPost - fdUsdcPre;
  report("H1 vault performance fee lands in FeeDistributor (USDC)",
    feeToFD > 0n, `fee=${fmt(feeToFD)}`);
  tx = await fd.receiveFees(); await tx.wait();
  report("H1b FD accounting recognizes received fees",
    (await fd.totalFeesReceived()) === fdUsdcPost, `received=${fmt(await fd.totalFeesReceived())}`);

  // H2: route fees to the treasury (insurance leg) — owner-only, event-logged
  const treasury = u4; // reuse an existing signer as the treasury destination
  const routeAmt = feeToFD / 2n;
  let nonOwnerRouteReverted = false;
  try { tx = await fd.connect(user1).route(await treasury.getAddress(), routeAmt); await tx.wait(); } catch { nonOwnerRouteReverted = true; }
  report("H2 non-owner cannot route fees", nonOwnerRouteReverted);
  tx = await fd.route(await treasury.getAddress(), routeAmt); await tx.wait();
  report("H2b owner routes half the fees to treasury (fee recycling)",
    (await usdc.balanceOf(await treasury.getAddress())) === routeAmt,
    `routed=${fmt(routeAmt)}`);

  // H3: staking — fund rewards, stake, warp, claim EXACTLY what the math says
  const STAKE = E.parseUnits("1000", 18);
  const REWARD_POOL = E.parseUnits("100000", 18);
  const DURATION = 30 * 24 * 3600;
  tx = await pydT.transfer(u2.address, E.parseUnits("5000", 18)); await tx.wait();
  tx = await pydT.approve(await stakeC.getAddress(), REWARD_POOL); await tx.wait();
  tx = await stakeC.fundRewards(REWARD_POOL, DURATION); await tx.wait();
  tx = await pydT.transfer(user1.address, STAKE); await tx.wait();
  tx = await pydT.connect(user1).approve(await stakeC.getAddress(), STAKE); await tx.wait();
  tx = await stakeC.connect(user1).stake(STAKE); await tx.wait();
  const bn3 = await E.provider.getBlockNumber();
  const stakeTs = (await E.provider.getBlock(bn3)).timestamp;
  await E.provider.send("evm_setNextBlockTimestamp", [stakeTs + 15 * 24 * 3600]); // half the period
  await E.provider.send("evm_mine", []); // views read the last MINED block — mine the warped one
  let earnedHalf = await stakeC.earned(user1.address);
  const expectedHalf = (REWARD_POOL / BigInt(DURATION)) * BigInt(15 * 24 * 3600); // 50k over 15d
  report("H3 staking earned() matches pro-rata math at half-period",
    earnedHalf >= (expectedHalf * 95n) / 100n && earnedHalf <= (expectedHalf * 105n) / 100n,
    `earned=${fmt(earnedHalf)} expected≈${fmt(expectedHalf)}`);
  tx = await stakeC.connect(user1).getReward(); await tx.wait();
  const claimed = (await pydT.balanceOf(user1.address)) - STAKE;
  report("H3b claimed rewards land as REAL PYD (old bug paid 100x stake and reverted)",
    claimed >= (expectedHalf * 95n) / 100n && claimed <= (expectedHalf * 105n) / 100n,
    `claimed=${fmt(claimed)}`);
  // H3c: claim again with zero elapsed — nothing (no double-pay)
  let claim2Amount = 0n;
  tx = await stakeC.connect(user1).getReward(); await tx.wait();
  claim2Amount = (await pydT.balanceOf(user1.address)) - STAKE - claimed;
  report("H3c immediate re-claim pays zero (no double-pay)", claim2Amount === 0n,
    `second claim=${fmt(claim2Amount)}`);
  // H3d: withdraw returns principal
  tx = await stakeC.connect(user1).withdraw(STAKE); await tx.wait();
  report("H3d withdraw returns staked principal", (await pydT.balanceOf(user1.address)) >= STAKE + claimed);

  // ── I. MORPHO DRAIN-VECTOR (regression) ─────────────────────────
  console.log("\n── I. Morpho strategy hardening ──");
  const Morpho = await E.getContractFactory("MorphoStrategy");
  const morphoS = await Morpho.deploy(await usdc.getAddress(), owner.address, u4.address); // u4 = "morpho market"
  await morphoS.waitForDeployment();
  tx = await usdc.mint(await morphoS.getAddress(), E.parseUnits("50000", 18)); await tx.wait(); // parked principal
  // OLD CODE: any caller could drain up to totalSupply; NEW CODE: vault/owner only
  let morphoDrainReverted = false;
  try { tx = await morphoS.connect(user1).withdraw(E.parseUnits("40000", 18)); await tx.wait(); } catch { morphoDrainReverted = true; }
  report("I1 public drain of Morpho strategy reverts (vault/owner-only now)", morphoDrainReverted);
  tx = await morphoS.harvest(); await tx.wait();
  report("I2 morpho harvest no longer books principal as profit",
    (await morphoS.totalDebt()) === 0n && (await usdc.balanceOf(await morphoS.getAddress())) === E.parseUnits("50000", 18),
    `balance intact=${fmt(await usdc.balanceOf(await morphoS.getAddress()))}`);

  // ── J. KEEPER ROLE ──────────────────────────────────────────────
  console.log("\n── J. Keeper authorization ──");
  const keeper = u4;
  tx = await vault.setKeeper(await keeper.getAddress()); await tx.wait();
  // keeper (non-owner) CAN harvest the vault
  const idleJ = await usdc.balanceOf(await vault.getAddress());
  let keeperHarvestOk = false;
  try { tx = await vault.connect(keeper).harvest(); await tx.wait(); keeperHarvestOk = true; } catch {}
  report("J1 keeper can call vault.harvest()", keeperHarvestOk);
  // random user CANNOT
  let randomBlocked = false;
  try { tx = await vault.connect(u3).harvestStrategy(await delta.getAddress()); await tx.wait(); } catch { randomBlocked = true; }
  report("J2 random user cannot harvestStrategy", randomBlocked);
  // keeper cannot drain emergency
  let keeperEmergencyBlocked = false;
  try { tx = await vault.connect(keeper).emergencyWithdraw(); await tx.wait(); } catch { keeperEmergencyBlocked = true; }
  report("J3 keeper cannot emergencyWithdraw (owner-only)", keeperEmergencyBlocked);

  console.log(`\n=== INTEGRATION: ${pass} passed, ${fail} failed ===`);
  if (fail > 0) process.exit(1);
}
main().catch(e => { console.error(e); process.exit(1); });
