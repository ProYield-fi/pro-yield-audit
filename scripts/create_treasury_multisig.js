// scripts/create_treasury_multisig.js — create the dedicated treasury multisig
// (Safe v1.4.1) on HyperEVM testnet.
//
// Owners (threshold 2 of 3):
//   #1 the owner EOA (0xaDD8f2678… — the deployer/ops wallet the user controls)
//   #2 a fresh ops signer generated on this box   -> ~/.proyield/treasury_signer.json
//   #3 a fresh backup signer generated on this box -> ~/.proyield/treasury_backup_signer.json
//
// The backup key is meant to LEAVE this machine (move to the user's device /
// hardware wallet, then delete the local file). Until it does, this box holds
// 2 of 3 keys — the multisig is correct wiring, not yet distributed trust.
// Key files are written 0600; private keys are NEVER printed.
//
// Run: HYPEREVM_RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm \
//      npx hardhat run scripts/create_treasury_multisig.js --network hyperTestnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const os = require("os");

const CHAIN_ID = 998;
const FACTORY = "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67";   // SafeProxyFactory v1.4.1
const SINGLETON = "0x41675C099F32341bf84BFc5382aF534df5C7461a"; // Safe v1.4.1 singleton
const FALLBACK = "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99";  // CompatibilityFallbackHandler v1.4.1
const OWNER_EOA = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D";
const THRESHOLD = 2;

const KEY_DIR = path.join(os.homedir(), ".proyield");
const RECORD = path.join(KEY_DIR, "treasury_multisig.json");

function loadOrCreateKey(file, label, note) {
  const p = path.join(KEY_DIR, file);
  if (fs.existsSync(p)) {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    return new hre.ethers.Wallet(j.private_key);
  }
  const w = hre.ethers.Wallet.createRandom();
  fs.mkdirSync(KEY_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(p, JSON.stringify({ label, note, address: w.address, private_key: w.privateKey }, null, 1), { mode: 0o600 });
  console.log("generated key:", file, "->", w.address);
  return w;
}

async function main() {
  const net = await hre.ethers.provider.getNetwork();
  if (Number(net.chainId) !== CHAIN_ID) {
    console.error(`REFUSING: chain ${net.chainId} is not HyperEVM testnet (998).`);
    process.exit(3);
  }
  const [deployer] = await hre.ethers.getSigners();
  console.log("deployer:", deployer.address, "| balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "HYPE");

  const ops = loadOrCreateKey("treasury_signer.json", "treasury ops signer (2/3)",
    "testnet signer used by ops tooling; keep 0600");
  const backup = loadOrCreateKey("treasury_backup_signer.json", "treasury backup signer (3/3)",
    "MOVE THIS KEY OFF THIS MACHINE (own device / hardware wallet), then delete this file");
  const owners = [OWNER_EOA, ops.address, backup.address].map((a) => hre.ethers.getAddress(a));

  const factory = new hre.ethers.Contract(FACTORY, [
    "function createProxyWithNonce(address _singleton, bytes initializer, uint256 saltNonce) returns (address proxy)",
    "event ProxyCreation(address proxy, address singleton)",
  ], deployer);
  const setupIface = new hre.ethers.Interface([
    "function setup(address[] _owners, uint256 _threshold, address to, bytes data, address fallbackHandler, address paymentToken, uint256 payment, address paymentReceiver)",
  ]);
  const initData = setupIface.encodeFunctionData("setup", [
    owners, THRESHOLD, hre.ethers.ZeroAddress, "0x", FALLBACK, hre.ethers.ZeroAddress, 0, hre.ethers.ZeroAddress,
  ]);
  const saltNonce = BigInt(Date.now());

  const predicted = await factory.createProxyWithNonce.staticCall(SINGLETON, initData, saltNonce);
  console.log("predicted Safe:", predicted);

  let txHash = null;
  if ((await hre.ethers.provider.getCode(predicted)) === "0x") {
    const tx = await factory.createProxyWithNonce(SINGLETON, initData, saltNonce);
    const rc = await tx.wait();
    txHash = rc.hash;
    const ev = rc.logs.map((l) => { try { return factory.interface.parseLog(l); } catch { return null; } }).find((e) => e && e.name === "ProxyCreation");
    console.log("deployed:", txHash, "| gas:", rc.gasUsed.toString(), "| event proxy:", ev ? ev.args.proxy : "(event not parsed)");
    if (ev && hre.ethers.getAddress(ev.args.proxy) !== hre.ethers.getAddress(predicted)) {
      console.error("REFUSING: event proxy != predicted — aborting before recording.");
      process.exit(4);
    }
  } else {
    console.log("already deployed at the predicted address — verifying only");
  }

  // Verify the whole thing ON-CHAIN: owners + threshold, read back from the proxy.
  const safe = new hre.ethers.Contract(predicted, [
    "function getOwners() view returns (address[])",
    "function getThreshold() view returns (uint256)",
    "function VERSION() view returns (string)",
  ], hre.ethers.provider);
  const [version, threshold, onchainOwners] = [await safe.VERSION(), await safe.getThreshold(), await safe.getOwners()];
  console.log("verify: version", version, "| threshold", threshold.toString(), "| owners", onchainOwners.join(", "));

  const match = Number(threshold) === THRESHOLD &&
    owners.every((o) => onchainOwners.map((x) => hre.ethers.getAddress(x)).includes(hre.ethers.getAddress(o)));
  if (!match) {
    console.error("REFUSING: on-chain owners/threshold do not match the intent — not recording.");
    process.exit(4);
  }

  fs.writeFileSync(RECORD, JSON.stringify({
    created_utc: new Date().toISOString(),
    chain_id: CHAIN_ID,
    safe: predicted,
    singleton: SINGLETON,
    factory: FACTORY,
    fallback_handler: FALLBACK,
    threshold: THRESHOLD,
    owners: onchainOwners,
    owner_roles: { 1: "owner EOA (user)", 2: "ops signer (this box)", 3: "backup signer (move off this box)" },
    deploy_tx: txHash,
    verified_onchain: true,
  }, null, 1), { mode: 0o600 });
  console.log("recorded ->", RECORD);
  console.log("TREASURY MULTISIG:", predicted);
}
main().catch((e) => { console.error("create_treasury_multisig error:", (e && e.stack) || e); process.exit(2); });