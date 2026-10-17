#!/usr/bin/env python3
"""
ProYield Security Monitor
─────────────────────────
Automated security monitoring for the ProYield vault contracts.

Two core functions:
1. Slither static analysis on hypervault/contracts/
2. Protocol security advisory monitoring (Aave, Sky, Morpho, Pendle)

Usage:
    python3 scripts/security_monitor.py                    # Run full scan
    python3 scripts/security_monitor.py --slither-only     # Just Slither
    python3 scripts/security_monitor.py --advisories-only  # Just advisories
    python3 scripts/security_monitor.py --json             # JSON output
    python3 scripts/security_monitor.py --output FILE      # Save report

Cron example:
    0 */6 * * * cd /home/user/hypervault && python3 scripts/security_monitor.py --quiet

POLICY — what "Security scan passed" means (t_56833c8e, 2026-10-15)
────────────────────────────────────────────────────────────────────
This monitor's guarantee is "alert only on something NEW". Three rules make that
guarantee real; do not weaken any of them to make the scan quiet.

1. SIGNATURE = `check:Contract`, PLUS AN ACCEPTED-INSTANCE COUNT.
   A finding's baseline key is the Slither check name and the contract it sits in
   (line-number free, so reformatting does not churn the baseline). The baseline
   VALUE is the accepted reason; for signatures with more than one accepted
   instance it is `{"count": N, "reason": "..."}` (a bare string means count 1).
   The monitor accepts at most N instances of that signature: a NEW instance of an
   already-accepted check in an already-accepted contract (N+1) is REPORTED, not
   blanket-accepted. Known residuals (accepted trade-offs, stated explicitly):
     • a net-zero SWAP inside one contract — deleting one accepted instance and
       adding a different one — leaves the count unchanged and stays silent;
     • Slither's aggregate-per-contract detectors (`pragma`, `solc-version`)
       report ONE finding per contract no matter how many pragma elements they
       contain, so adding another pragma inside an existing contract's file does
       not raise the count.
   Both residuals are inside a single contract whose diff is reviewed by a human.
   Everything else — any new check, any new contract, or any extra instance of an
   accepted check — alerts.

2. SEVERITY = FULL DETECTOR NAME (family-prefix aware). Matching is done on the
   whole check name (`incorrect-equality`, `naming-convention`, ...), and an entry
   also matches its family (`reentrancy` matches `reentrancy-eth` and friends).
   The old `check.split("-")[0]` lookup compared "incorrect" against
   "incorrect-equality" and therefore never matched any hyphenated entry — every
   hyphenated CRITICAL_DETECTORS / WARNING_DETECTORS entry was dead code and
   security-relevant detectors were mis-bucketed as INFO.

3. FAIL-CLOSED. The scan "passes" only when it ran AND nothing is unbaselined:
     • Slither could not compile / produced no JSON  → exit 2, never "passed";
     • any unbaselined finding (critical, warning OR informational) → exit 1;
     • zero unbaselined findings                     → exit 0, "Security scan passed".
   Silence is not a pass. An unbaselined INFO finding fails the gate on purpose:
   triage it and either fix it or add it to security_baseline.json WITH a reason.

The compile framework is pinned to Hardhat and the monitor compiles first itself
(`npx hardhat compile --force`, aborting the scan if that fails), then hands the
fresh build-info to Slither (`--hardhat-ignore-compile`, which also suppresses
`npx hardhat clean` — nothing under artifacts/ is ever deleted). Two reasons:
framework auto-detection picked Foundry whenever foundry.toml existed, which made
the CI scan die on a missing `forge` binary while the monitor still exited 0; and
Slither's Hardhat platform silently falls back to the LAST GOOD build-info when a
compile fails, which would mean scanning code that no longer exists. The scan must
neither depend on which tools happen to be on PATH nor analyse a stale build.
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ── Configuration ──────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONTRACTS_DIR = PROJECT_ROOT / "contracts"
SLITHERSOL = os.environ.get("SLITHER_BIN", "slither")
# Slither forces a full Hardhat recompile (109 contracts); CI runners are slower
# than a dev box, so allow a generous ceiling (the CI job timeout is 20 min).
SLITHER_TIMEOUT = int(os.environ.get("SLITHER_TIMEOUT", "600"))
HARDHAT_CONFIG = PROJECT_ROOT / "hardhat.config.js"
REPORTS_DIR = PROJECT_ROOT / "reports" / "security"

# Slither remapping for OpenZeppelin imports
SOLC_REMAPS = "@openzeppelin/contracts=node_modules/@openzeppelin/contracts"

# Protocols to monitor for security advisories
PROTOCOLS = {
    "Aave": {
        "url": "https://twitter.com/aave",
        "security_url": "https://github.com/aave/aave-v3-public/tree/main/audits",
        "name": "Aave",
    },
    "Sky": {
        "url": "https://twitter.com/Sky_Mechanism",
        "security_url": "https://github.com/SkyProtocol",
        "name": "Sky (formerly MakerDAO)",
    },
    "Morpho": {
        "url": "https://twitter.com/morpho_labs",
        "security_url": "https://github.com/morpho-org",
        "name": "Morpho",
    },
    "Pendle": {
        "url": "https://twitter.com/Pendle_fi",
        "security_url": "https://github.com/pendle-io",
        "name": "Pendle",
    },
}

# Critical Slither detector patterns — these indicate real risk.
# Entries are matched against the FULL Slither check name; an entry also matches
# its family, so `reentrancy` covers reentrancy-eth / -no-eth / -benign / -events.
# (Matching used to run `check.split("-")[0]`, which turned `incorrect-equality`
# into `incorrect` and made every hyphenated entry below dead code.)
CRITICAL_DETECTORS = {
    "reentrancy",
    "tx-origin",
    "suicidal",
    "controlled-delegatecall",
    "protected-contract",
    "incorrect-equality",
    "prohibited-admin-actions",
    "uninitialized-factory",
    "dropped-money",
    "incorrect-assert",
    "external-function-argument",
    "public-mappings-nested",
    "array-by-reference",
    "reentrancy-eth",
    "reentrancy-unprotected",
}

WARNING_DETECTORS = {
    "naming-convention",
    "shadowing-local",
    "dead-code",
    "timestamp",
    "calls-loop",
    "too-many-digits",
    "divide-before-multiply",
    "events-access",
    "missing-zero-check",
    "low-level-calls",
    "unprotected-upgradeable",
}


def classify_detector(check: str, confidence: str = "Medium") -> str:
    """Bucketed severity for a Slither check name: CRITICAL > WARNING > INFO.

    Matches the FULL check name (plus family prefix), so every entry in the two
    sets above is live. A Slither `Low` confidence finding is a WARNING as before.
    """
    name = (check or "").lower()
    if name in CRITICAL_DETECTORS or any(
        name.startswith(f"{fam}-") for fam in CRITICAL_DETECTORS
    ) or "reentrancy" in name:
        return "CRITICAL"
    if name in WARNING_DETECTORS or any(
        name.startswith(f"{fam}-") for fam in WARNING_DETECTORS
    ) or confidence in ("Low",):
        return "WARNING"
    return "INFO"


# ── Slither Analysis ───────────────────────────────────────────────────────

def run_hardhat_compile() -> str:
    """Force a fresh Hardhat build; return an error string, or "" on success.

    Slither's Hardhat platform does NOT abort when `npx hardhat compile` fails —
    it then parses whatever `artifacts/build-info` still holds, i.e. it would
    analyse the LAST GOOD build while contracts/ no longer compile. That is the
    'stale artifacts lie' failure mode (F1 / t_dd131407), so compile here first
    and treat any failure as a scan failure — never as a pass.
    """
    try:
        proc = subprocess.run(
            "npx hardhat compile --force",
            shell=True,
            capture_output=True,
            text=True,
            timeout=SLITHER_TIMEOUT,
            cwd=str(PROJECT_ROOT),
        )
    except FileNotFoundError:
        return "npx/hardhat not found — cannot compile the contracts for analysis"
    except subprocess.TimeoutExpired:
        return f"hardhat compile timed out after {SLITHER_TIMEOUT}s"
    if proc.returncode != 0:
        tail = ((proc.stderr or "") + (proc.stdout or "")).strip()[-800:]
        return f"hardhat compile failed (exit {proc.returncode}) — refusing to scan a stale build: {tail}"
    if not (PROJECT_ROOT / "artifacts" / "build-info").is_dir():
        return "hardhat compile produced no artifacts/build-info — nothing to analyse"
    return ""


def run_slither() -> dict[str, Any]:
    """Execute Slither on the contracts directory and return parsed results."""
    if not CONTRACTS_DIR.exists():
        return {"error": f"Contracts directory not found: {CONTRACTS_DIR}"}

    print(f"[*] Running Slither on {CONTRACTS_DIR} ...")

    compile_error = run_hardhat_compile()
    if compile_error:
        return {"error": compile_error}

    tmpfile = str(REPORTS_DIR / "_slither_tmp.json")
    contracts_abs = str(CONTRACTS_DIR.resolve())
    os.makedirs(str(REPORTS_DIR), exist_ok=True)
    if os.path.exists(tmpfile):
        os.unlink(tmpfile)

    # The compile framework is pinned to Hardhat and Slither is told to reuse the
    # build-info we just produced (`--hardhat-ignore-compile` implies no clean):
    # this repo also carries a foundry.toml, and framework auto-detection picks
    # Foundry whenever it exists — which made the CI scan (no `forge` on PATH)
    # die with FileNotFoundError. It also keeps `npx hardhat clean` from deleting
    # the committed artifacts/ tree, so a failed compile cannot damage the repo.
    cmd = (
        f'slither {contracts_abs} '
        f'--solc-remaps "@openzeppelin/contracts=node_modules/@openzeppelin/contracts" '
        f'--compile-force-framework hardhat --hardhat-ignore-compile --skip-clean '
        f'--json {tmpfile}'
    )

    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=SLITHER_TIMEOUT,
            cwd=str(PROJECT_ROOT),
        )
    except FileNotFoundError:
        return {"error": "Slither not found. Install with: pip install slither-analyzer"}
    except subprocess.TimeoutExpired:
        return {"error": f"Slither timed out after {SLITHER_TIMEOUT}s"}

    # NOTE: Slither itself exits non-zero whenever it reports findings, so the
    # exit code is not a success signal here — the JSON artifact is. A missing or
    # unparseable artifact IS a failure and must never be reported as "passed".
    try:
        with open(tmpfile) as f:
            data = json.load(f)
        os.unlink(tmpfile)
    except FileNotFoundError:
        if result.stderr and ("Error" in result.stderr or "Invalid" in result.stderr):
            return {"error": f"Solc compilation error (check imports): {result.stderr[:400]}"}
        return {"error": f"Slither produced no output. stderr: {result.stderr[:300]}"}
    except json.JSONDecodeError as e:
        if os.path.exists(tmpfile):
            os.unlink(tmpfile)
        return {"error": f"Failed to parse Slither JSON: {e}\nstderr: {result.stderr[:300]}"}

    return parse_slither_results(data)


BASELINE_PATH = PROJECT_ROOT / "security_baseline.json"


def load_baseline() -> dict:
    """Accepted-findings baseline. The monitor alerts ONLY on findings not
    accepted here, so a clean scan means 'nothing new', not 'nothing found'.

    Entry forms (see POLICY in the module docstring):
        "check:Contract": "why this is accepted"            → at most 1 instance
        "check:Contract": {"count": N, "reason": "..."}     → at most N instances
    """
    if BASELINE_PATH.exists():
        try:
            return json.loads(BASELINE_PATH.read_text())
        except Exception:
            return {}
    return {}


def baseline_entry(value: Any) -> tuple:
    """Normalise a baseline value to (accepted_instance_count, reason)."""
    if isinstance(value, dict):
        try:
            count = int(value.get("count", 1))
        except (TypeError, ValueError):
            count = 1
        return max(count, 0), str(value.get("reason", ""))
    return 1, str(value)


def finding_signature(f: dict) -> str:
    """Stable key `check:Contract` — survives line-number shifts."""
    desc = f.get("description", "") or ""
    m = re.search(r"in ([A-Za-z0-9_]+)[.(]", desc)
    contract = m.group(1) if m else None
    if not contract:
        m2 = re.match(r"([A-Za-z0-9_]+)[.(]", desc)
        contract = m2.group(1) if m2 else None
    if not contract:
        for e in (f.get("elements") or []):
            fname = e.get("file") or ""
            if fname.endswith(".sol"):
                contract = fname.split("/")[-1][:-4]
                break
    return f"{f.get('check')}:{contract or 'unknown'}"


def apply_baseline(summary: dict, baseline: dict) -> dict:
    """Move baselined findings out of the alert buckets; recompute counts.

    A signature is accepted for at most its baselined instance count: the extra
    instances of an already-accepted `check:Contract` are UNBASELINED and alert
    (they are the "new incorrect-equality in an already-baselined contract" case
    the old blanket `check:Contract` key silently swallowed).
    """
    accepted = baseline.get("accepted", {}) or {}
    kept = {"critical": [], "warning": [], "informational": [], "accepted": []}
    seen = collections.Counter()
    for bucket in ("critical", "warning", "informational"):
        for f in summary.get(bucket, []):
            sig = f.get("sig") or finding_signature(f)
            seen[sig] += 1
            if sig in accepted:
                limit, reason = baseline_entry(accepted[sig])
                if seen[sig] <= limit:
                    f["accepted_reason"] = reason
                    f["accepted_limit"] = limit
                    kept["accepted"].append(f)
                    continue
                f["new_instance_of"] = (
                    f"{sig} — {seen[sig]}# instance, baseline accepts {limit}"
                )
            kept[bucket].append(f)
    summary.update(kept)
    summary["critical_count"] = len(kept["critical"])
    summary["warning_count"] = len(kept["warning"])
    summary["info_count"] = len(kept["informational"])
    summary["accepted_count"] = len(kept["accepted"])
    summary["baseline_size"] = len(accepted)
    summary["unbaselined_count"] = (
        summary["critical_count"] + summary["warning_count"] + summary["info_count"]
    )
    # Baseline hygiene: signatures that no longer match anything still found.
    summary["stale_baseline"] = sorted(sig for sig in accepted if sig not in seen)
    return summary


def parse_slither_results(data: dict) -> dict[str, Any]:
    """Parse raw Slither JSON into a structured security report."""
    findings = data.get("results", {}).get("detectors", [])
    if not isinstance(findings, list):
        findings = []

    summary = {
        "total_findings": len(findings),
        "critical": [],
        "warning": [],
        "informational": [],
        "detector_counts": {},
        "files_analyzed": set(),
    }

    for finding in findings:
        check = finding.get("check", "unknown")
        desc = finding.get("description", "")[:200]
        impact = finding.get("impact", "")[:200]
        confidence = finding.get("confidence", "Medium")
        markdown = finding.get("markdown", "")[:500]
        elements = finding.get("elements", [])

        # Collect affected files
        for elem in elements:
            src = elem.get("source_mapping", {})
            if src.get("filename_short"):
                summary["files_analyzed"].add(src["filename_short"])

        # Classify by the FULL check name (family-prefix aware) — see POLICY.
        severity = classify_detector(check, confidence)

        finding_entry = {
            "check": check,
            "detector": check,
            "description": desc,
            "impact": impact,
            "confidence": confidence,
            "markdown": markdown,
            "elements": [
                {
                    "type": e.get("type"),
                    "name": e.get("name"),
                    "file": e.get("source_mapping", {}).get("filename_short"),
                    "lines": e.get("source_mapping", {}).get("lines", []),
                }
                for e in elements
            ],
        }

        finding_entry["sig"] = finding_signature(finding_entry)
        finding_entry["severity"] = severity
        summary[{"CRITICAL": "critical", "WARNING": "warning", "INFO": "informational"}[
            severity
        ]].append(finding_entry)

        summary["detector_counts"][check] = summary["detector_counts"].get(check, 0) + 1

    summary["files_analyzed"] = sorted(summary["files_analyzed"])
    summary["critical_count"] = len(summary["critical"])
    summary["warning_count"] = len(summary["warning"])
    summary["info_count"] = len(summary["informational"])

    return summary


# ── Protocol Advisory Monitoring ───────────────────────────────────────────

def fetch_protocol_advisories() -> dict[str, Any]:
    """Check protocol security channels for recent advisories."""
    print("[*] Checking protocol security advisories ...")
    advisories = {}

    for protocol_name, config in PROTOCOLS.items():
        protocol_advisories = {"name": config["name"], "url": config["url"], "findings": []}

        # Try web search for recent security advisories
        try:
            search_results = web_search_advisories(config["name"])
            protocol_advisories["findings"] = search_results
        except Exception as e:
            protocol_advisories["error"] = str(e)

        advisories[protocol_name] = protocol_advisories
        time.sleep(0.5)  # Be polite to APIs

    return advisories


def web_search_advisories(protocol_name: str) -> list[dict]:
    """Search for security advisories related to a protocol."""
    findings = []
    search_queries = [
        f'{protocol_name} security audit 2026',
        f'{protocol_name} smart contract vulnerability exploit',
        f'{protocol_name} security advisory github',
    ]

    for query in search_queries:
        try:
            # Try hermes_tools web_search first, fall back to HTTP
            try:
                from hermes_tools import web_search
                results = web_search(query, limit=5)
                for r in results.get("data", {}).get("web", []):
                    title = r.get("title", "")
                    desc = r.get("description", "")
                    combined = f"{title} {desc}"
                    security_keywords = ["vulnerability", "exploit", "audit", "caution", "alert", "bug", "compromised", "security"]
                    if any(kw in combined.lower() for kw in security_keywords):
                        findings.append({"title": title, "description": desc[:200], "url": r.get("url", ""), "query": query, "date": datetime.now().isoformat()})
                continue
            except (ImportError, Exception):
                pass

            # Fallback: direct HTTP search
            import urllib.request
            import urllib.parse
            import re
            url = f"https://www.google.com/search?q={urllib.parse.quote(query)}"
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "Mozilla/5.0 (compatible; ProYield-SecMonitor/1.0)"},
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                html = response.read().decode("utf-8", errors="ignore")
            security_keywords = ["vulnerability", "exploit", "audit", "caution", "alert", "bug", "compromised"]
            snippets = re.findall(r'<h3[^>]*>(.*?)</h3>', html)
            for snippet in snippets[:5]:
                clean = re.sub(r'<[^>]+>', "", snippet).strip()
                if any(kw in clean.lower() for kw in security_keywords):
                    findings.append({"title": clean, "query": query, "date": datetime.now().isoformat()})

        except Exception:
            pass  # Silently continue if web search fails

    return findings


# ── Report Generation ──────────────────────────────────────────────────────

def finding_location(f: dict) -> str:
    """Best-effort `file:line` for a finding, for alert lines."""
    for elem in f.get("elements", []):
        if elem.get("file"):
            line = elem["lines"][0] if elem.get("lines") else "?"
            return f"{elem['file']}:{line}"
    return "?"


def generate_report(slither_results: dict, advisories: dict, output_format: str = "text") -> str:
    """Generate a formatted security report."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    if output_format == "json":
        return json.dumps(
            {"timestamp": timestamp, "slither": slither_results, "advisories": advisories},
            indent=2,
            default=str,
        )

    # Text report
    lines = []
    lines.append("=" * 70)
    lines.append("  PROYIELD SECURITY MONITORING REPORT")
    lines.append("=" * 70)
    lines.append(f"  Generated: {timestamp}")
    lines.append("")

    # ── Slither Results ──
    lines.append("─" * 70)
    lines.append("  SLITHER STATIC ANALYSIS")
    lines.append("─" * 70)

    if "error" in slither_results:
        lines.append(f"  ERROR: {slither_results['error']}")
        lines.append("  ⛔ SCAN DID NOT RUN — this is NOT a pass (fail-closed).")
    else:
        unbaselined = slither_results.get("unbaselined_count", 0)
        lines.append(f"  Files analyzed: {len(slither_results['files_analyzed'])}")
        lines.append(f"  Total findings: {slither_results['total_findings']}")
        if "accepted_count" in slither_results:
            lines.append(f"  ✅ Accepted (baselined, justified): {slither_results['accepted_count']} of {slither_results['baseline_size']} signatures")
            lines.append(f"  → Alerting only on NEW findings (see security_baseline.json)")
        if unbaselined == 0:
            lines.append("  ✅ Security scan passed — 0 unbaselined findings")
        else:
            lines.append(f"  ⛔ NOT passed — {unbaselined} unbaselined finding(s) "
                         f"({slither_results['critical_count']} critical, "
                         f"{slither_results['warning_count']} warning, "
                         f"{slither_results['info_count']} info)")
        lines.append("")

        if slither_results["critical_count"] > 0:
            lines.append(f"  🔴 CRITICAL (unbaselined): {slither_results['critical_count']}")
            for f in slither_results["critical"][:10]:
                lines.append(f"     [{f['check']}] {f['description']}")
                if f.get("new_instance_of"):
                    lines.append(f"       ⚠ NEW INSTANCE OF {f['new_instance_of']}")
                lines.append(f"       → {finding_location(f)}")
            lines.append("")

        if slither_results["warning_count"] > 0:
            lines.append(f"  🟡 WARNING (unbaselined): {slither_results['warning_count']}")
            for f in slither_results["warning"][:10]:
                lines.append(f"     [{f['check']}] {f['description']}")
                if f.get("new_instance_of"):
                    lines.append(f"       ⚠ NEW INSTANCE OF {f['new_instance_of']}")
            lines.append("")

        if slither_results["info_count"] > 0:
            lines.append(f"  ℹ️  INFO (unbaselined): {slither_results['info_count']}")
            for f in slither_results["informational"][:10]:
                lines.append(f"     [{f['check']}] {f['description']}")
                if f.get("new_instance_of"):
                    lines.append(f"       ⚠ NEW INSTANCE OF {f['new_instance_of']}")
            lines.append("")

        stale = slither_results.get("stale_baseline") or []
        if stale:
            lines.append(f"  🧹 Stale baseline signatures (no longer found): {len(stale)}")
            for sig in stale[:10]:
                lines.append(f"     - {sig}")
            lines.append("     (harmless, but prune or re-justify so the baseline stays honest)")
            lines.append("")

        lines.append("  Top detector categories:")
        for detector, count in sorted(
            slither_results["detector_counts"].items(), key=lambda x: -x[1]
        )[:8]:
            lines.append(f"    {detector}: {count}")

    lines.append("")

    # ── Protocol Advisories ──
    lines.append("─" * 70)
    lines.append("  PROTOCOL SECURITY ADVISORIES")
    lines.append("─" * 70)

    for proto_name, data in advisories.items():
        lines.append(f"\n  {data['name']}:")
        if "error" in data:
            lines.append(f"    ⚠️  Could not fetch advisories: {data['error']}")
        elif data["findings"]:
            lines.append(f"    📢 {len(data['findings'])} relevant findings")
            for finding in data["findings"][:5]:
                lines.append(f"    - {finding.get('title', finding)}")
        else:
            lines.append(f"    ✅ No recent advisories found")

    lines.append("")
    lines.append("─" * 70)

    # ── Overall Assessment ──
    lines.append("  ASSESSMENT")
    lines.append("─" * 70)

    if "error" in slither_results:
        lines.append("  ⛔ SCAN DID NOT RUN — treat as a hard failure (exit 2), never as clean")
    elif slither_results.get("unbaselined_count", 0) > 0:
        lines.append("  ⛔ UNBASELINED FINDINGS — triage before shipping; fix, or add to")
        lines.append("     security_baseline.json with a justification (count included)")
    else:
        lines.append("  ✅ No unbaselined findings — nothing NEW vs the justified baseline")

    lines.append("")
    lines.append("=" * 70)
    lines.append("  End of Report")
    lines.append("=" * 70)

    return "\n".join(lines)


