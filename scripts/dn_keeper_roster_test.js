// dn_keeper_roster_test.js — roster-gated keeper behavior against the mocked
// anvil (subprocess runs of the REAL keeper):
//   A. asset not in roster → keeper REFUSES loudly (exit 2)
//   B. ZEC strategy, matching spot config → resolves coin, OPEN (dry)
//   C. ZEC asset + HYPE spot config (half-applied rotation) → HOLD + alert
//   D. rotation advice: board with stronger roster alt → alert, then dedup
//   E. rotation advice: no alt clears the bar → no alert
// Run: npx hardhat run scripts/dn_keeper_roster_test.js --network hyperTestnet
const hre = require("hardhat");
const { execSync } = require("child_process");
const fs = require("fs");

const CORE_WRITER = "0x3333333333333333333333333333333333333333";
const P_810 = "0x0000000000000000000000000000000000000810";
const P_813 = "0x0000000000000000000000000000000000000813";
const P_80F = "0x000000000000000000000000000000000000080f";
const P_80A = "0x000000000000000000000000000000000000080a";
const P_807 = "0x0000000000000000000000000000000000000807";
const P_801 = "0x0000000000000000000000000000000000000801";
const P_808 = "0x0000000000000000000000000000000000000808";
const TESTNET_DEPOSIT_WALLET = "0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206";

let pass = 0, fail = 0;
const report = (name, ok, detail = "") => {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
};

async function mockAt(name, fixedAddr) {
  const F = await hre.ethers.getContractFactory(name);
  const c = await F.deploy();
  await c.waitForDeployment();
  const code = await hre.ethers.provider.getCode(await c.getAddress());
  await hre.network.provider.send("anvil_setCode", [fixedAddr, code]);
  return await hre.ethers.getContractAt(name, fixedAddr);
}

