// dn_keeper_fresh_open_test.js — regression for the 2026-10-09 "BRIDGE_FIRST is
// a no-op" bug: a brand-new DN strategy (its HyperCore account not yet created,
// coreAccountExists=false) must reach OPEN — never the dead BRIDGE_FIRST
// decision that returned before bridging. In execute mode the OPEN path must
// bridge USDC to Core (initializing the account) BEFORE it class-transfers
// margin and opens the short (the ≥1-block sequencing rule).
// Run: npx hardhat run scripts/dn_keeper_fresh_open_test.js --network hyperTestnet
const hre = require("hardhat");
const { execSync, spawn } = require("child_process");
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

const SNAP = "/tmp/dn_fresh_open_snap.json";
const ALERTS = "/tmp/dn_fresh_open_alerts.log";

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
  // OOG-flake killer (same as the other DN suites)
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

  console.log("── mocks + deployment (FRESH Core account) ──");
  await mockAt("MockCoreWriter", CORE_WRITER);
  const existsAt = await mockAt("MockCoreUserExists", P_810);
  const positionAt = await mockAt("MockPosition2", P_813);
  const marginAt = await mockAt("MockMarginSummary", P_80F);
  const perpInfoAt = await mockAt("MockPerpInfo", P_80A);
  const oracleAt = await mockAt("MockOraclePx", P_807);
  const spotBalAt = await mockAt("MockSpotBalance", P_801);
  const spotPxAt = await mockAt("MockSpotPx", P_808);
  const walletAt = await mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET);
  const cw = await E.getContractAt("MockCoreWriter", CORE_WRITER);

  // Reset shared-anvil mock state, then set the FRESH-strategy precondition:
  // the HyperCore account does NOT exist yet.
  await (await walletAt.setToken(E.ZeroAddress)).wait();
  await (await spotBalAt.set(1n * 10n ** 8n, 0, 0)).wait(); // spot hedge present (covers the short)
  await (await spotPxAt.setPx(0n)).wait();
  await (await marginAt.set(0, 0, 0, 0)).wait();
  await (await positionAt.set(0n, 0n, 0, 0, false)).wait();
  await (await existsAt.setExists(false)).wait();
  await (await perpInfoAt.set("BTC", 1, 5, 40, false)).wait();
  await (await oracleAt.setPx(600_000n)).wait(); // $60k BTC (raw = human × 10^(6−szDec))

  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  await (await walletAt.setToken(await usdc.getAddress())).wait();

  const vault = await (await E.getContractFactory("ProYieldVault")).deploy(
    await usdc.getAddress(), owner.address, user1.address
  );
  await vault.waitForDeployment();
  const strategy = await (await E.getContractFactory("DNCoreStrategy")).deploy(
    await usdc.getAddress(), owner.address, 0, 100_000n * 10n ** 6n // asset 0 = BTC
  );
  await strategy.waitForDeployment();
  const sAddr = await strategy.getAddress();
  const vAddr = await vault.getAddress();
  await (await vault.addStrategy(sAddr)).wait();
  await (await strategy.setVault(vAddr)).wait();
  await (await strategy.setKeeper(keeper.address)).wait();
  await (await strategy.setSpotConfig(142, 197, 100000n)).wait(); // BTC roster config

  // $100 TVL → 90 to the strategy. The USDC stays IDLE on EVM (NEVER bridged) —
  // exactly the book-#2 state the bug trapped.
  await (await usdc.mint(user1.address, U(100))).wait();
  await (await usdc.connect(user1).approve(vAddr, U(100))).wait();
  await (await vault.connect(user1).deposit(U(100))).wait();
  await (await vault.connect(owner).allocate()).wait();
  const strategyBal = await usdc.balanceOf(sAddr);
  console.log(`strategy EVM USDC (idle) = ${Number(strategyBal) / 1e18} USD`);

  // The mock CoreWriter / deposit-wallet storage PERSISTS across suites on a
  // shared anvil, so every count assertion must be a DELTA from a baseline.
  const cwBefore = await cw.actionCount();
  const depBefore = await walletAt.depositCount();

  // Sizing snapshot → DN target = 100 × 0.15 = $15.
  fs.writeFileSync(SNAP, JSON.stringify({
    generated_utc: new Date().toISOString(),
    blend: { allocation: { DELTA_NEUTRAL: { weight: 0.15 } } },
  }));

  report("fresh: coreAccountExists() = false", (await strategy.coreAccountExists()) === false);
  report("fresh: no NEW CoreWriter actions", (await cw.actionCount()) === cwBefore);
  report("fresh: nothing bridged", (await walletAt.depositCount()) === depBefore);
  report("fresh: strategy funded on EVM", strategyBal > 0n);

  const baseEnv = `DN_SILENCE_TELEGRAM=1 DN_ALERT_LOG=${ALERTS} SCOUT_SNAPSHOT=${SNAP}`;

  // ── A. dry-run: a fresh strategy must decide OPEN, never a dead BRIDGE_FIRST ──
  console.log("\n── A. keeper dry-run vs fresh strategy ──");
  const dryOut = execSync(
    `DN_STRATEGY=${sAddr} DN_FORCE_APR=8.0 ${baseEnv} npx hardhat run scripts/dn_keeper.js --network hyperTestnet`,
    { cwd: process.cwd(), encoding: "utf8", timeout: 120000, stdio: ["pipe", "pipe", "pipe"] }
  );
  console.log(dryOut);
  report("A: fresh strategy reaches OPEN", dryOut.includes("decision: OPEN"));
  report("A: NO BRIDGE_FIRST no-op decision", !dryOut.includes("BRIDGE_FIRST"));
  report("A: dry-run sends nothing", dryOut.includes("no sends (dry-run or nothing to do)"));
  report("A: sizes from the scout snapshot weight", dryOut.includes("DN weight 0.15 (scout)"));
  report("A: target notional = 15.00 USD", dryOut.includes("target notional 15.00 USD"));
  report("A: no NEW actions after dry-run", (await cw.actionCount()) === cwBefore);
  report("A: no NEW deposits after dry-run", (await walletAt.depositCount()) === depBefore);

  // ── B. execute: bridgeUsdcToCore BEFORE the perp class-transfer / openShort ──
  console.log("\n── B. keeper --execute vs fresh strategy (bridge-before-action) ──");
  // The mock chain cannot know that a bridge CREATES the Core account, that a
  // class-transfer CREDITS perp margin, or that a filled order shows up as a
  // position — so a serial poller emulates those three "the venue reacted"
  // effects only AFTER observing the triggering action. It signs as user1 so it
  // never races the keeper (which signs as signer[0]).
  const order = []; // ordered observation log — proves bridge precedes actions
  let existsFlipped = false, marginSet = false, positionSet = false;
  let polling = true;
  const poller = (async () => {
    while (polling) {
      try {
        if (!existsFlipped && (await walletAt.depositCount()) > depBefore) {
          await (await existsAt.connect(user1).setExists(true)).wait(); // bridge → account exists
          existsFlipped = true; order.push("bridge");
        }
        const acDelta = (await cw.actionCount()) - cwBefore;
        if (!marginSet && acDelta >= 1n) {
          // class-transfer landed → perp margin = the level the keeper expects
          await (await marginAt.connect(user1).set(15_000_000, 0, 0, 15_000_000)).wait();
          marginSet = true; order.push("perp");
        }
        if (!positionSet && acDelta >= 2n) {
          // short filled → position visible (25,000 lots = 0.25 BTC at szDec 5)
          await (await positionAt.connect(user1).set(-25_000n, 0, 0, 40, false)).wait();
          positionSet = true; order.push("open");
        }
      } catch { /* transient read — retry next tick */ }
      await new Promise((r) => setTimeout(r, 150));
    }
  })();

  const child = spawn("npx",
    ["hardhat", "run", "scripts/dn_keeper.js", "--network", "hyperTestnet"],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        DN_STRATEGY: sAddr, DN_FORCE_APR: "8.0", DN_EXECUTE: "1",
        DN_SILENCE_TELEGRAM: "1", DN_ALERT_LOG: ALERTS, SCOUT_SNAPSHOT: SNAP,
      },
    });
  let execOut = "";
  child.stdout.on("data", (d) => { execOut += d.toString(); });
  child.stderr.on("data", (d) => { execOut += d.toString(); });
  const rc = await new Promise((res) => child.on("close", res));
  polling = false;
  await poller;
  console.log(execOut.slice(-2500));

  const deposits = (await walletAt.depositCount()) - depBefore;
  const actions = (await cw.actionCount()) - cwBefore;
  report("B: keeper exited 0", rc === 0, `exit ${rc}`);
  report("B: bridged USDC to Core (1 new deposit)", deposits === 1n, `${deposits}`);
  report("B: CoreWriter actions sent (>=2)", actions >= 2n, `${actions}`);
  report("B: keeper logged the bridge", execOut.includes("bridging"));
  report("B: keeper logged the perp class-transfer", execOut.includes("class-transfer spot→perp"));
  report("B: keeper logged the open", execOut.includes("opening short"));
  report("B: bridge observed BEFORE the perp action",
    order.indexOf("bridge") !== -1 && order.indexOf("bridge") < order.indexOf("perp"), JSON.stringify(order));
  report("B: perp action observed BEFORE the open",
    order.indexOf("perp") !== -1 && order.indexOf("perp") < order.indexOf("open"), JSON.stringify(order));
  report("B: verified position after open", execOut.includes("verified: szi="));
  report("B: no MISMATCH / exit-4", !execOut.includes("MISMATCH") && !execOut.includes("margin still short"));

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("fresh-open test error:", e.message?.slice(0, 400));
  process.exit(2);
});
