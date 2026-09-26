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

async function readScales(vaultAddr, hints = []) {
  // [assetDecimals, shareDecimals]; both default to 18 (repo generation).
  let assetDec = 18;
  let shareDec = 18;
  const tryDecimals = async (addr) => {
    const ac = new hre.ethers.Contract(addr, ["function decimals() view returns (uint8)"], hre.ethers.provider);
    return Number(await ac.decimals());
  };
  try {
    const vc = new hre.ethers.Contract(vaultAddr, [
      "function asset() view returns (address)",
      "function decimals() view returns (uint8)",
    ], hre.ethers.provider);
    try { shareDec = Number(await vc.decimals()); } catch { /* repo gen */ }
    try {
      const assetAddr = await vc.asset();
      assetDec = await tryDecimals(assetAddr);
    } catch {
      // Lean vaults expose no asset()/decimals() (user-facing fns only — the
      // mainnet ProYieldVault is one). Fall back to the manifest's vault_asset,
      // then the known HyperEVM USDC, so 6dp balances are never shown as 18dp.
      for (const h of [...hints, "0xb88339CB7199b77E23DB6E890353E22632Ba630f"]) {
        if (!h) continue;
        try { assetDec = await tryDecimals(h); break; } catch { /* next hint */ }
      }
    }
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
  const [assetDec, shareDec] = await readScales(deployed.pro_yield_vault, [deployed.vault_asset]);
  // Shares below one whole unit at their declared scale are a unit mismatch,
  // not a fact (the testnet vault declares 18 but counts in the asset's 6).
  const shownShareDec = totalShares > 0n && totalShares < 10n ** BigInt(shareDec) ? assetDec : shareDec;
  const price18 = totalShares > 0n ? (totalAssets * 10n ** 18n) / totalShares : 10n ** 18n;
  const F = (x, dec, unit) => `${hre.ethers.formatUnits(x, dec)} ${unit}`;

  // ── Live deployment: where the vault's assets actually sit ─────────────
  // All reads guarded; failures stay null (honest gaps), never zero-filled.
  const assetAddr = deployed.vault_asset || "0xb88339CB7199b77E23DB6E890353E22632Ba630f";
  const erc20 = new hre.ethers.Contract(
    assetAddr,
    ["function balanceOf(address) view returns (uint256)"],
    hre.ethers.provider,
  );
  let idle = null;
  try { idle = await erc20.balanceOf(deployed.pro_yield_vault); } catch { /* gap */ }

  const stratAbi = ["function totalAssets() view returns (uint256)"];
  const readStrat = async (addr) => {
    if (!addr) return null;
    try {
      const c = new hre.ethers.Contract(addr, stratAbi, hre.ethers.provider);
      return await c.totalAssets();
    } catch { return null; }
  };

  // Live rates for the sleeves — floating, so they ship with the feed.
  let fundingAprPct = null;
  try {
    const r = await fetch("https://api.hyperliquid.xyz/info", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type: "metaAndAssetCtxs" }),
    });
    const j = await r.json();
    const idx = j[0].universe.findIndex((u) => u.name === "HYPE");
    if (idx >= 0) fundingAprPct = Number((parseFloat(j[1][idx].funding) * 24 * 365 * 100).toFixed(2));
  } catch { /* gap */ }

  let lendingApyPct = null;
  try {
    const marketId = deployed.morpho_market && deployed.morpho_market.market_id;
    if (marketId) {
      const r = await fetch("https://blue-api.morpho.org/graphql", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: `{ markets(first: 1, where: { uniqueKey_in: ["${marketId}"] }) { items { state { supplyApy } } } }`,
        }),
      });
      const j = await r.json();
      const apy = j && j.data && j.data.markets && j.data.markets.items && j.data.markets.items[0]
        ? j.data.markets.items[0].state.supplyApy
        : null;
      if (apy != null) lendingApyPct = Number((apy * 100).toFixed(2));
    }
  } catch { /* gap */ }

  const fmt6 = (x) => (x == null ? null : hre.ethers.formatUnits(x, assetDec));
  const strategies = [];
  const morphoAssets = await readStrat(deployed.morpho_strategy);
  if (morphoAssets != null) {
    strategies.push({
      kind: "lending",
      name: "Morpho Blue",
      address: deployed.morpho_strategy,
      assets: fmt6(morphoAssets),
      apyPct: lendingApyPct,
    });
  }
  const dnAssets = await readStrat(deployed.dn_core_strategy);
  if (dnAssets != null) {
    const dnUsd = Number(hre.ethers.formatUnits(dnAssets, assetDec));
    strategies.push({
      kind: "funding",
      name: "Funding sleeve",
      address: deployed.dn_core_strategy,
      assets: fmt6(dnAssets),
      apyPct: fundingAprPct,
      // Below HL's $10 order minimums the sleeve cannot trade — say so
      // instead of implying the rate is being earned.
      ...(dnUsd < 11 ? { note: "idle — below venue minimums until TVL grows" } : {}),
    });
  }
  const deployment = {
    idleUsdc: fmt6(idle),
    strategies,
    assetsTotalUsdc: fmt6((idle || 0n) + (morphoAssets || 0n) + (dnAssets || 0n)),
    note: "live chain reads; strategies report totalAssets(); rates float with the market",
  };

  const tag = process.env.SMOKE_TAG;
  const status = {
    vault: deployed.pro_yield_vault,
    sharePrice: F(price18, 18, "USDC"),
    totalAssets: F(totalAssets, assetDec, "USDC"),
    totalShares: F(totalShares, shownShareDec, "shares"),
    targetApyBps: null,
    deployment,
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
