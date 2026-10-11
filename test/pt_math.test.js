// test/pt_math.test.js — regression pin for the min-out DECIMAL bug.
//
// The live Arbitrum keeper computed every buy/sell bound assuming the Pendle
// SY's mid token (USDai) was 6dp like USDC. It is 18dp. Every bound was
// therefore ~1e12x too small — the executor's slippage `require`s were
// satisfied by ANY output, including a 99% loss, so the "defensive" buys had
// no defence at all. These tests assert the SCALE of every leg, because the
// failure mode is silent: the numbers look plausible and the tx succeeds.
//
// Run: node test/pt_math.test.js   (no framework — stdlib assert, CI-safe)

const assert = require("assert");
const { buyBounds, sellBounds, scale } = require("../scripts/pt_math");

let passed = 0;
function t(name, fn) {
  try { fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { console.error(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
}

const USDC_DEC = 6, MID_DEC = 18, PT_DEC = 18;
const SLIP = 100n;              // 1%
const PRICE18 = 995_000_000_000_000_000n; // 0.995 conservative PT price

console.log("pt_math — min-out bound scale");

t("scale() bridges 6dp -> 18dp", () => {
  assert.strictEqual(scale(USDC_DEC, MID_DEC), 10n ** 12n);
  assert.strictEqual(scale(18, 18), 1n);
});

t("buy: mid bound is in the MID token's units, not USDC's", () => {
  const usdc = 1_000_000_000n;                       // $1000, 6dp
  const midQuote = 999_559_503_864_530_978_049n;     // real 18dp get_dy output
  const b = buyBounds({ usdcAmount: usdc, midQuote, usdcDec: USDC_DEC, midDec: MID_DEC, ptDec: PT_DEC, slippageBps: SLIP, price18: PRICE18 });
  // A 6dp assumption would put this ~1e12 lower — the exact live bug.
  assert.ok(b.minAssetOut > 900_000_000_000_000_000n,
    `minAssetOut ${b.minAssetOut} is below the 18dp scale — decimals are wrong`);
  assert.ok(b.minAssetOut < midQuote, "minAssetOut must sit below the live quote");
  // ~1% cushion
  const ratio = Number(b.minAssetOut * 10000n / midQuote);
  assert.ok(ratio > 9890 && ratio < 9901, `cushion ratio ${ratio} not ~99%`);
});

t("buy: PT bound is in PT's 18dp and clears the mid bound", () => {
  const b = buyBounds({
    usdcAmount: 1_000_000_000n, midQuote: 999_559_503_864_530_978_049n,
    usdcDec: USDC_DEC, midDec: MID_DEC, ptDec: PT_DEC, slippageBps: SLIP, price18: PRICE18,
  });
  // PT out ≈ midOut / 0.995 → slightly MORE PT than mid units.
  assert.ok(b.minPtOut > 900_000_000_000_000_000n, `minPtOut ${b.minPtOut} below 18dp scale`);
  assert.ok(b.minPtOut > b.minAssetOut, "at a sub-$1 PT price, PT units exceed mid units");
});

t("buy: falls back to a spot+fee estimate when the pool will not quote", () => {
  const b = buyBounds({
    usdcAmount: 1_000_000_000n, midQuote: null,
    usdcDec: USDC_DEC, midDec: MID_DEC, ptDec: PT_DEC, slippageBps: SLIP, price18: PRICE18,
  });
  // 1000 USDC -> 18dp mid at ~4bp -> ~996 * 1e18
  assert.ok(b.midOut > 990_000_000_000_000_000_000n && b.midOut < 1_000_000_000_000_000_000_000n,
      `fallback midOut ${b.midOut} outside the expected band (~996 * 1e18)`);
});

t("sell (symmetric): the mid bound equals the exit bound and is 18dp", () => {
  const sb = sellBounds({
    ptBal: 2_490_006_557_589_671_872n, priceUsd: 0.9965089009277458,
    ptDec: PT_DEC, exitDec: MID_DEC, midDec: MID_DEC, usdcDec: USDC_DEC,
    hop2Quote: null, slippageBps: SLIP,
  });
  assert.strictEqual(sb.minMidOut, sb.minExitOut, "symmetric: one bound covers both legs");
  assert.ok(sb.minExitOut > 2_000_000_000_000_000_000n, `minExitOut ${sb.minExitOut} below 18dp scale`);
  // USDC out must be ~$2.44 in 6dp = ~2.4e9, NOT 2.4e21 (the live bug's shape).
  // ~$2.43 of PT: 6dp USDC is ~2_430_000. A 1e12-too-large value here is the
  // mirror image of the shipped bug (passing a mid-scale number where USDC
  // units are expected) and would revert every sell.
  assert.ok(sb.minUsdcOut > 2_000_000n && sb.minUsdcOut < 3_000_000n,
    `minUsdcOut ${sb.minUsdcOut} is not on the USDC 6dp scale`);
});

t("sell (two-hop): the mid bound comes from the second pool quote", () => {
  const hop2Quote = 2_300_000_000_000_000_000n; // 18dp mid out of the 2nd hop
  const sb = sellBounds({
    ptBal: 2_490_006_557_589_671_872n, priceUsd: 0.9965089009277458,
    ptDec: PT_DEC, exitDec: MID_DEC, midDec: MID_DEC, usdcDec: USDC_DEC,
    hop2Quote, slippageBps: SLIP,
  });
  assert.ok(sb.minMidOut < sb.minExitOut, "a 2nd hop costs value, so the mid bound must be lower");
  assert.ok(sb.minMidOut > 2_000_000_000_000_000_000n, "mid bound still 18dp");
  assert.ok(sb.minUsdcOut > 2_000_000n && sb.minUsdcOut < 3_000_000n, "USDC bound on 6dp");
});

t("REGRESSION: a 6dp-mid assumption would be ~1e12 low (the shipped bug)", () => {
  // What the old keeper computed for $1000, versus the correct 18dp value.
  const usdc = 1_000_000_000n;
  const buggy = (usdc * 996n) / 1000n * 99n / 100n;      // 6dp assumption
  const correct = buyBounds({
    usdcAmount: usdc, midQuote: 999_559_503_864_530_978_049n,
    usdcDec: USDC_DEC, midDec: MID_DEC, ptDec: PT_DEC, slippageBps: SLIP, price18: PRICE18,
  }).minAssetOut;
  assert.ok(correct / buggy > 1e11, `expected a ~1e12 scale gap, got ${correct / buggy}`);
  // And the buggy bound is ~1e9 — it would be satisfied by essentially ANY
  // output the Curve pool or router produced, including a near-total loss.
  assert.ok(buggy < 1_000_000_000n, `the old bound ${buggy} was not near-zero scale`);
});

console.log(`\n${passed} passed${process.exitCode ? " (with failures)" : ""}`);