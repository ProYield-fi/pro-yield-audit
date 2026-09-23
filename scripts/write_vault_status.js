// scripts/write_vault_status.js — render vault_status.json for the web app
// from the CURRENT chain state (manifest-driven). Mirrors the shape the
// keeper publishes in production (vault_keeper.py); used by the local web
// smoke (scripts/web_smoke.sh) so the UI can be exercised against a local
// anvil. SMOKE_TAG, when set, is embedded in `network` so the smoke proves
// the page served THIS generation of the file.
//
// Chain identity: when the manifest declares a chain (`chain.id` + `chain.rpc`)
// this writer reads the provider's ACTUAL chain id and REFUSES to publish on a
// mismatch — the class of bug where a local anvil spoofing 998 served numbers
// labelled "on-chain". A manifest without a chain block keeps the sandbox/smoke
// label (the battery's cold-start manifests have no chain block).
//
// Run: npx hardhat run scripts/write_vault_status.js --network hyperTestnet
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const WEB = "/home/user/websites/pro-yield-web";

async function readTotalShares(addr) {
  // Vault generations differ: the audited repo vault exposes totalShares(),
  // the newer ERC-4626-style deployment exposes totalSupply(). Raw
  // human-readable ABI — the repo artifact lacks totalSupply(), and an
  // ABI-gated call would throw "function not found" and mask the real revert.
  const c = new hre.ethers.Contract(addr, [
    "function totalShares() view returns (uint256)",
    "function totalSupply() view returns (uint256)",
  ], hre.ethers.provider);
  try { return await c.totalShares(); } catch { /* fall through */ }
  try { return await c.totalSupply(); } catch { /* fall through */ }
  throw new Error("vault exposes neither totalShares() nor totalSupply()");
}

async function readScales(vaultAddr) {
  // [assetDecimals, shareDecimals]; both default to 18 (repo generation).
  let assetDec = 18;
  let shareDec = 18;
  try {
    const vc = new hre.ethers.Contract(vaultAddr, [
      "function asset() view returns (address)",
      "function decimals() view returns (uint8)",
    ], hre.ethers.provider);
    try { shareDec = Number(await vc.decimals()); } catch { /* repo gen */ }
    try {
      const assetAddr = await vc.asset();
      const ac = new hre.ethers.Contract(assetAddr, ["function decimals() view returns (uint8)"], hre.ethers.provider);
      assetDec = Number(await ac.decimals());
    } catch { /* no asset() — repo gen: 18dp mock accounting */ }
  } catch { /* not an ERC-4626-style vault */ }
  return [assetDec, shareDec];
}

async function main() {
  const deployed = JSON.parse(
    fs.readFileSync(process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json"), "utf8"),
  );
  const declared = deployed.chain || null;
  const net = await hre.ethers.provider.getNetwork();
  const actual = Number(net.chainId);

  if (declared?.id && Number(declared.id) !== actual) {
    console.error(`REFUSING: manifest declares chain ${declared.id} but the RPC answers ${actual} — not publishing a mislabelled feed.`);
    process.exit(3);
  }
  if (!deployed.pro_yield_vault) {
    console.error("REFUSING: manifest declares no pro_yield_vault.");
    process.exit(3);
  }
  const code = await hre.ethers.provider.getCode(deployed.pro_yield_vault);
  if (code === "0x") {
    console.error(`REFUSING: no code at vault ${deployed.pro_yield_vault} on chain ${actual}.`);
    process.exit(3);
  }

  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);
  const totalAssets = await vault.totalAssets();
  const totalShares = await readTotalShares(deployed.pro_yield_vault);
  const [assetDec, shareDec] = await readScales(deployed.pro_yield_vault);
  // Shares below one whole unit at their declared scale are a unit mismatch,
  // not a fact (the testnet vault declares 18 but counts in the asset's 6).
  const shownShareDec = totalShares > 0n && totalShares < 10n ** BigInt(shareDec) ? assetDec : shareDec;
  const price18 = totalShares > 0n ? (totalAssets * 10n ** 18n) / totalShares : 10n ** 18n;
  const F = (x, dec, unit) => `${hre.ethers.formatUnits(x, dec)} ${unit}`;

  const tag = process.env.SMOKE_TAG;
  const status = {
    vault: deployed.pro_yield_vault,
    sharePrice: F(price18, 18, "USDC"),
    totalAssets: F(totalAssets, assetDec, "USDC"),
    totalShares: F(totalShares, shownShareDec, "shares"),
    targetApyBps: null,
    recycling: { total: 0, boost: 0, runs: 0, last: null },
    ts: new Date().toISOString(),
    // Honest label: the declared chain when the manifest names one, otherwise
    // the local smoke path (the web smoke runs against the battery's anvil).
    network: declared
      ? `${declared.name || "chain " + declared.id} (chain ${declared.id}, verified)${tag ? " " + tag : ""}`
      : `local smoke${tag ? " " + tag : ""} (anvil, chain 998)`,
    chainId: actual,
    source: "scripts/write_vault_status.js",
  };

  const outs = [process.env.VAULT_STATUS_OUT || path.join(WEB, "public", "vault_status.json")];
  const dist = path.join(WEB, "dist", "vault_status.json");
  if (fs.existsSync(path.dirname(dist))) outs.push(dist);
  for (const o of outs) {
    fs.writeFileSync(o, JSON.stringify(status, null, 1));
    console.log("wrote", o);
  }
  console.log(`totalAssets=${status.totalAssets} sharePrice=${status.sharePrice}`);
}

main().catch((e) => {
  console.error("write_vault_status error:", (e && e.stack) || e);
  process.exit(2);
});
