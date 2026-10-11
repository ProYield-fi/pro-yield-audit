// pt_math.js — min-out bound maths for the PT fixed-rate sleeve, per lane.
//
// Extracted from the keeper as PURE functions precisely because the live
// Arbitrum keeper shipped a bound computed on the wrong token decimals for
// months: USDai is 18dp but the maths assumed 6dp, so every buy/sell bound was
// ~1e12x too small and the slippage protection was theatre. These functions
// take decimals as ARGUMENTS so no caller can quietly assume one, and
// test/pt_math.test.js pins the scale of every leg.

/// Scale factor between two decimal places.
function scale(fromDec, toDec) {
  return 10n ** BigInt(toDec - fromDec);
}

/// Min-out bounds for buyPT(usdcAmount, minAssetOut, minPtOut).
///
///   USDC(usdcDec) --curve--> mid(midDec) --pendle--> PT(ptDec)
///
/// `midQuote` is the chain's own get_dy for the Curve leg when available
/// (a live quote beats a hardcoded fee assumption — the apxUSD/USDC pool drifted
/// to ~+5bp intraday). Falls back to `fallbackHopBps` off the spot rate.
/// `slippageBps` is the cushion on top; `price18` is the deliberately
/// conservative PT price used for the PT leg (a PT buys below $1, redeems at $1).
function buyBounds({ usdcAmount, midQuote, usdcDec, midDec, ptDec, slippageBps, price18, fallbackHopBps = 40n }) {
  const midOut = midQuote !== null && midQuote !== undefined
    ? BigInt(midQuote)
    : (BigInt(usdcAmount) * scale(usdcDec, midDec) * (10000n - fallbackHopBps)) / 10000n;
  const minAssetOut = (midOut * (10000n - BigInt(slippageBps))) / 10000n;
  const minPtOut = (minAssetOut * 10n ** BigInt(ptDec)) / BigInt(price18);
  return { midOut, minAssetOut, minPtOut };
}

/// Min-out bounds for sellPT.
///
/// Symmetric lane (exitPool === 0): the executor takes
///   sellPT(ptAmount, minMidOut, minUsdcOut)
/// so the mid bound covers the Pendle leg and the Curve leg is bounded in USDC.
///
/// Two-hop lane (exitPool !== 0): sellPT(ptAmount, minExitOut, minMidOut,
/// minUsdcOut) — the exit token is DIFFERENT from mid, so its bound is quoted
/// from the second pool when it will answer, else left at 0 (an unbounded leg is
/// strictly safer than a wrong-scale one).
///
///   PT(ptDec) --pendle--> exitAsset(exitDec) --[pool]--> mid(midDec) --curve--> USDC(usdcDec)
function sellBounds({ ptBal, priceUsd, ptDec, exitDec, midDec, usdcDec, hop2Quote, slippageBps }) {
  const ptValue6 = (BigInt(ptBal) * BigInt(Math.round(Number(priceUsd) * 1e6))) / 10n ** BigInt(ptDec);
  const exitFair = ptValue6 * scale(usdcDec, exitDec);        // exitAsset units
  const minExitOut = (exitFair * (10000n - BigInt(slippageBps))) / 10000n;

  let minMidOut;
  if (hop2Quote !== null && hop2Quote !== undefined) {
    // Two-hop: the second pool quotes mid directly.
    minMidOut = (BigInt(hop2Quote) * (10000n - BigInt(slippageBps))) / 10000n;
  } else {
    // Symmetric (or unquotable): exit IS mid, so one bound covers both legs.
    minMidOut = minExitOut;
  }
  const minUsdcOut = (minMidOut / scale(usdcDec, midDec) * (10000n - BigInt(slippageBps))) / 10000n;
  return { minExitOut, minMidOut, minUsdcOut };
}

module.exports = { scale, buyBounds, sellBounds };