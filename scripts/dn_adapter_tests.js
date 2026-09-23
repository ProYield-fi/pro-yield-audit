// DN CoreWriter Adapter tests — mock CoreWriter + read precompiles at the FIXED
// system addresses via anvil_setCode (verified working on this anvil).
// Run: npx hardhat run scripts/dn_adapter_tests.js --network hyperTestnet
//
// NOTE: installs mock code at 0x3333 (CoreWriter), 0x80x/0x81x (precompiles),
// and the testnet CoreDepositWallet address. These persist on the shared anvil;
// no other script uses those addresses. Encoding assertions are byte-exact
// against the documented CoreWriter wire format (version 1 + uint24 action id +
// abi-encoded fields).
const hre = require("hardhat");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}
const CUSTOM_ERRORS = {
  // keccak256("ErrorName()")[:4] — verified against live revert data
  NotKeeper: "0x17315428", Paused: "0xaa3a5cb7", NotInitialized: "0x41ee6c5d",
  ZeroAmount: "0x918a28db", ZeroOrder: "0x8127db6f", BadTif: "0x967e0969",
  BelowMinNotional: "0x2f599ebf", WrongAsset: "0xb2d61bc5", Cap: "0x2e7d1a95",
  ZeroValidator: "0xc7673afa", NotFlat: "0xbdc8ed86", ReadFailed: "0x0ac298f9",
  SubDust: "0xcd67e235", ExceedsBalance: "0x13073609", ExceedsEquity: "0xc91236c2",
  BufferTooHigh: "0xa54871fc", Inactive: "0x6699be5d", NotAuthorized: "0x7cdf2b91",
  DecimalsTooLow: "0x678fa6e4", AdapterZeroKeeper: "0x004b0eb5",
  AdapterZeroUsdc: "0x7da4ddf4", AdapterZeroAmount: "0x7393954e",
};
async function expectRevert(promise, expect, name) {
  // `expect` = custom-error NAME ("Cap") or raw substring for anything else.
  try {
    const tx = await promise;
    if (tx && tx.wait) await tx.wait();
    report(name, false, "did not revert");
  } catch (e) {
    const raw = (e.shortMessage || "") + " " + (e.message || "");
    const data = e.data || (e.info && e.info.error && e.info.error.data) || "";
    const selector = typeof data === "string" ? data.slice(0, 10) : "";
    const wanted = CUSTOM_ERRORS[expect] || "no-selector";
    const match = selector === wanted || raw.includes(expect);
    report(name, match, match ? "" : `wrong reason: ${raw.slice(0, 120)} (selector=${selector})`);
  }
}

