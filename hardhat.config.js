require("@nomicfoundation/hardhat-toolbox");
const fs = require("fs");
const deployerKey = fs.readFileSync("/home/user/.hermes/vault_keys/hyperevm_testnet.deployer").toString().trim();
// Anvil well-known dev accounts (default mnemonic) — TESTNET ONLY.
// Derived here so multi-user tests get real, funded signers.
const { HDNodeWallet, Mnemonic } = require("ethers");
const anvilMnemonic = Mnemonic.fromPhrase("test test test test test test test test test test test junk");
const anvilDevKeys = [0, 1, 2, 3].map(i =>
  HDNodeWallet.fromMnemonic(anvilMnemonic, `m/44'/60'/0'/0/${i}`).privateKey
);

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks: {
    hyperTestnet: {
      url: process.env.HYPEREVM_RPC_URL || "http://localhost:8545",
      chainId: 998,
      accounts: [deployerKey, ...anvilDevKeys],
      // Estimation-vs-execution drift on the persistent anvil caused sporadic
      // OOG reverts (gasLimit == gasUsed == estimate). 2x padding kills it.
      gasMultiplier: 2,
    },
  },
  paths: {
    contracts: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
