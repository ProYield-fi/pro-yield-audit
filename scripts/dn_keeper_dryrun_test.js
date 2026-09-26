// dn_keeper_dryrun_test.js — exercise the FULL keeper decision path against
// the mocked anvil: deploy strategy + vault, bridge in, sync, and confirm the
// keeper (imported as a child process) reaches the right decision DRY-RUN.
// Run: npx hardhat run scripts/dn_keeper_dryrun_test.js --network hyperTestnet
const hre = require("hardhat");
const { execSync } = require("child_process");

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

  console.log("── mocks + deployment ──");
  const coreWriterAt = await mockAt("MockCoreWriter", CORE_WRITER);
  const existsAt = await mockAt("MockCoreUserExists", P_810);
  const positionAt = await mockAt("MockPosition2", P_813);
  const marginAt = await mockAt("MockMarginSummary", P_80F);
  const perpInfoAt = await mockAt("MockPerpInfo", P_80A);
  const oracleAt = await mockAt("MockOraclePx", P_807);
  const spotBalAt = await mockAt("MockSpotBalance", P_801);
  const spotPxAt = await mockAt("MockSpotPx", P_808);
  const walletAt = await mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET);
  await (await walletAt.setToken("0x0000000000000000000000000000000000000000")).wait(); // shared-anvil reset
  await (await spotBalAt.set(0n, 0n, 0n)).wait();
  await (await spotPxAt.setPx(0n)).wait();

  await (await existsAt.setExists(true)).wait();
  await (await perpInfoAt.set("BTC", 1, 5, 40, false)).wait();
  // Perp px raw = human × 10^(6−szDecimals) (live-verified) → $60k BTC = 600_000.
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
  // Roster gate: BTC spot config must match dn_roster.json (142/197/1e5) or
  // the keeper's config guard blocks the OPEN.
  await (await strategy.setSpotConfig(142, 197, 100000n)).wait();

  // User deposit 1,000,000 USD → vault totalAssets = 1M → target sleeve =
  // 1M × 0.15 = 150k USD. Deploy 90% of it: 135k short notional.
  await (await usdc.mint(user1.address, U(1_000_000))).wait();
  await (await usdc.connect(user1).approve(vAddr, U(1_000_000))).wait();
  await (await vault.connect(user1).deposit(U(1_000_000))).wait();

  // Allocate: vault → strategy (per-strategy split)
  await (await vault.connect(owner).allocate()).wait();

  // Bridge some USDC to Core (simulating prior keeper work)
  const k = strategy.connect(keeper);
  const strategyBal = await usdc.balanceOf(sAddr);
  await (await k.bridgeUsdcToCore(strategyBal)).wait();
  // Sync: mock margin = what we bridged (no PnL yet)
  const core6 = Number(strategyBal) / 1e12; // coreScale 1e12
  await (await marginAt.set(core6, 0, 0, core6)).wait();
  await (await k.syncCore()).wait();

  report("vault totalAssets = 1,000,000 USD", (await vault.totalAssets()) === U(1_000_000));
  report("strategy bridged principal to Core", (await strategy.corePrincipal6()) > 0n);

  // ── Run the keeper DRY-RUN against this state ──
  console.log("\n── keeper dry-run (subprocess) ──");
  const out = execSync(
    `DN_STRATEGY=${sAddr} DN_FORCE_APR=8.0 DN_SILENCE_TELEGRAM=1 DN_ALERT_LOG=/tmp/dn_dryrun_alerts.log npx hardhat run scripts/dn_keeper.js --network hyperTestnet`,
    { cwd: process.cwd(), encoding: "utf8", timeout: 120000, stdio: ["pipe", "pipe", "pipe"] }
  );
  console.log(out);

  report("keeper prints vault totalAssets", out.includes("vault: totalAssets = 1000000.00 USD"));
  report("keeper reads scout DN weight", out.includes("DN weight"));
  report("keeper computes target notional 150,000", out.includes("target notional 150000.00 USD"));
  report("keeper shows position drift vs target", out.includes("drift"));
  report("keeper is dry-run (no sends)", out.includes("dryRun=true"));
  report("keeper decided OPEN (roster config matches)", out.includes("decision: OPEN"));

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("dryrun test error:", e.message?.slice(0, 300));
  process.exit(2);
});
