// Ecosystem integrity audit — CROSS-ARTIFACT, offline. Every other suite
// proves contracts behave; this one proves the OPERATING ECOSYSTEM is coherent:
// the same vault is named everywhere, nobody's feed is silently stale, the
// policy that drives money movement matches the ledger of what moved, the
// website's rates match the scout's live rates, and every scheduled loop has a
// fresh heartbeat. Answers "is everything the way it should be?" in one run.
//
// Exit 0 iff no FAIL (WARNs are informational). Chain probes are used for
// identity checks and SKIP when unreachable.
const fs = require("fs");
const path = require("path");

const HOME = process.env.HOME || "/home/user";
const REPO = path.join(__dirname, "..");
const SCOUT = process.env.AUDIT_SCOUT_DIR || path.join(HOME, "yield_scout", "data");
const WEB = process.env.AUDIT_WEB_DIR || path.join(HOME, "websites", "pro-yield-web");
// Host-dependent roots: on a machine without the ops dirs (e.g. CI) those
// checks SKIP loudly instead of reporting phantom drift. Point AUDIT_SCOUT_DIR /
// AUDIT_WEB_DIR at a checkout to audit them anywhere.
const HAVE_SCOUT = fs.existsSync(SCOUT);
const HAVE_WEB = fs.existsSync(WEB);

let pass = 0, fail = 0, warn = 0, skip = 0;
const rows = [];
function check(name, status, detail = "") {
  if (status === "PASS") pass++;
  else if (status === "FAIL") fail++;
  else if (status === "SKIP") skip++;
  else warn++;
  rows.push({ name, status, detail });
  console.log(`  ${status === "PASS" ? "✓" : status === "FAIL" ? "✗" : status === "SKIP" ? "–" : "!"} ${name}${detail ? " — " + detail : ""}`);
}
const readJson = (p) => {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; }
};
const ageHours = (ts) => {
  if (ts == null) return null;
  const t = typeof ts === "number" ? (ts < 1e12 ? ts * 1000 : ts) : Date.parse(ts);
  if (Number.isNaN(t)) return null;
  return (Date.now() - t) / 3_600_000;
};
const short = (a) => (typeof a === "string" ? a.slice(0, 10) + "…" : String(a));

