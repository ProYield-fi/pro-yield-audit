// scripts/create_safe_mainnet.js — create the ProYield mainnet Safes (v1.4.1)
// on HyperEVM mainnet (999).
//
// SAFE_KIND=treasury | insurance  (separate runs; separate records)
//
// Owners (threshold 2 of 3) — the phone backup is set AT CREATION (born on the
// user's device; unlike testnet, no box-side backup key is ever generated):
//   #1 ops EOA            0xaDD8f2678…   (deployer/owner wallet the user controls)
//   #2 fresh ops signer   ~/.proyield/<kind>_signer_mainnet.json   (this box, 0600)
//   #3 backup owner       phone 0x45bf6BAc…  (user-held; BACKUP_OWNER env to override)
//
// Guards: MAINNET_OK=1 · chain 999 · expected deployer · canonical Safe v1.4.1
// stack has code · verify-before-record (VERSION/threshold/owners read back from
// the proxy; refuses to record on any mismatch).
//
//   MAINNET_OK=1 SAFE_KIND=treasury npx hardhat run scripts/create_safe_mainnet.js --network hyperMainnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const os = require("os");

const CHAIN_ID = 999;
const FACTORY = "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67"; // SafeProxyFactory v1.4.1
const SINGLETON = "0x41675C099F32341bf84BFc5382aF534df5C7461a"; // Safe v1.4.1 singleton
const FALLBACK = "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99"; // CompatibilityFallbackHandler v1.4.1
const OWNER_EOA = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D";
const PHONE = process.env.BACKUP_OWNER || "0x45bf6BAc9404714cd0b22912a102EA1f8826D349";
const THRESHOLD = 2;

const SEND = process.env.MAINNET_OK === "1";
const KIND = process.env.SAFE_KIND || "treasury";
const KEY_DIR = path.join(os.homedir(), ".proyield");

function fail(msg) {
  console.error(`REFUSING: ${msg}`);
  process.exit(3);
}

