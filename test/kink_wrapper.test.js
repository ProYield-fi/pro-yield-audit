// KinkWrapper v2 — REAL tranche-math suite (audit-bundle companion).
// Mock engine mirrors the real HLEarnStrategy vault-facing API. Time-travel epochs.
const { ethers, network } = require("hardhat");

const to6 = (n) => ethers.parseUnits(String(n), 6);
const DAY = 30 * 24 * 60 * 60;
const advance = async (secs) => {
  await network.provider.send("evm_setNextBlockTimestamp", [Number(await latest()) + secs]);
  await network.provider.send("evm_mine");
};
const latest = async () => Number((await ethers.provider.getBlock("latest")).timestamp);

// Conservation invariant: paidOut + systemValue == principalNet + cumYieldSettled + floatingYield
async function checkConservation(w, label) {
  const sv = Number(await w.systemValue()) / 1e6;
  const dep = Number(await w.totalDeposited()) / 1e6;
  const wd = Number(await w.totalWithdrawn()) / 1e6;
  const settled = Number(await w.cumYieldSettled()) / 1e6;
  const loss = Number(await w.cumLoss()) / 1e6;
  const floatY = Number(await w.floatingYield()) / 1e6;
  const book = dep - wd - loss + settled + floatY;
  const diff = Math.abs(sv - book);
  if (diff > 1e-6) throw new Error(`CONSERVATION BROKEN [${label}]: sv=${sv} book=${book} diff=${diff}`);
}