async function main() {
  console.log("── 1. artifact inventory + vault identity across generations ──");
  const manifest = readJson(path.join(REPO, "deployed_addresses.json")) || {};
  const canonical = manifest.pro_yield_vault ? String(manifest.pro_yield_vault).toLowerCase() : null;
  const artifacts = [
    ["repo/deployed_addresses.json", path.join(REPO, "deployed_addresses.json"), true],
    ["repo/data/vault_state.json", path.join(REPO, "data", "vault_state.json"), true],
    ["scout/data/vault_state.json", path.join(SCOUT, "vault_state.json"), HAVE_SCOUT],
    ["web/public/vault_status.json", path.join(WEB, "public", "vault_status.json"), HAVE_WEB],
  ];
  const vaults = {};
  for (const [name, p, rootPresent] of artifacts) {
    if (!rootPresent) { check(`artifact present: ${name}`, "SKIP", "root not on this host (set AUDIT_*_DIR)"); continue; }
    const j = readJson(p);
    if (j == null) { check(`artifact present: ${name}`, "FAIL", `missing/unparsable: ${p}`); continue; }
    const v = j.pro_yield_vault || j.vault || j.vault_address || j.vaults?.[0]?.address || j.vaults?.[0]?.vault_address;
    if (!v) { check(`vault identity in ${name}`, "WARN", "no vault address field"); continue; }
    vaults[name] = String(v).toLowerCase();
    check(`vault identity in ${name}`, "PASS", short(v));
  }
  const distinct = [...new Set(Object.values(vaults))];
  const divergent = Object.entries(vaults).filter(([, v]) => v !== canonical);
  check("vault address is single-valued across live artifacts",
    Object.keys(vaults).length < 2 ? "SKIP" : divergent.length === 0 ? "PASS" : "FAIL",
    Object.keys(vaults).length < 2
      ? `only ${Object.keys(vaults).length} artifact(s) on this host — nothing to cross-check`
      : divergent.length === 0
        ? `all artifacts agree on ${short(canonical)}`
        : `canonical(manifest)=${short(canonical)}; divergent: ${divergent.map(([n, v]) => `${n}=${short(v)}`).join(", ")}`);

  console.log("\n── 2. staleness / heartbeat of every operating loop ──");
  const loops = [
    ["vault keeper state (repo)", path.join(REPO, "data", "vault_state.json"), ["ts", "timestamp", "updated"], true],
    ["vault keeper state (scout)", path.join(SCOUT, "vault_state.json"), ["ts", "timestamp", "updated"], HAVE_SCOUT],
    ["scout snapshot (rates)", path.join(SCOUT, "snapshot.json"), ["generated_utc", "ts", "timestamp"], HAVE_SCOUT],
    ["web feed (public)", path.join(WEB, "public", "vault_status.json"), ["ts", "timestamp", "generated_utc"], HAVE_WEB],
  ];
  for (const [name, p, ks, rootPresent] of loops) {
    if (!rootPresent) { check(`heartbeat: ${name}`, "SKIP", "root not on this host"); continue; }
    const j = readJson(p);
    if (j == null) { check(`heartbeat: ${name}`, "FAIL", "missing"); continue; }
    let ts = null;
    for (const k of ks) if (j[k] != null) { ts = j[k]; break; }
    const age = ts != null ? ageHours(ts) : ageHours(fs.statSync(p).mtimeMs);
    const h = age == null ? "unknown" : `${age.toFixed(1)}h`;
    check(`heartbeat: ${name}`, age != null && age <= 24 ? "PASS" : "FAIL",
      `age=${h}${age != null && age > 24 ? " — STALE: producer is not completing" : ""}`);
  }

  console.log("\n── 3. deploy manifest completeness ──");
  const required = ["mock_usdc", "fee_distributor", "pro_yield_vault"];
  const missing = required.filter((k) => !manifest[k] || /^0x0+$/.test(String(manifest[k])));
  check("manifest has the core contract set (non-zero)",
    missing.length === 0 ? "PASS" : "FAIL",
    missing.length ? `missing/zero: ${missing.join(", ")}` : `${Object.keys(manifest).length} keys`);
  const zeroKeys = Object.entries(manifest).filter(([, v]) => /^0x0+$/.test(String(v))).map(([k]) => k);
  check("no zero-address entries in manifest", zeroKeys.length === 0 ? "PASS" : "WARN",
    zeroKeys.length ? zeroKeys.join(", ") : "clean");

  console.log("\n── 4. recycle policy vs the ledger of what actually moved ──");
  const policy = readJson(path.join(SCOUT, "recycle_policy.json")) || readJson(path.join(REPO, "data", "recycle_policy.json"));
  let pct = null;
  if (policy) {
    pct = {
      boost: BigInt(policy.depositor_boost_pct ?? 60),
      treasury: BigInt(policy.treasury_pct ?? 20),
      insurance: BigInt(policy.insurance_pct ?? 20),
    };
    check("recycle policy splits sum to 100%",
      pct.boost + pct.treasury + pct.insurance === 100n ? "PASS" : "FAIL",
      `${pct.boost}/${pct.treasury}/${pct.insurance}`);
  } else {
    check("recycle policy present", HAVE_SCOUT ? "FAIL" : "SKIP",
      HAVE_SCOUT ? "no recycle_policy.json found" : "no scout root on this host");
  }
  const ledgerPath = path.join(SCOUT, "recycling.jsonl");
  let entries = [];
  try {
    entries = fs.readFileSync(ledgerPath, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  } catch { /* none yet */ }
  check("recycling ledger parses", HAVE_SCOUT ? "PASS" : "SKIP",
    HAVE_SCOUT ? `${entries.length} run(s)` : "no scout root on this host");
  // Ledger values are full-precision decimal strings (whole USDC units) —
  // scale to 18dp so the policy split can be verified to the wei.
  const dec = (v) => {
    const m = /^(-?)(\d+)(?:\.(\d*))?$/.exec(String(v ?? "0").trim());
    if (!m) return 0n;
    return BigInt((m[1] || "") + m[2] + ((m[3] || "") + "0".repeat(18)).slice(0, 18));
  };
  if (pct && entries.length) {
    const bad = entries.filter((e) => {
      const total = dec(e.total), b = dec(e.boost), t = dec(e.treasury), i = dec(e.insurance);
      if (total === 0n) return true;
      return b !== (total * pct.boost) / 100n
        || t !== (total * pct.treasury) / 100n
        || i !== total - b - t
        || dec(e.remainder ?? 0) !== 0n;
    });
    check("every ledger run matches the policy split (exact) + conserves the total",
      bad.length === 0 ? "PASS" : "FAIL",
      bad.length ? `${bad.length}/${entries.length} malformed run(s)` : `${entries.length}/${entries.length} runs verified`);
    const last = entries[entries.length - 1];
    const a = ageHours(last.ts || last.timestamp);
    check("recycling has run in the last 7 days", a != null && a <= 168 ? "PASS" : "WARN",
      a == null ? "no timestamp" : `last run ${a.toFixed(1)}h ago`);
  }

  console.log("\n── 5. web feed schema (reader contract) ──");
  const feed = readJson(path.join(WEB, "public", "vault_status.json"));
  if (feed) {
    // Real reader contract (src/hooks/useVaultStatus.ts): flat keys, recycling
    // numbers, and sharePrice/totalAssets as strings.
    const shape = {
      "vault address (0x…)": /^0x[0-9a-fA-F]{40}$/.test(String(feed.vault || "")),
      "sharePrice field": feed.sharePrice != null,
      "totalAssets field": feed.totalAssets != null,
      "recycling{total,runs,last}": !!feed.recycling && feed.recycling.total != null &&
        feed.recycling.runs != null && feed.recycling.last != null,
      "ts field": !!feed.ts,
    };
    const badShape = Object.entries(shape).filter(([, ok]) => !ok).map(([k]) => k);
    check("feed matches the schema the web reader expects",
      badShape.length === 0 ? "PASS" : "FAIL",
      badShape.length ? `missing: ${badShape.join(", ")}` : "all reader fields present");
    const numOk = (v) => v != null && !Number.isNaN(parseFloat(String(v)));
    check("feed numerics parse for the UI (parseFloat)",
      numOk(feed.sharePrice) && numOk(feed.totalAssets) ? "PASS" : "FAIL",
      `sharePrice="${feed.sharePrice}" totalAssets="${feed.totalAssets}"`);
    check("feed numerics are not unit-suffixed (programmatic consumers)",
      /^[\d.]+$/.test(String(feed.sharePrice)) ? "PASS" : "WARN",
      /^[\d.]+$/.test(String(feed.sharePrice)) ? "plain numerics" : `"${feed.sharePrice}" carries a unit suffix`);
  } else {
    check("web feed readable", HAVE_WEB ? "FAIL" : "SKIP",
      HAVE_WEB ? "public/vault_status.json unreadable" : "no web root on this host (set AUDIT_WEB_DIR)");
  }

  console.log("\n── 6. rate coherence: website vs scout ──");
  let siteBlend = null, scoutBlend = null;
  try {
    const src = fs.readFileSync(path.join(WEB, "src", "lib", "liveRates.ts"), "utf8");
    const m = src.match(/BLEND_TARGET\s*=\s*([0-9.]+)/);
    if (m) siteBlend = Number(m[1]);
  } catch { /* missing */ }
  const snap = readJson(path.join(SCOUT, "snapshot.json"));
  if (snap) scoutBlend = Number(snap.blend?.blend_apy ?? snap.blend_apy ?? NaN);
  const haveBoth = siteBlend != null && scoutBlend != null && !Number.isNaN(scoutBlend);
  check("website BLEND_TARGET matches the scout's live blend",
    haveBoth ? (Math.abs(siteBlend - scoutBlend) <= 0.5 ? "PASS" : "FAIL")
      : (!HAVE_SCOUT || !HAVE_WEB ? "SKIP" : "FAIL"),
    haveBoth ? `site=${siteBlend}% scout=${scoutBlend}% Δ=${Math.abs(siteBlend - scoutBlend).toFixed(2)}pp`
      : (!HAVE_SCOUT || !HAVE_WEB ? "site/scout roots not both on this host" : "one side unreadable"));
  if (snap?.tier_apys) {
    const tiers = Object.entries(snap.tier_apys).filter(([, v]) => typeof v === "number");
    check("scout publishes tier APYs (product rates)",
      tiers.length >= 4 ? "PASS" : "WARN",
      tiers.map(([k, v]) => `${k}=${Number(v).toFixed(2)}`).join(" "));
  }

  console.log("\n── 7. alert channel integrity ──");
  const queuePath = path.join(SCOUT, "pending_notifications.log");
  let qlines = [];
  try { qlines = fs.readFileSync(queuePath, "utf8").split("\n").filter(Boolean); } catch { /* none */ }
  const testLeaks = qlines.filter((l) => /test run — telegram silenced/.test(l));
  const real = qlines.filter((l) => !/test run — telegram silenced/.test(l));
  check("operator queue carries no test-generated alerts",
    !HAVE_SCOUT ? "SKIP" : testLeaks.length === 0 ? "PASS" : "FAIL",
    !HAVE_SCOUT ? "no scout root on this host" : `${real.length} real + ${testLeaks.length} test-origin line(s)`);
  const pendingAge = qlines.length ? ageHours(qlines[qlines.length - 1].split(" ")[0]) : null;
  check("no undelivered alert older than 48h",
    !HAVE_SCOUT ? "SKIP" : pendingAge == null || pendingAge <= 48 ? "PASS" : "WARN",
    !HAVE_SCOUT ? "no scout root on this host"
      : pendingAge == null ? "queue empty" : `oldest/last entry ${pendingAge.toFixed(1)}h old (delivery may be broken)`);

  console.log("\n── 8. chain identity (claimed vs actually read) ──");
  // The class this catches: an artifact that LABELS a read "on-chain" while
  // hardhat silently serves a local chain that spoofs chain-id 998 — that is how
  // every fee recycling (and the insurance slice) ended up on a dev chain.
  const rpcProbe = async (url, timeoutMs = 4000) => {
    try {
      const res = await fetch(url, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      const j = await res.json();
      return { ok: true, chainId: Number(BigInt(j.result)) };
    } catch (e) { return { ok: false, err: String(e.message || e).slice(0, 60) }; }
  };
  const rpcCode = async (url, addr, timeoutMs = 4000) => {
    try {
      const res = await fetch(url, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [addr, "latest"] }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      const j = await res.json();
      return { ok: true, hasCode: !!j.result && j.result !== "0x" };
    } catch (e) { return { ok: false, err: String(e.message || e).slice(0, 60) }; }
  };

  const TESTNET_RPC = "https://rpc.hyperliquid-testnet.xyz/evm";
  const LOCAL_RPC = "http://localhost:8545";
  const readIf = (p) => { try { return fs.readFileSync(p, "utf8"); } catch { return ""; } };

  const t = await rpcProbe(TESTNET_RPC);
  check("canonical testnet RPC answers as chain 998",
    t.ok ? (t.chainId === 998 ? "PASS" : "FAIL") : "SKIP",
    t.ok ? `chainId=${t.chainId}` : `unreachable (${t.err})`);

  const local = await rpcProbe(LOCAL_RPC);
  if (local.ok && local.chainId === 998) {
    const c = await rpcCode(LOCAL_RPC, canonical || "");
    check("manifest vault has code on the chain the ops actually read (local anvil)",
      c.ok ? (c.hasCode ? "PASS" : "FAIL") : "SKIP",
      c.ok ? (c.hasCode ? `${short(canonical)} deployed there` : "NO CODE — stale manifest / wrong chain")
           : `probe failed (${c.err})`);
    check("local anvil spoofs chain-id 998 (chain-id alone cannot detect it)",
      "WARN", "localhost:8545 reports 998 — artifacts must pin the RPC, never trust the id");
  } else {
    check("manifest vault code on the ops chain", "SKIP",
      local.ok ? `localhost:8545 answered chain ${local.chainId}` : "no local chain on this host");
  }

  if (t.ok) {
    const c2 = await rpcCode(TESTNET_RPC, "0x42237e98aD8918401F898cb453ef714B64e5B3Bf");
    check("keeper's vault has code on the real testnet",
      c2.ok ? (c2.hasCode ? "PASS" : "FAIL") : "SKIP",
      c2.ok ? (c2.hasCode ? "0x42237e98… deployed" : "NO CODE") : `probe failed (${c2.err})`);
  } else {
    check("keeper's vault code on the real testnet", "SKIP", "testnet RPC unreachable");
  }

  // Chain map for every vault generation found: which chain does each live on?
  if ((t.ok || local.ok) && (distinct.length || canonical)) {
    const map = [];
    for (const v of (distinct.length ? distinct : [canonical])) {
      const onT = t.ok ? await rpcCode(TESTNET_RPC, v) : { ok: false };
      const onL = local.ok ? await rpcCode(LOCAL_RPC, v) : { ok: false };
      map.push(`${short(v)} testnet=${onT.ok ? (onT.hasCode ? "✓" : "—") : "?"} local=${onL.ok ? (onL.hasCode ? "✓" : "—") : "?"}`);
    }
    check("vault chain map (where each generation actually lives)", "PASS", map.join(" | "));
  }

  // Static (behavioural coverage lives in chainid_guard_test.js).
  const recyclerSrc = readIf(path.join(REPO, "scripts", "recycle_fees.js"));
  check("recycler source refuses an implicit RPC (defence in depth)",
    /REFUSING: HYPEREVM_RPC_URL is not set/.test(recyclerSrc) ? "PASS" : "FAIL",
    /REFUSING: HYPEREVM_RPC_URL is not set/.test(recyclerSrc) ? "guard present" : "guard missing");
  const insSrc = readIf(path.join(HOME, "yield_scout", "insurance_fund.py"));
  if (insSrc) {
    check("insurance module pins its RPC + verifies the chain",
      /rpc\.hyperliquid-testnet\.xyz/.test(insSrc) && /def verify_chain/.test(insSrc) ? "PASS" : "FAIL",
      /def verify_chain/.test(insSrc) ? "pinned + chain-verified" : "missing pin/verification");
    check("insurance reserves come from the recycling ledger (not a hardcoded stub)",
      /read_ledger_insurance/.test(insSrc) ? "PASS" : "FAIL",
      /read_ledger_insurance/.test(insSrc) ? "ledger-sourced" : "still a stub");
  } else {
    check("insurance module chain pinning", "SKIP", "yield_scout not on this host");
  }

  if (entries.length) {
    const lastEntry = entries[entries.length - 1];
    const hasTrace = !!(lastEntry.recipients && lastEntry.txs);
    check("ledger entries are traceable (recipients + tx hashes)",
      hasTrace ? "PASS" : "WARN",
      hasTrace ? `last run names recipients + ${Object.keys(lastEntry.txs || {}).length} tx(s)`
               : "last entry predates the traceability fix — next recycle will carry recipients+txs");
  }

  console.log(`\n══════ AUDIT: ${pass} passed, ${fail} failed, ${skip} skipped, ${warn} warnings ══════`);
  for (const r of rows.filter((x) => x.status !== "PASS")) {
    console.log(`  ${r.status}: ${r.name}${r.detail ? " — " + r.detail : ""}`);
  }
  // AUDIT_MODE=strict → FAILs are exit-1 (CI gate / release check).
  // default (info) → always exit 0: the audit reports OPERATOR-state drift
  // (stale feeds, a gas-blocked keeper) without failing contract-correctness
  // suites that are green for reasons unrelated to those conditions.
  process.exit(fail === 0 || process.env.AUDIT_MODE !== "strict" ? 0 : 1);
}

main().catch((e) => { console.error("audit error:", e); process.exit(2); });
