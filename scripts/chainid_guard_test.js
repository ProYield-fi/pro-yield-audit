// Chain-guard test — proves "never mainnet" is enforced by CODE, not convention.
//
// Method: stand up a throwaway anvil whose chain id IS 1 (mainnet's id) on a
// spare port, point each money-moving entry point at it, and require every one
// of them to refuse before sending anything. Then flip to the real testnet-id
// chain (the battery's own anvil, 998) as a positive control so the guard can
// never become a brick that blocks legitimate runs.
//
// Nothing here touches the shared chain: the decoy anvil is private to this
// suite and is killed in a finally block (process-group kill, never a pattern
// pkill — that has collateral-killed sibling runs before).
const hre = require("hardhat");
const { spawn, execSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) pass++; else fail++;
  console.log(`${ok ? "  ✓" : "  ✗"} ${name}${detail ? " — " + detail : ""}`);
}

const REPO = path.join(__dirname, "..");
const DECOY_PORT = Number(process.env.GUARD_DECOY_PORT || 8559);
const REAL_PORT = Number(process.env.BATTERY_PORT || 8547);

function anvilBinary() {
  try {
    const p = execSync("command -v anvil", { encoding: "utf8" }).trim();
    if (p) return p;
  } catch { /* not on PATH */ }
  const alt = "/home/user/.config/.foundry/bin/anvil";
  return fs.existsSync(alt) ? alt : null;
}

