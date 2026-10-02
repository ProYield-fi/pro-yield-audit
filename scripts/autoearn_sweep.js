// scripts/autoearn_sweep.js — the Layer-2 sweep keeper, v2 (2026-10-02).
//
// REWRITE after community audit finding #3 (Firlinata): v1 called
// deposit(uint256,address) and sharesOf(address), which do NOT exist on the
// deployed vault — the run crashed on the first row — and its two-phase
// transferFrom→deposit parked user funds in the keeper EOA (a custody window).
//
// v2 design, zero custody by construction:
//   1. CAPABILITY GATE: the sweep only acts if the deployed vault exposes a
//      keeper-credit path (depositFor). Today it does not — so the sweep is a
//      GATED NO-OP: no permits submitted, no funds moved, clean exit. Stored
//      permits just wait (they have deadlines).
//   2. The permit SPENDER is the VAULT itself (web spender + card updated in
//      lockstep — no user had signed when this changed, verified 0 permits).
//      When r3 ships depositFor(receiver), the vault pulls from the user
//      within their own signed allowance and mints to them — atomically, in
//      one tx. The keeper never touches user funds.
//   3. Per-row fault isolation: one junk row can never kill the run (finding
//      #3, item 2). Failures mark the row's last_error and continue.
//
// DRY BY DEFAULT; SWEEP_OK=1 + a capable deployed vault to send.
const hre = require("hardhat");
const { execFileSync } = require("child_process");

const VAULT = "0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1";
const USDC = "0xb88339CB7199b77E23DB6E890353E22632Ba630f";
const SPENDER = VAULT; // the allowance holder is the vault itself — no keeper custody, ever
const MIN_SWEEP = 5; // USD
const DRY = process.env.SWEEP_OK !== "1";

function d1(sql) {
  const out = execFileSync(
    "npx",
    ["wrangler", "d1", "execute", "pro-yield-db", "--remote", "--json", "--command", sql],
    { cwd: "/home/user/websites/pro-yield-web", encoding: "utf8", timeout: 120_000 }
  );
  const i = out.indexOf("[");
  return JSON.parse(out.slice(i))[0].results || [];
}

// Selector-probe the deployed bytecode the way the auditor did: absent
// functions revert with empty data on eth_call.
async function hasSelector(selector) {
  try {
    await hre.ethers.provider.call({ to: VAULT, data: selector + "0".repeat(64) });
    return true;
  } catch (e) {
    return false;
  }
}

