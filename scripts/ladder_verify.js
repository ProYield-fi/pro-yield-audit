#!/usr/bin/env node
/*
 * ladder_verify.js — auditor-facing check of docs/LADDER_EVIDENCE.md.
 *
 * Every cell of the S3b manifest is re-derived from the published evidence and
 * compared to the doc. One command, no arguments:
 *
 *     node scripts/ladder_verify.js          # exit 0 = every cell reconciles
 *
 * For each row it checks, against attestations/<date>.json (the published file
 * itself, bytes on disk):
 *   - evidence_pin / pin_kind:
 *       file_sha256 → first 16 hex of sha256(the attestation file's bytes)
 *       block_hash  → first 16 hex of product.as_of_block_hash
 *   - total_assets ($) → canonical shortest decimal of
 *       product.metrics.total_assets_usdc
 *   - vault → first 12 characters of product.vault
 *   - status → a row may only be marked `clean` (and therefore counted) when its
 *       attestation attests the currently deployed vault and is not degraded
 * Then it checks the derived prose: the clean-row count and the
 * "Next possible completion" date (last counted row + 30 − count days).
 *
 * Exit codes: 0 = all rows reconcile; 1 = at least one cell disagrees (a FAIL
 * line per cell, so the reason is never a guess).
 *
 * Card t_e34d6404.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = process.env.LADDER_ROOT || path.join(__dirname, '..');
const DOC = path.join(ROOT, 'docs', 'LADDER_EVIDENCE.md');
const ATTEST_DIR = path.join(ROOT, 'attestations');
const DEPLOYED = path.join(ROOT, 'deployed_addresses.mainnet.json');
const TARGET = 30;

let fails = 0;
let checks = 0;
function ok(name) { checks++; }
function bad(name, detail) { checks++; fails++; console.log(`FAIL ${name} — ${detail}`); }

const amount = (v) => String(Number(v));
const cells = (line) => line.replace(/^\|/, '').replace(/\|\s*$/, '').split('|').map(s => s.trim());

function addDays(iso, n) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

const doc = fs.readFileSync(DOC, 'utf8');
const lines = doc.split('\n');

// ── header ──────────────────────────────────────────────────────────────────
const headerLine = lines.find(l => /^\|\s*date\s*\|/i.test(l));
if (!headerLine) { console.log('FAIL header — no "| date |" table header found'); process.exit(1); }
const header = cells(headerLine).map(s => s.toLowerCase());
const H = {};
header.forEach((n, i) => { H[n] = i; });
for (const need of ['date', 'vault', 'evidence_pin', 'status', 'total_assets ($)', 'pin_kind']) {
  if (H[need] == null) bad(`header column "${need}"`, `present columns: ${header.join(' | ')}`);
}
if (fails) { console.log(`\n${checks} checks, ${fails} failed`); process.exit(1); }

const liveVault = String(JSON.parse(fs.readFileSync(DEPLOYED, 'utf8')).pro_yield_vault || '').toLowerCase();

// ── rows ────────────────────────────────────────────────────────────────────
const rowRe = /^\|\s*\d{4}-\d{2}-\d{2}\s*\|/;
const rows = lines.filter(l => rowRe.test(l)).map(l => {
  const c = cells(l);
  return {
    line: l,
    date: c[H['date']],
    vault: c[H['vault']],
    pin: c[H['evidence_pin']],
    status: (c[H['status']] || '').replace(/\*/g, '').trim(),
    total: c[H['total_assets ($)']],
    pinKind: c[H['pin_kind']],
  };
});

if (!rows.length) bad('table rows', 'no dated rows found');
console.log(`verifying ${rows.length} rows of docs/LADDER_EVIDENCE.md against attestations/*.json\n`);

