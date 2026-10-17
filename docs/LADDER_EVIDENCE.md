# S3b Attestation Ladder — Criteria & Per-Day Manifest

**Status:** 22/30 clean days on the LIVE vault → 30th clean day ≈ **Oct 25, 2026** (counted rule — settled by the owner 2026-10-17; see the note under the table).

## The rule (settled 2026-10-05, after the ladder audit)

A day counts toward the S3b cap raise **iff all of the following hold:**

1. **Right vault:** the attestation names the currently-deployed mainnet vault
   `0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1`. Attestations of superseded vault
   generations do NOT count (09-24 attests the r0 vault `0xadaE15e2…`, superseded
   2026-09-25 17:43 UTC — it is published for history, not counted).
2. **Complete:** every read resolved — no `unavailable` entries, no null headline.
3. **Unedited after publication:** the day's slot is written once by the daily cron
   (from 2026-10-06, same-day reruns are versioned `-rN` instead of overwriting).
4. **Cap raise trigger:** 30 clean days **counted** under this rule — counted,
   not consecutive (owner ruling 2026-10-17, card `t_ba8c3805`) → TVL cap
   $10,000 → $50,000 and per-user cap $1,000 → $5,000 (S3b), followed by the
   S4/T1 external audit engagement. A missed day (e.g. 2026-10-16) is not a
   clean day so it does not count, but it does **not** reset the count either.

## Per-day manifest (one row per published attestation day; every cell reproducible — see the auditor note under the table)

| date | vault | evidence_pin | status | total_assets ($) | pin_kind |
|---|---|---|---|---|---|
| 2026-09-24 | 0xadaE15e23b | 5ed92d60e5b661ef | **SUPERSEDED — not counted** | 0 | file_sha256 |
| 2026-09-25 | 0x8954a73Bb3 | 54d0fd9a32a7be57 | clean | 0 | file_sha256 |
| 2026-09-26 | 0x8954a73Bb3 | f1db93a74652fea1 | clean | 26.39053 | file_sha256 |
| 2026-09-27 | 0x8954a73Bb3 | f332028744801e3b | clean | 26.39053 | file_sha256 |
| 2026-09-28 | 0x8954a73Bb3 | ff0180fe1837e147 | clean | 26.39053 | file_sha256 |
| 2026-09-29 | 0x8954a73Bb3 | 50926a35af2d18ab | clean | 26.39053 | file_sha256 |
| 2026-09-30 | 0x8954a73Bb3 | f5c9114a7502f000 | clean | 51.959014 | file_sha256 |
| 2026-10-01 | 0x8954a73Bb3 | f50b6397d3dce92e | clean | 53.392731 | file_sha256 |
| 2026-10-02 | 0x8954a73Bb3 | 9ad4492fc47d1a6d | clean | 53.395516 | file_sha256 |
| 2026-10-03 | 0x8954a73Bb3 | 42c7cd7a614188b9 | clean | 53.398415 | file_sha256 |
| 2026-10-04 | 0x8954a73Bb3 | b7663d4865c98fc6 | clean | 158.693386 | file_sha256 |
| 2026-10-05 | 0x8954a73Bb3 | 490447de44eb94be | clean | 176.238867 | file_sha256 |
| 2026-10-06 | 0x8954a73Bb3 | ca61b4392d8c76bc | clean | 176.241787 | block_hash |
| 2026-10-07 | 0x8954a73Bb3 | 0cea1d9de57c9b9a | clean | 176.251334 | block_hash |
| 2026-10-08 | 0x8954a73Bb3 | 8984533bf04ee363 | clean | 176.258375 | block_hash |
| 2026-10-09 | 0x8954a73Bb3 | 743817fac4ab10ec | clean | 176.262619 | block_hash |
| 2026-10-10 | 0x8954a73Bb3 | 4d9cb8e32dc0c210 | clean | 126.269032 | block_hash |
| 2026-10-11 | 0x8954a73Bb3 | dc2c5539f90277b5 | clean | 126.274108 | block_hash |
| 2026-10-12 | 0x8954a73Bb3 | e054676770a91424 | clean | 126.278357 | block_hash |
| 2026-10-13 | 0x8954a73Bb3 | 3c3dae9fef19370f | clean | 126.282995 | block_hash |
| 2026-10-14 | 0x8954a73Bb3 | 3930cc8a274d4231 | clean | 126.287559 | block_hash |
| 2026-10-15 | 0x8954a73Bb3 | c749ff1803e7a74f | clean | 123.898535 | block_hash |
| 2026-10-17 | 0x8954a73Bb3 | 4d0c6e64c43693f7 | clean | 123.910911 | block_hash |

**How to read `evidence_pin` (auditor note; card `t_e34d6404`).** The column carries the first 16 hex
characters of the digest named in that same row's `pin_kind`, so a cell's meaning is explicit and never
changes silently:

- **`file_sha256`** (2026-09-24 … 2026-10-05) — `sha256(attestations/<date>.json)`, i.e. the published
  file's own bytes. The generator did not pin a block hash before 2026-10-06.
- **`block_hash`** (2026-10-06 …) — `product.as_of_block_hash` from that day's JSON: the hash of the
  HyperEVM block the numbers were read at, truncated to 16 hex. This is **not** a file digest — verify it
  against the JSON's own `product.as_of_block` / `as_of_block_hash`, or against the chain, never against
  the file. Block-hash pinning landed 2026-10-06.

