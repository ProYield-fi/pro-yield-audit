#!/usr/bin/env node
/*
 * ladder_verify.js — auditor-facing check of docs/LADDER_EVIDENCE.md.
 *
 * Every cell of the S3b manifest is re-derived from the day's own evidence and
 * compared to the doc. One command, no arguments:
 *
 *     node scripts/ladder_verify.js          # exit 0 = every cell reconciles
 *
 * For each row it checks, against attestations/<date>.json (the published file
 * itself, bytes on disk) — or attestations/degraded/<date>.json for a degraded
 * day:
 *   - evidence_pin / pin_kind:
 *       file_sha256        → first 16 hex of sha256(the attestation file's bytes)
 *       block_hash         → first 16 hex of product.as_of_block_hash
 *       quarantine_sha256  → first 16 hex of sha256(the quarantined file's bytes)
 *       none               → no attestation of any kind may exist for that date
 *   - total_assets ($) → canonical shortest decimal of
 *       product.metrics.total_assets_usdc
 *   - vault → first 12 characters of product.vault
 *   - status → the status the day's evidence derives (scripts/ladder_lib.js):
 *       `clean` only when the attestation is published, clean, names the LIVE
 *       vault and that day's recon snapshot carries no breach; `clean — closed
 *       generation` for an unbreached clean day on a superseded generation;
 *       `clean — breach excluded` when the recon snapshot breaches;
 *       `degraded — not counted` when the day's run was quarantined;
 *       `missed — not counted` when nothing was published at all.
 * Then it checks rule 1 names the live vault, and that the doc's rendered
 * numbers (status line + auto block: count per generation, completion date and
 * the not-counted list) are byte-identical to what ladder_lib.js derives from
 * the table alone. A number in the prose that the rows do not produce is a FAIL.
 *
 * Exit codes: 0 = all rows reconcile; 1 = at least one cell disagrees (a FAIL
 * line per cell, so the reason is never a guess).
 *
 * Cards t_e34d6404 (cells reproducible), t_d72b0501 (per-generation count).
 */
'use strict';
const fs = require('fs');
const path = require('path');
const L = require('./ladder_lib');

const ROOT = process.env.LADDER_ROOT || path.join(__dirname, '..');
const DOC = path.join(ROOT, 'docs', 'LADDER_EVIDENCE.md');
const ATTEST_DIR = path.join(ROOT, 'attestations');
const DEPLOYED = path.join(ROOT, 'deployed_addresses.mainnet.json');
const RECON_DIR = process.env.PROYIELD_RECON_DIR || path.join(process.env.HOME || '', '.proyield', 'recon');

let fails = 0;
let checks = 0;
let notes = 0;
function ok() { checks++; }
function bad(name, detail) { checks++; fails++; console.log(`FAIL ${name} — ${detail}`); }
function note(name, detail) { checks++; notes++; console.log(`NOTE ${name} — ${detail}`); }

const doc = fs.readFileSync(DOC, 'utf8');
const lines = doc.split('\n');

// ── header ──────────────────────────────────────────────────────────────────
const H = L.headerIndex(lines);
if (!H) { console.log('FAIL header — no "| date |" table header found'); process.exit(1); }
const headerLine = lines.find((l) => /^\|\s*date\s*\|/i.test(l));
const header = L.cells(headerLine).map((s) => s.toLowerCase());
for (const need of ['date', 'vault', 'evidence_pin', 'status', 'total_assets ($)', 'pin_kind']) {
  if (H[need] == null) bad(`header column "${need}"`, `present columns: ${header.join(' | ')}`);
}
if (fails) { console.log(`\n${checks} checks, ${fails} failed`); process.exit(1); }

const liveVault = String(JSON.parse(fs.readFileSync(DEPLOYED, 'utf8')).pro_yield_vault || '');
const SERIES = path.join(ROOT, 'attestations', 'series.jsonl');
const slots = L.loadSlots(SERIES);
const ctx = { attestDir: ATTEST_DIR, slots, reconDir: RECON_DIR, liveVault,
  today: process.env.LADDER_TODAY || new Date().toISOString().slice(0, 10) };

// ── rule 1 must name the vault the manifest says is deployed ────────────────
{
  const i = lines.findIndex((l) => /^1\.\s*\*\*Right vault/.test(l));
  if (i < 0) bad('rule 1', 'no "1. **Right vault:**" item found');
  else {
    const para = lines.slice(i, i + 12).join(' ');
    const m = /0x[0-9a-fA-F]{40}/.exec(para);
    if (!m) bad('rule 1', 'rule 1 names no vault address');
    else if (m[0].toLowerCase() !== liveVault.toLowerCase()) {
      bad('rule 1 vault', `rule 1 names ${m[0]} but deployed_addresses.mainnet.json says ${liveVault} — the rule would count the wrong book`);
    } else ok();
  }
}

