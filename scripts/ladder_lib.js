#!/usr/bin/env node
/*
 * ladder_lib.js — the ONE implementation of the S3b ladder's row model and its
 * rendered prose. Required by both writers/checkers so the doc's numbers cannot
 * drift from the table again:
 *
 *   scripts/ladder_append.js  — appends today's row (cron) / backfills a date
 *   scripts/ladder_verify.js  — auditor-facing, re-derives every cell
 *
 * WHY THIS FILE EXISTS (card t_d72b0501, 2026-10-26). The doc previously carried
 * the count in three hand-written places (status line, "Clean-day summary"
 * section, auto block) and the writer counted every `clean` row regardless of
 * which vault it attests. On 2026-10-25 book #1 moved generations, so the writer
 * summed 21 rows of the CLOSED 0x8954 generation with 1 row of the live R1 vault
 * and printed "22/30 → Nov 3" while the same file also said "21 → 2026-11-01".
 * The model below is per-generation and breach-aware:
 *
 *   counted(live)  = rows with status `clean` (which, by construction, must name
 *                    the live vault) — rule 1 (right vault) + rule 5 (breach).
 *   counted(closed)= rows with status `clean — closed generation`, per address.
 *   everything else is recorded but never counted.
 *
 * The status cell describes THE DAY'S OWN EVIDENCE; the count is derived from
 * the vault column + the status. A `clean` row can only ever name the live
 * vault, so a superseded generation can never inflate the live count.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const TARGET = 30;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const STATUS = {
  COUNTED: 'clean',
  CLOSED: 'clean — closed generation',
  BREACH: 'clean — breach excluded',
  SUPERSEDED: 'superseded — not counted',
  DEGRADED: 'degraded — not counted',
  MISSED: 'missed — not counted',
};

const AUTO_START = '<!-- ladder:auto:start';
const AUTO_END = '<!-- ladder:auto:end -->';

function addDays(iso, n) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function pretty(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  return `${MONTHS[m - 1]} ${d}, ${y}`;
}

const amount = (v) => String(Number(v));
const shortAddr = (a) => `${String(a).slice(0, 10)}…${String(a).slice(-4)}`;
const sha16 = (buf) => crypto.createHash('sha256').update(buf).digest('hex').slice(0, 16);
const cells = (line) => line.replace(/^\|/, '').replace(/\|\s*$/, '').split('|').map((s) => s.trim());

/** Header-name → column index for the manifest table. */
function headerIndex(lines) {
  for (const line of lines) {
    if (!/^\|\s*date\s*\|/i.test(line)) continue;
    const idx = {};
    cells(line).map((s) => s.toLowerCase()).forEach((n, i) => { idx[n] = i; });
    return idx;
  }
  return null;
}

const rowRe = /^\|\s*\d{4}-\d{2}-\d{2}\s*\|/;

/** Parse the manifest table into row objects (order preserved). */
function parseRows(lines, h) {
  const out = [];
  for (const line of lines) {
    if (!rowRe.test(line)) continue;
    const c = cells(line);
    out.push({
      line,
      date: c[h['date']],
      vault: c[h['vault']],
      pin: h['evidence_pin'] != null ? c[h['evidence_pin']] : null,
      status: (c[h['status']] || '').replace(/\*/g, '').trim(),
      total: h['total_assets ($)'] != null ? c[h['total_assets ($)']] : null,
      pinKind: h['pin_kind'] != null ? c[h['pin_kind']] : null,
    });
  }
  return out.sort((a, b) => a.date.localeCompare(b.date));
}

/**
 * The day's FINAL slot (rule 3: a same-day rerun is versioned `-rN` instead of
 * overwriting, and `series.jsonl` records which slot is published). The slot id
 * comes from the series — not from scanning the directory — and is legal-id
 * checked so a corrupted series line can never steer a read to an arbitrary
 * path. Reading only `<date>.json` would publish r1's numbers for a day whose
 * series row carries r2's: on 2026-10-17, r1 = 123.910911 @48782038 while the
 * series slot `2026-10-17-r2` = 122.479258 @48813315 (found 2026-10-26).
 * Slot resolution + the in-file cross-check follow card t_a48e5524.
 */
const SLOT_RE = /^\d{4}-\d{2}-\d{2}(?:-r\d+)?$/;

/** date → published slot id, from series.jsonl (falls back to the bare date). */
function loadSlots(seriesPath) {
  const map = new Map();
  let txt;
  try { txt = fs.readFileSync(seriesPath, 'utf8'); } catch (_) { return map; }
  for (const line of txt.split('\n')) {
    if (!line.trim()) continue;
    let row;
    try { row = JSON.parse(line); } catch (_) { continue; }
    if (!row || !row.date) continue;
    map.set(String(row.date), row.slot ? String(row.slot) : String(row.date));
  }
  return map;
}

