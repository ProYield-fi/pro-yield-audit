// dn_keeper_rebalance_min_test.js — regression for t_c8427d27: the NEAR
// REBALANCE reduce orders reverted "execution reverted" for days (the sleeve
// sat ~+31% over target). Root cause (captured on mainnet): the contract's
// _order() reverts DNCore__BelowMinNotional (selector 0x2f599ebf) whenever the
// order notional is under MIN_ORDER_USD6 ($10, HL's minimum order value). The
// keeper emitted $5.31-$5.88 reduce slices every cycle — guaranteed reverts.
//
// This suite pins the fix on the mocked anvil:
//   A. over-target drift whose correction is < $10  → HOLD, NO order sent, exit 0
//   B. over-target drift whose correction is >= $10 → the reduce IS sent, and
//      the emitted wire fields pass the contract's own check (staticCall)
//   C. the perp margin boundary: equity $0.001 under need (mark-to-market drift
//      on the open leg) must PROCEED, not exit 4
// Run: npx hardhat run scripts/dn_keeper_rebalance_min_test.js --network hyperTestnet
const hre = require("hardhat");
const { spawn } = require("child_process");
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

// NEAR roster entry (scripts/dn_roster.json): asset 74, spotPair 496,
// spotToken 513, pxScale 1e8. The LIVE perp reads szDecimals = 1 for NEAR.
const NEAR_ASSET = 74;
const NEAR_SPOT_PAIR = 496;
const NEAR_SPOT_TOKEN = 513;
const NEAR_PX_SCALE = 100000000n; // 1e8
const NEAR_SZ_DEC = 1;
const ORACLE_PX_RAW = 539450n; // perp raw = human × 10^(6−szDec) → $5.3945
// spot raw = human × 10^(8 − spotSzDecimals); NEAR spot pxScale 1e8 → ×10^6
// (live-verified: spotPx 5378500 with the hedge marked at $5.3785).
const SPOT_PX_RAW = 5394500n; // → $5.3945
const MAX_ACTION_6 = 25n * 10n ** 6n; // $25 per-action cap (live value)
const VAULT_USD = "126.27"; // → target = 126.27 × 0.15 (mandate clamp) = $18.94

const SNAP = "/tmp/dn_rebalance_min_snap.json";
const ALERTS = "/tmp/dn_rebalance_min_alerts.log";

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

