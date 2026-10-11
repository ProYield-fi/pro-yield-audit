// dn_keeper_hedgedprofit_test.js — A3 keeper regression (security review t_3a89fe76).
//
// The profit path must be measured on the honest ALL-LEGS Core basis
// (perp equity + Core spot USDC + spot hedge) — not perp alone, which reads 0
// while a hedge is held so BRIDGE_PROFIT never fires (book #1 live weeks with
// realized=0/swept=0). This drives the keeper DRY-RUN against a hedged sleeve
// where perp equity < principal but all-legs equity > principal, and proves:
//   • with the all-legs basis enabled → decision BRIDGE_PROFIT (funding realized)
//   • with the change INERT (default, live posture) → legacy perp-only basis,
//     coreProfit6 == 0, decision is NOT BRIDGE_PROFIT (nothing fires unguarded)
//
// Run: npx hardhat run scripts/dn_keeper_hedgedprofit_test.js --network hyperTestnet
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

const SNAP = "/tmp/dn_hedgedprofit_snap.json";
const ALERTS = "/tmp/dn_hedgedprofit_alerts.log";

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

  console.log("── mocks + deployment (hedged sleeve, perp < principal) ──");
  await mockAt("MockCoreWriter", CORE_WRITER);
  const existsAt = await mockAt("MockCoreUserExists", P_810);
  const positionAt = await mockAt("MockPosition2", P_813);
  const marginAt = await mockAt("MockMarginSummary", P_80F);
  const perpInfoAt = await mockAt("MockPerpInfo", P_80A);
  const oracleAt = await mockAt("MockOraclePx", P_807);
  const spotBalAt = await mockAt("MockSpotBalance", P_801);
  const spotPxAt = await mockAt("MockSpotPx", P_808);
  const walletAt = await mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET);

  await (await walletAt.setToken(E.ZeroAddress)).wait();
  await (await spotBalAt.set(0n, 0n, 0n)).wait();
  await (await spotPxAt.setPx(0n)).wait();
  // FLAT position: mock storage PERSISTS across suites on the shared anvil, and
  // dn_keeper_unwind_test leaves a nonzero szi at 0x813 — setSpotConfig() below
  // reverts DNCore__NotFlat against it (masked as "transaction execution
  // reverted" by the OOG-fallback in the signer patch above).
  await (await positionAt.set(0n, 0n, 0, 40, false)).wait();

  await (await existsAt.setExists(true)).wait();
  await (await perpInfoAt.set("BTC", 1, 5, 40, false)).wait();
  await (await oracleAt.setPx(600_000n)).wait(); // $60k BTC

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

  // $1,000,000 TVL → 900,000 to the strategy (10% reserve) → principal 900e6.
  await (await usdc.mint(user1.address, U(1_000_000))).wait();
  await (await usdc.connect(user1).approve(vAddr, U(1_000_000))).wait();
  await (await vault.connect(user1).deposit(U(1_000_000))).wait();
  await (await vault.connect(owner).allocate()).wait();

  const k = strategy.connect(keeper);
  // Bridge a CONTROLLED amount (the vault allocated ~900k; leave the rest idle).
  await (await k.bridgeUsdcToCore(U(60))).wait();
  const principal6 = 60_000_000; // U(60)/1e12 → $60 in 6dp
  await (await k.syncCore()).wait();
  report("principal bridged to Core", (await strategy.corePrincipal6()) === BigInt(principal6));

  // Hedged sleeve: perp equity BELOW principal, all-legs (perp + hedge) ABOVE it.
  // hedge value = 50,000 × 100,000,000 / 1e5 = 50e6 ($50) → all-legs = $70.
  await (await marginAt.set(20_000_000, 0, 0, 20_000_000)).wait();   // perp $20
  await (await spotPxAt.setPx(100_000_000n)).wait();
  await (await spotBalAt.setToken(197n, 50_000n, 0n, 0n)).wait();    // hedge token
  await (await positionAt.set(-1124n, 0, 0, 40, false)).wait();      // a live short
  await (await k.syncCore()).wait();
  report("perp-only equity < principal (the defect trigger)",
    (await strategy.coreEquity6()) === 20_000_000n && (await strategy.corePrincipal6()) === BigInt(principal6));
  const allLegs = (await strategy.coreEquity6()) + BigInt(await strategy.coreSpotUsdc6()) + BigInt(await strategy.spotValue6());
  report("all-legs Core equity > principal (profit exists)", allLegs > BigInt(principal6), `allLegs=${allLegs}`);

  fs.writeFileSync(SNAP, JSON.stringify({
    generated_utc: new Date().toISOString(),
    blend: { allocation: { DELTA_NEUTRAL: { weight: 0.25 } } },
  }));

  const baseEnv = `DN_SILENCE_TELEGRAM=1 DN_ALERT_LOG=${ALERTS} SCOUT_SNAPSHOT=${SNAP}`;
  const run = (extra) => execSync(
    `DN_STRATEGY=${sAddr} DN_FORCE_APR=8.0 ${extra} ${baseEnv} npx hardhat run scripts/dn_keeper.js --network hyperTestnet`,
    { cwd: process.cwd(), encoding: "utf8", timeout: 120000, stdio: ["pipe", "pipe", "pipe"] }
  );

  // ── A. INERT (live posture): legacy perp-only basis, nothing fires ──
  console.log("\n── A. default (DN_ALL_LEGS_PROFIT unset) — must stay inert ──");
  const inertOut = run("");
  console.log(inertOut);
  report("A: basis is the legacy perp-only one", inertOut.includes("profit basis: perp-only (legacy/inert)"));
  report("A: coreProfit6 == 0 while hedged", /coreProfit6=0\b/.test(inertOut));
  report("A: BRIDGE_PROFIT does NOT fire", !inertOut.includes("decision: BRIDGE_PROFIT"));

  // ── B. ENABLED: all-legs basis realizes the hedged funding profit ──
  console.log("\n── B. DN_ALL_LEGS_PROFIT=1 — realizes on the all-legs basis ──");
  const onOut = run("DN_ALL_LEGS_PROFIT=1");
  console.log(onOut);
  report("B: basis is ALL-LEGS", onOut.includes("profit basis: ALL-LEGS"));
  report("B: coreProfit6 > 0 while hedged", !/coreProfit6=0\b/.test(onOut));
  report("B: decision BRIDGE_PROFIT (funding realized)", onOut.includes("decision: BRIDGE_PROFIT"));
  report("B: dry-run — no sends", onOut.includes("no sends (dry-run or nothing to do)"));

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("hedged-profit test error:", e.message?.slice(0, 400));
  process.exit(2);
});