/** Resolve a manifest date to the published file that is its evidence. */
function evidenceFor({ attestDir, date, slots }) {
  const slot = (slots && slots.get(String(date))) || String(date);
  if (!SLOT_RE.test(slot)) {
    return { slot, file: `${slot}.json`, filePath: null, exists: false,
      slotError: `series slot "${slot}" is not a legal slot id (expected YYYY-MM-DD or YYYY-MM-DD-rN)` };
  }
  const filePath = path.join(attestDir, `${slot}.json`);
  return { slot, file: `${slot}.json`, filePath, exists: fs.existsSync(filePath), slotError: null };
}

/**
 * The day's own evidence: published attestation (its published slot), else the
 * quarantine, else nothing. `slots` comes from loadSlots(series.jsonl).
 */
function loadDay(attestDir, date, slots) {
  const ev = evidenceFor({ attestDir, date, slots });
  const pub = ev.slotError ? null : ev.filePath;
  const quar = path.join(attestDir, 'degraded', `${date}.json`);
  for (const [p, kind] of [[pub, 'published'], [quar, 'quarantined']]) {
    if (!p) continue;
    if (!fs.existsSync(p)) continue;
    const bytes = fs.readFileSync(p);
    let att;
    try { att = JSON.parse(bytes.toString('utf8')); }
    catch (e) { return { kind, path: p, bytes, error: `not valid JSON (${e.message})` }; }
    const product = att.product || {};
    // cross-check the slot recorded INSIDE the file against the slot the series
    // says is published (pre-2026-10-06 files carry no slot field: not a mismatch)
    let slotError = null;
    if (kind === 'published' && att.slot != null && String(att.slot) !== String(ev.slot)) {
      slotError = `the file's own slot field says "${att.slot}" but the series records this day's slot as "${ev.slot}" — wrong revision`;
    }
    return {
      kind,
      path: p,
      slot: ev.slot,
      bytes,
      att,
      error: slotError,
      status: att.status != null ? String(att.status) : null,
      vault: product.vault || null,
      total: product.metrics ? product.metrics.total_assets_usdc : undefined,
      blockHash: String(product.as_of_block_hash || '').replace(/^0x/, ''),
      block: product.as_of_block,
    };
  }
  return { kind: 'none', path: null, bytes: null };
}

