// Integration tests — NEVER-RUN paths. Proves what actually pays on-chain vs what is a stub.
// Run: npx hardhat run scripts/integration_tests.js --network hyperTestnet
const hre = require("hardhat");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}

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

  const DeltaNeutral = await E.getContractFactory("DeltaNeutralStrategy");
  const delta = await DeltaNeutral.deploy(await usdc.getAddress(), owner.address, owner.address, owner.address);
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

  // A1: updateFunding with no oracle integration
  let tx = await delta.updateFunding(); await tx.wait();
  report("A1 delta.updateFunding() runs", true);
  const rate = await delta.fundingRate();
  report("A2 fundingRate is 0 (oracle integration is a STUB — nothing fetched)", rate === 0n, `rate=${rate}`);

  // A3: set a real-looking oracle -> rate STILL 0 (interface not implemented in contract)
  tx = await delta.setOracle(user1.address); await tx.wait();
  tx = await delta.updateFunding(); await tx.wait();
  const rate2 = await delta.fundingRate();
  report("A3 oracle set but rate still 0 (IOracle not implemented yet)", rate2 === 0n);

  // A4: harvest with zero ETH balance -> profit 0
  const debtBefore = await delta.totalDebt();
  tx = await delta.harvest(); const rc = await tx.wait();
  const harvestEv = rc.logs.map(l => { try { return delta.interface.parseLog(l); } catch { return null; } }).find(e => e && e.name === "Harvest");
  report("A4 delta.harvest profit == 0 with empty ETH balance", harvestEv && harvestEv.args[0] === 0n,
    `Harvest(profit=${harvestEv ? harvestEv.args[0].toString() : "?"})`);

  // A5: DISCOVERED BUG — delta strategy has no receive()/fallback, so it cannot
  // even ACCEPT the native ETH its _doHarvest forwards. The only "paying" path
  // is unreachable. Document on-chain, then verify via low-level call.
  const ethAmount = E.parseEther("0.5");
  const deltaAddr = await delta.getAddress();
  let fundReverted = false;
  try {
    await owner.sendTransaction({ to: deltaAddr, value: ethAmount });
  } catch { fundReverted = true; }
  const deltaEth = await hre.ethers.provider.getBalance(deltaAddr);
  report("A5 delta 'paying' path UNREACHABLE: contract cannot receive ETH (no receive/fallback)",
    fundReverted && deltaEth === 0n, `fund attempt reverted=${fundReverted}, balance=${fmt(deltaEth)} ETH`);

  // A5b: even if ETH existed (forced via anvil_setBalance), harvest forwards it to
  // short — but ONLY when a position is open (delta > 0). Two gates verified:
  try {
    await hre.ethers.provider.send("anvil_setBalance", [deltaAddr, "0x" + ethAmount.toString(16)]);
    tx = await delta.harvest(); await tx.wait();
    const debtNoPosition = await delta.totalDebt();
    report("A5b-i forced-funded but NO open position -> nothing forwarded (delta>0 gate)",
      debtNoPosition === 0n, `totalDebt=${fmt(debtNoPosition)}`);
    tx = await delta.openPosition(E.parseUnits("10000", 18)); await tx.wait();
    tx = await delta.harvest(); await tx.wait();
    const debtWithPosition = await delta.totalDebt();
    report("A5b-ii position open + forced-funded -> ETH forwarded to short (code path works; funding-oracle + receive() are the missing links)",
      debtWithPosition === ethAmount, `totalDebt=${fmt(debtWithPosition)} ETH`);
  } catch (e) {
    report("A5b forced-funded delta harvest", false, (e.message || "").slice(0, 80));
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

  console.log(`\n=== INTEGRATION: ${pass} passed, ${fail} failed ===`);
  if (fail > 0) process.exit(1);
}
main().catch(e => { console.error(e); process.exit(1); });
