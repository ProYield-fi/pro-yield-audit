// DNCoreStrategy tests — vault wiring + honest accounting on mocked HyperCore.
// Run: npx hardhat run scripts/dn_strategy_tests.js --network hyperTestnet
//
// Flow covered: user deposit -> vault.allocate (plain transfer) -> keeper
// bridge to Core (principal tracked) -> hedge actions -> Core equity sync
// (mocked precompiles) -> bridge-back (principal vs profit split) -> vault
// harvest (sweeps realized profit above buffer, performance fee) -> user
// withdrawal (vault recalls idle from strategy) -> loss case (no fake profit).
//
// Mocks at fixed system addresses via anvil_setCode (same as dn_adapter_tests).
const hre = require("hardhat");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}
async function expectRevert(promise, substr, name) {
  try {
    const tx = await promise;
    if (tx && tx.wait) await tx.wait();
    report(name, false, "did not revert");
  } catch (e) {
    const msg = (e.shortMessage || "") + " " + (e.message || "");
    report(name, msg.includes(substr), msg.includes(substr) ? "" : `wrong reason: ${msg.slice(0, 120)}`);
  }
}

const CORE_WRITER = "0x3333333333333333333333333333333333333333";
const P_810 = "0x0000000000000000000000000000000000000810";
const P_813 = "0x0000000000000000000000000000000000000813";
const P_80F = "0x000000000000000000000000000000000000080f";
const P_80A = "0x000000000000000000000000000000000000080a";
const P_807 = "0x0000000000000000000000000000000000000807";
const TESTNET_DEPOSIT_WALLET = "0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206";

async function mockAt(name, fixedAddr) {
  const F = await hre.ethers.getContractFactory(name);
  const c = await F.deploy();
  await c.waitForDeployment();
  const code = await hre.ethers.provider.getCode(await c.getAddress());
  await hre.network.provider.send("anvil_setCode", [fixedAddr, code]);
  return await hre.ethers.getContractAt(name, fixedAddr);
}