/** The day's recon snapshot (rule 5). Absent is NOT clean — it is unknown. */
function loadRecon(reconDir, date) {
  const p = path.join(reconDir, `${date}.json`);
  if (!fs.existsSync(p)) return { present: false, path: p };
  let rec;
  try { rec = JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (_) { return { present: false, path: p, error: 'unreadable JSON' }; }
  const books = rec.books || {};
  const perBook = {};
  let breach = false;
  for (const [k, v] of Object.entries(books)) {
    if (!v) continue;
    perBook[k] = { breach: !!v.breach, gap_bps: v.gap_bps != null ? String(v.gap_bps) : null };
    if (v.breach) breach = true;
  }
  if (!Object.keys(perBook).length && rec.breach) breach = true;
  return { present: true, path: p, generated_at: rec.generated_at || null, block: rec.block || null, breach, perBook };
}

/**
 * Derive the status cell from the day's own evidence. Never returns a counted
 * status for a day that is missed, degraded, breached, or off-vault.
 */
function deriveStatus(day, recon, liveVault, { allowClosed = false } = {}) {
  if (day.kind === 'none') return { status: STATUS.MISSED };
  if (day.error) return { status: null, error: day.error };
  // The clean/degraded flag only exists from 2026-10-06 (audit F5). Files
  // before it carry no `status` field and were counted as clean at the time, so
  // a null status means "published before the flag", not "degraded".
  const attStatus = day.status == null ? 'clean' : String(day.status).toLowerCase();
  if (attStatus !== 'clean') return { status: STATUS.DEGRADED };
  if (recon && recon.present && recon.breach) return { status: STATUS.BREACH };
  const onLive = String(day.vault || '').toLowerCase() === String(liveVault).toLowerCase();
  if (onLive) return { status: STATUS.COUNTED };
  if (allowClosed) return { status: STATUS.CLOSED };
  return { status: null, error: `attests ${day.vault}, not the live vault ${liveVault}` };
}

/** Build the manifest row (cell array) for a day, from that day's evidence. */
function buildRow(date, day, recon, liveVault, opts = {}) {
  const d = deriveStatus(day, recon, liveVault, opts);
  if (!d.status) return { error: d.error };
  const width = opts.width || 6;
  let out;
  if (d.status === STATUS.MISSED) {
    out = [date, '—', '—', STATUS.MISSED, '—', 'none'];
  } else if (d.status === STATUS.DEGRADED) {
    out = [date, String(day.vault || '').slice(0, 12), sha16(day.bytes), STATUS.DEGRADED,
      typeof day.total === 'number' ? amount(day.total) : '—', 'quarantine_sha256'];
  } else {
    const pinKind = day.blockHash ? 'block_hash' : 'file_sha256';
    const pin = day.blockHash ? day.blockHash.slice(0, 16) : sha16(day.bytes);
    if (typeof day.total !== 'number' || !isFinite(day.total)) {
      return { error: `attestation has no numeric product.metrics.total_assets_usdc` };
    }
    out = [date, String(day.vault).slice(0, 12), pin, d.status, amount(day.total), pinKind];
  }
  if (out.length !== width) return { error: `row/header width mismatch (${out.length} vs ${width})` };
  return { status: d.status, cells: out, line: '| ' + out.join(' | ') + ' |' };
}

/** Counts derived ONLY from the table. */
function tally(rows, liveVault, ctx) {
  const live = String(liveVault).toLowerCase();
  const counted = rows.filter((r) => r.status === STATUS.COUNTED);
  // the vault column carries a 12-char prefix ("0x" + 10 hex), so match by prefix
  const offLiveCounted = counted.filter((r) => !live.startsWith(String(r.vault).toLowerCase()));
  const closed = rows.filter((r) => r.status === STATUS.CLOSED);
  const excluded = rows.filter((r) => r.status === STATUS.BREACH);
  const generations = new Map();
  for (const r of rows) {
    const key = r.vault;
    if (!generations.has(key)) generations.set(key, { vault: key, counted: 0, attested_clean: 0, degraded: 0, dates: [] });
    const g = generations.get(key);
    if (r.status === STATUS.COUNTED || r.status === STATUS.CLOSED) { g.counted++; g.dates.push(r.date); }
    if (r.status === STATUS.COUNTED || r.status === STATUS.CLOSED || r.status === STATUS.BREACH) g.attested_clean++;
    if (r.status === STATUS.DEGRADED) g.degraded++;
  }
  const dates = rows.map((r) => r.date).sort();
  const lastDate = dates.length ? dates[dates.length - 1] : null;
  return {
    rows, counted, offLiveCounted, closed, excluded,
    generations: [...generations.values()],
    liveCount: counted.length,
    lastDate,
    completion: completionDate({ lastDate, liveCount: counted.length, ctx }),
  };
}

/**
 * Earliest date the 30th counted day can fall: walk forward from the day after
 * the last attested one. A PAST day only counts when its own evidence is there,
 * clean, on the live vault and unbreached (so a known missed/breached day is
 * skipped, which `last + remaining` could not do); a FUTURE day is assumed
 * clean, which is what makes this the earliest possible date.
 */
function completionDate({ lastDate, liveCount, ctx }) {
  if (!lastDate) return null;
  if (liveCount >= TARGET) return null;
  if (!ctx || !ctx.attestDir) return addDays(lastDate, TARGET - liveCount);
  const today = (ctx.today || new Date().toISOString().slice(0, 10));
  let n = liveCount;
  let d = addDays(lastDate, 1);
  for (let i = 0; i < 400; i++) {
    let clean = d > today; // future days assumed clean
    if (!clean) {
      const day = loadDay(ctx.attestDir, d, ctx.slots);
      if (day.kind !== 'none' && !day.error) {
        const recon = loadRecon(ctx.reconDir, d);
        clean = deriveStatus(day, recon, ctx.liveVault, { allowClosed: false }).status === STATUS.COUNTED;
      }
    }
    if (clean) n++;
    if (n >= TARGET) return d;
    d = addDays(d, 1);
  }
  return null;
}

/**
 * The auto block. Every figure traces to the table or to a named snapshot;
 * nothing here is hand-written.
 */
function renderBlock(t, liveVault, reconFor, existing = {}) {
  const liveShort = shortAddr(liveVault);
  const dates = t.rows.map((r) => r.date);
  const firstDate = dates[0];
  const derived = t.completion
    ? `earliest 30th counted clean day if every remaining day counts from ${addDays(t.lastDate, 1)}`
    : 'no attested day yet';
  const genBits = t.generations
    .filter((g) => g.attested_clean > 0)
    .map((g) => {
      const isLive = String(liveVault).toLowerCase().startsWith(String(g.vault).toLowerCase());
      const span = g.dates.length ? ` ${g.dates[0]} … ${g.dates[g.dates.length - 1]}` : '';
      return `\`${g.vault}\` ${isLive ? '(LIVE)' : '(closed)'}: **${g.counted} counted** of ${g.attested_clean} clean attestations${span}`;
    });
  const notCounted = t.rows.filter((r) => r.status !== STATUS.COUNTED && r.status !== STATUS.CLOSED && r.status !== STATUS.SUPERSEDED);
  const notCountedLines = notCounted.map((r) => {
    if (r.status === STATUS.MISSED) return `- **${r.date}** — missed: no attestation was ever generated (see the miss note below)`;
    if (r.status === STATUS.DEGRADED) return `- **${r.date}** — degraded, quarantined at \`attestations/degraded/${r.date}.json\`, never published as an attestation`;
    const rec = reconFor(r.date);
    let detail;
    if (rec && rec.present) {
      detail = `snapshot ${rec.generated_at} block ${rec.block}: ` + Object.entries(rec.perBook)
        .map(([k, v]) => `${k} ${v.breach ? 'BREACH ' : ''}${v.gap_bps} bps`).join(' · ');
    } else if (existing[r.date]) {
      // no snapshot in THIS checkout (a public clone legitimately has none):
      // keep the detail the doc already carries rather than blanking evidence
      detail = existing[r.date];
    } else {
      detail = 'recon snapshot not available to this render';
    }
    const why = r.status === STATUS.BREACH
      ? 'clean attestation, excluded by rule 5 (recon breach)'
      : `status \`${r.status}\``;
    return `- **${r.date}** — ${why} — ${detail}`;
  });
  return [
    `${AUTO_START} — written by scripts/ladder_append.js; do not hand-edit -->`,
    `**Clean days on the live vault: ${t.liveCount}.** Next possible completion: ${t.completion || 'not derivable'} — ${derived}.`,
    `**Counted per generation:** ${genBits.join(' · ') || '(no rows)'}.`,
    `**Counting rule — SETTLED by the owner 2026-10-17 (card \`t_ba8c3805\`): counted, not consecutive.**`,
    `A day counts iff its row is \`clean\` (clean attestation, no \`breach: true\` in that day's recon snapshot)`,
    `**and** it names the live vault; adjacency is NOT required, so a missed day (such as 2026-10-16) does not`,
    `reset the count. Rows are per generation: a superseded generation's days are recorded, never added.`,
    `**Not counted (${notCounted.length} day${notCounted.length === 1 ? '' : 's'}${notCounted.length ? `, ${notCounted[0].date} … ${notCounted[notCounted.length - 1].date}` : ''}):**`,
    ...(notCountedLines.length ? notCountedLines : ['- none']),
    AUTO_END,
  ].join('\n');
}

/** The one-line status headline. */
function renderStatus(t, liveVault) {
  const liveShort = shortAddr(liveVault);
  const closed = t.generations
    .filter((g) => String(g.vault).toLowerCase() !== String(liveVault).toLowerCase() && g.counted > 0)
    .sort((a, b) => b.counted - a.counted)[0];
  if (t.liveCount === 0) {
    const closedBit = closed
      ? `; the \`${closed.vault}\` generation closed at ${closed.counted} counted (${closed.attested_clean} clean attestations), rung not reached`
      : '';
    return `**Status:** 0/30 counted clean days on the LIVE vault ${liveShort} — day 1 not yet earned${closedBit}. (rendered by scripts/ladder_append.js — do not hand-edit)`;
  }
  const first = t.counted[0].date;
  const last = t.counted[t.counted.length - 1].date;
  return `**Status:** ${t.liveCount}/30 counted clean days on the LIVE vault ${liveShort} (${first} … ${last}); ` +
    `30th counted clean day ≈ **${t.completion}** if every remaining day counts. (rendered by scripts/ladder_append.js — do not hand-edit)`;
}

/** Reproduce every derived cell the doc claims from the table alone. */
function renderDoc(docLines, t, liveVault, reconFor) {
  const statusRe = /^\*\*Status:\*\* [^\n]*$/m;
  const blockRe = new RegExp(`${AUTO_START.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[\\s\\S]*?${AUTO_END.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`);

  // keep whatever detail the doc already states for a day we cannot re-read here
  const existingDetail = {};
  for (const l of docLines) {
    const m = /^- \*\*(\d{4}-\d{2}-\d{2})\*\* — ([^]*?) — (.*)$/.exec(l);
    if (m) existingDetail[m[1]] = m[3];
  }
  const status = renderStatus(t, liveVault);
  const block = renderBlock(t, liveVault, reconFor, existingDetail);
  let out = docLines.join('\n');
  const lines = out.split('\n');
  if (!lines.some((l) => /^\*\*Status:\*\*/.test(l))) return { error: 'no "**Status:**" line' };
  out = out.replace(statusRe, () => status);
  if (!blockRe.test(out)) return { error: 'no ladder:auto block' };
  out = out.replace(blockRe, () => block);
  return { out };
}

module.exports = {
  TARGET, STATUS, AUTO_START, AUTO_END,
  addDays, pretty, amount, shortAddr, sha16, cells, headerIndex, parseRows, rowRe,
  loadDay, loadRecon, deriveStatus, buildRow, tally, renderBlock, renderStatus, renderDoc,
  SLOT_RE, loadSlots, evidenceFor, completionDate,
};
