# S3b Attestation Ladder — Criteria & Per-Day Manifest

**Status:** 0/30 counted clean days on the LIVE vault 0x9DA979aD…cFD9 — day 1 not yet earned; the `0x8954a73Bb3` generation closed at 21 counted (27 clean attestations), rung not reached. (rendered by scripts/ladder_append.js — do not hand-edit)

## The rule (settled 2026-10-17, after the ladder audit; re-based on the R1 vault 2026-10-26)

A day counts toward the S3b cap raise **iff all of the following hold:**

1. **Right vault:** the attestation names the currently-deployed mainnet vault
   `0x9DA979aD9F44dBC96f3977F305cea9D1E1EAcFD9` (generation 2026-10-25,
   `deployed_addresses.mainnet.json`; ownership = the 2-of-3 treasury Safe). The ladder is
   **per-address**: attestations of superseded vault generations do NOT count toward this
   book's streak. Two superseded generations are published for history only — the r0 vault
   `0xadaE15e2…` (superseded 2026-09-25 17:43 UTC) and the
   `0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1` generation (2026-09-25 → 2026-10-25, now
   `depositsPaused = true` with `totalAssets = 0.004768 USDC`). The 0x8954 generation's count
   **CLOSED at 21 counted clean days** — 27 clean attestations were published for it and 6 of
   those are excluded by rule 5 — so **30 was never reached and no cap raise was earned on it**.
   The R1 book starts its own streak from its first counted day. **No cap raise was earned
   before the migration; R1 deployed at $10,000 TVL / $1,000 per user** (chain-read 2026-10-26,
   block 49,584,006).
2. **Complete:** every read resolved — no `unavailable` entries, no null headline.
3. **Unedited after publication:** the day's slot is written once by the daily cron
   (from 2026-10-06, same-day reruns are versioned `-rN` instead of overwriting).
4. **Cap raise trigger:** 30 clean days **counted** under this rule — counted,
   not consecutive (owner ruling 2026-10-17, card `t_ba8c3805`) → TVL cap
   $10,000 → $50,000 and per-user cap $1,000 → $5,000 (S3b), followed by the
   S4/T1 external audit engagement. A missed day (e.g. 2026-10-16) is not a
   clean day so it does not count, but it does **not** reset the count either.
5. **Recon breach exclusion:** a day with `breach: true` in the associated recon
   snapshot (any book, any direction, past the configured bps threshold — 5 bps) does
   **not** count as a clean day, regardless of its attestation `status` (owner ruling
   2026-10-23, card `t_9baa0916`). It applies to **every** generation: 6 of the 0x8954
   generation's days are excluded (10-17 … 10-22) and the first day of this book (10-26)
   is excluded for the same reason. An owner-signed exception recorded on the day's file
   may override this exclusion (see the exception mechanism at the bottom of this doc).
6. **Owner ruling pending — "earned but unused" (card `t_d72b0501`, item 4).** Whether the
   21 counted clean days of the 0x8954 generation are recorded as *earned but unused* (kept
   as a credit toward a future rung) is **not decided** and this doc asserts neither way. It
   is recorded as CLOSED at 21; the answer does not change this book's count, which is 0
   until its first counted day.

## Per-day manifest (one row per calendar day from 2026-09-24; every cell reproducible — see the auditor note under the table)

The status cell records **the day's own evidence**, never the prose:

| status | meaning |
|---|---|
| `clean` | attestation published clean, no recon breach that day, names the LIVE vault → counted |
| `clean — closed generation` | clean and unbreached, but attests a superseded generation → counted for its own generation, not for the live book |
| `clean — breach excluded` | attestation published clean, but the day's recon snapshot has `breach: true` → not counted (rule 5) |
| `superseded — not counted` | the r0 generation, excluded wholesale by rule 1 |
| `degraded — not counted` | the day's run was quarantined (`attestations/degraded/<date>.json`), never published as an attestation |
| `missed — not counted` | no attestation of any kind exists for that date |

