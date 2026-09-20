// dn_realread_check.js v3 — verify the ENTIRE read layer against the REAL
// HyperEVM mainnet precompiles. Read-only eth_calls: no keys, no funds, no
// HyperEVM state changes (the DecodeVerifier is deployed LOCALLY on anvil).
//
// Method: fetch raw production bytes from rpc.hyperliquid.xyz → decode twice:
//   (a) JS manual (outer-offset word stripped), (b) SOLIDITY via the real
//   DNCoreStrategy structs → both must agree with expected values.
//
// Layout discovered (0x80a, 256 bytes): [0x20][0xa0][mt][szDec][maxLev][oi][len]["BTC"]
//   = wrapped 1-tuple — exactly what abi.decode(ret, (PerpAssetInfo)) expects.
// THE BIG ONE (v1→v3): accountMarginSummary takes (uint32 perpDexIndex, address
//   user) — TWO args. Our original single-arg encode reverted for every address
//   on mainnet (verified) and the mock could not catch it. Fixed in strategy +
//   adapter; mocks now assert calldata shapes. With (0, user): returns zeros for
//   empty accounts, real values otherwise (HLP $47.07M verified).
//
// Run: npx hardhat run scripts/dn_realread_check.js --network hyperTestnet
const hre = require("hardhat");
const { ethers } = require("ethers");

const RPC = "https://rpc.hyperliquid.xyz/evm";
const coder = ethers.AbiCoder.defaultAbiCoder();
const NONEXISTENT = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D"; // deployer — no Core account
const EXISTING = "0xfefefefefefefefefefefefefefefefefefefefe";    // assistance fund — exists by definition

const P = {
  position2: "0x0000000000000000000000000000000000000813",
  withdrawable: "0x0000000000000000000000000000000000000803",
  markPx: "0x0000000000000000000000000000000000000806",
  oraclePx: "0x0000000000000000000000000000000000000807",
  perpAssetInfo: "0x000000000000000000000000000000000000080a",
  marginSummary: "0x000000000000000000000000000000000000080f",
  coreUserExists: "0x0000000000000000000000000000000000000810",
};

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}
async function tryCall(provider, to, data) {
  try { return { ok: true, ret: await provider.call({ to, data }) }; }
  catch (e) { return { ok: false, err: (e.shortMessage || e.message || "").slice(0, 70) }; }
}
// JS decode of the wrapped form: strip "0x" + first word (outer offset), then
// decode the payload as a flat tuple (offsets are payload-relative).
const unwrap = (ret) => "0x" + ret.slice(66);

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  report("mainnet HyperEVM reachable (chainId 999)", Number(net.chainId) === 999, `chainId=${net.chainId}`);

  // Deploy the Solidity verifier LOCALLY (anvil) — zero HyperEVM deployment.
  const V = await hre.ethers.getContractFactory("DecodeVerifier");
  const verifier = await V.deploy();
  await verifier.waitForDeployment();
  console.log(`DecodeVerifier (local anvil): ${await verifier.getAddress()}\n`);

  // ── 0x80a perpAssetInfo — both decoders ──
  for (const [idx, expectCoin, expectSz, expectMl] of [[0, "BTC", 5, 40], [1, "ETH", 4, 25]]) {
    const { ok, ret } = await tryCall(provider, P.perpAssetInfo, coder.encode(["uint32"], [idx]));
    if (!ok) { report(`0x80a[${idx}] call`, false, ret); continue; }
    const [coin, mt, sz, ml, oi] = coder.decode(["string", "uint32", "uint8", "uint8", "bool"], unwrap(ret));
    report(`0x80a[${idx}] JS decode: coin=${coin} mt=${mt} szDec=${sz} maxLev=${ml}`, coin === expectCoin && Number(sz) === expectSz,
      `onlyIsolated=${oi}`);
    const s = await verifier.decodePerpAssetInfo.staticCall(ret);
    report(`0x80a[${idx}] SOLIDITY decode (real struct): coin=${s[0]} szDec=${s[2]} maxLev=${s[3]}`,
      s[0] === expectCoin && Number(s[2]) === expectSz && Number(s[3]) === expectMl);
  }

  // ── oracle / mark ──
  const oRet = (await tryCall(provider, P.oraclePx, coder.encode(["uint32"], [0]))).ret;
  const mRet = (await tryCall(provider, P.markPx, coder.encode(["uint32"], [0]))).ret;
  const oracle = Number(await verifier.decodeUint64.staticCall(oRet));
  const mark = Number(await verifier.decodeUint64.staticCall(mRet));
  report("0x807 oraclePx(BTC) via SOLIDITY decode", oracle / 10 > 1000, `≈ $${(oracle / 10).toLocaleString()}`);
  report("0x806 markPx(BTC) via SOLIDITY decode", mark / 10 > 1000, `≈ $${(mark / 10).toLocaleString()}`);

  // ── account-dependent reads, both account states ──
  for (const [label, addr] of [["non-existent", NONEXISTENT], ["existing (assistance fund)", EXISTING]]) {
    const e = await tryCall(provider, P.coreUserExists, coder.encode(["address"], [addr]));
    if (e.ok) {
      const ex = await verifier.decodeBool.staticCall(e.ret);
      report(`0x810 coreUserExists [${label}] → ${ex}`, true);
    } else {
      report(`0x810 coreUserExists [${label}] REVERTS`, true, e.err);
    }

    const m = await tryCall(provider, P.marginSummary, coder.encode(["uint32", "address"], [0, addr]));
    if (m.ok) {
      const s = await verifier.decodeMarginSummary.staticCall(m.ret);
      report(`0x80f marginSummary [${label}] via SOLIDITY decode (dex,user encoding)`, true, `accountValue=${s[0]} marginUsed=${s[1]}`);
    } else {
      report(`0x80f marginSummary [${label}]`, false, `unexpected revert with corrected (dex,user) encoding: ${m.err}`);
    }

    const w = await tryCall(provider, P.withdrawable, coder.encode(["address"], [addr]));
    report(`0x803 withdrawable [${label}]`, w.ok,
      w.ok ? `${await verifier.decodeUint64.staticCall(w.ret)}` : `REVERTS: ${w.err}`);

    const p = await tryCall(provider, P.position2, coder.encode(["address", "uint32"], [addr, 0]));
    if (p.ok) {
      const s = await verifier.decodePosition.staticCall(p.ret);
      report(`0x813 position2 [${label}] via SOLIDITY decode`, true, `szi=${s[0]}`);
    } else {
      report(`0x813 position2 [${label}] REVERTS`, true, `→ contract must branch on existence (${p.err})`);
    }
  }

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("realread error:", e.message?.slice(0, 300));
  process.exit(2);
});
