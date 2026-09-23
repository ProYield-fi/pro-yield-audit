// scripts/swap_insurance_owner.js — swap the insurance Safe's backup owner
// (the key generated on THIS box) for an address the user holds on their own
// device: phone MetaMask, browser MetaMask, or a hardware wallet.
//
// Why: the Safe is 2-of-3, but until the backup key leaves this machine all
// three keys live here. Swapping in a user-held address AND deleting the local
// key file makes the multisig genuinely distributed: spending then needs the
// user's device plus one more key (their EOA or ops).
//
// The swap itself is a Safe transaction → needs `threshold` (2) signatures.
// The script signs with the ops key + the backup key (both still owners at that
// moment) and executes. Signature scheme is validated against the Safe's own
// getTransactionHash() BEFORE anything is sent (DRY_RUN=1 stops there).
//
// Usage:
//   NEW_OWNER=0x…PhoneAddress DRY_RUN=1 npx hardhat run scripts/swap_insurance_owner.js --network hyperTestnet
//   NEW_OWNER=0x…PhoneAddress          npx hardhat run scripts/swap_insurance_owner.js --network hyperTestnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const os = require("os");

const KEY_DIR = path.join(os.homedir(), ".proyield");
const RECORD = path.join(KEY_DIR, "insurance_multisig.json");
const SENTINEL = "0x0000000000000000000000000000000000000001";

async function main() {
  const rec = JSON.parse(fs.readFileSync(RECORD, "utf8"));
  const safeAddr = rec.safe;
  if (!process.env.NEW_OWNER) { console.error("set NEW_OWNER=0x… (address from the user's own device)"); process.exit(2); }
  const newOwnerAddr = hre.ethers.getAddress(process.env.NEW_OWNER);
  const dryRun = process.env.DRY_RUN === "1";

  const [signer] = await hre.ethers.getSigners();
  const safe = new hre.ethers.Contract(safeAddr, [
    "function getOwners() view returns (address[])",
    "function getThreshold() view returns (uint256)",
    "function nonce() view returns (uint256)",
    "function swapOwner(address prevOwner, address oldOwner, address newOwner)",
    "function getTransactionHash(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce) view returns (bytes32)",
    "function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures) returns (bool)",
  ], signer);

  const owners = (await safe.getOwners()).map((a) => hre.ethers.getAddress(a));
  const oldOwner = hre.ethers.getAddress(rec.owners[2]); // the box-generated backup slot
  const idx = owners.indexOf(oldOwner);
  if (idx < 0) { console.error("backup owner not on-chain anymore (already swapped?) — nothing to do."); process.exit(2); }
  const prevOwner = idx === 0 ? SENTINEL : owners[idx - 1]; // Safe owner linked list

  const data = safe.interface.encodeFunctionData("swapOwner", [prevOwner, oldOwner, newOwnerAddr]);
  const nonce = await safe.nonce();
  const args = [safeAddr, 0n, data, 0, 0n, 0n, 0n, hre.ethers.ZeroAddress, hre.ethers.ZeroAddress, nonce];

  // 1) the hash the SAFE will verify against
  const onchainHash = await safe.getTransactionHash(...args);

  // 2) the hash we EIP-712-sign locally (Safe >=1.3 domain: {chainId, verifyingContract})
  const domain = { chainId: Number((await hre.ethers.provider.getNetwork()).chainId), verifyingContract: safeAddr };
  const types = { SafeTx: [
    { name: "to", type: "address" }, { name: "value", type: "uint256" }, { name: "data", type: "bytes" },
    { name: "operation", type: "uint8" }, { name: "safeTxGas", type: "uint256" }, { name: "baseGas", type: "uint256" },
    { name: "gasPrice", type: "uint256" }, { name: "gasToken", type: "address" }, { name: "refundReceiver", type: "address" },
    { name: "nonce", type: "uint256" },
  ] };
  const value = { to: safeAddr, value: 0n, data, operation: 0, safeTxGas: 0n, baseGas: 0n, gasPrice: 0n,
    gasToken: hre.ethers.ZeroAddress, refundReceiver: hre.ethers.ZeroAddress, nonce };
  const localHash = hre.ethers.TypedDataEncoder.hash(domain, types, value);

  console.log("on-chain getTransactionHash:", onchainHash);
  console.log("local EIP-712 hash:         ", localHash);
  if (localHash !== onchainHash) { console.error("REFUSING: signing scheme mismatch — do NOT execute. (investigate domain/types)"); process.exit(3); }
  console.log("hash match ✓ — signing scheme validated against the live Safe");

  const ops = new hre.ethers.Wallet(JSON.parse(fs.readFileSync(path.join(KEY_DIR, "insurance_signer.json"), "utf8")).private_key);
  const backup = new hre.ethers.Wallet(JSON.parse(fs.readFileSync(path.join(KEY_DIR, "insurance_backup_signer.json"), "utf8")).private_key);
  const sigs = await Promise.all([ops, backup].map((w) => w.signTypedData(domain, types, value)));

  if (dryRun) {
    console.log(`DRY RUN — nothing executed. Threshold is ${(await safe.getThreshold()).toString()}; both signatures collected.`);
    console.log("would swap", oldOwner, "->", newOwnerAddr);
    return;
  }

  // Safe requires signatures sorted ascending by signer address.
  const pairs = [[ops.address, sigs[0]], [backup.address, sigs[1]]]
    .map(([a, s]) => [hre.ethers.getAddress(a).toLowerCase(), s])
    .sort((x, y) => (x[0] < y[0] ? -1 : 1));
  const signatures = "0x" + pairs.map(([, s]) => s.slice(2)).join("");

  const tx = await safe.execTransaction(...args, signatures);
  const rc = await tx.wait();
  console.log("swapped ✓ | tx:", rc.hash, "| gas:", rc.gasUsed.toString());

  const after = (await safe.getOwners()).map((a) => hre.ethers.getAddress(a));
  console.log("owners now:", after.join(", "));
  if (!after.includes(newOwnerAddr)) { console.error("swap did not land — investigate before trusting."); process.exit(4); }

  rec.owners = after;
  rec.owner_roles = { 1: "owner EOA (user)", 2: "ops signer (this box)", 3: `user-held signer ${newOwnerAddr} — key never on this box` };
  rec.backup_swapped_utc = new Date().toISOString();
  fs.writeFileSync(RECORD, JSON.stringify(rec, null, 1), { mode: 0o600 });
  const backupFile = path.join(KEY_DIR, "insurance_backup_signer.json");
  if (fs.existsSync(backupFile)) { fs.unlinkSync(backupFile); console.log("local backup key file DELETED (no longer an owner)"); }
  console.log("record updated ->", RECORD);
}
main().catch((e) => { console.error("swap_insurance_owner error:", (e && e.stack) || e); process.exit(2); });