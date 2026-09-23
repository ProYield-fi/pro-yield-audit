// dn_realread_replay.js — offline regression of the read-layer decoders
// against FROZEN REAL HyperEVM mainnet bytes (test/fixtures/hyperevm_reads.json,
// captured by dn_realread_capture.js). No mainnet access, no fork (the
// precompiles are native — unforkable); wired into the battery + CI.
//
// For every recorded read with return bytes it re-runs the SAME decode paths
// (JS unwrap + the Solidity DecodeVerifier using the real strategy structs)
// and requires:
//   1. re-decoded values == the values recorded at capture time (string-eq),
//   2. the live check's semantic expectations (coin/szDec/maxLev, sane prices).
// A decoder/struct edit that changes parsing therefore fails HERE — the
// regression that a mock can never catch (see the v1→v3 marginSummary bug).
//
// Run: npx hardhat run scripts/dn_realread_replay.js --network hyperTestnet
const hre = require("hardhat");
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const FIXTURE = path.join(__dirname, "..", "test", "fixtures", "hyperevm_reads.json");
const coder = ethers.AbiCoder.defaultAbiCoder();
const unwrap = (ret) => "0x" + ret.slice(66);
const S = (x) => x.toString();

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

async function main() {
  const fx = JSON.parse(fs.readFileSync(FIXTURE, "utf8"));
  console.log(`fixture: ${fx.source} @ block ${fx.blockNumber} (chainId ${fx.chainId}, captured ${fx.capturedAt})`);

  const V = await hre.ethers.getContractFactory("DecodeVerifier");
  const verifier = await V.deploy();
  await verifier.waitForDeployment();

  for (const e of fx.reads) {
    if (!e.ret) { report(`${e.name} (recorded revert, informational)`, true, e.err || ""); continue; }
    const ret = e.ret;
    const exp = e.expected || {};

    if (e.name.startsWith("perpAssetInfo[")) {
      const [coin, mt, sz, ml, oi] = coder.decode(["string", "uint32", "uint8", "uint8", "bool"], unwrap(ret));
      const s = await verifier.decodePerpAssetInfo.staticCall(ret);
      const nullAddr = "0x0000000000000000000000000000000000000000";
      report(
        `${e.name} JS+SOLIDITY decode matches frozen bytes`,
        coin === exp.coin && S(sz) === exp.szDec && S(ml) === exp.maxLev && s[0] === exp.coin && S(s[2]) === exp.szDec && S(s[3]) === exp.solMaxLev,
        `coin=${coin} szDec=${sz} maxLev=${ml} oi=${oi}`,
      );
    } else if (e.name.startsWith("oraclePx") || e.name.startsWith("markPx")) {
      const v = S(await verifier.decodeUint64.staticCall(ret));
      report(`${e.name} SOLIDITY decode matches frozen bytes`, v === exp.value, `≈ $${(Number(v) / 10).toLocaleString()}`);
      if (e.name.startsWith("oraclePx")) report(`${e.name} sane price`, Number(v) / 10 > 1000);
    } else if (e.name.startsWith("coreUserExists")) {
      const b = await verifier.decodeBool.staticCall(ret);
      report(`${e.name} SOLIDITY decode matches frozen bytes`, b === exp.exists, `→ ${b}`);
    } else if (e.name.startsWith("marginSummary")) {
      const s = await verifier.decodeMarginSummary.staticCall(ret);
      report(
        `${e.name} SOLIDITY decode matches frozen bytes (dex,user encoding)`,
        S(s[0]) === exp.accountValue && S(s[1]) === exp.marginUsed,
        `accountValue=${s[0]} marginUsed=${s[1]}`,
      );
    } else if (e.name.startsWith("withdrawable")) {
      const v = S(await verifier.decodeUint64.staticCall(ret));
      report(`${e.name} SOLIDITY decode matches frozen bytes`, v === exp.value, v);
    } else if (e.name.startsWith("position2")) {
      const s = await verifier.decodePosition.staticCall(ret);
      report(`${e.name} SOLIDITY decode matches frozen bytes`, S(s[0]) === exp.szi, `szi=${s[0]}`);
    } else {
      report(`${e.name} (unknown read kind)`, false);
    }
  }

  console.log(`\n══════ ${pass} passed, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  const stack = (e && e.stack) || String(e);
  let done = false;
  const bail = () => { if (done) return; done = true; console.error("replay error (full stack):\n" + stack); process.exit(2); };
  setTimeout(bail, 1500).unref?.();
  process.stdout.write("", bail);
});