function loadOrCreateKey(file, label, note) {
  const p = path.join(KEY_DIR, file);
  if (fs.existsSync(p)) {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    return new hre.ethers.Wallet(j.private_key);
  }
  if (!SEND) {
    // Dry runs must not mint new key material (the recorded owners would change on the real run).
    return null;
  }
  const w = hre.ethers.Wallet.createRandom();
  fs.mkdirSync(KEY_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(p, JSON.stringify({ label, note, address: w.address, private_key: w.privateKey }, null, 1), { mode: 0o600 });
  console.log("generated key:", file, "->", w.address);
  return w;
}

async function main() {
  const { ethers } = hre;
  if (!["treasury", "insurance"].includes(KIND)) fail(`SAFE_KIND must be treasury|insurance (got ${KIND})`);

  const net = await ethers.provider.getNetwork();
  if (Number(net.chainId) !== CHAIN_ID) fail(`chainId ${net.chainId} is not HyperEVM mainnet (999)`);
  console.log(`chain 999 ✓ · ${SEND ? "SEND MODE" : "DRY MODE"} · kind=${KIND}`);

  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== OWNER_EOA.toLowerCase()) fail(`deployer ${deployer.address} != expected ${OWNER_EOA}`);
  console.log("deployer:", deployer.address, "|", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "HYPE");

  for (const [name, addr] of [["factory", FACTORY], ["singleton", SINGLETON], ["fallback", FALLBACK]]) {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") fail(`Safe ${name} ${addr} has no code on chain 999`);
  }
  console.log("Safe v1.4.1 stack present ✓");

  const ops = loadOrCreateKey(`${KIND}_signer_mainnet.json`, `${KIND} ops signer (2/3, mainnet)`, "mainnet ops signer used by box tooling; keep 0600");
  const opsAddr = ops ? ops.address : "«generated on first SEND run»";
  const owners = [OWNER_EOA, ...(ops ? [opsAddr] : []), PHONE].map((a) => ethers.getAddress(a));
  if (new Set(owners.map((o) => o.toLowerCase())).size !== owners.length) fail("duplicate owner addresses");
  console.log(`owners: [${owners.join(", ")}] · threshold ${THRESHOLD}`);

  const factory = new ethers.Contract(FACTORY, [
    "function createProxyWithNonce(address _singleton, bytes initializer, uint256 saltNonce) returns (address proxy)",
    "event ProxyCreation(address proxy, address singleton)",
  ], deployer);
  const setupIface = new ethers.Interface([
    "function setup(address[] _owners, uint256 _threshold, address to, bytes data, address fallbackHandler, address paymentToken, uint256 payment, address paymentReceiver)",
  ]);

  if (!SEND || !ops) {
    console.log("\nDRY — stack verified; key material and deployment are deferred to the SEND run (MAINNET_OK=1).");
    return;
  }

  const initData = setupIface.encodeFunctionData("setup", [
    owners, THRESHOLD, ethers.ZeroAddress, "0x", FALLBACK, ethers.ZeroAddress, 0, ethers.ZeroAddress,
  ]);
  const saltNonce = BigInt(Date.now());
  const predicted = await factory.createProxyWithNonce.staticCall(SINGLETON, initData, saltNonce);
  console.log("predicted Safe:", predicted);

  let txHash = null;
  if ((await ethers.provider.getCode(predicted)) === "0x") {
    const tx = await factory.createProxyWithNonce(SINGLETON, initData, saltNonce);
    const rc = await tx.wait();
    txHash = rc.hash;
    const ev = rc.logs
      .map((l) => { try { return factory.interface.parseLog(l); } catch { return null; } })
      .find((e) => e && e.name === "ProxyCreation");
    console.log("deployed:", txHash, "| gas:", rc.gasUsed.toString(), "| event proxy:", ev ? ev.args.proxy : "(not parsed)");
    if (ev && ethers.getAddress(ev.args.proxy) !== ethers.getAddress(predicted)) {
      fail("event proxy != predicted — aborting before recording");
    }
  } else {
    console.log("already deployed at predicted address — verifying only");
  }

  const safe = new ethers.Contract(predicted, [
    "function getOwners() view returns (address[])",
    "function getThreshold() view returns (uint256)",
    "function VERSION() view returns (string)",
  ], ethers.provider);
  const [version, threshold, onchainOwners] = [await safe.VERSION(), await safe.getThreshold(), await safe.getOwners()];
  console.log("verify: version", version, "| threshold", threshold.toString(), "| owners", onchainOwners.join(", "));

  const match = version === "1.4.1" && Number(threshold) === THRESHOLD &&
    owners.length === onchainOwners.length &&
    owners.every((o) => onchainOwners.map((x) => ethers.getAddress(x)).includes(ethers.getAddress(o)));
  if (!match) fail("on-chain owners/threshold/version do not match intent — not recording");

  const record = path.join(KEY_DIR, `${KIND}_multisig_mainnet.json`);
  fs.writeFileSync(record, JSON.stringify({
    created_utc: new Date().toISOString(),
    chain_id: CHAIN_ID,
    kind: KIND,
    safe: predicted,
    singleton: SINGLETON,
    factory: FACTORY,
    fallback_handler: FALLBACK,
    threshold: THRESHOLD,
    owners: onchainOwners,
    owner_roles: { 1: "ops EOA (user)", 2: `${KIND} ops signer (this box)`, 3: "backup owner — user's phone; key never on this box" },
    deploy_tx: txHash,
    verified_onchain: true,
  }, null, 1), { mode: 0o600 });
  console.log("recorded ->", record);
  console.log(`${KIND.toUpperCase()} SAFE (mainnet):`, predicted);
}

main().catch((e) => { console.error("create_safe_mainnet error:", (e && e.stack) || e); process.exit(2); });