# ── Main Entry Point ───────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="ProYield Security Monitor — automated smart contract security scanning"
    )
    parser.add_argument("--slither-only", action="store_true", help="Run only Slither analysis")
    parser.add_argument("--advisories-only", action="store_true", help="Run only advisory checks")
    parser.add_argument("--json", action="store_true", help="Output JSON instead of text")
    parser.add_argument("--output", "-o", type=str, help="Save report to file")
    parser.add_argument("--quiet", action="store_true", help="Minimal output")
    parser.add_argument("--no-save", action="store_true", help="Don't save report to disk")
    parser.add_argument("--update-baseline", action="store_true",
                        help="Rewrite security_baseline.json from the CURRENT findings "
                             "(review first! writes per-signature instance counts)")
    args = parser.parse_args()

    start_time = time.time()
    os.makedirs(str(REPORTS_DIR), exist_ok=True)

    # ── Run Slither ──
    slither_results = {}
    if not args.advisories_only:
        slither_results = run_slither()
        if not args.quiet and "error" not in slither_results:
            print(f"    Found {slither_results['total_findings']} findings "
                  f"({slither_results['critical_count']} critical, "
                  f"{slither_results['warning_count']} warnings)")
        # --update-baseline: bless current findings after review. Signatures with
        # more than one instance are written as {"count": N, "reason": ...} so the
        # next scan still catches an ADDITIONAL instance of the same signature.
        if args.update_baseline and "error" not in slither_results:
            allf = (slither_results.get("critical", []) + slither_results.get("warning", [])
                    + slither_results.get("informational", []))
            previous = (load_baseline().get("accepted", {}) or {})
            counts = collections.Counter(finding_signature(f) for f in allf)
            accepted = {}
            for sig, n in sorted(counts.items()):
                _, old_reason = baseline_entry(previous.get(sig, ""))
                reason = old_reason or "REVIEW REQUIRED — add the justification for this finding"
                accepted[sig] = reason if n == 1 else {"count": n, "reason": reason}
            BASELINE_PATH.write_text(json.dumps({
                "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                "note": ("Accepted findings — the monitor alerts on anything NOT listed here, "
                         "and on any instance beyond the per-signature accepted count."),
                "accepted": dict(sorted(accepted.items())),
            }, indent=2) + "\n")
            print(f"    Baseline updated: {len(allf)} findings over {len(accepted)} signatures "
                  f"-> {BASELINE_PATH.name} (review reasons!)")
        # filter against baseline so alerts mean "something NEW"
        if "error" not in slither_results:
            slither_results = apply_baseline(slither_results, load_baseline())
            if not args.quiet:
                print(f"    vs baseline: {slither_results['critical_count']} new critical, "
                      f"{slither_results['warning_count']} new warnings, "
                      f"{slither_results['info_count']} new info; "
                      f"{slither_results['accepted_count']} accepted across "
                      f"{slither_results['baseline_size']} signatures")

    # ── Run Advisory Checks ──
    advisories = {}
    if not args.slither_only:
        advisories = fetch_protocol_advisories()
        if not args.quiet:
            for name, data in advisories.items():
                count = len(data.get("findings", []))
                print(f"    {data['name']}: {count} advisory hits")

    # ── Generate Report ──
    report = generate_report(slither_results, advisories, output_format="json" if args.json else "text")

    if args.output:
        output_path = Path(args.output)
        output_path.write_text(report)
        print(f"[+] Report saved to {output_path}")
    elif not args.no_save:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        report_path = REPORTS_DIR / f"report_{timestamp}.md"
        report_path.write_text(report)
        if not args.quiet:
            print(f"[+] Report saved to {report_path}")

    # ── Print Report ──
    if not args.quiet:
        print(report)
    else:
        # Quiet mode: one line, and the EXIT CODE carries the verdict.
        if "error" in slither_results:
            print(f"ERROR: {slither_results['error']}")
        elif slither_results.get("unbaselined_count", 0) > 0:
            print(f"⛔ {slither_results['unbaselined_count']} unbaselined finding(s): "
                  f"{slither_results['critical_count']} critical, "
                  f"{slither_results['warning_count']} warning, "
                  f"{slither_results['info_count']} info")
        else:
            print("✅ Security scan passed")

    elapsed = time.time() - start_time
    if not args.quiet:
        print(f"\nScan completed in {elapsed:.1f}s")

    # ── Exit code (fail-closed) ────────────────────────────────────────────
    # 2 = the scan did not run (compile failure, Slither missing, no JSON);
    # 1 = the scan ran and found something unbaselined; 0 = clean.
    # Silence is never a pass: a broken scanner must fail the gate, not skip it.
    if "error" in slither_results:
        sys.exit(2)
    if slither_results.get("unbaselined_count", 0) > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
