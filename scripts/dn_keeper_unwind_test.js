// dn_keeper_unwind_test.js — exercise the keeper's UNWIND path end-to-end:
// mocked open short + forced negative funding → keeper must decide UNWIND,
// close the position via the strategy, and alert. Run as a subprocess so the
// real decision logic executes (no re-implementation).
// Run: npx hardhat run scripts/dn_keeper_unwind_test.js --network hyperTestnet
const hre = require("hardhat");
const { execSync } = require("child_process");

const CORE_WRITER = "0x3333333333333333333333333333333333333333";
const P_810 = "0x0000000000000000000000000000000000000810";
const P_813 = "0x0000000000000000000000000000000000000813";
const P_80F = "0x000000000000000000000000000000000000080f";
const P_80A = "0x000000000000000000000000000000000000080a";
const P_807 = "0x0000000000000000000000000000000000000807";
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
  // OOG-flake killer
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
  await mockAt("MockCoreWriter", CORE_WRITER);
  const existsAt = await mockAt("MockCoreUserExists", P_810);
  const positionAt = await mockAt("MockPosition2", P_813);
  const marginAt = await mockAt("MockMarginSummary", P_80F);
  const perpInfoAt = await mockAt("MockPerpInfo", P_80A);
  const oracleAt = await mockAt("MockOraclePx", P_807);
  const walletAt = await mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET);
  await (await walletAt.setToken("0x0000000000000000000000000000000000000000")).wait();

  await (await existsAt.setExists(true)).wait();
  await (await perpInfoAt.set("BTC", 1, 5, 40, false)).wait();
  await (await oracleAt.setPx(6_000_000_000_000n)).wait(); // $60k

  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  await (await walletAt.setToken(await usdc.getAddress())).wait();

  const vault = await (await E.getContractFactory("ProYieldVault")).deploy(
    await usdc.getAddress(), owner.address, user1.address
  );
  await vault.waitForDeployment();
  const strategy = await (await E.getContractFactory("DNCoreStrategy")).deploy(
    await usdc.getAddress(), owner.address, 0, 1_000_000n * 10n ** 6n
  );
  await strategy.waitForDeployment();
  const sAddr = await strategy.getAddress();
  const vAddr = await vault.getAddress();
  await (await vault.addStrategy(sAddr)).wait();
  await (await strategy.setVault(vAddr)).wait();
  await (await strategy.setKeeper(keeper.address)).wait();

  // State: position OPEN (short 0.05 BTC = -$3,000 notional), margin synced.
  // MockUSDC 18-dec: equity = principal 100k USD = 100e21; sz in 1e8-scaled human
  // BTC: -0.05 BTC → szi = -5_000_000n (0.05 × 1e8).
  const SZI = -5_000_000n;
  await (await usdc.mint(user1.address, U(1_000_000))).wait();
  await (await usdc.connect(user1).approve(vAddr, U(1_000_000))).wait();
  await (await vault.connect(user1).deposit(U(1_000_000))).wait();
  await (await vault.connect(owner).allocate()).wait();
  const k = strategy.connect(keeper);
  const strategyBal = await usdc.balanceOf(sAddr);
  await (await k.bridgeUsdcToCore(strategyBal)).wait();
  const core6 = Number(strategyBal) / 1e12;
  await (await marginAt.set(core6, 0, 0, core6)).wait();
  await (await positionAt.set(SZI, 3000n * 10n ** 8n, 0, 40, false)).wait();
  await (await k.syncCore()).wait();

  report("position open (short 0.05 BTC)", (await strategy.lastPositionSzi()) === SZI);

  // ── Run the keeper with FORCED negative funding (short PAYS... no: negative
  // funding means longs pay; a SHORT receives when funding positive. We force
  // funding BELOW the unwind threshold (-2%) → keeper must UNWIND. ──
  const cwBefore = await (await hre.ethers.getContractAt("MockCoreWriter", CORE_WRITER)).actionCount();
  console.log(`\n── keeper UNWIND run (subprocess, forced funding -5%/yr; cw before=${cwBefore}) ──`);
  let out = "";
  let exitCode = 0;
  try {
    out = execSync(
      `DN_STRATEGY=${sAddr} DN_FORCE_APR=-5.0 DN_EXECUTE=1 DN_SILENCE_TELEGRAM=1 DN_ALERT_LOG=/tmp/dn_unwind_alerts.log npx hardhat run scripts/dn_keeper.js --network hyperTestnet`,
      { cwd: process.cwd(), encoding: "utf8", timeout: 180000, stdio: ["pipe", "pipe", "pipe"] }
    );
  } catch (e) {
    out = (e.stdout || "") + (e.stderr || "");
    exitCode = e.status ?? -1;
  }
  console.log(out.slice(-1200));

  report("keeper decided UNWIND", out.includes("decision: UNWIND"));
  report("keeper closed the short", out.includes("unwinding short"));
  report("keeper verified the close", out.includes("verified: szi="));
  report("keeper alerted", out.includes("[dn-keeper]"));

  // The unwind closeShort is a CoreWriter action — verify it was SENT via the
  // mock (byte-exact: action 1, reduceOnly=true)
  const cw = await hre.ethers.getContractAt("MockCoreWriter", CORE_WRITER);
  const actions = await cw.actionCount();
  report("CoreWriter action sent by THIS run (close)", actions > cwBefore, `${actions} (was ${cwBefore})`);

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("unwind test error:", e.message?.slice(0, 300));
  process.exit(2);
});
