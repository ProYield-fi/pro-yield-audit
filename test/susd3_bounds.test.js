// test/susd3_bounds.test.js — regression pins for the sUSD3 entry/exit min-out
// bounds (F-2, HIGH) and the venue-floor guard (F-7, LOW).
//
// The live bug: `enter()` derived its min-outs from the FACE input as if the
// venue were 1:1 (`got*998/1000`), but the venue's real share price makes
// $1,000 USDC buy ~846.5 USD3 and 1,000 USD3 buy ~756.9 sUSD3. The scripted
// minima were therefore mathematically unreachable and the next real-size cycle
// would revert SUSD3E__Slippage AFTER the CCTP mint had already funded the
// executor. These tests exercise the SAME pure functions the live runner and
// ops driver call (scripts/susd3_math.js), so the fix cannot silently regress.
//
// Run: node test/susd3_bounds.test.js   (no framework — stdlib assert, CI-safe)

const assert = require("assert");
const {
  cut,
  enterBounds,
  exitBounds,
  unwindBounds,
  checkVenueFloor,
} = require("../scripts/susd3_math");

let passed = 0;
function t(name, fn) {
  try { fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { console.error(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
}
function throws(fn, re) {
  let threw = false;
  try { fn(); } catch (e) { threw = true; assert.ok(re.test(e.message), `error '${e.message}' !~ ${re}`); }
  assert.ok(threw, "expected a refusal but none was thrown");
}

// Live venue reads, 2026-10-05 (adversarial review + independent dry-run).
const PV_USD3 = 846_533_242n;    // USD3.previewDeposit(1e9)
const PV_SUSD3 = 756_948_134n;   // sUSD3(depositedUsd3).previewDeposit  (two-hop)

console.log("susd3_math — live-derived min-out bounds (F-2 / F-7)");

t("cut() applies a 0.5% floor haircut", () => {
  assert.strictEqual(cut(1_000_000n), 995_000n);
  assert.strictEqual(cut(PV_SUSD3), 753_163_393n); // 756948134 * 995/1000
});

t("F-2: enter bounds are SHARES OUT of the live previews, not the face", () => {
  const b = enterBounds({ usdcIn: 1_000_000_000n, previewUsd3: PV_USD3, previewSusd3: PV_SUSD3 });
  assert.strictEqual(b.expUsd3, PV_USD3);
  assert.strictEqual(b.expSusd3, PV_SUSD3);
  assert.strictEqual(b.minUsd3Out, 842_300_575n);  // 846533242 * 995/1000
  assert.strictEqual(b.minSusd3Out, 753_163_393n);
  // The bounds sit BELOW the live preview, so `enter` can succeed.
  assert.ok(b.minUsd3Out < b.expUsd3);
  assert.ok(b.minSusd3Out < b.expSusd3);
});

t("F-2 REGRESSION: the old face-derived 99.8%/99.6% bounds are refused", () => {
  // got*998/1000 for a $1,000 face is 998e6 — far ABOVE the real 846.5e6 out.
  const oldMinUsd3 = (1_000_000_000n * 998n) / 1000n;
  assert.ok(oldMinUsd3 > PV_USD3, "old bound must exceed the live preview (the bug)");
  throws(
    () => enterBounds({ usdcIn: 1_000_000_000n, previewUsd3: PV_USD3, previewSusd3: PV_SUSD3, minUsd3: oldMinUsd3 }),
    /unreachable \(F-2\)/,
  );
});

t("F-2: an explicitly unreachable min is refused on both legs", () => {
  throws(
    () => enterBounds({ usdcIn: 1_000_000_000n, previewUsd3: PV_USD3, previewSusd3: PV_SUSD3, minUsd3: 999_000_000n }),
    /min USD3 999000000 exceeds/,
  );
  throws(
    () => enterBounds({ usdcIn: 1_000_000_000n, previewUsd3: PV_USD3, previewSusd3: PV_SUSD3, minSusd3: PV_SUSD3 + 1n }),
    /min sUSD3 .* exceeds/,
  );
});

t("F-2: a reachable explicit min is honoured (lower is safe)", () => {
  const b = enterBounds({ usdcIn: 1_000_000_000n, previewUsd3: PV_USD3, previewSusd3: PV_SUSD3, minUsd3: 800_000_000n });
  assert.strictEqual(b.minUsd3Out, 800_000_000n);
  assert.strictEqual(b.minSusd3Out, 753_163_393n); // other leg still auto-derived
});

t("F-2: a paused venue (preview 0) is refused, never guessed", () => {
  throws(() => enterBounds({ usdcIn: 1_000_000_000n, previewUsd3: 0n, previewSusd3: PV_SUSD3 }), /returned 0/);
});

t("F-2: complete-exit bounds derive from previewRedeem + convertToAssets", () => {
  const b = exitBounds({ shares: 1_000_000_000n, previewRedeemUsd3: 1_118_000_000n, convertToAssetsUsdc: 1_118_000_000n });
  assert.strictEqual(b.minUsd3Out, 1_112_410_000n);
  assert.strictEqual(b.minUsdcOut, 1_112_410_000n);
  throws(
    () => exitBounds({ shares: 1n, previewRedeemUsd3: 1_118_000_000n, convertToAssetsUsdc: 1_118_000_000n, minUsdc: 2_000_000_000n }),
    /unreachable \(F-2\)/,
  );
});

t("F-2: unwind-usd3 bound derives from convertToAssets", () => {
  const b = unwindBounds({ usd3In: 500_000_000n, convertToAssetsUsdc: 500_000_000n });
  assert.strictEqual(b.minUsdcOut, 497_500_000n);
});

t("F-7: a sub-minDeposit slice is refused before bridging", () => {
  // The runner's first-cycle cap ($20) and the observed $15.794 slice are both far
  // below the venue floor ($1,000).
  throws(() => checkVenueFloor({ slice: 20_000_000n, minDeposit: 1_000_000_000n }), /below the venue minDeposit .*F-7/);
  throws(() => checkVenueFloor({ slice: 15_794_000n, minDeposit: 1_000_000_000n }), /F-7/);
});

t("F-7: a slice equal to (or above) the floor clears", () => {
  assert.ok(checkVenueFloor({ slice: 1_000_000_000n, minDeposit: 1_000_000_000n }));
  assert.ok(checkVenueFloor({ slice: 6_667_000_000n, minDeposit: 1_000_000_000n }));
  // exactly one unit below the floor is still refused (boundary)
  throws(() => checkVenueFloor({ slice: 999_999_999n, minDeposit: 1_000_000_000n }), /F-7/);
});

console.log(`\n${passed} passed`);
if (process.exitCode) console.error("SUSD3 BOUNDS PIN FAILED");
