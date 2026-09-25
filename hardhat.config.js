require("@nomicfoundation/hardhat-toolbox");
// Widens every gas estimate (anvil eth_estimateGas can under-report by a few
// percent → sporadic OutOfGas reverts; see scripts/gas_guard.js). Must load
// before any provider is created.
require("./scripts/gas_guard.js");
const fs = require("fs");
// Anvil well-known dev accounts (default mnemonic) — TESTNET ONLY.
// Derived here so multi-user tests get real, funded signers.
const { HDNodeWallet, Mnemonic } = require("ethers");
const anvilMnemonic = Mnemonic.fromPhrase("test test test test test test test test test test test junk");
const anvilDevKeys = [0, 1, 2, 3].map(i =>
  HDNodeWallet.fromMnemonic(anvilMnemonic, `m/44'/60'/0'/0/${i}`).privateKey
);
// Deployer key resolution order: env override (CI) → local key file →
// well-known anvil dev key #0 (CI compile/slither jobs carry neither, and
// reading a missing file crashed the whole config load with ENOENT).
const KEY_FILE = "/home/user/.hermes/vault_keys/hyperevm_testnet.deployer";
const deployerKey = process.env.DEPLOYER_PRIVATE_KEY ||
  (fs.existsSync(KEY_FILE) ? fs.readFileSync(KEY_FILE).toString().trim() : anvilDevKeys[0]);

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      // Optimizer ON for the deployment build. Rationale (2026-09-24): HyperEVM
      // hard-caps a tx at 3,000,000 gas (block gas limit). The unoptimized vault
      // runtime grew to 15,304 bytes → code deposit alone = 3.06M gas → the
      // deploy tx can never fit. Foundry already builds optimized (runs=200);
      // putting hardhat on the same footing makes the deployment build match
      // the bytecode the whole fuzz/invariant suite exercises.
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
    },
  },
  networks: {
    hyperTestnet: {
      url: process.env.HYPEREVM_RPC_URL || "http://localhost:8545",
      chainId: 998,
      accounts: [deployerKey, ...anvilDevKeys],
      // NOTE: `gasMultiplier` does NOT apply to http-type networks (hardhat
      // only wires it into its in-process/local provider wrappers) — verified
      // 2026-09-23 when a raw anvil estimate went out unmultiplied and OOG'd
      // mid-execution. The margin now lives in scripts/gas_guard.js (3x,
      // provider-level, covers every send and subprocess).
    },
    hyperMainnet: {
      // HyperEVM mainnet (999). The key file is the same ops EOA as testnet
      // (0xaDD8f267…), which is the sanctioned mainnet deployer. Deploys only
      // happen through scripts/deploy_mainnet.js, which carries its own
      // guards (MAINNET_OK=1, chain 999, expected-deployer check, manifest
      // absent). The RPC override exists for anvil fork dry-runs.
      url: process.env.HYPEREVM_MAINNET_RPC_URL || "https://rpc.hyperliquid.xyz/evm",
      chainId: 999,
      accounts: [deployerKey],
    },
  },
  paths: {
    contracts: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