async function main() {
  // OOG-flake killer: pad gas 3x (same as integration_tests.js)
  {
    const { HardhatEthersSigner } = require("@nomicfoundation/hardhat-ethers/signers");
    const origSend = HardhatEthersSigner.prototype.sendTransaction;
    HardhatEthersSigner.prototype.sendTransaction = async function (tx) {
      if (tx.gasLimit == null) {
        try {
          const est = await hre.ethers.provider.estimateGas({ ...tx, from: this.address });
          tx = { ...tx, gasLimit: (est * 3n) + 21000n };
        } catch {
          tx = { ...tx, gasLimit: 1_000_000n };
        }
      }
      return origSend.call(this, tx);
    };
  }
  const E = hre.ethers;
  const [owner, keeper, user1, user2] = await E.getSigners();
  const coder = E.AbiCoder.defaultAbiCoder();
  const U = (n) => E.parseUnits(String(n), 18); // MockUSDC = 18 decimals

  console.log("── mocks + deployment ──");
  const coreWriterAt = await mockAt("MockCoreWriter", CORE_WRITER);
  const existsAt = await mockAt("MockCoreUserExists", P_810);
  const positionAt = await mockAt("MockPosition2", P_813);
  const marginAt = await mockAt("MockMarginSummary", P_80F);
  const perpInfoAt = await mockAt("MockPerpInfo", P_80A);
  const oracleAt = await mockAt("MockOraclePx", P_807);
  const walletAt = await mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET);
  await (await existsAt.setExists(true)).wait();
  await (await perpInfoAt.set("BTC", 1, 5, 40, false)).wait();
  await (await oracleAt.setPx(6_000_000_000_000n)).wait();

  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  await (await walletAt.setToken(await usdc.getAddress())).wait(); // realistic pulls

  const vault = await (await E.getContractFactory("ProYieldVault")).deploy(
    await usdc.getAddress(), owner.address, user1.address // user1 doubles as dummy FeeDistributor
  );
  await vault.waitForDeployment();
  const cap = 100_000n * 10n ** 6n;
  const strategy = await (await E.getContractFactory("DNCoreStrategy")).deploy(
    await usdc.getAddress(), owner.address, 0, cap
  );
  await strategy.waitForDeployment();
  const sAddr = await strategy.getAddress();
  const vAddr = await vault.getAddress();

  await (await vault.addStrategy(sAddr)).wait();
  await (await strategy.setVault(vAddr)).wait();
  await (await strategy.setKeeper(keeper.address)).wait();

  report("coreScale = 1e12 for 18-dec MockUSDC", (await strategy.coreScale()) === 10n ** 12n);
  report("buffer default 1500 bps", (await strategy.bufferBps()) === 1500n);

  // ── 1. Deposit -> allocate (vault plain-transfers; 10% reserve kept) ──
  await (await usdc.mint(user1.address, U(1000))).wait();
  await (await usdc.connect(user1).approve(vAddr, U(1000))).wait();
  await (await vault.connect(user1).deposit(U(1000))).wait();
  await (await vault.allocate()).wait();
  report("allocate: strategy holds 900 (10% vault reserve kept)",
    (await usdc.balanceOf(sAddr)) === U(900) && (await usdc.balanceOf(vAddr)) === U(100));

  // ── 2. Bridge to Core: principal tracked in 6dp, funds actually pulled ──
  const k = strategy.connect(keeper);
  await (await k.bridgeUsdcToCore(U(500))).wait();
  report("bridge-in: corePrincipal6 = 500e6", (await strategy.corePrincipal6()) === 500_000_000n);
  report("bridge-in: funds pulled (strategy 900 -> 400)", (await usdc.balanceOf(sAddr)) === U(400));
  await expectRevert(k.bridgeUsdcToCore.staticCall(1), "sub-6dp dust", "bridge-in dust guard (non-6dp multiple)");

  // ── 3. Core equity sync (mocked precompiles) ──
  await (await marginAt.set(505_000_000n, 0n, 0n, 0n)).wait(); // 505 USDC: principal 500 + 5 profit
  await (await k.syncCore()).wait();
  report("syncCore: equity 505e6 recorded", (await strategy.coreEquity6()) === 505_000_000n);
  report("totalAssets = 505 (Core) + 400 (idle) = 905", (await strategy.totalAssets()) === U(905));

  // ── 4. Bridge back: principal vs profit split at fresh equity ──
  await (await k.bridgeBackToEvm(505_000_000n)).wait();
  const want = E.concat(["0x0100000d", coder.encode(
    ["address", "address", "uint32", "uint32", "uint64", "uint64"],
    ["0x2000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000",
     4294967295, 4294967295, 0, 505_000_000n])]);
  report("bridgeBackToEvm bytes (action 13)", (await coreWriterAt.lastAction()).toLowerCase() === want.toLowerCase());
  report("split: principal reduced to 0, profit 5e6 realized",
    (await strategy.corePrincipal6()) === 0n && (await strategy.profitRealized()) === U(5));
  report("harvestableProfit = 5", (await strategy.harvestableProfit()) === U(5));

  // Simulate Core->EVM credit of the returned funds
  await (await usdc.mint(sAddr, U(505))).wait();
  await (await marginAt.set(0n, 0n, 0n, 0n)).wait();

  // ── 5. Vault harvest: sweeps realized profit above buffer; 10% perf fee ──
  const vaultBalBefore = await usdc.balanceOf(vAddr);
  const fdBefore = await usdc.balanceOf(user1.address);
  const taBefore = await vault.totalAssets();
  await (await vault.harvest()).wait();
  const vaultDelta = (await usdc.balanceOf(vAddr)) - vaultBalBefore;
  const fdDelta = (await usdc.balanceOf(user1.address)) - fdBefore;
  const taDelta = (await vault.totalAssets()) - taBefore;
  report("harvest: 5 swept (net 4.5 stays, 0.5 fee)", vaultDelta === U(4.5) && vaultDelta + fdDelta === U(5));
  report("harvest: 10% perf fee = 0.5 to FeeDistributor", fdDelta === U(0.5));
  report("harvest: net profit raises vault totalAssets (+4.5)", taDelta === U(4.5));
  report("harvest: profitSwept == realized, nothing left",
    (await strategy.profitSwept()) === U(5) && (await strategy.harvestableProfit()) === 0n);
  report("strategy idle after sweep = 900", (await usdc.balanceOf(sAddr)) === U(900));

  // ── 6. Keeper harvest is settle-only (no movement) ──
  const balBeforeKeeperHarvest = await usdc.balanceOf(sAddr);
  await (await k.harvest()).wait();
  report("keeper harvest: no funds moved", (await usdc.balanceOf(sAddr)) === balBeforeKeeperHarvest);

  // ── 7. Loss case: equity below principal -> no fake profit ──
  await (await k.bridgeUsdcToCore(U(300))).wait();
  await (await marginAt.set(290_000_000n, 0n, 0n, 0n)).wait(); // 290 < 300 principal
  await (await k.syncCore()).wait();
  await (await k.bridgeBackToEvm(290_000_000n)).wait();
  report("loss: principal 300->10, profit realized UNCHANGED at 5",
    (await strategy.corePrincipal6()) === 10_000_000n && (await strategy.profitRealized()) === U(5));
  await (await usdc.mint(sAddr, U(290))).wait();
  await (await marginAt.set(0n, 0n, 0n, 0n)).wait();

  // ── 8. User withdrawal: vault recalls idle from the strategy ──
  const u1Before = await usdc.balanceOf(user1.address);
  await (await vault.connect(user1).withdraw(U(200))).wait();
  report("withdraw 200: user paid in full via strategy recall",
    (await usdc.balanceOf(user1.address)) - u1Before === U(200));

  // ── 9. Encodings (spot checks; full set in dn_adapter_tests) ──
  await (await k.moveUsdcToPerp(5_000_000n)).wait();
  let want2 = E.concat(["0x01000007", coder.encode(["uint64", "bool"], [5_000_000n, true])]);
  report("moveUsdcToPerp bytes (action 7)", (await coreWriterAt.lastAction()).toLowerCase() === want2.toLowerCase());

  const px = 6_000_000_000_000n, sz = 100_000_000n;
  await (await k.openShort(0, px, sz, 3)).wait();
  let want3 = E.concat(["0x01000001", coder.encode(
    ["uint32", "bool", "uint64", "uint64", "bool", "uint8", "uint128"],
    [0, false, px, sz, false, 3, 0n])]);
  report("openShort bytes (action 1)", (await coreWriterAt.lastAction()).toLowerCase() === want3.toLowerCase());

  // ── 10. Gates ──
  await expectRevert(strategy.connect(user2).moveUsdcToPerp.staticCall(1_000_000n), "not keeper", "keeper gate");
  await (await strategy.setPaused(true)).wait();
  await expectRevert(k.moveUsdcToPerp.staticCall(1_000_000n), "paused", "pause gate");
  await (await strategy.setPaused(false)).wait();
  await (await existsAt.setExists(false)).wait();
  await expectRevert(k.bridgeBackToEvm.staticCall(1_000_000n), "not initialized", "core-account gate");
  await (await existsAt.setExists(true)).wait();
  await expectRevert(k.openShort.staticCall(0, px, 10_000n * 10n ** 8n, 3), "cap", "notional cap");
  await expectRevert(k.openShort.staticCall(1, px, sz, 3), "wrong asset", "asset whitelist");
  await (await positionAt.set(-5_000_000n, 0n, 0n, 10, false)).wait();
  await expectRevert(strategy.setPerpAsset.staticCall(1), "not flat", "setPerpAsset guard (open position)");
  await (await positionAt.set(0n, 0n, 0n, 10, false)).wait();
  report("permissionless syncCore works", await (async () => { await strategy.syncCore(); return true; })());

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("ORPHAN ERROR:", e.message?.slice(0, 300));
  process.exit(2);
});