/// Decode the CoreWriter limit-order action the mock recorded:
/// encodePacked(uint8 actionType=1, uint24 actionId, abi.encode(asset,isBuy,limitPx,sz,reduceOnly,tif,cloid))
function decodeOrderAction(raw) {
  const body = "0x" + raw.slice(2 + 2 * 4); // drop 0x + 1 byte type + 3 bytes actionId
  const [asset, isBuy, limitPx, sz, reduceOnly, tif] = hre.ethers.AbiCoder.defaultAbiCoder()
    .decode(["uint32", "bool", "uint64", "uint64", "bool", "uint8", "uint128"], body);
  return { asset, isBuy, limitPx, sz, reduceOnly, tif };
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
  const [owner, , user1] = await E.getSigners();
  const U = (n) => E.parseUnits(String(n), 18);

  console.log("── mocks + deployment (NEAR lane, over-target) ──");
  // Labelled setup: this suite shares an anvil with every other suite, so a
  // failure must name the exact step (cross-suite mock-state interactions).
  const tx = async (label, p) => {
    process.stdout.write(`· ${label}\n`);
    const t = await p;
    if (typeof t.waitForDeployment === "function") await t.waitForDeployment();
    else await t.wait();
    return t;
  };

  await tx("mock MockCoreWriter", mockAt("MockCoreWriter", CORE_WRITER));
  const existsAt = await tx("mock MockCoreUserExists", mockAt("MockCoreUserExists", P_810));
  const positionAt = await tx("mock MockPosition2", mockAt("MockPosition2", P_813));
  const marginAt = await tx("mock MockMarginSummary", mockAt("MockMarginSummary", P_80F));
  const perpInfoAt = await tx("mock MockPerpInfo", mockAt("MockPerpInfo", P_80A));
  const oracleAt = await tx("mock MockOraclePx", mockAt("MockOraclePx", P_807));
  const spotBalAt = await tx("mock MockSpotBalance", mockAt("MockSpotBalance", P_801));
  const spotPxAt = await tx("mock MockSpotPx", mockAt("MockSpotPx", P_808));
  const walletAt = await tx("mock MockCoreDepositWallet", mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET));
  const cw = await E.getContractAt("MockCoreWriter", CORE_WRITER);

  // Reset shared-anvil mock state (other suites persist storage here).
  await tx("reset deposit-wallet token", walletAt.setToken(E.ZeroAddress));
  await tx("reset spot balance (default)", spotBalAt.set(0n, 0n, 0n));
  // FLAT position + empty margin: mock storage PERSISTS across suites on the
  // shared anvil, and dn_keeper_unwind_test leaves a nonzero szi at 0x813 —
  // setSpotConfig() below reverts DNCore__NotFlat against it.
  await tx("reset position flat", positionAt.set(0n, 0n, 0, 10, false));
  await tx("reset margin summary", marginAt.set(0n, 0n, 0n, 0n));
  await tx("set hedge token 513", spotBalAt.setToken(NEAR_SPOT_TOKEN, 460000000n, 0n, 0n)); // 4.6 NEAR (1e8 units)
  await tx("zero USDC token 0", spotBalAt.setToken(0n, 0n, 0n, 0n)); // Core spot USDC cash = 0
  await tx("set spot px", spotPxAt.setPx(SPOT_PX_RAW)); // hedge mark $5.3945
  await tx("set core account exists", existsAt.setExists(true));
  await tx("set perp info", perpInfoAt.set("NEAR", 10, NEAR_SZ_DEC, 10, false));
  await tx("set oracle px", oracleAt.setPx(ORACLE_PX_RAW));
  if (fs.existsSync(ALERTS)) fs.unlinkSync(ALERTS);

  const usdc = await tx("deploy MockUSDC", E.getContractFactory("MockUSDC").then((F) => F.deploy()));
  await tx("point deposit wallet at USDC", walletAt.setToken(await usdc.getAddress()));

  const vault = await tx("deploy ProYieldVault",
    E.getContractFactory("ProYieldVault").then(async (F) => F.deploy(await usdc.getAddress(), owner.address, user1.address)));
  const strategy = await tx("deploy DNCoreStrategy",
    E.getContractFactory("DNCoreStrategy").then(async (F) => F.deploy(await usdc.getAddress(), owner.address, NEAR_ASSET, MAX_ACTION_6)));
  const sAddr = await strategy.getAddress();
  const vAddr = await vault.getAddress();
  await tx("vault.addStrategy", vault.addStrategy(sAddr));
  await tx("strategy.setVault", strategy.setVault(vAddr));
  await tx("strategy.setKeeper", strategy.setKeeper(owner.address)); // the keeper subprocess signs as signer[0]
  await tx("strategy.setSpotConfig", strategy.setSpotConfig(NEAR_SPOT_PAIR, NEAR_SPOT_TOKEN, NEAR_PX_SCALE));

  await tx("mint USDC", usdc.mint(user1.address, U(VAULT_USD)));
  await tx("approve vault", usdc.connect(user1).approve(vAddr, U(VAULT_USD)));
  await tx("deposit", vault.connect(user1).deposit(U(VAULT_USD)));
  await tx("vault.allocate", vault.connect(owner).allocate());
  // Principal basis ABOVE the perp equity (so BRIDGE_PROFIT stays inert) but
  // BELOW the all-legs equity (so no phantom loss alert): $20 bridged.
  await tx("bridgeUsdcToCore", strategy.bridgeUsdcToCore(U(20)));

  fs.writeFileSync(SNAP, JSON.stringify({
    generated_utc: new Date().toISOString(),
    blend: { allocation: { DELTA_NEUTRAL: { weight: 0.25 } } },
  }));

  report("strategy order policy readable",
    (await strategy.MIN_ORDER_USD6()) === 10000000n && (await strategy.maxActionUsd6()) === MAX_ACTION_6,
    `min $${Number(await strategy.MIN_ORDER_USD6()) / 1e6} · cap $${Number(await strategy.maxActionUsd6()) / 1e6}`);
  report("principal basis set above perp equity (BRIDGE_PROFIT inert)", (await strategy.corePrincipal6()) === 20000000n,
    `principal6=${await strategy.corePrincipal6()}`);

  const childEnv = {
    ...process.env,
    DN_STRATEGY: sAddr,
    DN_FORCE_APR: "8.0",
    DN_EXECUTE: "1",
    DN_MAX_SLEEVE_PCT: "0.15",
    DN_MARGIN_UTIL_BPS: "2050",
    DN_SILENCE_TELEGRAM: "1",
    DN_ALERT_LOG: ALERTS,
    SCOUT_SNAPSHOT: SNAP,
  };
  // spawn (not execSync): case C runs a poller alongside the keeper, and
  // execSync would block this process's event loop.
  const runKeeper = () => new Promise((resolve) => {
    const child = spawn("npx", ["hardhat", "run", "scripts/dn_keeper.js", "--network", "hyperTestnet"], {
      cwd: process.cwd(), env: childEnv,
    });
    let out = "";
    child.stdout.on("data", (d) => { out += d.toString(); });
    child.stderr.on("data", (d) => { out += d.toString(); });
    child.on("close", (rc) => resolve({ rc, out }));
  });

  // ── A. over target, correction < $10 → HOLD, nothing sent ─────────────────
  console.log("\n── A. reduce slice below the $10 venue minimum ──");
  // 4.6 NEAR short @ $5.3945 = $24.81 vs target $18.94 → drift +31%, gap $5.87
  await (await positionAt.set(-46n, 0n, 0, 10, false)).wait();
  await (await marginAt.set(5000000n, 0n, 0n, 5000000n)).wait();
  const cwBeforeA = await cw.actionCount();
  const A = await runKeeper();
  console.log(A.out.slice(-2200));
  const cwAfterA = await cw.actionCount();
  const alertA = fs.existsSync(ALERTS) ? fs.readFileSync(ALERTS, "utf8") : "";

  report("A: keeper exits 0 (no failure)", A.rc === 0, `exit ${A.rc}`);
  report("A: target notional = $18.94 (15% mandate clamp)", A.out.includes("target notional 18.94 USD"));
  report("A: drift ~+31% vs target detected", /drift 3[01]\.\d\d% vs target/.test(A.out));
  report("A: decision is HOLD (not REBALANCE)", A.out.includes("decision: HOLD (dryRun=false)"));
  report("A: explains the slice is not expressible", A.out.includes("NOT expressible as an order"));
  report("A: names the $10 minimum order value", A.out.includes("minimum order value $10.00"));
  report("A: NO reduce order emitted", !A.out.includes("reducing short by"));
  report("A: no CoreWriter action sent at all", cwAfterA === cwBeforeA, `${cwBeforeA} → ${cwAfterA}`);
  report("A: operator alert queued", alertA.includes("DN rebalance blocked"));

  // ── B. over target, correction >= $10 → reduce IS sent, wire-legal ────────
  console.log("\n── B. reduce slice above the $10 minimum ──");
  // 5.5 NEAR short @ $5.3945 = $29.67 vs target $18.94 → gap $10.73
  await (await positionAt.set(-55n, 0n, 0, 10, false)).wait();
  const cwBeforeB = await cw.actionCount();
  const B = await runKeeper();
  console.log(B.out.slice(-1600));
  const cwAfterB = await cw.actionCount();

  report("B: keeper exits 0", B.rc === 0, `exit ${B.rc}`);
  report("B: decision is REBALANCE", B.out.includes("decision: REBALANCE (dryRun=false)"));
  report("B: reduce order emitted", B.out.includes("reducing short by"));
  report("B: exactly one CoreWriter action (the closeShort)", cwAfterB - cwBeforeB === 1n, `+${cwAfterB - cwBeforeB}`);

  const ord = decodeOrderAction(await cw.lastAction());
  const ordNotional6 = (ord.limitPx * ord.sz) / 10000000000n;
  report("B: emitted order is the reduce (NEAR asset, BUY + reduceOnly)",
    ord.asset === BigInt(NEAR_ASSET) && ord.isBuy === true && ord.reduceOnly === true,
    `asset=${ord.asset} isBuy=${ord.isBuy} reduceOnly=${ord.reduceOnly}`);
  report("B: emitted notional clears the $10 minimum", ordNotional6 >= 10000000n,
    `$${Number(ordNotional6) / 1e6} (sz=${ord.sz} @ px=${ord.limitPx})`);
  // The contract itself must accept the exact wire fields the keeper emitted.
  let accepted = true, why = "";
  try {
    await strategy.closeShort.staticCall(ord.asset, ord.limitPx, ord.sz, ord.tif);
  } catch (e) {
    accepted = false; why = String(e.message || e).slice(0, 160);
  }
  report("B: contract accepts the emitted wire fields (staticCall, no revert)", accepted, why);

  // ── C. margin boundary: $0.001 under need must PROCEED (was exit 4) ───────
  console.log("\n── C. perp margin boundary (mark-drift residual) ──");
  await (await positionAt.set(0n, 0n, 0, 10, false)).wait(); // flat → OPEN
  await (await marginAt.set(5000000n, 0n, 0n, 5000000n)).wait();
  const cwBeforeC = await cw.actionCount();
  // need = floor(18.94e6) × 2050/10000 = 3,882,700 ($3.8827). Emulate the venue:
  // after the leveling class-transfer lands, the perp equity re-reads $0.001
  // UNDER need (unrealized PnL moved) — the old strict `<` blocked at exit 4.
  let polling = true;
  const poller = (async () => {
    let marginSet = false, posSet = false;
    while (polling) {
      try {
        const delta = (await cw.actionCount()) - cwBeforeC;
        if (!marginSet && delta >= 1n) {
          await (await marginAt.connect(user1).set(3881700n, 0n, 0n, 3881700n)).wait();
          marginSet = true;
        }
        if (!posSet && delta >= 2n) {
          await (await positionAt.connect(user1).set(-35n, 0n, 0, 10, false)).wait(); // 3.5 NEAR filled
          posSet = true;
        }
      } catch { /* transient read — retry next tick */ }
      await new Promise((r) => setTimeout(r, 150));
    }
  })();
  const C = await runKeeper();
  polling = false;
  await poller;
  console.log(C.out.slice(-1800));

  report("C: keeper exits 0 (boundary no longer blocks)", C.rc === 0, `exit ${C.rc}`);
  report("C: residual named as within tolerance", /within the \$0\.\d\d tolerance/.test(C.out));
  report("C: no 'margin still short' block", !C.out.includes("margin still short after bridge"));
  report("C: short was opened after the tolerated residual", C.out.includes("opening short:"));

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("rebalance-min test error:", e.message?.slice(0, 400));
  process.exit(2);
});