| date | vault | evidence_pin | status | total_assets ($) | pin_kind |
|---|---|---|---|---|---|
| 2026-09-24 | 0xadaE15e23b | 5ed92d60e5b661ef | **superseded — not counted** | 0 | file_sha256 |
| 2026-09-25 | 0x8954a73Bb3 | 54d0fd9a32a7be57 | clean — closed generation | 0 | file_sha256 |
| 2026-09-26 | 0x8954a73Bb3 | f1db93a74652fea1 | clean — closed generation | 26.39053 | file_sha256 |
| 2026-09-27 | 0x8954a73Bb3 | f332028744801e3b | clean — closed generation | 26.39053 | file_sha256 |
| 2026-09-28 | 0x8954a73Bb3 | ff0180fe1837e147 | clean — closed generation | 26.39053 | file_sha256 |
| 2026-09-29 | 0x8954a73Bb3 | 50926a35af2d18ab | clean — closed generation | 26.39053 | file_sha256 |
| 2026-09-30 | 0x8954a73Bb3 | f5c9114a7502f000 | clean — closed generation | 51.959014 | file_sha256 |
| 2026-10-01 | 0x8954a73Bb3 | f50b6397d3dce92e | clean — closed generation | 53.392731 | file_sha256 |
| 2026-10-02 | 0x8954a73Bb3 | 9ad4492fc47d1a6d | clean — closed generation | 53.395516 | file_sha256 |
| 2026-10-03 | 0x8954a73Bb3 | 42c7cd7a614188b9 | clean — closed generation | 53.398415 | file_sha256 |
| 2026-10-04 | 0x8954a73Bb3 | b7663d4865c98fc6 | clean — closed generation | 158.693386 | file_sha256 |
| 2026-10-05 | 0x8954a73Bb3 | 490447de44eb94be | clean — closed generation | 176.238867 | file_sha256 |
| 2026-10-06 | 0x8954a73Bb3 | ca61b4392d8c76bc | clean — closed generation | 176.241787 | block_hash |
| 2026-10-07 | 0x8954a73Bb3 | 0cea1d9de57c9b9a | clean — closed generation | 176.251334 | block_hash |
| 2026-10-08 | 0x8954a73Bb3 | 8984533bf04ee363 | clean — closed generation | 176.258375 | block_hash |
| 2026-10-09 | 0x8954a73Bb3 | 743817fac4ab10ec | clean — closed generation | 176.262619 | block_hash |
| 2026-10-10 | 0x8954a73Bb3 | 4d9cb8e32dc0c210 | clean — closed generation | 126.269032 | block_hash |
| 2026-10-11 | 0x8954a73Bb3 | dc2c5539f90277b5 | clean — closed generation | 126.274108 | block_hash |
| 2026-10-12 | 0x8954a73Bb3 | e054676770a91424 | clean — closed generation | 126.278357 | block_hash |
| 2026-10-13 | 0x8954a73Bb3 | 3c3dae9fef19370f | clean — closed generation | 126.282995 | block_hash |
| 2026-10-14 | 0x8954a73Bb3 | 3930cc8a274d4231 | clean — closed generation | 126.287559 | block_hash |
| 2026-10-15 | 0x8954a73Bb3 | c749ff1803e7a74f | clean — closed generation | 123.898535 | block_hash |
| 2026-10-16 | — | — | missed — not counted | — | none |
| 2026-10-17 | 0x8954a73Bb3 | 467d362c588ea3d1 | clean — breach excluded | 122.479258 | block_hash |
| 2026-10-18 | 0x8954a73Bb3 | f68f47b03873f755 | clean — breach excluded | 122.480719 | block_hash |
| 2026-10-19 | 0x8954a73Bb3 | 37dee8c5122f373b | clean — breach excluded | 122.480719 | block_hash |
| 2026-10-20 | 0x8954a73Bb3 | 944cda7431397d1e | clean — breach excluded | 122.480719 | block_hash |
| 2026-10-21 | 0x8954a73Bb3 | ac2e19d6226002b2 | clean — breach excluded | 122.498188 | block_hash |
| 2026-10-22 | 0x8954a73Bb3 | 0e73df8dd2541270 | clean — breach excluded | 122.503231 | block_hash |
| 2026-10-23 | 0x8954a73Bb3 | 1f1318dc06960989 | degraded — not counted | 122.514784 | quarantine_sha256 |
| 2026-10-24 | 0x8954a73Bb3 | d3643105916d9c01 | degraded — not counted | 122.520467 | quarantine_sha256 |
| 2026-10-25 | 0x8954a73Bb3 | 3495c8d6ea0a79c5 | degraded — not counted | 122.520467 | quarantine_sha256 |
| 2026-10-26 | 0x9DA979aD9F | aa7020fd854ff263 | clean — breach excluded | 12.95 | block_hash |

