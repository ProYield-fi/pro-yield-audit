require("@nomicfoundation/hardhat-toolbox");
const fs = require("fs");
const deployerKey = fs.readFileSync("/home/user/.hermes/vault_keys/hyperevm_testnet.deployer").toString().trim();
// Anvil well-known dev key #0 — TESTNET ONLY (publicly known, zero funds on mainnet).
// Needed so test scripts get a second signer (getSigners()[1] for onlyOwner tests).
const anvilDevKey0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks: {
    hyperTestnet: {
      url: "http://localhost:8545",
      chainId: 998,
      accounts: [deployerKey, anvilDevKey0],
    },
  },
  paths: {
    contracts: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};
