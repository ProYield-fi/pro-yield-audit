// dn_realread_capture.js — freeze REAL HyperEVM mainnet precompile bytes into
// a fixture so the read-layer decode regression is reproducible without the
// network. HyperEVM's read precompiles (0x803/0x806/0x807/0x80a/0x80f/0x810/
// 0x813) are NATIVE handlers — they have no code at those addresses, so a
// standard anvil fork CANNOT replay them (calls return empty). Instead:
// capture (this script, live, one-time) → replay (dn_realread_replay.js,
// offline, wired into the battery + CI).
//
// Each entry records: target, calldata, raw return bytes, and the value the
// CURRENT decoders (JS unwrap + the real Solidity structs via DecodeVerifier)
// produce. Any later decoder regression breaks the replay.
//
// Run: HYPEREVM_RPC_URL=<scratch anvil> npx hardhat run scripts/dn_realread_capture.js --network hyperTestnet
const hre = require("hardhat");
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const { assessEndpoint } = require("./he_pin");

const RPC = process.env.HYPEREVM_MAINNET_RPC || "https://rpc.hyperliquid.xyz/evm";
const FIXTURE = path.join(__dirname, "..", "test", "fixtures", "hyperevm_reads.json");
const coder = ethers.AbiCoder.defaultAbiCoder();
const NONEXISTENT = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D"; // deployer — no Core account
const EXISTING = "0xfefefefefefefefefefefefefefefefefefefefe";    // assistance fund
// Book-#1 vault (public mainnet constant) — only used as the pre-deployment
// sentinel target for the block-pin capability check below (t_bb11f1bc).
const PIN_PROBE_VAULT = "0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1";
const ALLOW_UNPINNED = process.env.ALLOW_UNPINNED_CAPTURE === "1";

const P = {
  position2: "0x0000000000000000000000000000000000000813",
  withdrawable: "0x0000000000000000000000000000000000000803",
  markPx: "0x0000000000000000000000000000000000000806",
  oraclePx: "0x0000000000000000000000000000000000000807",
  perpAssetInfo: "0x000000000000000000000000000000000000080a",
  marginSummary: "0x000000000000000000000000000000000000080f",
  coreUserExists: "0x0000000000000000000000000000000000000810",
};

const unwrap = (ret) => "0x" + ret.slice(66);
const S = (x) => x.toString();

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  const block = await provider.getBlockNumber();
  console.log(`capturing from ${RPC} (chainId ${net.chainId}, block ${block})`);

  // t_bb11f1bc: a fixture must not claim a `block` pin unless the endpoint
  // honours the tag. Three of four HyperEVM public endpoints silently return
  // LATEST state for a historical eth_call — that would make `block` a lie.
  const pin = await assessEndpoint(provider, PIN_PROBE_VAULT);
  const pinned = pin.honoured;
  if (!pinned && !ALLOW_UNPINNED) {
    console.error(
      `REFUSING to capture: ${RPC} ${pin.reason}\n` +
        `  Use an archive endpoint (HYPEREVM_MAINNET_RPC=https://hyperliquid.drpc.org)\n` +
        `  or set ALLOW_UNPINNED_CAPTURE=1 to record an explicitly unpinned fixture (pinned:false).`
    );
    process.exit(2);
  }
  if (!pinned) console.warn(`WARNING: ${RPC} ${pin.reason} — fixture will be marked pinned:false`);

  // Local verifier (scratch anvil only — NEVER deploy to the persistent chain).
  const V = await hre.ethers.getContractFactory("DecodeVerifier");
  const verifier = await V.deploy();
  await verifier.waitForDeployment();

  const entries = [];
  async function read(name, to, data, decode) {
    const e = { name, to, data, block };
    try {
      const ret = await provider.call({ to, data, blockTag: block }); // pinned (tag inside tx — ethers v6 ignores a 2nd arg; t_bb11f1bc)
      e.ret = ret;
      if (decode) e.expected = await decode(ret);
    } catch (err) {
      e.revert = true;
      e.err = (err.shortMessage || err.message || "").slice(0, 140);
    }
    entries.push(e);
    console.log(`  ${e.ret ? "ret " + e.ret.slice(0, 26) + "…" : "REVERT"}  ${name}`);
  }

  for (const idx of [0, 1]) {
    await read(`perpAssetInfo[${idx}]`, P.perpAssetInfo, coder.encode(["uint32"], [idx]), async (ret) => {
      const [coin, mt, sz, ml, oi] = coder.decode(["string", "uint32", "uint8", "uint8", "bool"], unwrap(ret));
      const s = await verifier.decodePerpAssetInfo.staticCall(ret); // real Solidity structs
      return { coin, mt: S(mt), szDec: S(sz), maxLev: S(ml), oi, solCoin: s[0], solSzDec: S(s[2]), solMaxLev: S(s[3]) };
    });
  }
  await read("oraclePx(0)", P.oraclePx, coder.encode(["uint32"], [0]), async (ret) => ({
    value: S(await verifier.decodeUint64.staticCall(ret)),
  }));
  await read("markPx(0)", P.markPx, coder.encode(["uint32"], [0]), async (ret) => ({
    value: S(await verifier.decodeUint64.staticCall(ret)),
  }));
  for (const [label, addr] of [["non-existent", NONEXISTENT], ["existing", EXISTING]]) {
    await read(`coreUserExists[${label}]`, P.coreUserExists, coder.encode(["address"], [addr]), async (ret) => ({
      exists: await verifier.decodeBool.staticCall(ret),
    }));
    await read(`marginSummary[${label}]`, P.marginSummary, coder.encode(["uint32", "address"], [0, addr]), async (ret) => {
      const s = await verifier.decodeMarginSummary.staticCall(ret);
      return { accountValue: S(s[0]), marginUsed: S(s[1]) };
    });
    await read(`withdrawable[${label}]`, P.withdrawable, coder.encode(["address"], [addr]), async (ret) => ({
      value: S(await verifier.decodeUint64.staticCall(ret)),
    }));
    await read(`position2[${label}]`, P.position2, coder.encode(["address", "uint32"], [addr, 0]), async (ret) => {
      const s = await verifier.decodePosition.staticCall(ret);
      return { szi: S(s[0]) };
    });
  }

  fs.mkdirSync(path.dirname(FIXTURE), { recursive: true });
  fs.writeFileSync(
    FIXTURE,
    JSON.stringify(
      {
        source: RPC,
        chainId: Number(net.chainId),
        blockNumber: block,
        pinned, // t_bb11f1bc: whether `blockNumber` is a REAL pin on this endpoint
        pin_check: { mode: pin.mode, reason: pin.reason },
        capturedAt: new Date().toISOString(),
        reads: entries,
      },
      null,
      1
    ),
  );
  console.log(`\nwrote ${entries.length} reads → ${FIXTURE}`);
}

main().catch((e) => {
  console.error("capture error:", (e && e.stack) || e);
  process.exit(2);
});