**How to read `evidence_pin` (auditor note; card `t_e34d6404`).** The column carries the first 16 hex
characters of the digest named in that same row's `pin_kind`, so a cell's meaning is explicit and never
changes silently:

- **`file_sha256`** (2026-09-24 … 2026-10-05) — `sha256(attestations/<date>.json)`, i.e. the published
  file's own bytes. The generator did not pin a block hash before 2026-10-06.
- **`block_hash`** (2026-10-06 …) — `product.as_of_block_hash` from that day's JSON: the hash of the
  HyperEVM block the numbers were read at, truncated to 16 hex. This is **not** a file digest — verify it
  against the JSON's own `product.as_of_block` / `as_of_block_hash`, or against the chain, never against
  the file.
- **`quarantine_sha256`** (degraded days) — `sha256(attestations/degraded/<date>.json)[:16]`, the day's
  own quarantined bytes. Degraded evidence is **not published** in either repository (audit F4 keeps it
  out of the public tree), so all three of 2026-10-23 … 10-25 are retained by the operator and available
  to an auditor on request — the digest above is what makes that request checkable. A degraded day never
  counts, so no counted figure depends on an unpublished digest.
- **`none`** (missed days) — no attestation exists. `ladder_verify.js` fails the row if a file for that
  date ever appears, so a silent backfill cannot slip in.

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
the `series.jsonl` tail, and `scripts/ladder_verify.js` re-checks every row independently.