async function main() {
  // OOG-flake killer (same as other suites)
  {
    const { HardhatEthersSigner } = require("@nomicfoundation/hardhat-ethers/signers");
    const origSend = HardhatEthersSigner.prototype.sendTransaction;
    HardhatEthersSigner.prototype.sendTransaction = async function (tx) {
      if (tx.gasLimit == null) {
        try {
          const est = await hre.ethers.provider.estimateGas({ ...tx, from: this.address });
          tx = { ...tx, gasLimit: est + 21000n };
        } catch {
          tx = { ...tx, gasLimit: 1_000_000n };
        }
      }
      return origSend.call(this, tx);
    };
  }
  const E = hre.ethers;
  const [owner, keeper, user1] = await E.getSigners();
  const U = (n) => E.parseUnits(String(n), 18);

  // ── snapshots for the keeper's sizing + rotation advice ──
  const SNAP_BASE = "/tmp/dn_roster_test_snap_base.json";
  const SNAP_BOARD = "/tmp/dn_roster_test_snap_board.json";
  const SNAP_WEAK = "/tmp/dn_roster_test_snap_weak.json";
  const MARKER = "/tmp/dn_roster_test_marker.json";
  const ALERTS = "/tmp/dn_roster_test_alerts.log";
  const baseSnap = { generated_utc: new Date().toISOString(), blend: { allocation: { DELTA_NEUTRAL: { weight: 0.15 } } } };
  fs.writeFileSync(SNAP_BASE, JSON.stringify(baseSnap));
  const row = (name, mean, pos, min, cap) => ({
    dex: "main", name, funding_apr: 11, mean_30d_apr: mean, pos_30d_pct: pos,
    min_30d_apr: min, max_30d_apr: 40, oi_usd: cap * 20, cap_usd: cap, harvest_usd_yr: (cap * mean) / 100, hours: 720,
  });
  fs.writeFileSync(SNAP_BOARD, JSON.stringify({
    ...baseSnap,
    hyperliquid_funding: { capacity_board: { board: [
      row("BTC", 9.3, 92.9, -14.0, 158e6), row("ETH", 10.1, 95.7, -15.1, 148e6),
      row("XMR", 47.3, 98.5, -88.7, 4e6), row("ZEC", 12.4, 96.2, -64.5, 38e6),
      row("HYPE", 9.1, 88.8, -39.2, 94e6),
    ] } },
  }));
  fs.writeFileSync(SNAP_WEAK, JSON.stringify({
    ...baseSnap,
    hyperliquid_funding: { capacity_board: { board: [
      row("BTC", 9.3, 92.9, -14.0, 158e6), row("ETH", 10.1, 95.7, -15.1, 148e6),
      row("SOL", 7.3, 85.6, -25.0, 34e6),
    ] } },
  }));

  console.log("── mocks + shared setup ──");
  await mockAt("MockCoreWriter", CORE_WRITER);
  const existsAt = await mockAt("MockCoreUserExists", P_810);
  const positionAt = await mockAt("MockPosition2", P_813);
  const marginAt = await mockAt("MockMarginSummary", P_80F);
  const perpInfoAt = await mockAt("MockPerpInfo", P_80A);
  const oracleAt = await mockAt("MockOraclePx", P_807);
  const spotBalAt = await mockAt("MockSpotBalance", P_801);
  const spotPxAt = await mockAt("MockSpotPx", P_808);
  const walletAt = await mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET);
  await (await walletAt.setToken("0x0000000000000000000000000000000000000000")).wait();
  await (await existsAt.setExists(true)).wait();
  await (await spotBalAt.set(0n, 0n, 0n)).wait(); // no spot hedge held (dry decisions only)
  await (await spotPxAt.setPx(0n)).wait();

  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  await (await walletAt.setToken(await usdc.getAddress())).wait();

  // full strategy+vault deployment with a given perp asset + spot config
  async function deployCase(asset, spotPair, spotToken, pxScale, perpName, szDec, maxLev, pxRaw) {
    await (await positionAt.set(0n, 0n, 0, 0, false)).wait(); // flat
    await (await perpInfoAt.set(perpName, 1, szDec, maxLev, false)).wait();
    await (await oracleAt.setPx(pxRaw)).wait();
    const vault = await (await E.getContractFactory("ProYieldVault")).deploy(
      await usdc.getAddress(), owner.address, user1.address
    );
    await vault.waitForDeployment();
    const strategy = await (await E.getContractFactory("DNCoreStrategy")).deploy(
      await usdc.getAddress(), owner.address, asset, 100_000n * 10n ** 6n
    );
    await strategy.waitForDeployment();
    const sAddr = await strategy.getAddress();
    const vAddr = await vault.getAddress();
    await (await vault.addStrategy(sAddr)).wait();
    await (await strategy.setVault(vAddr)).wait();
    await (await strategy.setKeeper(keeper.address)).wait();
    if (spotPair) await (await strategy.setSpotConfig(spotPair, spotToken, pxScale)).wait();
    await (await usdc.mint(user1.address, U(1_000_000))).wait();
    await (await usdc.connect(user1).approve(vAddr, U(1_000_000))).wait();
    await (await vault.connect(user1).deposit(U(1_000_000))).wait();
    await (await vault.connect(owner).allocate()).wait();
    const k = strategy.connect(keeper);
    const bal = await usdc.balanceOf(sAddr);
    await (await k.bridgeUsdcToCore(bal)).wait();
    const core6 = Number(bal) / 1e12;
    await (await marginAt.set(core6, 0, 0, core6)).wait();
    await (await k.syncCore()).wait();
    return { strategy, vault, sAddr, vAddr };
  }

  function runKeeper(env, expectFail = false) {
    const base = `DN_SILENCE_TELEGRAM=1 DN_ALERT_LOG=${ALERTS} DN_ROTATION_MARKER=${MARKER}`;
    try {
      const out = execSync(
        `${env} ${base} npx hardhat run scripts/dn_keeper.js --network hyperTestnet`,
        { cwd: process.cwd(), encoding: "utf8", timeout: 120000, stdio: ["pipe", "pipe", "pipe"] }
      );
      if (expectFail) { report("keeper exited non-zero", false, "unexpected success"); return ""; }
      return out;
    } catch (e) {
      const out = (e.stdout || "") + (e.stderr || "");
      if (expectFail) { report(`keeper refused (exit ${e.status ?? "?"})`, true); return out; }
      console.log(out.slice(-800));
      report("keeper ran clean", false, `exit ${e.status ?? "?"}`);
      return out;
    }
  }

  // ── A. asset not in roster → refuse ──
  {
    const { sAddr } = await deployCase(999, null, null, null, "WHAT", 2, 10, 1000n);
    console.log("\n── A. keeper vs asset=999 (not in roster) ──");
    const out = runKeeper(`DN_STRATEGY=${sAddr}`, true);
    report("A: refusal mentions roster", out.includes("not in DN roster"),
      (out.match(/not in DN roster[^\n]*/) || [""])[0].slice(0, 80));
  }

  // ── B. ZEC resolution → OPEN (dry) ──
  {
    const { sAddr } = await deployCase(214, 272, 419, 1000000n, "ZEC", 2, 10, 15368000n);
    console.log("\n── B. ZEC strategy, matching spot config ──");
    const out = runKeeper(`DN_STRATEGY=${sAddr} DN_FORCE_APR=12.0 SCOUT_SNAPSHOT=${SNAP_BASE}`);
    report("B: funding line names ZEC", out.includes("funding: 12.00% annualized (HlPerp, ZEC)"));
    report("B: no config mismatch", !out.includes("config: ⚠"));
    report("B: decision OPEN", out.includes("decision: OPEN"));
    report("B: dry-run (no sends)", out.includes("dryRun=true"));
  }

  // ── C. half-applied rotation (ZEC asset + HYPE spot config) → HOLD + alert ──
  {
    const { sAddr } = await deployCase(214, 107, 150, 100000000n, "ZEC", 2, 10, 15368000n);
    console.log("\n── C. ZEC asset + HYPE spot config (mismatch) ──");
    const out = runKeeper(`DN_STRATEGY=${sAddr} DN_FORCE_APR=12.0 SCOUT_SNAPSHOT=${SNAP_BASE}`);
    report("C: config mismatch flagged", out.includes("config: ⚠"));
    report("C: open blocked → HOLD", out.includes("decision: HOLD"));
    report("C: alert queued", out.includes("DN open blocked — spot config mismatch"));
  }

  // ── D. rotation advice fires + dedup ──
  {
    const { sAddr } = await deployCase(0, 142, 197, 100000n, "BTC", 5, 40, 600000n);
    try { fs.unlinkSync(MARKER); } catch { /* fresh */ }
    console.log("\n── D. rotation advice (board: XMR 47.3% best) ──");
    const out = runKeeper(`DN_STRATEGY=${sAddr} DN_FORCE_APR=9.0 SCOUT_SNAPSHOT=${SNAP_BOARD}`);
    report("D: current coin logged", out.includes("rotation: current BTC 9.3%/30d"));
    report("D: best alts listed", out.includes("XMR 47.3%"));
    report("D: alert fired", out.includes("DN ROTATION CANDIDATE") && out.includes("→ XMR"));
    const out2 = runKeeper(`DN_STRATEGY=${sAddr} DN_FORCE_APR=9.0 SCOUT_SNAPSHOT=${SNAP_BOARD}`);
    report("D: dedup on second run", out2.includes("already alerted"));
  }

  // ── E. no alt clears the bar → silent ──
  {
    const { sAddr } = await deployCase(0, 142, 197, 100000n, "BTC", 5, 40, 600000n);
    console.log("\n── E. rotation advice negative ──");
    const out = runKeeper(`DN_STRATEGY=${sAddr} DN_FORCE_APR=9.0 SCOUT_SNAPSHOT=${SNAP_WEAK}`);
    report("E: no alert", !out.includes("DN ROTATION CANDIDATE"));
    report("E: comparison still logged", out.includes("rotation: current BTC"));
  }

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("roster test error:", e.message?.slice(0, 300));
  process.exit(2);
});