async function main() {
  console.log(`=== autoearn_sweep v2 ${new Date().toISOString()} · ${DRY ? "DRY" : "SEND"} ===`);

  // ── Capability gate ──────────────────────────────────────────────
  // r3 adds depositFor: the vault pulls from the user (allowance holder =
  // vault) and mints to the user, atomically — the keeper never touches
  // user funds. Until it exists, the sweep is a gated no-op.
  const hasDepositFor = (await hasSelector(hre.ethers.id("depositFor(address,uint256)").slice(0, 10)))
    || (await hasSelector(hre.ethers.id("depositFor(uint256,address)").slice(0, 10)));
  if (!hasDepositFor) {
    console.log("GATED: the deployed vault has no depositFor — the sweep cannot credit a user");
    console.log("without parking funds in the keeper EOA (finding #3). No permits submitted,");
    console.log("no funds moved. Stored permits wait for the r3 deploy; the card copy says so.");
    return;
  }

  let rows = [];
  try {
    rows = d1("SELECT wallet, spender, value, deadline, sig_v, sig_r, sig_s, submitted_at FROM autoearn_permits WHERE last_error IS NULL");
  } catch (e) {
    try {
      // add the failure-ledger column if the table predates it
      execFileSync(
        "npx",
        ["wrangler", "d1", "execute", "pro-yield-db", "--remote", "--command",
          "ALTER TABLE autoearn_permits ADD COLUMN last_error TEXT"],
        { cwd: "/home/user/websites/pro-yield-web", encoding: "utf8", timeout: 120_000, stdio: "pipe" }
      );
      rows = d1("SELECT wallet, spender, value, deadline, sig_v, sig_r, sig_s, submitted_at FROM autoearn_permits WHERE last_error IS NULL");
    } catch (e2) {
      console.log("permits table unavailable:", String(e2.message || e2).slice(0, 80));
      return;
    }
  }
  console.log(`permits: ${rows.length}`);
  if (!rows.length) return;

  const usdc = new hre.ethers.Contract(
    USDC,
    [
      "function balanceOf(address) view returns (uint256)",
      "function allowance(address,address) view returns (uint256)",
    ],
    hre.ethers.provider
  );
  const vault = new hre.ethers.Contract(
    VAULT,
    [
      "function depositFor(address user, uint256 amount)",
      "function shares(address) view returns (uint256)",
      "function totalAssets() view returns (uint256)",
      "function totalShares() view returns (uint256)",
      "function perUserCap() view returns (uint256)",
    ],
    hre.ethers.provider
  );
  const [keeper] = await hre.ethers.getSigners();
  const vaultW = vault.connect(keeper);

  const ta = Number((await vault.totalAssets()).toString()) / 1e6;
  const ts = Number((await vault.totalShares()).toString()) / 1e6;
  const price = ts > 0 ? ta / ts : 1;
  const cap = Number((await vault.perUserCap()).toString()) / 1e6;
  const now = Math.floor(Date.now() / 1000);

  for (const row of rows) {
    const user = row.wallet.toLowerCase();
    try {
      if (Number(row.deadline) < now) {
        console.log(`  ${user.slice(0, 10)} — permit expired, marking`);
        d1(`UPDATE autoearn_permits SET last_error = 'expired' WHERE wallet = '${user}'`);
        continue;
      }
      if (row.spender.toLowerCase() !== SPENDER.toLowerCase()) {
        // pre-v2 rows (spender = keeper EOA) are legacy — never act on them
        console.log(`  ${user.slice(0, 10)} — legacy spender row, marking skipped`);
        d1(`UPDATE autoearn_permits SET last_error = 'legacy-spender' WHERE wallet = '${user}'`);
        continue;
      }
      const balance = Number((await usdc.balanceOf(user)).toString()) / 1e6;
      const allowance = Number((await usdc.allowance(user, SPENDER)).toString()) / 1e6;
      const userValue = (Number((await vault.shares(user)).toString()) / 1e6) * price;
      const capRemaining = Math.max(0, cap - userValue);
      const amount = Math.min(balance, allowance, capRemaining);
      if (amount < MIN_SWEEP) {
        console.log(`  ${user.slice(0, 10)} — nothing to sweep (bal $${balance.toFixed(2)} / allow $${allowance.toFixed(2)} / room $${capRemaining.toFixed(2)})`);
        continue;
      }
      const amtRaw = BigInt(Math.floor(amount * 1e6));
      console.log(`  ${user.slice(0, 10)} — depositFor $${amount.toFixed(2)} (vault pulls from user, mints to user)`);
      if (!DRY) {
        const tx = await vaultW.depositFor(user, amtRaw);
        const rc = await tx.wait();
        console.log(`    swept ✓ ${rc.hash.slice(0, 18)}…`);
        d1(`UPDATE autoearn_permits SET last_swept_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'), swept_total = swept_total + ${amtRaw} WHERE wallet = '${user}'`);
      }
    } catch (e) {
      // per-row fault isolation: log, mark, continue — never kill the run
      const msg = String(e.message || e).slice(0, 200);
      console.log(`  ${user.slice(0, 10)} — row failed soft: ${msg}`);
      try {
        d1(`UPDATE autoearn_permits SET last_error = '${msg.replace(/'/g, "''").slice(0, 180)}' WHERE wallet = '${user}'`);
      } catch (_) { /* ledger write is best-effort */ }
    }
  }
  console.log(DRY ? "\nDRY — nothing sent. SWEEP_OK=1 (with a capable deployed vault) to send." : "\nsweep done.");
}

main().catch((e) => {
  console.error("autoearn_sweep error:", e);
  process.exit(1);
});