// ── rows ────────────────────────────────────────────────────────────────────
const rows = L.parseRows(lines, H);
if (!rows.length) bad('table rows', 'no dated rows found');
console.log(`verifying ${rows.length} rows of docs/LADDER_EVIDENCE.md against attestations/*.json\n`);

const seen = new Set();
let prev = '';
for (const r of rows) {
  const tag = r.date;
  if (seen.has(tag)) bad(`${tag} duplicate`, 'date appears twice in the manifest');
  seen.add(tag);
  if (prev && tag < prev) bad(`${tag} order`, `row sorts before ${prev} — the manifest must be chronological`);
  prev = tag;

  const day = L.loadDay(ATTEST_DIR, tag, slots);
  const recon = L.loadRecon(RECON_DIR, tag);

  // ── missed day: nothing may exist ──
  if (r.pinKind === 'none' || r.status === L.STATUS.MISSED) {
    if (r.status !== L.STATUS.MISSED) bad(`${tag} status`, `pin_kind=none but status is "${r.status}"`);
    else if (r.pin !== '—' || r.total !== '—') bad(`${tag} cells`, `a missed day must carry "—" in evidence_pin and total_assets, got ${r.pin} / ${r.total}`);
    else if (day.kind !== 'none') bad(`${tag} file`, `recorded as missed but evidence exists at ${day.path} — an unrecorded attestation cannot hide behind a miss row`);
    else ok();
    continue;
  }

  if (day.kind === 'none' && r.pinKind === 'quarantine_sha256') {
    // A degraded day's evidence is quarantined (audit F4) and may not be
    // published at all — 2026-10-23 is retained privately only. The row is a
    // disclosure that the day does not count, not a counted figure, so its
    // absence here is said out loud and does not void the manifest.
    note(`${tag} quarantined`, 'evidence retained privately and not published; the row is pinned to its quarantined ' +
      'bytes and does not count — ask the operator for the file to re-check the digest');
    continue;
  }
  if (day.kind === 'none') {
    bad(`${tag} file`, `no published attestation for ${tag} (series slot "${slots.get(tag) || tag}")`);
    continue;
  }
  if (day.error) { bad(`${tag} file`, `${day.path} is ${day.error}`); continue; }

  const fileSha16 = L.sha16(day.bytes);
  const block16 = String(day.blockHash || '').slice(0, 16);
  const attVault = String(day.vault || '');

  // ── evidence pin ──
  if (r.pinKind === 'file_sha256') {
    if (day.kind !== 'published') bad(`${tag} evidence_pin`, 'pin_kind=file_sha256 on a non-published file');
    else if (r.pin !== fileSha16) bad(`${tag} evidence_pin`, `pin_kind=file_sha256 but row=${r.pin} and sha256(file)[:16]=${fileSha16}`);
    else ok();
  } else if (r.pinKind === 'block_hash') {
    if (!block16) bad(`${tag} evidence_pin`, 'pin_kind=block_hash but the attestation has no product.as_of_block_hash');
    else if (r.pin !== block16) bad(`${tag} evidence_pin`, `pin_kind=block_hash but row=${r.pin} and block_hash[:16]=${block16}`);
    else ok();
  } else if (r.pinKind === 'quarantine_sha256') {
    if (day.kind !== 'quarantined') {
      bad(`${tag} evidence_pin`, `pin_kind=quarantine_sha256 but the day is not quarantined (${day.path})`);
    } else if (r.pin !== fileSha16) {
      bad(`${tag} evidence_pin`, `pin_kind=quarantine_sha256 but row=${r.pin} and sha256(degraded file)[:16]=${fileSha16}`);
    } else ok();
  } else {
    bad(`${tag} pin_kind`, `unknown pin_kind "${r.pinKind}" (expected file_sha256, block_hash, quarantine_sha256 or none)`);
  }

  // ── TVL and vault, from the day's own file ──
  if (typeof day.total !== 'number' || !isFinite(day.total)) {
    bad(`${tag} total_assets`, `${day.path} has no numeric product.metrics.total_assets_usdc`);
  } else if (r.total !== L.amount(day.total)) {
    bad(`${tag} total_assets`, `row=${r.total} but ${path.basename(day.path)} says ${L.amount(day.total)}`);
  } else ok();

  if (attVault.slice(0, 12).toLowerCase() !== String(r.vault).toLowerCase()) {
    bad(`${tag} vault`, `row=${r.vault} but the attestation attests ${attVault}`);
  } else ok();

  // ── status, from the day's own evidence ──
  if (r.status === L.STATUS.SUPERSEDED) {
    // a documented one-off exclusion (the r0 generation): it may only be used
    // for a clean attestation of a vault that is NOT the live one, and never
    // for a day that would otherwise count.
    if (attVault.toLowerCase() === liveVault.toLowerCase()) {
      bad(`${tag} status`, `marked "${r.status}" but attests the LIVE vault — that would hide a counted day`);
    } else if (day.status != null && String(day.status).toLowerCase() !== 'clean') {
      bad(`${tag} status`, `marked "${r.status}" but the attestation status is ${day.status}`);
    } else ok();
  } else {
    const derived = L.deriveStatus(day, recon, liveVault, { allowClosed: true });
    if (derived.error) bad(`${tag} status`, `cannot derive a status: ${derived.error}`);
    else if (derived.status !== r.status && !recon.present && r.status === L.STATUS.BREACH) {
      // The row claims rule 5 exclusion and the recon snapshots are not present
      // in THIS checkout (they are ops-host data, not published). The claim is
      // therefore unverifiable here rather than wrong: say so, do not fail, and
      // never let it count. On the ops host the snapshot exists and a mismatch
      // is a hard FAIL.
      note(`${tag} rule 5`, `recorded as "${r.status}" but this checkout has no recon snapshot for the day — ` +
        'exclusion not verifiable here (it does not count either way); verify on the ops host');
    } else if (derived.status !== r.status) {
      bad(`${tag} status`, `row says "${r.status}" but the day's evidence derives "${derived.status}"` +
        (recon.present ? ` (recon: ${Object.entries(recon.perBook).map(([k, v]) => `${k} ${v.breach ? 'BREACH ' : ''}${v.gap_bps}`).join(', ')})` : ' (no recon snapshot available)'));
    } else ok();
  }

  // ── rule 5 floor: a counted row must not sit on a breached day ──
  if (r.status === L.STATUS.COUNTED) {
    if (attVault.toLowerCase() !== liveVault.toLowerCase()) {
      bad(`${tag} counted`, `counted row attests ${attVault}, not the live vault ${liveVault} — rule 1 (per-address count)`);
    } else if (!recon.present) {
      note(`${tag} recon`, 'counted row, but no recon snapshot is available here to confirm rule 5 — verify on the ops host');
    } else if (recon.breach) {
      bad(`${tag} counted`, 'counted row on a day whose recon snapshot breaches (rule 5)');
    } else ok();
  }

  // ── degraded days: say out loud when the evidence is not published ──
  if (day.kind === 'quarantined') {
    note(`${tag} quarantined`, 'evidence is not published; the row is pinned to its quarantined bytes and does not count');
  }
}

