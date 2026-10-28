# PY-SCOPE-02 — public finding note

**Status: CLOSED for `ProYieldVault` and `FeeDistributor` (2026-10-26).**

## What the finding was

The source tree and the vault generation deployed on 2026-09-25 had drifted: the
published source was not a byte-for-byte rebuild of the deployed runtime. That
made "audit this repository" ambiguous for the older generation.

## What was verified

The current Book #1 vault was deployed 2026-10-25 from source cut `0624616c`
(the `808e2ecf` vault tip plus the `depositFor` auto-earn guard), solc 0.8.28,
optimizer runs=200, no viaIR, evm `paris`.

- Vault runtime: **12,140 B**, sha256 `ff907cc7…f97e6f0a`.
- FeeDistributor: **2,106 B**, sha256 `e7cceb78…75b004b5`.
- Live code equals the pinned artifact outside constructor-immutable slots only
  (vault 440 differing bytes, FeeDistributor 80, **0 outside**
  `immutableReferences`; CBOR trailers byte-identical).
- The on-chain fixes called out by PY-SCOPE-02 are present: r1 (`c652e006`),
  r3-CEI (`609ad90b`), sUSD3 (`e9c899a8`), F-4 gate (`dca15b6a`), F-4R-2
  (`808e2ecf`) and `depositFor`.

`docs/AUDIT_SCOPE.md` §1.4 carries the reproducible build instructions and the
exact hash conventions. The older generation (vault `0x8954a73B…D1C1`,
source `8daa2ce5`) is `depositsPaused=true` and is historical, not current
scope.

## Note on the private record

The detailed working record is kept private because it contains internal paths
and operator material that are not part of the public audit surface. This public
note is the citable outcome; an auditor who needs the private evidence can
request it from the team.