<!-- ladder:auto:start — written by scripts/ladder_append.js; do not hand-edit -->
**Clean days on the live vault: 0.** Next possible completion: 2026-11-25 — earliest 30th counted clean day if every remaining day counts from 2026-10-27.
**Counted per generation:** `0x8954a73Bb3` (closed): **21 counted** of 27 clean attestations 2026-09-25 … 2026-10-15 · `0x9DA979aD9F` (LIVE): **0 counted** of 1 clean attestations.
**Counting rule — SETTLED by the owner 2026-10-17 (card `t_ba8c3805`): counted, not consecutive.**
A day counts iff its row is `clean` (clean attestation, no `breach: true` in that day's recon snapshot)
**and** it names the live vault; adjacency is NOT required, so a missed day (such as 2026-10-16) does not
reset the count. Rows are per generation: a superseded generation's days are recorded, never added.
**Not counted (11 days, 2026-10-16 … 2026-10-26):**
- **2026-10-16** — missed: no attestation was ever generated (see the miss note below)
- **2026-10-17** — clean attestation, excluded by rule 5 (recon breach) — snapshot 2026-10-17T22:50:01.388Z block 48821074: core BREACH -168.16 bps · boost BREACH -2679.00 bps
- **2026-10-18** — clean attestation, excluded by rule 5 (recon breach) — snapshot 2026-10-18T16:50:01.677Z block 48886955: core BREACH -178.12 bps · boost BREACH -2642.15 bps
- **2026-10-19** — clean attestation, excluded by rule 5 (recon breach) — snapshot 2026-10-19T22:50:01.981Z block 48996755: core BREACH -192.69 bps · boost BREACH -2711.80 bps
- **2026-10-20** — clean attestation, excluded by rule 5 (recon breach) — snapshot 2026-10-20T22:50:01.470Z block 49084594: core BREACH -199.73 bps · boost BREACH -2782.24 bps
- **2026-10-21** — clean attestation, excluded by rule 5 (recon breach) — snapshot 2026-10-21T22:50:01.765Z block 49172435: core BREACH -203.60 bps · boost BREACH -2777.89 bps
- **2026-10-22** — clean attestation, excluded by rule 5 (recon breach) — snapshot 2026-10-22T22:50:02.563Z block 49260275: core BREACH -194.39 bps · boost BREACH -2640.88 bps
- **2026-10-23** — degraded, quarantined at `attestations/degraded/2026-10-23.json`, never published as an attestation
- **2026-10-24** — degraded, quarantined at `attestations/degraded/2026-10-24.json`, never published as an attestation
- **2026-10-25** — degraded, quarantined at `attestations/degraded/2026-10-25.json`, never published as an attestation
- **2026-10-26** — clean attestation, excluded by rule 5 (recon breach) — snapshot 2026-10-26T14:54:47.214Z block 49582590: core BREACH -178.07 bps · boost -3.30 bps
<!-- ladder:auto:end -->

## Days not counted, and why

The auto block above lists every non-counted day with its reason, read from the day's own evidence.
The two mechanisms behind them:

- **Rule 5 (recon breach).** The associated snapshot for a date is `~/.proyield/recon/<date>.json`
  (written by `scripts/recon_cron.sh`, every 6 h, block-tag enforced). Those snapshots are **not
  published** in this repository; an auditor can request the exact bytes. The auto block quotes each
  snapshot's `generated_at`, block and per-book `gap_bps` — the 2026-10-17 hand-written bullet list is
  retired, because the doc itself noted that some of its boost figures matched no run of their day.
- **Quarantine (audit F4).** A degraded run is written to `attestations/degraded/<date>.json` and is
  never counted. 2026-10-23, 2026-10-24 and 2026-10-25 are degraded for the same reason: each day's
  recon snapshot carried `breach: true` on the core book (−191.09, −194.87 and −202.60 bps
  respectively) with no owner exception on file, and the generator fails closed to `degraded` on a
  breach (`scripts/attestation.js`). Their own "unavailable reads" sections are empty — the breach, not
  a missing read, is the reason. None of them counts.

## Missed day — 2026-10-16 (diagnosed 2026-10-17, card `t_ba8c3805`)

No attestation exists for 2026-10-16 and none was ever generated: the ops host was powered off
2026-10-16 02:09:33 → 09:11:55 EDT (clean systemd-logind power-off, then a LUKS passphrase boot), so
the 08:10 local cron never fired. Nothing is quarantined under `attestations/degraded/` because
nothing ran.
Backfill was considered and **rejected as dishonest**: `scripts/attestation.js` stamps
`date = new Date()` and takes the Hyperliquid venue reads as a live API snapshot
(`venues.hyperliquid.snapshot_at = now`), and it has no historical-date flag. A 10-16 re-run today
would therefore be 10-17 state labelled 10-16 (and would degrade to `unavailable` on the HL reads →
quarantined by its own F4 rule). There is no honest reconstruction of 2026-10-16 with this generator.
Publication of the miss (owner ruling, same day): 2026-10-16 is published as a one-line honest note at
`pyd.fi/attestations/2026-10-16.md` — *"No attestation 2026-10-16 — the ops host was offline 02:09–09:11 EDT."*
No `.json`, no `series.jsonl`/`series.json` row and no counted row exists for that date: the
machine-readable series still jumps 10-15 → 10-17. The note records the miss; it is not an attestation
and cannot become one.

## Audit trail

This doc exists because of the 2026-10-05 ladder audit (proyield-security seat):
the "12/30 → Oct 23" headline silently counted the 09-24 attestation of the
superseded r0 vault. Verified independently: the 09-24 file's `product.vault` is
`0xadaE15e2…` and its TVL is $0.

**2026-10-26 — re-based on the R1 vault; three record defects corrected (card `t_d72b0501`, raised by
proyield-security from `t_f0f617cc`).** What was wrong, and what the evidence shows:

1. **Rule 1 named a superseded vault as the live one.** It named `0x8954…D1C1`, which the R1 generation
   superseded on 2026-10-25; that address now reads `depositsPaused = true` and
   `totalAssets = 0.004768 USDC`, while `0x9DA979aD…AcFD9` reads `tvlCap = $10,000`,
   `perUserCap = $1,000`, `depositsPaused = false`, `totalAssets = 12.95` (both chain-read 2026-10-26,
   block 49,584,006). Rule 1 now names the live vault and states the count is per-address.
2. **The headline added days across two generations, and three different numbers sat in one file.** The
   published copy said "22/30 … 30th clean day ≈ Oct 25, 2026"; 22 was 21 rows on the closed 0x8954
   generation plus one row on the live vault, and the file also said 21 → 2026-11-01 (static summary)
   and 22 → Nov 3 (auto block). The count and the completion date are now **rendered from the table by
   `scripts/ladder_append.js`**, and `scripts/ladder_verify.js` fails if any prose number disagrees
   with the rows.
3. **Nine days were missing from the manifest** — 10-16 (missed), 10-17 … 10-22 (clean attestations,
   breach-excluded) and 10-23 … 10-25 (degraded) had no rows. Each was appended from its own evidence
   with `node scripts/ladder_append.js --backfill <date>`; none was typed by hand.

The card's own arithmetic is corrected here in one respect: it counted **27** as the old vault's clean
days. 27 is the number of clean *attestations* published for that generation; under rule 5 only **21**
of them COUNT (the other 6 are 10-17 … 10-22). Either way the rung was not reached.

The substance of the gate is unchanged and unearned: **the 0x8954 generation closed at 21 of the 30
required counted clean days, so no cap raise was earned before the migration, and the R1 vault deployed
at $10k/$1k.** This book's streak starts at its first day that is clean, unbreached and attests
`0x9DA979…`; as of 2026-10-26 that is **0**.

## Boost book −26% determination (2026-10-23, card `t_a83ab3c7`, read-only)

It is a booking defect, identified to the cent; it is not yield. The gap between the boost book
($38.007055, constant since 10-17) and its all-legs ($48.01–48.59, mark-dependent) is the
**0.13021643 HYPE** that the treasury Safe sent back into the boost DN Core account on **2026-10-17
22:07:44Z** (block 48,818,494, tx `0x34c7f7ef…`, CoreWriter `spotSend`), 1 h 41 min **after** the owner
Safe had written the book down by $11.992945 (`LossReported`, block 48,812,344) — a write-down that
expensed that same HYPE when it had left the sleeve for the Safe on 10-15. The asset returned; the book
was never re-credited; the deployed pre-A3 strategy has no path to push an in-kind recovery into the
vault book (`harvest()` books USDC only, `creditYield` is bounded by USDC arrivals in the vault, and
`totalAssets()` on that build counts EVM USDC only). Arithmetic: `|gap| + $0.002644 book residual
= 0.13021643 × HYPE mark`, which reproduces the measured gap to 8 decimals on 6 of the 7 daily
snapshots — the book never moves, only the mark does. **Not unharvested yield** (lifetime funding on
that account is $0.020141 and the perp is flat since 10-17 16:25Z). **Not the A3 mark under-report**
(that defect is present — the same 12,452-byte build as book #1's DN under-reports its own NAV by
$26.403338 — but the vault book is a stored ledger, not a sum of strategy marks). Direction is safe
(book < assets: no depositor over-payment, invariant 11 holds), the harm is reporting (breach on
record, `/transparency` understates the sleeve) plus $10.16 of unhedged HYPE in a delta-neutral
sleeve. Full evidence: `~/.proyield/recon/BOOST_GAP_2026-10-23.md`. The cause was already published in
plain English on 10-17 in `~/.proyield/COMMUNITY_NOTE_DN_2026-10-17.md` ("the recovered $10.18 sits in
the sleeve but is not yet reflected in the share price"). Resolution needs an owner GO (return the HYPE
to the Safe, or sell→bridge→harvest it); no threshold or detector change is proposed.
Measured boost gap range across the 23 breach runs since the hand-in is **−2632 to −2785 bps**,
mark-dependent. The boost book left breach on 10-23 (it has read 0.70 bps since), so the run-5 breach
that still gates days on this repo is the **core** book's.

## Exception mechanism

A day previously flagged as `breach: true` may be overridden if an owner-signed exception is recorded.
To file an exception, create `attestations/exceptions/<date>.json` with content
`{ "owner_exception": true, "signed_by": "<owner-identifier>", "signed_at": "<ISO-timestamp>", "reason": "<brief-reason>" }`.
The attestation generator checks for this file and, if present, allows the day to retain `status: "clean"`
even though the recon snapshot carries `breach: true`. No exceptions have been filed as of 2026-10-26.
