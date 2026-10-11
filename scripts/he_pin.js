"use strict";
/**
 * he_pin.js — HyperEVM block-pin capability guard (shared, read-only).
 *
 * WHY THIS EXISTS (kanban t_bb11f1bc). On HyperEVM 999, a historical `eth_call`
 * — any block parameter other than `latest` — is SILENTLY answered with LATEST
 * state by three of the four endpoints in our failover pool:
 *
 *   https://rpc.hyperliquid.xyz/evm    (official)  -> IGNORES the tag
 *   https://hyperliquid.publicnode.com            -> IGNORES the tag
 *   https://999.rpc.thirdweb.com                  -> IGNORES the tag
 *   https://hyperliquid.drpc.org       (drpc)      -> honours historical state (archive)
 *
 * No error is returned, so a "pin the block FIRST, then read every value AT that
 * tag" pattern is a NO-OP on the first three: the numbers come out as head state
 * but get labelled with the pinned `as_of_block`. That is the dangerous kind of
 * failure (silent). Any script that pins a HyperEVM block MUST verify the
 * endpoint actually honours the tag before trusting the result.
 *
 * THE SENTINEL. Every ProYield contract (deployed 2026-09 or later) did NOT exist
 * at HyperEVM block 1 (`0x1`). A correct archive endpoint therefore returns
 * EMPTY (`0x`) for `eth_call(vault, totalAssets(), 0x1)`. An endpoint that
 * ignores the block tag returns the contract's CURRENT (non-empty) value. An
 * endpoint that refuses deep-archive outright THROWS — that is fail-loud and also
 * safe (we never get a silently-stale value back). So:
 *
 *   empty      -> honoured  (archive; the tag was respected)
 *   non-empty  -> IGNORED   (silently served LATEST)  <-- refuse to trust
 *   throws     -> honoured  (refused; fail-loud, no silent staleness)
 *
 * `assessEndpoint` MUST only be called on a reachable provider (call
 * `getNetwork()` first) so an unreachable host is not misread as "refused".
 *
 * Read-only. No keys, no money, no state change.
 */

const { ethers } = require("ethers");

// `totalAssets()` — the same probe used by every pinned read in this repo.
const VAULT_TOTALASSETS_SEL = "0x01e1d114";
// Any block before the 2026-09 deployments. 1 is the cheapest permanent proof:
// no ProYield contract can ever exist there.
const PRE_DEPLOY_BLOCK = 1;

// Ordered HyperEVM endpoint pools. Archive-first for PINNED reads; the public
// (latest-only) endpoints are kept as an explicit record of the pool so the
// capability check can name each one it rejects.
const HE_ARCHIVE_RPC = "https://hyperliquid.drpc.org";
const HE_PUBLIC_RPC = "https://rpc.hyperliquid.xyz/evm";
const HE_PINNED_POOL = [
  HE_ARCHIVE_RPC, // drpc — the only endpoint that honours historical state today
  HE_PUBLIC_RPC, // official — ignores the tag (checked, rejected)
  "https://hyperliquid.publicnode.com", // ignores the tag (checked, rejected)
  "https://999.rpc.thirdweb.com", // ignores the tag (checked, rejected)
];

// Endpoints observed (2026-10-10) to IGNORE a historical eth_call block tag.
// Useful for a fast pre-filter; the runtime sentinel is still authoritative.
const KNOWN_TAG_IGNORING = new Set([
  HE_PUBLIC_RPC,
  "https://hyperliquid.publicnode.com",
  "https://999.rpc.thirdweb.com",
]);

const short = (e) =>
  String((e && (e.shortMessage || e.message)) || e).replace(/\s+/g, " ").slice(0, 140);

/**
 * Assess whether `provider` honours a historical block tag, using the
 * pre-deployment sentinel. ONLY call on a provider whose `getNetwork()` has
 * already resolved.
 *
 * @param {object} provider
 * @param {string|{to:string,data:string}} targetOrOpts - probe target, or {to,data}
 * @param {string} [data] - probe calldata (default totalAssets selector)
 * @param {number} [probeBlock]
 * @returns {{honoured:boolean, mode:string, reason:string, result?:string}}
 */
async function assessEndpoint(
  provider,
  targetOrOpts,
  data = VAULT_TOTALASSETS_SEL,
  probeBlock = PRE_DEPLOY_BLOCK
) {
  const tx =
    targetOrOpts && typeof targetOrOpts === "object"
      ? targetOrOpts
      : { to: targetOrOpts, data };
  try {
    // NB: ethers v6 `provider.call(tx)` takes ONE argument; the block tag lives
    // INSIDE the tx as `blockTag` (a 2nd argument is silently IGNORED). Pass it
    // in the object so the tag actually reaches the node.
    const ret = await provider.call({ to: tx.to, data: tx.data, blockTag: probeBlock });
    if (ret === "0x") {
      return {
        honoured: true,
        mode: "archive",
        reason: `empty return at pre-deployment block ${probeBlock} — endpoint honoured the block tag`,
        result: ret,
      };
    }
    return {
      honoured: false,
      mode: "ignored-tag",
      reason:
        `returned ${String(ret).slice(0, 22)}… at pre-deployment block ${probeBlock} ` +
        `(contract did not exist) — endpoint served LATEST state and IGNORED the block tag`,
      result: ret,
    };
  } catch (e) {
    // A refusal (missing trie / archive token / prune) is fail-loud, not silent.
    return {
      honoured: true,
      mode: "refused-archive",
      reason: `refused archive read at block ${probeBlock} (fail-loud, no silent staleness): ${short(e)}`,
    };
  }
}

/**
 * Pick the first REACHABLE pool endpoint that honours a historical block tag.
 * Returns `{provider:null, url:null, tried}` when none qualifies — the caller
 * MUST then degrade/refuse rather than label head state with a pinned block.
 *
 * @param {object} opts
 * @param {number} opts.chainId
 * @param {string} opts.vault - address to probe with the pre-deployment sentinel
 * @param {string[]} [opts.pool] - ordered candidate URLs (default HE_PINNED_POOL)
 * @returns {Promise<{provider:object|null, url:string|null, tried:Array}>}
 */
async function pickPinnedProvider({ chainId, vault, pool = HE_PINNED_POOL }) {
  const tried = [];
  for (const url of pool) {
    let provider;
    try {
      provider = new ethers.JsonRpcProvider(url, chainId);
      await provider.getNetwork();
    } catch (e) {
      tried.push({ url, ok: false, mode: "unreachable", reason: short(e) });
      continue;
    }
    const chk = await assessEndpoint(provider, vault);
    tried.push({ url, ok: chk.honoured, mode: chk.mode, reason: chk.reason });
    if (chk.honoured) return { provider, url, tried };
  }
  return { provider: null, url: null, tried };
}

module.exports = {
  VAULT_TOTALASSETS_SEL,
  PRE_DEPLOY_BLOCK,
  HE_ARCHIVE_RPC,
  HE_PUBLIC_RPC,
  HE_PINNED_POOL,
  KNOWN_TAG_IGNORING,
  assessEndpoint,
  pickPinnedProvider,
  short,
};