async function rpcChain(port) {
  const res = await fetch(`http://localhost:${port}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
    signal: AbortSignal.timeout(3000),
  });
  const j = await res.json();
  return Number(BigInt(j.result));
}

// Run a hardhat script against a given RPC and capture rc + output.
function runScript(args, rpcUrl, extraEnv = {}) {
  try {
    const out = execSync(args, {
      cwd: REPO, encoding: "utf8", timeout: 120000, stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, HYPEREVM_RPC_URL: rpcUrl, ...extraEnv },
    });
    return { rc: 0, out: String(out) };
  } catch (e) {
    return { rc: e.status ?? -1, out: String((e.stdout || "") + (e.stderr || "")) };
  }
}

// Which layer refused? HH101 = hardhat's own config chainId check (fires before
// our code); REFUSING = the explicit guard in the script (raw-provider path).
function refusalLayer(out) {
  if (/HH101|was set to use chain id/i.test(out)) return "hardhat-config";
  if (/REFUSING/.test(out)) return "explicit-guard";
  if (/chain guard failed to evaluate/.test(out)) return "guard-evaluation";
  return "none";
}
function guardPresent(file) {
  try { return /REFUSING/.test(fs.readFileSync(path.join(REPO, "scripts", file), "utf8")); }
  catch { return false; }
}

async function main() {
  const bin = anvilBinary();
  if (bin) report("anvil binary located", true, bin);
  else {
    // No anvil on this host (some CI images): still run the static guard checks
    // and skip the dynamic ones loudly, so the suite never reds a pipeline for a
    // missing binary while making the gap obvious in the log.
    report("explicit chain guard present in dn_keeper + recycler source",
      guardPresent("dn_keeper.js") && guardPresent("recycle_fees.js"),
      "dynamic refusal checks SKIPPED — no anvil binary on this host");
    console.log(`\n══════ GUARD: ${pass} passed, ${fail} failed (dynamic checks skipped — no anvil) ══════`);
    process.exit(fail === 0 ? 0 : 1);
  }

  // Implicit-RPC class: hardhat silently falls back to http://localhost:8545 when
  // HYPEREVM_RPC_URL is unset — the exact trap that ran every fee recycling (and
  // the insurance slice) on a local chain spoofing chain-id 998. Must refuse,
  // and must refuse before touching the network at all.
  const implicit = runScript("npx hardhat run scripts/recycle_fees.js --network hyperTestnet", "",
    { HYPEREVM_RPC_URL: "" });
  report("recycler refuses an IMPLICIT RPC (unset HYPEREVM_RPC_URL) before touching the network",
    implicit.rc === 3 && /REFUSING: HYPEREVM_RPC_URL is not set/.test(implicit.out),
    `rc=${implicit.rc}`);

  const manifest = path.join(REPO, "deployed_addresses.json");
  const manifestExists = fs.existsSync(manifest);
  let child = null;
  let decoyReady = false;

  try {
    console.log("── decoy chain (id 1 = mainnet's id) ──");
    child = spawn(bin, ["--port", String(DECOY_PORT), "--chain-id", "1", "--silent"],
      { detached: true, stdio: "ignore" });
    for (let i = 0; i < 20 && !decoyReady; i++) {
      await new Promise((r) => setTimeout(r, 500));
      try { decoyReady = (await rpcChain(DECOY_PORT)) === 1; } catch { /* not up yet */ }
    }
    report("decoy chain is live with chain id 1", decoyReady, `port ${DECOY_PORT}`);

    if (decoyReady) {
      const decoyUrl = `http://localhost:${DECOY_PORT}`;

      const g = runScript("npx hardhat run scripts/chain_guard.js --network hyperTestnet", decoyUrl);
      report("chain_guard refuses chain 1 (non-zero + chain-mismatch reason)",
        g.rc !== 0 && refusalLayer(g.out) !== "none", `rc=${g.rc} layer=${refusalLayer(g.out)}`);

      const k = runScript("npx hardhat run scripts/dn_keeper.js --network hyperTestnet", decoyUrl,
        { DN_STRATEGY: "0x000000000000000000000000000000000000dEaD", DN_SILENCE_TELEGRAM: "1" });
      report("dn_keeper refuses chain 1 before touching any strategy",
        k.rc !== 0 && refusalLayer(k.out) !== "none" && !/position|szi|UNWIND/.test(k.out),
        `rc=${k.rc} layer=${refusalLayer(k.out)}`);
      report("dn_keeper carries an EXPLICIT chain guard in source (defence in depth)",
        guardPresent("dn_keeper.js"), guardPresent("dn_keeper.js") ? "explicit guard present" : "missing");

      const r = runScript("npx hardhat run scripts/recycle_fees.js --network hyperTestnet", decoyUrl,
        { DEPLOY_MANIFEST: manifestExists ? manifest : "" });
      report("recycler refuses chain 1 before reading policy/manifest files",
        r.rc !== 0 && refusalLayer(r.out) !== "none" && !/ENOENT|no such file/i.test(r.out),
        `rc=${r.rc} layer=${refusalLayer(r.out)}`);
      report("recycler carries an EXPLICIT chain guard in source (defence in depth)",
        guardPresent("recycle_fees.js"), guardPresent("recycle_fees.js") ? "explicit guard present" : "missing");

      // Python keeper's own guard, exercised in isolation (never run the real
      // keeper here — it has side effects).
      const py = (() => {
        try {
          const out = execSync(
            "python3 -c \"import sys; sys.path.insert(0,'.'); import vault_keeper as k; print('REFUSED' if not k.check_chain() else 'ALLOWED')\"",
            { cwd: REPO, encoding: "utf8", timeout: 60000,
              env: { ...process.env, HYPEREVM_RPC_URL: decoyUrl } });
          return String(out);
        } catch (e) { return String((e.stdout || "") + (e.stderr || "")); }
      })();
      report("vault_keeper.check_chain() refuses chain 1 (raw JSON-RPC path — no hardhat layer)",
        /REFUSED/.test(py) && !/ALLOWED/.test(py), py.trim().split("\n").pop().slice(0, 160));
    }

    console.log("\n── positive control (real testnet id 998) ──");
    let realChain = null;
    try { realChain = await rpcChain(REAL_PORT); } catch { /* battery chain down */ }
    if (realChain === 998) {
      const okRun = runScript("npx hardhat run scripts/chain_guard.js --network hyperTestnet",
        `http://localhost:${REAL_PORT}`);
      report("guard ALLOWS the real testnet chain (not a brick)",
        okRun.rc === 0 && /chain guard ok: chain 998/.test(okRun.out), `rc=${okRun.rc}`);
      const pyOk = (() => {
        try {
          return String(execSync(
            "python3 -c \"import sys; sys.path.insert(0,'.'); import vault_keeper as k; print('ALLOWED' if k.check_chain() else 'REFUSED')\"",
            { cwd: REPO, encoding: "utf8", timeout: 60000,
              env: { ...process.env, HYPEREVM_RPC_URL: `http://localhost:${REAL_PORT}` } }));
        } catch (e) { return String((e.stdout || "") + (e.stderr || "")); }
      })();
      const explicit = runScript("npx hardhat run scripts/recycle_fees.js --network hyperTestnet",
        `http://localhost:${REAL_PORT}`, { RECYCLE_POLICY: "/nonexistent/policy.json" });
      report("recycler with an EXPLICIT RPC passes the implicit-RPC check (not a brick)",
        explicit.rc !== 0 && !/REFUSING: HYPEREVM_RPC_URL/.test(explicit.out)
          && /(ENOENT|no such file|no FeeDistributor code)/i.test(explicit.out),
        `rc=${explicit.rc} (failed at a downstream layer, as expected)`);
      report("python guard ALLOWS chain 998", /ALLOWED/.test(pyOk), pyOk.trim().split("\n").pop().slice(0, 120));
    } else {
      report("positive control available", false, `no 998 chain on port ${REAL_PORT} (got ${realChain})`);
    }
  } finally {
    if (child && child.pid) {
      try { process.kill(-child.pid, "SIGKILL"); } catch { try { child.kill("SIGKILL"); } catch { /* gone */ } }
    }
  }

  console.log(`\n══════ GUARD: ${pass} passed, ${fail} failed ══════`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error("guard test error:", e); process.exit(2); });
