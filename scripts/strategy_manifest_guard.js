// scripts/strategy_manifest_guard.js — read-only invariant: every strategy
// REGISTERED in the live vault's on-chain `strategyList` must be NAMED
// somewhere in deployed_addresses.mainnet.json.
//
// Why: the on-chain `strategyList` is the source of truth (runbook: never
// enumerate strategies from the manifest). The manifest is only a record, and
// it silently fell behind once — docs/AUDIT_HANDOFF_2026-09-30.md flagged it,
// and it was STILL true on 2026-10-10 (7 registered on-chain, the manifest
// named 5; kanban t_ed8b04aa, finding t_edbb5fb7). This guard makes that drift
// loud instead of silent.
//
// DEGRADED-DATA SAFE: "found nothing" is not "absent". If the RPC cannot be
// read (throttle/timeout), the guard reports DEGRADED and FAILS — it never
// returns OK on a failed or empty read (degraded endpoints have burned this
// project before).
//
// READ-ONLY: eth_call + file read only. Never sends, never writes, never
// changes a deployed address/cap/fee. Safe to run in the sentinel loop.
//
// Standalone:
//   node scripts/strategy_manifest_guard.js
//     exit 0 = clean · 1 = drift · 2 = DEGRADED (read failed / empty)
// Exported:
//   checkStrategyManifestDrift({ ethers, heProvider, manifestPath, vault })
//     -> { ok, degraded, empty, reason, vault,
//          live:[{index,address,active}], missing:[...], manifestValues }
//
// Wired into scripts/vault_watch_mainnet.js (the 10-min sentinel) with a
// latched drift alert + a degraded-read streak alert.

const fs = require("fs");
const path = require("path");

const DEFAULT_MANIFEST = path.join(__dirname, "..", "deployed_addresses.mainnet.json");
const VAULT_ABI = [
  "function strategyList(uint256) view returns (address)",
  "function strategyActive(address) view returns (bool)",
];
const ZERO = "0x0000000000000000000000000000000000000000";
const MAX_SLOTS = 64;
const MAX_ATTEMPTS = 3;

// Recursively collect every 20-byte address that appears as a VALUE under an
// OPERATIVE manifest key (any key that is not a doc/notes block). Key-agnostic
// on purpose — the invariant is "the manifest binds the strategy", not a
// particular key spelling — but the `strategyList_reconciled` block and any
// `_`-prefixed note are documentation, so an address that lives ONLY there does
// NOT satisfy the invariant (it must have a real role/address key).
const SKIP_KEYS = new Set(["strategyList_reconciled"]);
const isDocKey = (k) => SKIP_KEYS.has(k) || String(k).startsWith("_");

function collectAddressValues(node, out) {
  if (typeof node === "string") {
    if (/^0x[0-9a-fA-F]{40}$/.test(node)) out.add(node.toLowerCase());
  } else if (Array.isArray(node)) {
    for (const v of node) collectAddressValues(v, out);
  } else if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) {
      if (isDocKey(k)) continue;
      collectAddressValues(v, out);
    }
  }
}

// One enumeration attempt. Returns { live, degraded, reason }.
async function enumerate(v) {
  const live = [];
  for (let i = 0; i < MAX_SLOTS; i++) {
    let addr;
    try {
      addr = await v.strategyList(i);
    } catch (e) {
      if (i === 0) {
        // Could not read even slot 0 — a DEGRADED read (RPC throttle/timeout),
        // NOT an empty list. Do not mistake it for "nothing registered".
        return { live, degraded: true, reason: (e && (e.shortMessage || e.message)) || String(e) };
      }
      break; // out-of-range index reverts — genuine end of list
    }
    if (!addr || addr.toLowerCase() === ZERO) break;
    let active = null;
    try {
      active = await v.strategyActive(addr);
    } catch {
      /* optional read — never gates the invariant */
    }
    live.push({ index: i, address: addr, active });
  }
  return { live, degraded: false, reason: null };
}

async function checkStrategyManifestDrift({ ethers, heProvider, manifestPath, vault } = {}) {
  const mp = manifestPath || DEFAULT_MANIFEST;
  const manifest = JSON.parse(fs.readFileSync(mp, "utf8"));
  const V = vault || manifest.pro_yield_vault;
  const manifestValues = new Set();
  collectAddressValues(manifest, manifestValues);

  const v = new ethers.Contract(V, VAULT_ABI, heProvider);
  let live = [];
  let degraded = false;
  let reason = null;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    const r = await enumerate(v);
    if (!r.degraded) {
      live = r.live;
      degraded = false;
      reason = null;
      break;
    }
    live = r.live;
    degraded = true;
    reason = r.reason;
  }

  const empty = !degraded && live.length === 0;
  const missing = live.filter((s) => !manifestValues.has(s.address.toLowerCase()));
  return {
    ok: !degraded && !empty && missing.length === 0,
    degraded,
    empty,
    reason,
    vault: V,
    live,
    missing,
    manifestValues: manifestValues.size,
  };
}

module.exports = { checkStrategyManifestDrift, collectAddressValues, DEFAULT_MANIFEST };

if (require.main === module) {
  (async () => {
    const { ethers } = require("ethers");
    const provider = new ethers.JsonRpcProvider(
      process.env.HYPEREVM_RPC_URL || "https://rpc.hyperliquid.xyz/evm",
      999,
    );
    const r = await checkStrategyManifestDrift({ ethers, heProvider: provider });
    console.log(`strategy_manifest_guard — vault ${r.vault}`);
    console.log(`live strategyList: ${r.live.length} registered (${r.manifestValues} addresses named in the manifest)`);
    const missingIdx = new Set(r.missing.map((m) => m.index));
    for (const s of r.live) {
      console.log(`  [${s.index}] ${s.address} active=${s.active} ${missingIdx.has(s.index) ? "MISSING" : "named"}`);
    }
    if (r.degraded) {
      console.error(`\nDEGRADED: could not read the live strategyList after ${MAX_ATTEMPTS} attempts — ${r.reason}`);
      console.error("Drift CANNOT be assessed. Do NOT treat this as OK (degraded data is not absent data).");
      process.exit(2);
    }
    if (r.empty) {
      console.error("\nDEGRADED: the live strategyList read returned EMPTY — verify the read before trusting it.");
      process.exit(2);
    }
    if (!r.ok) {
      console.error(`\nDRIFT: ${r.missing.length} registered strateg${r.missing.length === 1 ? "y is" : "ies are"} NOT named in the manifest:`);
      for (const m of r.missing) console.error(`  [${m.index}] ${m.address}`);
      process.exit(1);
    }
    console.log("\nOK — every registered strategy is named in the manifest.");
  })().catch((e) => {
    console.error("strategy_manifest_guard failed:", (e && e.message) || e);
    process.exit(2);
  });
}
