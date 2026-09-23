// Gas headroom guard for anvil-backed suites.
//
// Root cause (proven by replaying a failed tx with `cast run`, 2026-09-23):
// anvil's eth_estimateGas occasionally under-reports by a few thousand gas
// (cold/warm accounting drift). Hardhat's `networks.*.gasMultiplier` does NOT
// apply to http-type networks — it is only wired into the in-process/local
// provider wrappers — so every send went out with gasLimit == the raw
// estimate, and an unlucky short estimate reverted OutOfGas mid-execution:
// a sporadic, sample-dependent flake in ANY suite (~1/12 runs of the pyd
// suite locally, also seen in CI with pyd_demand_tests and elsewhere).
//
// Fix: multiply every estimateGas result by GAS_MARGIN at the provider layer.
// Unused gas is refunded, so the margin is free — it only widens the limit.
// Loaded from hardhat.config.js so it covers every `hardhat run` script and
// every spawned hardhat subprocess (e.g. the keeper suites).
const GAS_MARGIN = 3n;

try {
  // eslint-disable-next-line global-require
  const { HardhatEthersProvider } = require("@nomicfoundation/hardhat-ethers/internal/hardhat-ethers-provider");
  const proto = HardhatEthersProvider.prototype;
  if (!proto.__gasGuardPatched) {
    const orig = proto.estimateGas;
    proto.estimateGas = async function (tx, ...rest) {
      const est = await orig.call(this, tx, ...rest);
      return BigInt(est) * GAS_MARGIN;
    };
    proto.__gasGuardPatched = true;
  }
} catch (e) {
  // If hardhat-ethers ever moves its internals, fail loudly instead of
  // silently reintroducing the OOG flake.
  throw new Error("gas_guard.js could not patch HardhatEthersProvider: " + e.message);
}