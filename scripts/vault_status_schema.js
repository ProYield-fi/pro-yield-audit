// scripts/vault_status_schema.js — multi-book feed schema v2 (Way A / W3a).
//
// Pure, chain-free helpers the feed writer (scripts/write_vault_status.js)
// uses to publish a `books[]` array ADDITIVELY: every existing v1 top-level
// field stays in place, and books[0] MUST reproduce them — enforced by
// assertCoreCanary(), which refuses to publish on any drift.
//
// A DEPLOYED book publishes its real addresses + the live numbers the writer
// read for it. A book that is NOT deployed publishes an HONEST GAP
// (null + deployed:false) — never a fabricated 0. The class of degraded data
// this project was burned by.
//
// The registry (books.mainnet.json) is INTERNAL and purged from the public
// audit export; when it is absent this module degrades to a single core row so
// the exported writer still runs. No chain access, no side effects — testable
// in isolation (scripts/vault_status_books_test.js).
const fs = require("fs");
const path = require("path");

const REGISTRY_DEFAULT = path.join(__dirname, "..", "books.mainnet.json");

function registryPath() {
  return process.env.BOOK_REGISTRY || REGISTRY_DEFAULT;
}

function manifestPath(rel) {
  return path.join(__dirname, "..", rel);
}

function readJson(p) {
  // Path resolved per call so a test can point BOOK_REGISTRY at a fixture (and
  // so the public export, where the registry is purged, degrades to core-only).
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; }
}

function readRegistry() { return readJson(registryPath()); }

// The v1 top-level fields books[0] (core) must reproduce verbatim.
const CORE_FIELDS = ["vault", "sharePrice", "totalAssets", "totalShares", "deployment", "pulse", "ts"];

// Registry books (other than core) that are deployed AND whose manifest is
// present — the writer reads these on-chain and hands the numbers to buildBooks.
function deployedBooks() {
  const reg = readRegistry();
  if (!reg || !reg.books) return [];
  const out = [];
  for (const id of Object.keys(reg.books)) {
    if (id === "core") continue;
    const b = reg.books[id] || {};
    if (!b.deployed || !b.manifest) continue;
    const m = readJson(manifestPath(b.manifest));
    if (m && m.pro_yield_vault) out.push({ id, label: b.label || id, manifest: m, manifestPath: manifestPath(b.manifest) });
  }
  return out;
}

function coreRow({ core, label }) {
  return {
    id: "core",
    label: label || "Core",
    vault: core.vault,
    feeDistributor: core.feeDistributor ?? null,
    deployed: true,
    sharePrice: core.sharePrice,
    totalAssets: core.totalAssets,
    totalShares: core.totalShares,
    deployment: core.deployment,
    pulse: core.pulse,
    ts: core.ts,
  };
}

// The build-provenance clause of a deployed row is read from the book's OWN
// manifest note, never hard-coded: book #2 (Boost) is the head-fixed build, NOT
// book-#1-identical (t_49e24963), so a fixed string asserting bytecode identity
// is a false public claim. A manifest with no usable note degrades to a neutral,
// claim-free line so the feed never re-asserts a claim the manifest does not make.
function manifestBuildNote(manifest) {
  const n = manifest && Array.isArray(manifest._notes) ? manifest._notes[0] : null;
  return typeof n === "string" && n.trim() ? n.trim() : null;
}

// A DEPLOYED non-core book: real addresses from its manifest, live numbers from
// the writer's `reads[id]` (an honest null when the read failed — never a 0).
function deployedRow({ id, label, manifest, read }) {
  const r = read || {};
  const provenance = manifestBuildNote(manifest);
  return {
    id,
    label,
    vault: manifest.pro_yield_vault || null,
    feeDistributor: manifest.fee_distributor || null,
    deployed: true,
    sharePrice: r.sharePrice ?? null,
    totalAssets: r.totalAssets ?? null,
    totalShares: r.totalShares ?? null,
    // Composition + per-book reconcile are the W6 harness; until then the row
    // carries live vault reads only — never the core book's composition.
    deployment: null,
    pulse: null,
    reconcile: null,
    note: provenance
      ? `${provenance} Vault reads live; per-book composition + reconcile land with the W6 harness.`
      : "deployed — vault reads live; per-book composition + reconcile land with the W6 harness",
  };
}

