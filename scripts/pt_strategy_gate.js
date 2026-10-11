// scripts/pt_strategy_gate.js — the F-1 no-new-TVL gate as CODE (single source).
//
// Two pre-remediation PTSleeveStrategy instances (PT-Arb 0x2D3E5bf1… /
// PT-ETH 0xA96D0BB2…) are REGISTERED + ACTIVE in the live Book #1 vault but
// carry F-1 (HIGH): completeInbound books retFace6 without consuming inFlight6,
// so a forgotten keeper `ackArrival` leaves a returned inbound counted TWICE and
// totalAssets() can report up to 2x the real money. They must never be
// re-activated, and never receive new TVL, until the remediated pair is
// registered by the vault owner (treasury Safe).
//
// Every script that could activate or fund a PT strategy imports its address
// list from HERE, so the gate cannot drift between scripts:
//   * assertNotPreRemediation(addr)      — fail CLOSED on any funding path
//   * assertRemediatedActivationTarget() — activation allowed ONLY for the
//                                          remediated allowlist
//
// Source of truth: deployed_addresses.mainnet.json _accepted_risks[F-1];
//                  docs/PT_SLEEVE_REMEDIATION_2026-10-05.md.
"use strict";

// Registered + ACTIVE in the live vault, F-1 (HIGH), unremediated. HARD-FAIL set.
const PT_PRE_REMEDIATION = [
  "0x2D3E5bf1D34791b8b66Ac4eEA6D281E918577B6b", // PT-Arb old (strategyList idx 3, ACTIVE)
  "0xA96D0BB29cEE6F9e26239529789CEb74912C4b25", // PT-ETH old (strategyList idx 4, ACTIVE)
];

// The remediated pair (F-1/F-5/yield-split + R-1). Activation is PERMITTED, but
// only once each is registered in the vault (owner/Safe action). Currently NOT
// registered, so no PT activation can happen yet — the script stays inert.
const PT_REMEDIATED_ALLOWLIST = [
  "0xd7075C9BD95649b3d6831182bea2986552097A2f", // PT-Arb (remediated), dormant
  "0x9238320Cc802863c7c1d78D1aaA6cbe0F7975092", // PT-ETH (remediated), dormant
];

const norm = (a) => String(a || "").toLowerCase();
const PRE = new Set(PT_PRE_REMEDIATION.map(norm));
const ALLOW = new Set(PT_REMEDIATED_ALLOWLIST.map(norm));

const isPreRemediation = (addr) => PRE.has(norm(addr));
const isRemediatedAllowlisted = (addr) => ALLOW.has(norm(addr));

/** Throw if `addr` is a pre-remediation strategy. Use on EVERY path that could
 *  activate or fund a PT strategy — it fails CLOSED (a throw, never a skip). */
function assertNotPreRemediation(addr, where) {
  if (isPreRemediation(addr)) {
    throw new Error(
      `PT GATE (F-1): ${where} refuses pre-remediation strategy ${addr} — ` +
        `registered+ACTIVE but unremediated (F-1 HIGH). See _accepted_risks[F-1].`,
    );
  }
}

/** Activation target must be on the remediated allowlist (and therefore not a
 *  pre-remediation address). Fails CLOSED for anything else. */
function assertRemediatedActivationTarget(addr, where) {
  assertNotPreRemediation(addr, where);
  if (!isRemediatedAllowlisted(addr)) {
    throw new Error(
      `PT GATE: ${where} refuses to activate ${addr} — not on the remediated ` +
        `allowlist. Only the remediated pair may ever be activated.`,
    );
  }
}

module.exports = {
  PT_PRE_REMEDIATION,
  PT_REMEDIATED_ALLOWLIST,
  isPreRemediation,
  isRemediatedAllowlisted,
  assertNotPreRemediation,
  assertRemediatedActivationTarget,
};
