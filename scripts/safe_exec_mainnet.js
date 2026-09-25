/**
 * Safe (treasury 2-of-3, v1.4.1) transaction executor — HyperEVM mainnet.
 * DRY BY DEFAULT; sending requires MAINNET_OK=1.
 *
 * Signs a SafeTx with BOTH on-box owner keys (ops EOA owner #1 + treasury ops
 * signer #2), sorts signatures by owner address (Safe v1.4.1 rule), simulates
 * via callStatic, then executes. The deployer EOA pays gas; msg.sender to
 * the Safe can be anyone.
 *
 * Usage:
 *   ACTION=addStrategy STRATEGY=0x... npx hardhat run scripts/safe_exec_mainnet.js --network hyperMainnet
 *   ACTION=allocate    npx hardhat run scripts/safe_exec_mainnet.js --network hyperMainnet
 *   TO=0x... CALLDATA=0x... npx hardhat run scripts/safe_exec_mainnet.js --network hyperMainnet
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const SAFE = "0x8A1b107e1DDabC868E40b8718F09537B0A50C9aB";
const MANIFEST = process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.mainnet.json");
const SIGNER2_FILE = process.env.SIGNER2_FILE || path.join(process.env.HOME, ".proyield", "treasury_signer_mainnet.json");

const SEND = process.env.MAINNET_OK === "1" && process.env.DRY !== "1";

const SAFE_ABI = [
  "function nonce() view returns (uint256)",
  "function getThreshold() view returns (uint256)",
  "function getOwners() view returns (address[])",
  "function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures) payable returns (bool success)",
  "function getTransactionHash(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce) view returns (bytes32)",
];

const SAFE_TX_TYPES = {
  SafeTx: [
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
    { name: "operation", type: "uint8" },
    { name: "safeTxGas", type: "uint256" },
    { name: "baseGas", type: "uint256" },
    { name: "gasPrice", type: "uint256" },
    { name: "gasToken", type: "address" },
    { name: "refundReceiver", type: "address" },
    { name: "nonce", type: "uint256" },
  ],
};

async function main() {
  const { ethers } = hre;
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  console.log(`network: ${hre.network.name} · chainId ${chainId} · ${SEND ? "SEND MODE" : "DRY MODE"}`);
  if (chainId !== 999) {
    console.error(`REFUSING: chainId ${chainId} is not HyperEVM mainnet (999)`);
    process.exit(3);
  }

  const [deployer] = await ethers.getSigners();
  // hardhat-ethers signers don't expose .signingKey — build raw wallets for
  // the EIP-712 SafeTx signatures (deployer key from the config's key file).
  const DEPLOYER_KEY_FILE = process.env.DEPLOYER_KEY_FILE || path.join(process.env.HOME, ".hermes", "vault_keys", "hyperevm_testnet.deployer");
  const deployerKey = process.env.DEPLOYER_PRIVATE_KEY || fs.readFileSync(DEPLOYER_KEY_FILE, "utf8").trim();
  const deployerW = new ethers.Wallet(deployerKey, ethers.provider);
  if (deployerW.address.toLowerCase() !== deployer.address.toLowerCase()) {
    console.error(`REFUSING: key file address ${deployerW.address} != hardhat signer ${deployer.address}`);
    process.exit(3);
  }
  const signer2 = new ethers.Wallet(JSON.parse(fs.readFileSync(SIGNER2_FILE, "utf8")).private_key, ethers.provider);
  console.log(`signer 1: ${deployer.address}`);
  console.log(`signer 2: ${signer2.address}`);

  // ── Build the inner call ────────────────────────────────────────────────────
  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  const vault = manifest.pro_yield_vault;
  const vaultIface = new ethers.Interface([
    "function addStrategy(address strategy)",
    "function allocate()",
  ]);
  const stratIface = new ethers.Interface(["function setVault(address vault)"]);

  let to = process.env.TO;
  let data = process.env.CALLDATA;
  const action = process.env.ACTION;
  if (action === "addStrategy") {
    to = to || vault;
    const strategy = process.env.STRATEGY || manifest.dn_core_strategy;
    if (!strategy) { console.error("REFUSING: no STRATEGY and manifest has no dn_core_strategy"); process.exit(3); }
    data = vaultIface.encodeFunctionData("addStrategy", [strategy]);
    console.log(`action: vault.addStrategy(${strategy})`);
  } else if (action === "setVault") {
    const strategy = process.env.STRATEGY || manifest.dn_core_strategy;
    if (!strategy) { console.error("REFUSING: no STRATEGY and manifest has no dn_core_strategy"); process.exit(3); }
    to = to || strategy;
    data = stratIface.encodeFunctionData("setVault", [vault]);
    console.log(`action: strategy.setVault(${vault})`);
  } else if (action === "allocate") {
    to = to || vault;
    data = vaultIface.encodeFunctionData("allocate");
    console.log(`action: vault.allocate()`);
  } else {
    if (!to || !data) {
      console.error("REFUSING: pass ACTION=addStrategy|allocate, or TO=0x... CALLDATA=0x...");
      process.exit(3);
    }
    console.log(`action: raw call to ${to}`);
  }
  console.log(`  to:   ${to}`);
  console.log(`  data: ${data}`);

  // ── Compose the SafeTx ──────────────────────────────────────────────────────
  const safe = new ethers.Contract(SAFE, SAFE_ABI, deployer);
  const nonce = await safe.nonce();
  const txStruct = {
    to,
    value: 0n,
    data,
    operation: 0, // CALL
    safeTxGas: 0n,
    baseGas: 0n,
    gasPrice: 0n,
    gasToken: ethers.ZeroAddress,
    refundReceiver: ethers.ZeroAddress,
    nonce,
  };
  console.log(`safe nonce: ${nonce} · threshold: ${await safe.getThreshold()} · owners: ${(await safe.getOwners()).join(", ")}`);

  const domain = { chainId: 999, verifyingContract: SAFE };
  const safeTxHash = ethers.TypedDataEncoder.hash(domain, SAFE_TX_TYPES, txStruct);
  console.log(`safeTxHash: ${safeTxHash}`);

  // Cross-check against the Safe's own hasher when the version exposes it.
  try {
    const onchain = await safe.getTransactionHash(
      to, 0n, data, 0, 0n, 0n, 0n, ethers.ZeroAddress, ethers.ZeroAddress, nonce
    );
    console.log(`on-chain hash: ${onchain} ${onchain === safeTxHash ? "✓ matches" : "✗ MISMATCH"}`);
    if (onchain !== safeTxHash) { console.error("REFUSING: EIP-712 hash mismatch"); process.exit(3); }
  } catch (e) {
    console.log(`(getTransactionHash unavailable on this Safe version — ${e.message.slice(0, 60)}; relying on callStatic)`);
  }

  const sig1 = deployerW.signingKey.sign(safeTxHash).serialized;
  const sig2 = signer2.signingKey.sign(safeTxHash).serialized;
  // Safe requires signatures strictly ascending by owner address.
  const ordered =
    BigInt(deployer.address) < BigInt(signer2.address) ? [sig1, sig2] : [sig2, sig1];
  const signatures = ethers.concat(ordered);

  // ── Simulate, then send ─────────────────────────────────────────────────────
  try {
    await safe.execTransaction.staticCall(
      to, 0n, data, 0, 0n, 0n, 0n, ethers.ZeroAddress, ethers.ZeroAddress, signatures
    );
    console.log("callStatic: ✓ would succeed");
  } catch (e) {
    console.error(`callStatic FAILED: ${(e.shortMessage || e.message || "").slice(0, 200)}`);
    process.exit(3);
  }

  if (!SEND) {
    console.log("\nDRY — not sending. Re-run with MAINNET_OK=1.");
    return;
  }

  const tx = await safe.execTransaction(
    to, 0n, data, 0, 0n, 0n, 0n, ethers.ZeroAddress, ethers.ZeroAddress, signatures
  );
  console.log(`execTransaction sent: ${tx.hash}`);
  const rc = await tx.wait();
  console.log(`confirmed in block ${rc.blockNumber}, gas ${rc.gasUsed}`);

  // Post-state verification per action.
  if (action === "addStrategy") {
    const v = new ethers.Contract(vault, ["function strategies(address) view returns (bool)", "function strategyActive(address) view returns (bool)"], deployer);
    const strategy = process.env.STRATEGY || manifest.dn_core_strategy;
    console.log(`verify: strategies[strategy]=${await v.strategies(strategy)} strategyActive=${await v.strategyActive(strategy)}`);
  } else if (action === "allocate") {
    const v = new ethers.Contract(vault, ["function totalAssets() view returns (uint256)"], deployer);
    console.log(`verify: vault.totalAssets=${ethers.formatUnits(await v.totalAssets(), 6)} USDC`);
    const strategy = process.env.STRATEGY || manifest.dn_core_strategy;
    const usdc = new ethers.Contract(manifest.vault_asset, ["function balanceOf(address) view returns (uint256)"], deployer);
    console.log(`verify: strategy idle USDC=${ethers.formatUnits(await usdc.balanceOf(strategy), 6)}`);
  }
}

main().catch((e) => {
  console.error("safe exec failed:", e.message || e);
  process.exit(1);
});