// HONEST GAP row: a book the feed cannot read a real number for. Nulls +
// deployed:false — a consumer renders the locked/preview card, never a live 0.
function gapRow({ id, label, manifestPresent }) {
  return {
    id,
    label,
    vault: null,
    feeDistributor: null,
    deployed: false,
    sharePrice: null,
    totalAssets: null,
    totalShares: null,
    deployment: null,
    pulse: null,
    reconcile: null,
    note: manifestPresent
      ? "manifest present but book not armed — honest gap, never a fabricated 0"
      : "not deployed — honest gap, never a fabricated 0",
  };
}

// Build the books[] array: core first (from the writer's own reads), then every
// other registry book — a deployed row with the supplied live reads, else a gap.
function buildBooks({ core, reads }) {
  const reg = readRegistry();
  const readsMap = reads || {};
  const coreLabel = (reg && reg.books && reg.books.core && reg.books.core.label) || "Core";
  const rows = [coreRow({ core, label: coreLabel })];
  if (reg && reg.books && reg.default_book) {
    for (const id of Object.keys(reg.books)) {
      if (id === "core") continue;
      const b = reg.books[id] || {};
      const rel = b.manifest || null;
      const present = Boolean(rel && fs.existsSync(manifestPath(rel)));
      if (b.deployed && present) {
        const m = readJson(manifestPath(rel));
        if (m && m.pro_yield_vault) {
          rows.push(deployedRow({ id, label: b.label || id, manifest: m, read: readsMap[id] }));
          continue;
        }
      }
      rows.push(gapRow({ id, label: b.label || id, manifestPresent: present }));
    }
  }
  return rows;
}

// The canary: books[0] must equal the v1 top-level output field-for-field.
// Throws (so the writer exits before publishing) on any drift.
function assertCoreCanary({ core, books }) {
  const row = (books || [])[0];
  if (!row || row.id !== "core") throw new Error("books[0] is not the core book");
  for (const f of CORE_FIELDS) {
    const a = JSON.stringify(core[f] ?? null);
    const b = JSON.stringify(row[f] ?? null);
    if (a !== b) throw new Error(`books[0].${f} drifted from the v1 top-level (books=${b} v1=${a})`);
  }
  if (JSON.stringify(row.feeDistributor ?? null) !== JSON.stringify(core.feeDistributor ?? null)) {
    throw new Error("books[0].feeDistributor drifted from the v1 feed");
  }
  return true;
}

// ── Primary-book guard (defense-in-depth, 2026-10-10) ─────────────────────
// The feed's TOP-LEVEL (vault/sharePrice/totalAssets/totalShares + the events
// basis) is ALWAYS book #1 (core). The writer is driven by DEPLOY_MANIFEST, so a
// non-core manifest republishes CORE's slot with another book's numbers — and
// diffs the events ledger against the wrong baseline (the false "loss posted"
// class). Per-book data belongs in books[] (extend deployedRow), never by
// re-running the writer with another primary. Resolve which registry book a
// manifest path belongs to; null when it is not a registry book (smoke/export).
function bookIdForManifest(manifest) {
  const reg = readRegistry();
  if (!reg || !reg.books || !manifest) return null;
  const target = path.resolve(process.cwd(), manifest);
  for (const id of Object.keys(reg.books)) {
    const rel = reg.books[id] && reg.books[id].manifest;
    if (!rel) continue;
    if (path.resolve(manifestPath(rel)) === target) return id;
  }
  return null;
}

// Throws unless the primary book is `core` (or the manifest is not a registry
// book). `allowNonCore` bypasses ONLY on an explicit, deliberate override.
function assertPrimaryIsCore(manifest, { allowNonCore = false } = {}) {
  const id = bookIdForManifest(manifest);
  if (id === null || id === "core" || allowNonCore) return id;
  throw new Error(
    `primary book is '${id}', not 'core' — the public feed's top-level ` +
      `(vault/sharePrice/totalAssets) and the events basis are ALWAYS book #1. ` +
      `Per-book data belongs in books[] (extend deployedRow), never by re-running ` +
      `this writer with another book's manifest as the primary.`,
  );
}

module.exports = {
  buildBooks,
  assertCoreCanary,
  readRegistry,
  deployedBooks,
  CORE_FIELDS,
  bookIdForManifest,
  assertPrimaryIsCore,
};