const CORE_WRITER = "0x3333333333333333333333333333333333333333";
const P_810 = "0x0000000000000000000000000000000000000810"; // coreUserExists
const P_813 = "0x0000000000000000000000000000000000000813"; // position2
const P_80F = "0x000000000000000000000000000000000000080f"; // margin summary
const P_803 = "0x0000000000000000000000000000000000000803"; // withdrawable
const P_80A = "0x000000000000000000000000000000000000080a"; // perp asset info
const P_807 = "0x0000000000000000000000000000000000000807"; // oracle px
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
  // OOG-flake killer: pad gas 3x on the persistent anvil (same as integration_tests.js)
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
  const coder = E.AbiCoder.defaultAbiCoder();

  console.log("── installing mocks at fixed system addresses ──");
  const coreWriterAt = await mockAt("MockCoreWriter", CORE_WRITER);
  const existsAt = await mockAt("MockCoreUserExists", P_810);
  const positionAt = await mockAt("MockPosition2", P_813);
  const marginAt = await mockAt("MockMarginSummary", P_80F);
  const withdrawableAt = await mockAt("MockWithdrawable", P_803);
  const perpInfoAt = await mockAt("MockPerpInfo", P_80A);
  const oracleAt = await mockAt("MockOraclePx", P_807);
  const walletAt = await mockAt("MockCoreDepositWallet", TESTNET_DEPOSIT_WALLET);
  // Shared anvil: storage survives runs — reset token so deposit() does not
  // attempt a pull the adapter cannot back (set by dn_strategy_tests).
  await (await walletAt.setToken("0x0000000000000000000000000000000000000000")).wait();

  await (await existsAt.setExists(true)).wait();
  await (await perpInfoAt.set("BTC", 1, 5, 40, false)).wait();
  await (await oracleAt.setPx(6_000_000_000_000n)).wait();

  console.log("── deploying adapter ──");
  const usdc = await (await E.getContractFactory("MockUSDC")).deploy();
  await usdc.waitForDeployment();
  const cap = 100_000n * 10n ** 6n; // $100k per action
  const adapter = await (await E.getContractFactory("DNCoreAdapter")).deploy(
    owner.address, keeper.address, await usdc.getAddress(), 0, cap
  );
  await adapter.waitForDeployment();
  const adapterAddr = await adapter.getAddress();
  const a = adapter.connect(keeper);

  // ── Reads ──
  report("coreAccountExists=true (0x810)", (await adapter.coreAccountExists()) === true);
  report("perpSzDecimals=5 (0x80a)", (await adapter.perpSzDecimals()) === 5n);
  report("oraclePx=6e12 (0x807)", (await adapter.oraclePx()) === 6_000_000_000_000n);

  // ── Byte-exact encodings ──
  const px = 6_000_000_000_000n; // $60,000 × 1e8
  const sz = 100_000_000n;       // 1 BTC × 1e8 → $60k notional ≤ cap

  let tx = await a.moveUsdcToPerp(5_000_000n);
  await tx.wait();
  let want = E.concat(["0x01000007", coder.encode(["uint64", "bool"], [5_000_000n, true])]);
  report("moveUsdcToPerp bytes (action 7)", (await coreWriterAt.lastAction()).toLowerCase() === want.toLowerCase());

  tx = await a.openShort(0, px, sz, 3);
  await tx.wait();
  want = E.concat(["0x01000001", coder.encode(
    ["uint32", "bool", "uint64", "uint64", "bool", "uint8", "uint128"],
    [0, false, px, sz, false, 3, 0n])]);
  report("openShort bytes (action 1, sell IOC)", (await coreWriterAt.lastAction()).toLowerCase() === want.toLowerCase());

  tx = await a.closeShort(0, px, sz, 3);
  await tx.wait();
  want = E.concat(["0x01000001", coder.encode(
    ["uint32", "bool", "uint64", "uint64", "bool", "uint8", "uint128"],
    [0, true, px, sz, true, 3, 0n])]);
  report("closeShort bytes (reduceOnly buy)", (await coreWriterAt.lastAction()).toLowerCase() === want.toLowerCase());

  tx = await a.bridgeBackToEvm(500_000_000n);
  await tx.wait();
  want = E.concat(["0x0100000d", coder.encode(
    ["address", "address", "uint32", "uint32", "uint64", "uint64"],
    ["0x2000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000",
     4294967295, 4294967295, 0, 500_000_000n])]);
  report("bridgeBackToEvm bytes (action 13 sendAsset)", (await coreWriterAt.lastAction()).toLowerCase() === want.toLowerCase());

  tx = await adapter.stakeHype(10_000_000_000n); // 100 HYPE × 1e8
  await tx.wait();
  want = E.concat(["0x01000004", coder.encode(["uint64"], [10_000_000_000n])]);
  report("stakeHype bytes (action 4)", (await coreWriterAt.lastAction()).toLowerCase() === want.toLowerCase());

  tx = await adapter.delegateHype(user1.address, 10_000_000_000n, false);
  await tx.wait();
  want = E.concat(["0x01000003", coder.encode(["address", "uint64", "bool"], [user1.address, 10_000_000_000n, false])]);
  report("delegateHype bytes (action 3)", (await coreWriterAt.lastAction()).toLowerCase() === want.toLowerCase());

  // ── Bridge in ──
  const depBefore = await walletAt.depositCount(); // persistent anvil: storage survives runs
  tx = await a.bridgeUsdcToCore(1_000_000n);
  await tx.wait();
  report("bridgeUsdcToCore → deposit wallet call",
    (await walletAt.depositCount()) === depBefore + 1n &&
    (await walletAt.lastAmount()) === 1_000_000n &&
    (await walletAt.lastDex()) === 4294967295n);
  report("bridgeUsdcToCore → USDC approve",
    (await usdc.allowance(adapterAddr, TESTNET_DEPOSIT_WALLET)) === 1_000_000n);

  // ── Gates ──
  await expectRevert(adapter.connect(user1).moveUsdcToPerp.staticCall(1_000_000n), "NotKeeper", "keeper gate");
  await (await adapter.setPaused(true)).wait();
  await expectRevert(a.moveUsdcToPerp.staticCall(1_000_000n), "Paused", "pause gate");
  await (await adapter.setPaused(false)).wait();
  await (await existsAt.setExists(false)).wait();
  await expectRevert(a.moveUsdcToPerp.staticCall(1_000_000n), "NotInitialized", "core-account gate (transfer)");
  await expectRevert(a.openShort.staticCall(0, px, sz, 3), "NotInitialized", "core-account gate (order)");
  await (await existsAt.setExists(true)).wait();
  report("core-account gate restores", (await adapter.coreAccountExists()) === true);

  // ── Caps & sanity ──
  await expectRevert(a.openShort.staticCall(0, px, 10_000n * 10n ** 8n, 3), "Cap", "notional cap on orders");
  await expectRevert(a.openShort.staticCall(0, px, 10_000n, 3), "BelowMinNotional", "HL $10 min notional");
  await expectRevert(a.openShort.staticCall(1, px, sz, 3), "WrongAsset", "asset whitelist");
  await expectRevert(a.moveUsdcToPerp.staticCall(200_000n * 10n ** 6n), "Cap", "class-transfer cap");
  await expectRevert(a.openShort.staticCall(0, px, sz, 9), "BadTif", "tif validation");

  // ── Position + admin ──
  await (await positionAt.set(-5_000_000n, 0n, 0n, 10, false)).wait();
  const p = await adapter.position();
  report("position read (0x813) — szi=-5e6 (short)", p.szi === -5_000_000n);
  await expectRevert(adapter.setPerpAsset.staticCall(1), "NotFlat", "setPerpAsset guard (open position)");
  await (await positionAt.set(0n, 0n, 0n, 10, false)).wait();
  tx = await adapter.setPerpAsset(1); await tx.wait();
  report("setPerpAsset allowed when flat", (await adapter.perpAsset()) === 1n);
  tx = await adapter.setPerpAsset(0); await tx.wait();

  await (await marginAt.set(123_456n, 100n, 200n, 50n)).wait();
  const m = await adapter.marginSummary();
  report("margin summary read (0x80f)", m.accountValue === 123_456n && m.marginUsed === 100n);
  await (await withdrawableAt.setAmount(42_000_000n)).wait();
  report("withdrawable read (0x803)", (await adapter.withdrawable()) === 42_000_000n);

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("ORPHAN ERROR:", e.message?.slice(0, 300));
  process.exit(2);
});
