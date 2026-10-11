# S3b Attestation Ladder — Criteria & Per-Day Manifest

**Status:** 17/30 clean days on the LIVE vault → 30th clean day ≈ **Oct 24, 2026** (not Oct 23).

## The rule (settled 2026-10-05, after the ladder audit)

A day counts toward the S3b cap raise **iff all of the following hold:**

1. **Right vault:** the attestation names the currently-deployed mainnet vault
   `0x8954a73Bb36D17e4B212137Eb7B2328A1A14D1C1`. Attestations of superseded vault
   generations do NOT count (09-24 attests the r0 vault `0xadaE15e2…`, superseded
   2026-09-25 17:43 UTC — it is published for history, not counted).
2. **Complete:** every read resolved — no `unavailable` entries, no null headline.
3. **Unedited after publication:** the day's slot is written once by the daily cron
   (from 2026-10-06, same-day reruns are versioned `-rN` instead of overwriting).
4. **Cap raise trigger:** 30 consecutive clean days (per this rule) → TVL cap
   $10,000 → $50,000 and per-user cap $1,000 → $5,000 (S3b), followed by the
   S4/T1 external audit engagement.

## Per-day manifest (generated 2026-10-05; sha256 truncated to 16 hex)

| date | vault | sha256-16 | status | total_assets ($) |
|---|---|---|---|---|
| 2026-09-24 | 0xadaE15e23b | 5ed92d60e5b661ef | **SUPERSEDED — not counted** | 0 |
| 2026-09-25 | 0x8954a73Bb3 | 54d0fd9a32a7be57 | clean | 0 |
| 2026-09-26 | 0x8954a73Bb3 | f1db93a74652fea1 | clean | 26.39053 |
| 2026-09-27 | 0x8954a73Bb3 | f332028744801e3b | clean | 26.39053 |
| 2026-09-28 | 0x8954a73Bb3 | ff0180fe1837e147 | clean | 26.39053 |
| 2026-09-29 | 0x8954a73Bb3 | 50926a35af2d18ab | clean | 26.39053 |
| 2026-09-30 | 0x8954a73Bb3 | f5c9114a7502f000 | clean | 51.959014 |
| 2026-10-01 | 0x8954a73Bb3 | f50b6397d3dce92e | clean | 53.392731 |
| 2026-10-02 | 0x8954a73Bb3 | 9ad4492fc47d1a6d | clean | 53.395516 |
| 2026-10-03 | 0x8954a73Bb3 | 42c7cd7a614188b9 | clean | 53.398415 |
| 2026-10-04 | 0x8954a73Bb3 | b7663d4865c98fc6 | clean | 158.693386 |
| 2026-10-05 | 0x8954a73Bb3 | 490447de44eb94be | clean | 176.238867 |
| 2026-10-06 | 0x8954a73Bb3 | ca61b4392d8c76bc | clean | 176.238867 |
| 2026-10-07 | 0x8954a73Bb3 | 0cea1d9de57c9b9a | clean | 176.251334 |
| 2026-10-08 | 0x8954a73Bb3 | 8984533bf04ee363 | clean | 176.258375 |
| 2026-10-09 | 0x8954a73Bb3 | 743817fac4ab10ec | clean | 176.262619 |
| 2026-10-10 | 0x8954a73Bb3 | 4d9cb8e32dc0c210 | clean | 126.269032 |
| 2026-10-11 | 0x8954a73Bb3 | dc2c5539f90277b5 | clean | 126.274108 |

**Clean days on the live vault: 17 (09-25 … 10-11). Next possible completion: 2026-10-24.**

## Audit trail

This doc exists because of the 2026-10-05 ladder audit (proyield-security seat):
the "12/30 → Oct 23" headline silently counted the 09-24 attestation of the
superseded r0 vault. Verified independently: the 09-24 file's `product.vault` is
`0xadaE15e2…` and its TVL is $0. Remaining generator fixes (cap fields in each
attestation, clean/degraded flag, block-hash pinning, same-day versioning) are
tracked on the kanban board (ops lane).