const counted = [];
const dates = new Set();
for (const r of rows) {
  const tag = r.date;
  if (dates.has(tag)) bad(`${tag} duplicate`, 'date appears twice in the manifest');
  dates.add(tag);

  const p = path.join(ATTEST_DIR, `${tag}.json`);
  if (!fs.existsSync(p)) { bad(`${tag} file`, `attestations/${tag}.json is missing`); continue; }
  const bytes = fs.readFileSync(p);
  const att = JSON.parse(bytes.toString('utf8'));
  const product = att.product || {};
  const attTotal = product.metrics ? product.metrics.total_assets_usdc : undefined;

  // evidence pin
  const fileSha16 = crypto.createHash('sha256').update(bytes).digest('hex').slice(0, 16);
  const block16 = String(product.as_of_block_hash || '').replace(/^0x/, '').slice(0, 16);
  if (r.pinKind === 'file_sha256') {
    if (r.pin !== fileSha16) bad(`${tag} evidence_pin`, `pin_kind=file_sha256 but row=${r.pin} and sha256(file)[:16]=${fileSha16}`);
    else ok(tag);
  } else if (r.pinKind === 'block_hash') {
    if (!block16) bad(`${tag} evidence_pin`, 'pin_kind=block_hash but the attestation has no product.as_of_block_hash');
    else if (r.pin !== block16) bad(`${tag} evidence_pin`, `pin_kind=block_hash but row=${r.pin} and block_hash[:16]=${block16}`);
    else ok(tag);
  } else {
    bad(`${tag} pin_kind`, `unknown pin_kind "${r.pinKind}" (expected file_sha256 or block_hash)`);
  }

  // TVL — must equal the day's own JSON, exactly
  if (typeof attTotal !== 'number') bad(`${tag} total_assets`, 'attestation has no numeric product.metrics.total_assets_usdc');
  else if (r.total !== amount(attTotal)) bad(`${tag} total_assets`, `row=${r.total} but attestations/${tag}.json says ${amount(attTotal)}`);
  else ok(tag);

  // vault — the row names the vault the attestation attests
  const attVault = String(product.vault || '');
  if (attVault.slice(0, 12).toLowerCase() !== String(r.vault).toLowerCase()) {
    bad(`${tag} vault`, `row=${r.vault} but the attestation attests ${attVault}`);
  } else ok(tag);

  // status — the only counted status is clean, and only for the live vault
  const isClean = /^clean$/i.test(r.status);
  const isLive = attVault.toLowerCase() === liveVault;
  const attStatus = att.status != null ? String(att.status) : null;
  if (isClean) {
    if (!isLive) bad(`${tag} status`, `marked clean but attests superseded vault ${attVault} (live ${liveVault})`);
    else if (attStatus != null && attStatus !== 'clean') bad(`${tag} status`, `marked clean but attestation status=${attStatus}`);
    else counted.push(tag);
  } else if (/not counted/i.test(r.status)) {
    if (isLive) bad(`${tag} status`, `marked not-counted but attests the live vault`);
    else ok(tag);
  } else {
    bad(`${tag} status`, `unrecognised status "${r.status}"`);
  }
}

// ── derived prose ───────────────────────────────────────────────────────────
const countMatch = /Clean days on the live vault:\s*(\d+)/i.exec(doc);
const statusMatch = /(\d+)\s*\/\s*30 clean days/i.exec(doc);
const nextMatch = /Next possible completion:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})/i.exec(doc);
if (!countMatch) bad('prose count', 'no "Clean days on the live vault: N" line');
else if (Number(countMatch[1]) !== counted.length) bad('prose count', `prose says ${countMatch[1]}, table has ${counted.length} counted rows`);
else ok('prose');
if (statusMatch && Number(statusMatch[1]) !== counted.length) bad('status headline', `${statusMatch[1]}/30 but table has ${counted.length} counted rows`);
if (!nextMatch) bad('prose completion', 'no "Next possible completion: YYYY-MM-DD" line');
else {
  counted.sort();
  const expected = counted.length ? addDays(counted[counted.length - 1], Math.max(0, TARGET - counted.length)) : null;
  if (expected && nextMatch[1] !== expected) bad('prose completion', `prose says ${nextMatch[1]}, derived ${expected} (last counted ${counted[counted.length - 1]} + ${TARGET - counted.length})`);
  else ok('prose');
}

console.log(
  fails
    ? `\n${checks} checks, ${fails} FAILED — the manifest does not reconcile with its evidence`
    : `\n${checks} checks, 0 failed — counted clean rows: ${counted.length}/${TARGET}` +
      (counted.length ? ` (${counted[0]} … ${counted[counted.length - 1]})` : '')
);
process.exit(fails ? 1 : 0);
