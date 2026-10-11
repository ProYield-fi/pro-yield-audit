// dn_keeper_hedge_sizing_test.js — A1 regression (security review t_3a89fe76).
//
// The spot hedge order used to be sized to EXACTLY the short. HL charges the
// spot fee in the BASE asset, so an exact-size IOC under-fills by the fee and
// leaves an un-closeable sub-$10 net-short residual (observed: requested 0.14
// HYPE, filled 0.13 + 0.000091 fee → 0.010091 short ≈ $0.85, 7.1%).
//
// This drives the keeper in EXECUTE mode through a fresh OPEN with NO spot hedge
// present, so the hedge-buy branch fires, and asserts the requested size covers
// the short INCLUDING the base-asset fee, rounded UP to one lot (tiny net-long).
//
// Run: npx hardhat run scripts/dn_keeper_hedge_sizing_test.js --network hyperTestnet
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

const SNAP = "/tmp/dn_hedge_sizing_snap.json";
const ALERTS = "/tmp/dn_hedge_sizing_alerts.log";

// Expected A1 size: short 0.25 BTC (szDec 5) → 25,000,000 (1e8). pxScale 1e5 →
// one lot 1e3. target = 25,000,000 × (10000+15)/10000 = 25,037,500 → ceil to
// 1e3 = 25,038,000 (a 38e-6 BTC net-long — safe side).
const SHORT_1E8 = 25_000_000n;
const EXPECT_SZ = 25_038_000n;
const SPOT_ASSET_BTC = 10142n; // 10000 + pair 142

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

  console.log("── mocks + deployment (fresh OPEN, NO hedge) ──");
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

  await (await walletAt.setToken(E.ZeroAddress)).wait();
  await (await spotBalAt.set(0n, 0n, 0n)).wait();          // NO spot hedge held
  await (await spotPxAt.setPx(91_727_000n)).wait();         // live-ish HYPE/BTC mark
  await (await marginAt.set(0, 0, 0, 0)).wait();
  await (await positionAt.set(0n, 0n, 0, 0, false)).wait();
  await (await existsAt.setExists(false)).wait();
  await (await perpInfoAt.set("BTC", 1, 5, 40, false)).wait();
  await (await oracleAt.setPx(600_000n)).wait();            // $60k BTC

  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  await (await walletAt.setToken(await usdc.getAddress())).wait();

  const vault = await (await E.getContractFactory("ProYieldVault")).deploy(
    await usdc.getAddress(), owner.address, user1.address
  );
  await vault.waitForDeployment();
  const strategy = await (await E.getContractFactory("DNCoreStrategy")).deploy(
    await usdc.getAddress(), owner.address, 0, 100_000n * 10n ** 6n
  );
  await strategy.waitForDeployment();
  const sAddr = await strategy.getAddress();
  const vAddr = await vault.getAddress();
  await (await vault.addStrategy(sAddr)).wait();
  await (await strategy.setVault(vAddr)).wait();
  await (await strategy.setKeeper(keeper.address)).wait();
  await (await strategy.setSpotConfig(142, 197, 100000n)).wait();

  await (await usdc.mint(user1.address, U(100))).wait();
  await (await usdc.connect(user1).approve(vAddr, U(100))).wait();
  await (await vault.connect(user1).deposit(U(100))).wait();
  await (await vault.connect(owner).allocate()).wait();

  const cwBefore = await cw.actionCount();
  const depBefore = await walletAt.depositCount();

  fs.writeFileSync(SNAP, JSON.stringify({
    generated_utc: new Date().toISOString(),
    blend: { allocation: { DELTA_NEUTRAL: { weight: 0.15 } } },
  }));

  // Emulate the venue reacting to the keeper's actions (mock chain is inert).
  const order = [];
  let existsFlipped = false, marginSet = false, positionSet = false, hedgeSet = false;
  let polling = true;
  const poller = (async () => {
    while (polling) {
      try {
        if (!existsFlipped && (await walletAt.depositCount()) > depBefore) {
          await (await existsAt.connect(user1).setExists(true)).wait();
          existsFlipped = true; order.push("bridge");
        }
        const acDelta = (await cw.actionCount()) - cwBefore;
        if (!marginSet && acDelta >= 1n) {
          await (await marginAt.connect(user1).set(15_000_000, 0, 0, 15_000_000)).wait();
          marginSet = true; order.push("perp");
        }
        if (!positionSet && acDelta >= 2n) {
          await (await positionAt.connect(user1).set(-25_000n, 0, 0, 40, false)).wait();
          positionSet = true; order.push("open");
        }
        if (!hedgeSet && acDelta >= 3n) {
          // filled hedge = requested − base-asset fee (net covers the short)
          await (await spotBalAt.connect(user1).set(25_037_000n, 0, 0)).wait();
          hedgeSet = true; order.push("hedge");
        }
      } catch { /* transient */ }
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
  let out = "";
  child.stdout.on("data", (d) => { out += d.toString(); });
  child.stderr.on("data", (d) => { out += d.toString(); });
  const rc = await new Promise((res) => child.on("close", res));
  polling = false;
  await poller;
  console.log(out.slice(-1800));

  report("A1: keeper exited 0", rc === 0, `exit ${rc}`);
  report("A1: hedge-buy branch fired", out.includes("buying spot hedge gap"));
  report("A1: log names the base-asset fee buffer + round-up",
    out.includes("base-asset fee, rounded up to one lot"));

  const raw = await cw.lastAction();
  const payload = "0x" + raw.slice(10); // drop 0x + 4-byte (0x01 + actionId 1)
  const [asset, isBuy, , sz] = E.AbiCoder.defaultAbiCoder().decode(
    ["uint32", "bool", "uint64", "uint64", "bool", "uint8", "uint128"], payload);
  report("A1: last action is the spot BUY for the hedge pair",
    asset === SPOT_ASSET_BTC && isBuy === true, `asset=${asset} isBuy=${isBuy}`);
  report("A1: requested size covers the short (net-long after fee)",
    sz >= SHORT_1E8, `sz=${sz} short=${SHORT_1E8}`);
  report("A1: fee-inclusive size rounds up to one lot (25,038,000)",
    sz === EXPECT_SZ, `sz=${sz}`);
  report("A1: hedge verified after buy (no 'still short' alert)",
    out.includes("verified hedge") && !out.includes("hedge still short after buy"));

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("hedge-sizing test error:", e.message?.slice(0, 400));
  process.exit(2);
});
