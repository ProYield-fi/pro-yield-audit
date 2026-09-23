// Chain guard — the single place every money-moving script can check the
// network it is about to touch. HyperEVM TESTNET (998) only: "never mainnet"
// must be enforced by code, not by convention.
//
// Usage:  npx hardhat run scripts/chain_guard.js --network hyperTestnet
// Exit:   0 = chain 998 (safe) · 3 = REFUSED (wrong chain, nothing was sent)
const hre = require("hardhat");

const ALLOWED_CHAIN_IDS = new Set([998]);

async function main() {
  const net = await hre.ethers.provider.getNetwork();
  const id = Number(net.chainId);
  const rpc = process.env.HYPEREVM_RPC_URL || "(hardhat default)";
  if (!ALLOWED_CHAIN_IDS.has(id)) {
    console.error(`REFUSING: chain ${id} is not HyperEVM testnet (998) — never mainnet. rpc=${rpc}`);
    process.exit(3);
  }
  console.log(`chain guard ok: chain ${id} (${rpc})`);
}

main().catch((e) => { console.error("chain guard failed to evaluate:", e.message); process.exit(4); });