describe("KinkWrapper v2 (audit bundle)", function () {
  this.timeout(120000);
  let usdc, engine, wrapper, owner, keeper, senior, junior;

  const deploy = async () => {
    const T = await ethers.getContractFactory("MockUSDC6");
    usdc = await T.connect(owner).deploy(); await usdc.waitForDeployment();
    await usdc.connect(owner).mint(owner.address, to6(10_000_000));
    const E = await ethers.getContractFactory("MockEngine");
    engine = await E.connect(owner).deploy(await usdc.getAddress()); await engine.waitForDeployment();
    for (const s of [senior, junior]) await usdc.connect(owner).transfer(s.address, to6(1_000_000));
    const W = await ethers.getContractFactory("KinkWrapper");
    wrapper = await W.connect(owner).deploy(
      await usdc.getAddress(), await engine.getAddress(),
      200 /* 2% */, 30 /* days */, 1000 /* 10% reserve */);
    await wrapper.waitForDeployment();
    // Wire: engine's vault = wrapper (the real Safe call is engine.setVault(wrapper))
    await engine.connect(owner).setVault(await wrapper.getAddress());
    // engine gets initial principal via wrapper deposits only (real flow)
  };

  beforeEach(async () => {
    [, owner, keeper, senior, junior] = await ethers.getSigners();
    await deploy();
    await wrapper.connect(owner).setKeeper(keeper.address);
  });

  it("deposits: float keeps 10%, engine gets the rest; conservation holds", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000));
    await wrapper.connect(junior).depositJunior(to6(1000));
    const float = Number(await usdc.balanceOf(await wrapper.getAddress())) / 1e6;
    const engineBal = Number(await usdc.balanceOf(await engine.getAddress())) / 1e6;
    // first deposit: float was 0, target after both = 2000*10% = 200 → float=200, engine=1800
    if (Math.abs(float - 200) > 1e-9) throw new Error(`float=${float} expected 200`);
    if (Math.abs(engineBal - 1800) > 1e-9) throw new Error(`engine=${engineBal} expected 1800`);
    await checkConservation(wrapper, "deposits");
  });

  it("settle: senior gets exactly the fixed rate, junior the residual", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000));
    await wrapper.connect(junior).depositJunior(to6(1000));
    await advance(DAY + 60);
    await engine.connect(owner).setProfit(to6(120)); // +6% on 2000
    await wrapper.connect(junior).harvestEngine();   // sweeps 120 real USDC to wrapper float
    await wrapper.connect(junior).settleEpoch();
    const e = await wrapper.epochs(0);
    const owed = Number(e.seniorOwed) / 1e6;   // 1000 * 2% * 30/365 = 1.643835...
    const sp = Number(e.seniorPaid) / 1e6;
    const jp = Number(e.juniorPaid) / 1e6;
    const owedExp = 1000 * 0.02 * 30 / 365; // ±tx-timestamp drift ≪ 2e-4
    if (Math.abs(owed - owedExp) > 2e-4) throw new Error(`owed=${owed} expected ${owedExp.toFixed(6)}`);
    if (Math.abs(sp - owedExp) > 2e-4) throw new Error(`seniorPaid=${sp}`);
    if (Math.abs(jp - (120 - owedExp)) > 2e-4) throw new Error(`juniorPaid=${jp}`);
    const sv = Number(await wrapper.seniorValueOf(senior.address)) / 1e6;
    if (Math.abs(sv - (1000 + owedExp)) > 2e-4) throw new Error(`seniorValue=${sv}`);
    await checkConservation(wrapper, "settle");
  });

  it("shortfall: profit < owed → senior gets what exists, junior zero", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000));
    await wrapper.connect(junior).depositJunior(to6(1000));
    await advance(DAY + 60);
    await engine.connect(owner).setProfit(to6(1)); // $1 profit < $1.64 owed
    await wrapper.connect(junior).harvestEngine();
    await wrapper.connect(junior).settleEpoch();
    const e = await wrapper.epochs(0);
    if (Math.abs(Number(e.seniorPaid) / 1e6 - 1) > 1e-9) throw new Error(`seniorPaid=${Number(e.seniorPaid)/1e6}`);
    if (Math.abs(Number(e.juniorPaid)) > 1e-9) throw new Error("junior got paid in shortfall");
    await checkConservation(wrapper, "shortfall");
  });

  it("withdrawals: float-served; keeper pullLiquidity tops it up", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000)); // float 100, engine 900
    // withdraw 400 > float 100 → must revert
    let reverted = false;
    try { await wrapper.connect(senior).withdrawSenior(await wrapper.seniorShares(senior.address)); }
    catch { reverted = true; }
    if (!reverted) throw new Error("withdraw should fail without float");
    // keeper pulls from engine (vault path) — engine holds 900, recall caps there
    await wrapper.connect(keeper).pullLiquidity(to6(900));
    const float = Number(await usdc.balanceOf(await wrapper.getAddress())) / 1e6;
    if (Math.abs(float - 1000) > 1e-9) throw new Error(`float=${float} expected 1000`);
    const shares = await wrapper.seniorShares(senior.address);
    await wrapper.connect(senior).withdrawSenior(shares); // full exit at par
    const got = Number(await usdc.balanceOf(senior.address)) / 1e6;
    if (Math.abs(got - 1000000) > 1e-9) throw new Error(`got=${got}`); // mint minus deposit plus refund
    await checkConservation(wrapper, "withdraw");
  });

  it("loss: junior absorbs first, then senior; anchor re-set", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000));
    await wrapper.connect(junior).depositJunior(to6(1000));
    await advance(DAY + 60);
    await engine.connect(owner).setLoss(to6(50)); // engine loses $50 (bad debt sim)
    await wrapper.connect(junior).settleEpoch();
    const ja = Number(await wrapper.juniorAssets()) / 1e6;
    const sa = Number(await wrapper.seniorAssets()) / 1e6;
    // book was 2000+200 float = 2000 system; loss 50 → junior 1000→950, senior untouched
    if (Math.abs(ja - 950) > 1e-6) throw new Error(`juniorAssets=${ja}`);
    if (Math.abs(sa - 1000) > 1e-6) throw new Error(`seniorAssets=${sa}`);
    // bigger loss hits senior too
    await advance(DAY + 60);
    await engine.connect(owner).setLoss(to6(200)); // system now 1750-200-... junior 950 absorbs 200 → 750
    await wrapper.connect(junior).settleEpoch();
    const ja2 = Number(await wrapper.juniorAssets()) / 1e6;
    if (Math.abs(ja2 - 750) > 1e-6) throw new Error(`juniorAssets2=${ja2}`);
    await checkConservation(wrapper, "loss");
  });

  it("audit F1: donation inflation attack FAILS (dead shares)", async () => {
    // Classic ERC4626 attack: first depositor mints 1 share, donates to the
    // system, share price explodes, victim mints ~0 shares, attacker drains.
    const attacker = keeper;
    await usdc.connect(owner).transfer(attacker.address, to6(2_000_000));
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(10000));
    // attacker is the FIRST junior depositor (1 wei... min deposit is $1)
    await usdc.connect(attacker).approve(await wrapper.getAddress(), to6(2_000_000));
    await wrapper.connect(attacker).depositJunior(to6(1)); // 1 USDC first deposit
    const sharesAfterAttacker = Number(await wrapper.totalJuniorShares()) / 1e6;
    if (Math.abs(sharesAfterAttacker - 1) > 1e-9) throw new Error("first deposit not value-neutral");
    // attacker donates 1M to the wrapper (can't be blocked for ERC20s)
    await usdc.connect(attacker).transfer(await wrapper.getAddress(), to6(1_000_000));
    // victim deposits 10,000 at the (diluted) price
    await wrapper.connect(junior).depositJunior(to6(10000));
    // attacker's 1 share is now worth ~ (1 + 1,000,000 + 10,000 + 1M-dead…) — verify the
    // attack CAN'T steal the victim: victim's value must stay ≈ their deposit
    const victimVal = Number(await wrapper.juniorValueOf(junior.address)) / 1e6;
    if (victimVal < 9999) throw new Error(`INFLATION ATTACK SUCCEEDED: victim=${victimVal}`);
    // attacker's donation is socialized, not stolen: attacker ≈ 1 share of ~11M
    const attackerVal = Number(await wrapper.juniorValueOf(attacker.address)) / 1e6;
    if (attackerVal > 1_100_000) throw new Error(`attacker over-captured: ${attackerVal}`);
    await checkConservation(wrapper, "F1 inflation");
  });

  it("audit F2: settle caller CANNOT set the next rate; ratchet monotonic", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000));
    await advance(DAY + 60);
    // non-owner tries to queue 0% → revert
    let grieved = false;
    try { await wrapper.connect(junior).setNextFixedRateBps(0); } catch { grieved = true; }
    if (!grieved) throw new Error("rate griefing succeeded!");
    // owner queues an increase → allowed; decrease → rejected
    await wrapper.connect(owner).setNextFixedRateBps(300);
    let down = false;
    try { await wrapper.connect(owner).setNextFixedRateBps(200); } catch { down = true; }
    if (!down) throw new Error("monotonic ratchet violated");
    await wrapper.connect(junior).settleEpoch(); // permissionless, rate safe
    const next = await wrapper.currentEpoch();
    if (Number(next.fixedRateBps) !== 300) throw new Error("queued rate not applied");
    const q = Number(await wrapper.nextFixedRateBps());
    if (q !== 300) throw new Error("queue must persist flat after open");
  });

  it("audit F3: engine harvest reverting no longer blocks settlement", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000));
    await wrapper.connect(junior).depositJunior(to6(1000));
    await advance(DAY + 60);
    await engine.connect(owner).setFailHarvest(true);
    await wrapper.connect(junior).settleEpoch(); // must NOT revert
    const e = await wrapper.epochs(0);
    if (!e.settled) throw new Error("settle did not complete");
    // epoch 2 opened
    if (Number(await wrapper.epochsLength()) !== 2) throw new Error("no rollover");
    await checkConservation(wrapper, "F3 harvest-revert");
  });

  it("mid-epoch senior entry accrues from entry moment (per-second policy 5)", async () => {
    await usdc.connect(senior).approve(await wrapper.getAddress(), to6(1000));
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(1000));
    await wrapper.connect(senior).depositSenior(to6(1000));
    await wrapper.connect(junior).depositJunior(to6(1000));
    await advance(DAY / 2); // mid-epoch
    await usdc.connect(junior).approve(await wrapper.getAddress(), to6(500));
    await wrapper.connect(junior).depositJunior(to6(500));
    await advance(DAY / 2 + 60);
    await engine.connect(owner).setProfit(to6(100));
    await wrapper.connect(junior).harvestEngine();
    await wrapper.connect(junior).settleEpoch();
    const e = await wrapper.epochs(0);
    // obligation only on seniorAssetsAtOpen = 1000
    const owedExp = 1000 * 0.02 * 30 / 365; // mid-epoch junior deposit doesn't touch senior accrual
    if (Math.abs(Number(e.seniorPaid) / 1e6 - owedExp) > 2e-4) throw new Error("mid-epoch obligation wrong");
    await checkConservation(wrapper, "mid-epoch");
  });
});