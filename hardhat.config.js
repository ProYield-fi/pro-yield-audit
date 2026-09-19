require("@nomicfoundation/hardhat-toolbox");
const fs = require("fs");
const deployerKey = fs.readFileSync("/home/user/.hermes/vault_keys/hyperevm_testnet.deployer").toString().trim();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks: {
    hyperTestnet: {
      url: "http://localhost:8545",
      chainId: 998,
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
