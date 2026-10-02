// scripts/autoearn_sweep.js — the Layer-2 sweep keeper (owner-approved 2026-10-02).
//
// For every signed auto-earn permit (web /api/autoearn):
//   phase 1 — submit an un-submitted EIP-2612 permit (sets the on-chain allowance)
//   phase 2 — sweep: USDC.transferFrom(user → keeper) then vault.deposit(amount, user)
//             amount = min(wallet balance, allowance, remaining per-user cap)
// Non-custodial by construction: the user signed a capped, single-spender,
// revocable allowance; every sweep credits THEIR OWN vault position.
//
// DRY BY DEFAULT; sending requires SWEEP_OK=1. Gas is paid by the ops EOA
// (funded by the gas tank / dripper, same as the other keepers).
//
// Usage: HYPEREVM_RPC_URL=https://rpc.hyperliquid.xyz/evm \
//        npx hardhat run scripts/autoearn_sweep.js --network hyperMainnet
const hre = require("hardhat");
const { execFileSync } = require("child_process");

const VAULT = "0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1";
const USDC = "0xb88339CB7199b77E23DB6E890353E22632Ba630f";
const SPENDER = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D"; // ops EOA — MUST match web AutoEarnCard + /api/autoearn
const PER_USER_CAP = 500; // the vault's per-user cap (USD)
const MIN_SWEEP = 5; // USD — below this, gas costs more than the sweep is worth
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

async function main() {
  console.log(`=== autoearn_sweep ${new Date().toISOString()} · ${DRY ? "DRY" : "SEND"} ===`);
  const provider = hre.ethers.provider;
  const [keeper] = await hre.ethers.getSigners();
  const usdc = new hre.ethers.Contract(
    USDC,
    [
      "function balanceOf(address) view returns (uint256)",
      "function allowance(address,address) view returns (uint256)",
      "function permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
      "function transferFrom(address,address,uint256) returns (bool)",
    ],
    keeper
  );
  const vault = new hre.ethers.Contract(
    VAULT,
    [
      "function deposit(uint256 assets, address receiver) returns (uint256)",
      "function totalAssets() view returns (uint256)",
      "function totalShares() view returns (uint256)",
      "function sharesOf(address) view returns (uint256)",
      "function perUserCap() view returns (uint256)",
    ],
    hre.ethers.provider
  );

  let rows = [];
  try {
    rows = d1("SELECT wallet, spender, value, deadline, sig_v, sig_r, sig_s, submitted_at FROM autoearn_permits");
  } catch (e) {
    console.log("no permits table yet (nothing to do):", String(e.message || e).slice(0, 80));
    return;
  }
  console.log(`permits: ${rows.length}`);
  if (!rows.length) return;

  // share price for per-user value → remaining cap
  const ta = Number((await vault.totalAssets()).toString()) / 1e6;
  const ts = Number((await vault.totalShares()).toString()) / 1e6;
  const price = ts > 0 ? ta / ts : 1;
  const onChainCapRaw = await vault.perUserCap().catch(() => null);
  const cap = onChainCapRaw != null ? Number(onChainCapRaw.toString()) / 1e6 : PER_USER_CAP;
  const now = Math.floor(Date.now() / 1000);

  for (const row of rows) {
    const user = row.wallet.toLowerCase();
    if (Number(row.deadline) < now) {
      console.log(`  ${user.slice(0, 10)} — permit expired, skipping`);
      continue;
    }
    if (row.spender.toLowerCase() !== SPENDER.toLowerCase()) {
      console.log(`  ${user.slice(0, 10)} — spender mismatch (stale row), skipping`);
      continue;
    }
    const balance = Number((await usdc.balanceOf(user)).toString()) / 1e6;
    let allowance = Number((await usdc.allowance(user, SPENDER)).toString()) / 1e6;

    // Phase 1 — submit the permit if the allowance isn't live yet
    if (allowance <= 0 && !row.submitted_at) {
      console.log(`  ${user.slice(0, 10)} — submitting permit (cap $${(Number(row.value) / 1e6).toFixed(2)})`);
      if (!DRY) {
        try {
          const tx = await usdc
            .connect(keeper)
            .permit(user, SPENDER, row.value, row.deadline, row.sig_v, row.sig_r, row.sig_s);
          await tx.wait();
          console.log("    permit submitted ✓");
        } catch (e) {
          console.log("    permit REVERTED (bad/expired/stale signature) — logging and skipping:", String(e.message || e).slice(0, 120));
          continue;
        }
      }
      allowance = Number(row.value) / 1e6; // post-permit assumption for the dry print
    }

    const userShares = Number((await vault.sharesOf(user)).toString()) / 1e6;
    const userValue = userShares * price;
    const capRemaining = Math.max(0, cap - userValue);
    const amount = Math.min(balance, allowance, capRemaining);

    if (amount < MIN_SWEEP) {
      console.log(
        `  ${user.slice(0, 10)} — nothing to sweep (balance $${balance.toFixed(2)}, allowance $${allowance.toFixed(2)}, cap room $${capRemaining.toFixed(2)})`
      );
      continue;
    }
    const amtRaw = BigInt(Math.floor(amount * 1e6));
    console.log(
      `  ${user.slice(0, 10)} — sweep $${amount.toFixed(2)} → vault.deposit(receiver=user) [balance $${balance.toFixed(2)} / allowance $${allowance.toFixed(2)} / room $${capRemaining.toFixed(2)}]`
    );
    if (!DRY) {
      try {
        const t1 = await usdc.connect(keeper).transferFrom(user, await keeper.getAddress(), amtRaw);
        await t1.wait();
        const t2 = await vault.connect(keeper).deposit(amtRaw, user);
        const rc = await t2.wait();
        console.log(`    swept ✓ (deposit tx ${rc.hash.slice(0, 18)}…)`);
        try {
          execFileSync(
            "npx",
            [
              "wrangler", "d1", "execute", "pro-yield-db", "--remote", "--command",
              `UPDATE autoearn_permits SET last_swept_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'), swept_total = swept_total + ${amtRaw} WHERE wallet = '${user}'`,
            ],
            { cwd: "/home/user/websites/pro-yield-web", encoding: "utf8", timeout: 120_000, stdio: "pipe" }
          );
        } catch (_) { /* ledger update is best-effort */ }
      } catch (e) {
        console.log("    sweep REVERTED:", String(e.message || e).slice(0, 140));
      }
    }
  }
  console.log(DRY ? "\nDRY — nothing sent. SWEEP_OK=1 to send." : "\nsweep done.");
}

main().catch((e) => {
  console.error("autoearn_sweep error:", e);
  process.exit(1);
});