Reproduce **every** cell of this table with one command from the repo root: `node scripts/ladder_verify.js`
(exit 0 = every row reconciles; otherwise one FAIL line per disagreeing cell, naming both values). The
per-cell equivalents are `sha256sum attestations/2026-10-05.json | cut -c1-16` for a `file_sha256` row and
`jq -r .product.as_of_block_hash attestations/2026-10-06.json | sed 's/^0x//' | cut -c1-16` for a `block_hash`
row (the `0x` prefix is stripped — every `evidence_pin` cell is exactly 16 hex characters, no prefix);
`total_assets ($)` is `jq -r .product.metrics.total_assets_usdc attestations/<date>.json`.

**Corrected cell — 2026-10-06 `total_assets` (card `t_e34d6404`, fixed 2026-10-17).** This row was
published as `176.238867`, which is the **2026-10-05** value, while carrying 10-06's correct block hash.
The 2026-10-06 attestation itself has always said `product.metrics.total_assets_usdc = 176.241787`
(block 47815864), so the row — not the attestation — was wrong, and the cell now equals its own JSON.
Cause, to the limit the record supports: the 10-06 row was not written by the daily job (the auto-appender
did not exist on 10-06; it was introduced on 2026-10-07 in commit `92b812ac`, whose diff adds both the
10-06 and 10-07 rows, and a single run can only append the series tail). Its two cells therefore came from
different days — pin from `attestations/2026-10-06.json`, TVL equal to the 10-05 series value — which is a
backfill that read the previous row for the amount; the exact one-off command is not recoverable because
`~/.hermes/logs/attestation.log` had already rotated past 10-07. The mechanism it exposes was real and is
now closed: the appender required no cross-check between the row and the day's own JSON. It now reads the
TVL and pin from `attestations/<date>.json` and **refuses to write** (exit 1) when that JSON disagrees with
the `series.jsonl` tail, and `scripts/ladder_verify.js` re-checks all 23 rows independently. No other row's
value changed, and the clean-day count (22/30) is unaffected by this correction.

<!-- ladder:auto:start — written by scripts/ladder_append.js; do not hand-edit -->
**Clean days on the live vault: 22 (09-25 … 10-17). Next possible completion: 2026-10-25** (last counted row 2026-10-17 + 8 remaining days: 30 − 22 = 8).
**Counting rule — SETTLED by the owner 2026-10-17 (card `t_ba8c3805`): counted, not consecutive.**
A day counts iff it is a `clean` row for the live vault; adjacency is NOT required, so a missed day
(such as 2026-10-16) does not reset the streak. That is exactly what this script counts — verified, no
logic change — so the date above stands. The pre-gap "Oct 24" figure is retired.
<!-- ladder:auto:end -->

**Gap note — 2026-10-16 is a MISSED day, not a degraded one (diagnosed 2026-10-17, card `t_ba8c3805`).**
No attestation exists for 2026-10-16 and none was ever generated: the ops host was powered off
2026-10-16 02:09:33 → 09:11:55 EDT (clean systemd-logind power-off, then a LUKS passphrase boot), so
the 08:10 local cron never fired. Nothing is quarantined under `attestations/degraded/` because
nothing ran. The series resumed on its own at 2026-10-17 08:10 and published clean
(TVL 123.910911, block 48782038) — that row is the 22nd above.
Backfill was considered and **rejected as dishonest**: `scripts/attestation.js` stamps
`date = new Date()` and takes the Hyperliquid venue reads as a live API snapshot
(`venues.hyperliquid.snapshot_at = now`), and it has no historical-date flag. A 10-16 re-run today
would therefore be 10-17 state labelled 10-16 (and would degrade to `unavailable` on the HL reads →
quarantined by its own F4 rule). There is no honest reconstruction of 2026-10-16 with this generator.
**Owner ruling applied (2026-10-17, card `t_ba8c3805`) — the counted clean-day rule stands.**
The host power-off does **not** reset the streak: a day counts iff it is a `clean` row for the live vault,
and adjacency is not required. 30th clean day = **2026-10-25** (last counted 2026-10-17 + 8 days).
`ladder_append.js` already implements exactly this (it counts clean rows and never checks adjacency):
verified, **no logic change was needed** — only its rendered prose was updated so it stops advertising an
open question. The pre-gap "Oct 24" figure is **retired**: it was pre-gap arithmetic and is not supported
by the manifest. The R1 deploy window then moved to **2026-10-25** (owner decision 2026-10-17, card `t_77e86b55`):
R1 and the S3b `setCaps` rung are ONE sitting, run AFTER that morning's 08:10 attestation — so the
rung is earned at 30/30, not waived.
**Publication of the miss (owner ruling, same day):** 2026-10-16 is published as a one-line honest note at
`pyd.fi/attestations/2026-10-16.md` — *"No attestation 2026-10-16 — the ops host was offline 02:09–09:11 EDT."*
No `.json`, no `series.jsonl`/`series.json` row and no ladder row exists for that date: the machine-readable
series still jumps 10-15 → 10-17. The note records the miss; it is not an attestation and cannot become one.

## Audit trail

This doc exists because of the 2026-10-05 ladder audit (proyield-security seat):
the "12/30 → Oct 23" headline silently counted the 09-24 attestation of the
superseded r0 vault. Verified independently: the 09-24 file's `product.vault` is
`0xadaE15e2…` and its TVL is $0. Remaining generator fixes (cap fields in each
attestation, clean/degraded flag, block-hash pinning, same-day versioning) are
tracked on the kanban board (ops lane).
