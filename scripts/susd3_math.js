// susd3_math.js — live-preview min-out bounds for the sUSD3 sleeve (PURE).
//
// Extracted exactly like the PT sleeve's `pt_math.js`, and for the same reason:
// the sUSD3 entry min-outs shipped FACE-DERIVED (`got*998/1000`), i.e. they
// assumed the venue was 1:1 USDC→USD3→sUSD3. It is NOT (live 2026-10-05:
// USD3.previewDeposit(1e9)=846535134, sUSD3 ~1.118 USD3), so those bounds were
// mathematically UNREACHABLE — the next real-size `enter()` would revert
// SUSD3E__Slippage after the CCTP mint had already funded the executor
// (adversarial review F-2). Every bound here is derived from the venue's OWN
// preview and haircut, and `test/susd3_bounds.test.js` pins the SAME functions
// the live scripts call, so a regression cannot return silently.
//
// Units: `minUsd3`/`minSusd3` are SHARES OUT of each leg (not dollars); the
// executor enforces them per ERC4626 leg.

const HAIRCUT_BPS = 50n; // 0.5% tolerance
const BPS_DEN = 10000n;

/// Haircut `x` by `haircutBps` (floor). Default 0.5%.
function cut(x, haircutBps = HAIRCUT_BPS) {
  const b = BigInt(haircutBps);
  if (b < 0n || b >= BPS_DEN) throw new Error(`haircutBps ${b} out of range`);
  return (BigInt(x) * (BPS_DEN - b)) / BPS_DEN;
}

/// enter(): USDC --previewDeposit--> USD3 --previewDeposit--> sUSD3.
/// Bounds are SHARES OUT, derived from the live previews. Explicit minima are
/// honoured only when REACHABLE (<= the live preview); an unreachable one is
/// refused before any tx is built (F-2).
function enterBounds({
  usdcIn,
  previewUsd3,
  previewSusd3,
  haircutBps = HAIRCUT_BPS,
  minUsd3,
  minSusd3,
} = {}) {
  if (usdcIn === undefined || previewUsd3 === undefined || previewSusd3 === undefined) {
    throw new Error("enterBounds needs usdcIn, previewUsd3, previewSusd3 (live previewDeposit reads)");
  }
  const expUsd3 = BigInt(previewUsd3);
  const expSusd3 = BigInt(previewSusd3);
  if (expUsd3 <= 0n || expSusd3 <= 0n) {
    throw new Error("previewDeposit returned 0 — venue paused/misconfigured; refusing");
  }
  const minUsd3Out = minUsd3 !== undefined && minUsd3 !== null ? BigInt(minUsd3) : cut(expUsd3, haircutBps);
  const minSusd3Out = minSusd3 !== undefined && minSusd3 !== null ? BigInt(minSusd3) : cut(expSusd3, haircutBps);
  if (minUsd3Out > expUsd3) {
    throw new Error(`min USD3 ${minUsd3Out} exceeds live previewDeposit ${expUsd3} — unreachable (F-2)`);
  }
  if (minSusd3Out > expSusd3) {
    throw new Error(`min sUSD3 ${minSusd3Out} exceeds live previewDeposit ${expSusd3} — unreachable (F-2)`);
  }
  return { usdcIn: BigInt(usdcIn), expUsd3, expSusd3, minUsd3Out, minSusd3Out };
}

/// complete-exit(): sUSD3 shares --previewRedeem--> USD3 --convertToAssets--> USDC.
function exitBounds({
  shares,
  previewRedeemUsd3,
  convertToAssetsUsdc,
  haircutBps = HAIRCUT_BPS,
  minUsd3,
  minUsdc,
} = {}) {
  if (shares === undefined || previewRedeemUsd3 === undefined || convertToAssetsUsdc === undefined) {
    throw new Error("exitBounds needs shares, previewRedeemUsd3, convertToAssetsUsdc (live reads)");
  }
  const expUsd3 = BigInt(previewRedeemUsd3);
  const expUsdc = BigInt(convertToAssetsUsdc);
  if (expUsd3 <= 0n) throw new Error("previewRedeem returned 0 — nothing eligible; refusing");
  if (expUsdc <= 0n) throw new Error("convertToAssets returned 0 — senior has no USDC liquidity; refusing");
  const minUsd3Out = minUsd3 !== undefined && minUsd3 !== null ? BigInt(minUsd3) : cut(expUsd3, haircutBps);
  const minUsdcOut = minUsdc !== undefined && minUsdc !== null ? BigInt(minUsdc) : cut(expUsdc, haircutBps);
  if (minUsd3Out > expUsd3) {
    throw new Error(`min USD3 ${minUsd3Out} exceeds live previewRedeem ${expUsd3} — unreachable (F-2)`);
  }
  if (minUsdcOut > expUsdc) {
    throw new Error(`min USDC ${minUsdcOut} exceeds live convertToAssets ${expUsdc} — unreachable (F-2)`);
  }
  return { shares: BigInt(shares), expUsd3, expUsdc, minUsd3Out, minUsdcOut };
}

/// unwind-usd3(): USD3 --convertToAssets--> USDC (single leg).
function unwindBounds({ usd3In, convertToAssetsUsdc, haircutBps = HAIRCUT_BPS, minUsdc } = {}) {
  if (usd3In === undefined || convertToAssetsUsdc === undefined) {
    throw new Error("unwindBounds needs usd3In, convertToAssetsUsdc (live reads)");
  }
  const expUsdc = BigInt(convertToAssetsUsdc);
  const minUsdcOut = minUsdc !== undefined && minUsdc !== null ? BigInt(minUsdc) : cut(expUsdc, haircutBps);
  if (minUsdcOut > expUsdc) {
    throw new Error(`min USDC ${minUsdcOut} exceeds live convertToAssets ${expUsdc} — unreachable (F-2)`);
  }
  return { usd3In: BigInt(usd3In), expUsdc, minUsdcOut };
}

/// F-7: the venue's first-deposit floor is a HARD revert inside leg 1, so a
/// slice below `minDeposit` is a guaranteed revert + a wasted CCTP round trip.
/// Throw (refuse) rather than bridge dust.
function checkVenueFloor({ slice, minDeposit } = {}) {
  if (slice === undefined || minDeposit === undefined) {
    throw new Error("checkVenueFloor needs slice and minDeposit (live USD3.minDeposit read)");
  }
  const s = BigInt(slice);
  const m = BigInt(minDeposit);
  if (s < m) {
    throw new Error(`slice ${s} is below the venue minDeposit ${m} — entry WOULD revert; DO NOT bridge dust (F-7)`);
  }
  return { slice: s, minDeposit: m };
}

module.exports = {
  HAIRCUT_BPS,
  BPS_DEN,
  cut,
  enterBounds,
  exitBounds,
  unwindBounds,
  checkVenueFloor,
};