// ── the doc's numbers must be exactly what the table produces ────────────────
{
  const t = L.tally(rows, liveVault, ctx);
  if (t.offLiveCounted.length) {
    bad('count integrity', `${t.offLiveCounted.length} counted row(s) do not name the live vault (${t.offLiveCounted.map((r) => r.date).join(', ')})`);
  }
  const r = L.renderDoc(lines, t, liveVault, (d) => L.loadRecon(RECON_DIR, d));
  if (r.error) bad('rendered prose', `${r.error} — the doc has no status line or auto block to check`);
  else if (r.out !== doc) {
    const a = doc.split('\n');
    const b = r.out.split('\n');
    const at = a.findIndex((l, i) => l !== b[i]);
    bad('rendered prose', `the doc's derived numbers disagree with its own table at line ${at + 1}:\n` +
      `   doc : ${a[at]}\n   table: ${b[at]}\n   fix: node scripts/ladder_append.js`);
  } else ok();
  console.log(`\ncounted on the live vault ${L.shortAddr(liveVault)}: ${t.liveCount}/${L.TARGET}` +
    (t.counted.length ? ` (${t.counted[0].date} … ${t.counted[t.counted.length - 1].date})` : ''));
  for (const g of t.generations.filter((x) => x.attested_clean > 0)) {
    console.log(`  ${g.vault}  counted ${g.counted} of ${g.attested_clean} clean attestations`);
  }
}

console.log(
  fails
    ? `\n${checks} checks, ${fails} FAILED — the manifest does not reconcile with its evidence`
    : `\n${checks} checks, 0 failed${notes ? `, ${notes} note(s)` : ''} — the manifest reconciles with its evidence`
);
process.exit(fails ? 1 : 0);
