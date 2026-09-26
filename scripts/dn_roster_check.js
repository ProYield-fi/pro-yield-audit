// dn_roster_check.js — verify the DN roster against LIVE Hyperliquid + HyperEVM.
// Read-only (no sends, no keys needed beyond a configured signer for the run).
//
// Checks per roster coin:
//   1. perp: meta.universe[asset].name === coin (CoreWriter-tradable main perp)
//   2. spot: spotMeta pair index → tokens[0] === spotToken, szDecimals match
//   3. pxScale: 10^(10 - szDec) formula + LIVE read of the 0x808 spot-px
//      precompile for the pair → human px must track the spot mid (≤2%)
//   4. liquidity: spot dayNtlVlm > 0
//   5. basis: |spot mid / perp mark − 1| < 2% (hedge tracks the perp)
//   6. funding: predictedFundings APR available for the coin
//
// Run: npx hardhat run scripts/dn_roster_check.js --network hyperMainnet
// Exits non-zero if any roster entry FAILS — treat as a rotation blocker.
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ROSTER_FILE = process.env.DN_ROSTER_FILE || path.join(__dirname, "dn_roster.json");
const HL_INFO = "https://api.hyperliquid.xyz/info";
const P_808 = "0x0000000000000000000000000000000000000808";

async function hl(body) {
  const res = await fetch(HL_INFO, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return res.json();
}

async function main() {
  const { ethers } = hre;
  const roster = JSON.parse(fs.readFileSync(ROSTER_FILE, "utf8"));
  console.log(`roster: ${Object.keys(roster.coins).length} coins (verified ${roster.verified_utc})`);

  const [meta, smac, mids, pf] = await Promise.all([
    hl({ type: "meta" }),
    hl({ type: "spotMetaAndAssetCtxs" }),
    hl({ type: "allMids" }),
    hl({ type: "predictedFundings" }),
  ]);
  const sm = smac[0];
  const sctxByCoin = {};
  for (const c of smac[1]) sctxByCoin[c.coin] = c;
  const tokens = { [0]: { index: 0, name: "USDC", szDecimals: 2 } };
  for (const t of sm.tokens) tokens[t.index] = t;
  const pairs = {};
  for (const p of sm.universe) pairs[p.index] = p;

  let pass = 0, fail = 0;
  const coder = ethers.AbiCoder.defaultAbiCoder();

  for (const [coin, e] of Object.entries(roster.coins)) {
    const problems = [];
    // 1. perp
    const pu = meta.universe[e.asset];
    if (!pu || pu.name !== coin) problems.push(`perp[${e.asset}] = ${pu ? pu.name : "?"} ≠ ${coin}`);
    // 2. spot pair + token
    const pr = pairs[e.spotPair];
    if (!pr) problems.push(`spot pair @${e.spotPair} missing`);
    else if (pr.tokens[0] !== e.spotToken) problems.push(`pair @${e.spotPair} base token ${pr.tokens[0]} ≠ ${e.spotToken}`);
    const tok = tokens[e.spotToken];
    if (!tok) problems.push(`token ${e.spotToken} missing`);
    else if (tok.szDecimals !== e.szDec) problems.push(`token szDec ${tok.szDecimals} ≠ roster ${e.szDec}`);
    // 3. pxScale formula + live 0x808 read
    const expectScale = 10n ** BigInt(10 - e.szDec);
    if (BigInt(e.pxScale) !== expectScale) problems.push(`pxScale ${e.pxScale} ≠ 10^(10-${e.szDec}) = ${expectScale}`);
    let pxHuman = null;
    try {
      const raw = coder.decode(["uint64"], await ethers.provider.call({
        to: P_808, data: coder.encode(["uint64"], [e.spotPair]),
      }))[0];
      pxHuman = Number(raw) / 10 ** (8 - e.szDec);
    } catch (err) {
      problems.push(`0x808 read failed: ${err.message?.slice(0, 60)}`);
    }
    const mid = parseFloat(mids[`@${e.spotPair}`] || "0");
    if (pxHuman && mid && Math.abs(pxHuman / mid - 1) > 0.02) problems.push(`0x808 px ${pxHuman.toFixed(6)} vs mid ${mid} (Δ>2%)`);
    // 4. liquidity
    const ctx = sctxByCoin[`@${e.spotPair}`];
    const vol = ctx ? parseFloat(ctx.dayNtlVlm || "0") : 0;
    if (!vol) problems.push("spot day volume 0");
    // 5. basis
    const mark = parseFloat(pu?.markPx ?? ctx?.markPx ?? "0");
    const basis = mid && mark ? (mid / mark - 1) * 100 : null;
    if (basis !== null && Math.abs(basis) > 2) problems.push(`basis ${basis.toFixed(2)}% (>2%)`);
    // 6. funding
    const row = pf.find((r) => r[0] === coin);
    const venue = row ? row[1].find((v) => v[0] === "HlPerp") || row[1][0] : null;
    const apr = venue ? parseFloat(venue[1].fundingRate) * 24 * 365 * 100 : null;
    if (apr === null) problems.push("no predicted funding row");

    const ok = problems.length === 0;
    ok ? pass++ : fail++;
    console.log(
      `${ok ? "✅" : "❌"} ${coin.padEnd(5)} asset=${e.asset} pair=@${e.spotPair} tok=${e.spotToken} ` +
      `pxScale=${e.pxScale} px=${pxHuman ? pxHuman.toFixed(4) : "?"} mid=${mid} basis=${basis === null ? "?" : basis.toFixed(2)}% ` +
      `vol=$${(vol / 1e6).toFixed(2)}M fund=${apr === null ? "?" : apr.toFixed(1)}% perpSzDec=${pu?.szDecimals} maxLev=${pu?.maxLeverage}` +
      (problems.length ? `\n     ⚠ ${problems.join(" | ")}` : "")
    );
  }
  console.log(`\n══════ roster check: ${pass} ok, ${fail} failed ══════`);
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error("roster check error:", e.message?.slice(0, 300));
  process.exit(2);
});
