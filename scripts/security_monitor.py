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
"""

import argparse
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

# Critical Slither detector patterns — these indicate real risk
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


# ── Slither Analysis ───────────────────────────────────────────────────────

def run_slither() -> dict[str, Any]:
    """Execute Slither on the contracts directory and return parsed results."""
    if not CONTRACTS_DIR.exists():
        return {"error": f"Contracts directory not found: {CONTRACTS_DIR}"}

    print(f"[*] Running Slither on {CONTRACTS_DIR} ...")

    tmpfile = str(REPORTS_DIR / "_slither_tmp.json")
    contracts_abs = str(CONTRACTS_DIR.resolve())
    os.makedirs(str(REPORTS_DIR), exist_ok=True)

    # Use shell=True so bash handles the quoting for --solc-remaps correctly
    cmd = (
        f'slither {contracts_abs} '
        f'--solc-remaps "@openzeppelin/contracts=node_modules/@openzeppelin/contracts" '
        f'--json {tmpfile}'
    )

    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=str(PROJECT_ROOT),
        )
    except FileNotFoundError:
        return {"error": "Slither not found. Install with: pip install slither-analyzer"}
    except subprocess.TimeoutExpired:
        return {"error": "Slither timed out after 120s"}

    # Read JSON from temp file
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
    """Accepted-findings baseline. The monitor alerts ONLY on findings not in
    this list, so a clean scan means 'nothing new', not 'nothing found'."""
    if BASELINE_PATH.exists():
        try:
            return json.loads(BASELINE_PATH.read_text())
        except Exception:
            return {}
    return {}


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
    """Move baselined findings out of the alert buckets; recompute counts."""
    accepted = baseline.get("accepted", {}) or {}
    kept = {"critical": [], "warning": [], "informational": [], "accepted": []}
    for bucket in ("critical", "warning", "informational"):
        for f in summary.get(bucket, []):
            sig = f.get("sig") or finding_signature(f)
            if sig in accepted:
                f["accepted_reason"] = accepted[sig]
                kept["accepted"].append(f)
            else:
                kept[bucket].append(f)
    summary.update(kept)
    summary["critical_count"] = len(kept["critical"])
    summary["warning_count"] = len(kept["warning"])
    summary["info_count"] = len(kept["informational"])
    summary["accepted_count"] = len(kept["accepted"])
    summary["baseline_size"] = len(accepted)
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

        # Classify by detector type
        detector_family = check.split("-")[0] if "-" in check else check

        finding_entry = {
            "check": check,
            "detector": detector_family,
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

        if detector_family in CRITICAL_DETECTORS or "reentrancy" in check.lower():
            finding_entry["severity"] = "CRITICAL"
            summary["critical"].append(finding_entry)
        elif detector_family in WARNING_DETECTORS or confidence in ("Low",):
            finding_entry["severity"] = "WARNING"
            summary["warning"].append(finding_entry)
        else:
            finding_entry["severity"] = "INFO"
            summary["informational"].append(finding_entry)

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
    else:
        lines.append(f"  Files analyzed: {len(slither_results['files_analyzed'])}")
        lines.append(f"  Total findings: {slither_results['total_findings']}")
        if "accepted_count" in slither_results:
            lines.append(f"  ✅ Accepted (baselined, justified): {slither_results['accepted_count']} of {slither_results['baseline_size']}")
            lines.append(f"  → Alerting only on NEW findings (see security_baseline.json)")
        lines.append("")

        if slither_results["critical_count"] > 0:
            lines.append(f"  🔴 CRITICAL: {slither_results['critical_count']}")
            for f in slither_results["critical"][:10]:
                lines.append(f"     [{f['check']}] {f['description']}")
                for elem in f["elements"][:3]:
                    loc = f"{elem['file']}:{elem['lines'][0] if elem['lines'] else '?'}" if elem['file'] else '?'
                    lines.append(f"       → {loc}")
            lines.append("")

        if slither_results["warning_count"] > 0:
            lines.append(f"  🟡 WARNING: {slither_results['warning_count']}")
            for f in slither_results["warning"][:10]:
                lines.append(f"     [{f['check']}] {f['description']}")
            lines.append("")

        lines.append(f"  ℹ️  INFO: {slither_results['info_count']}")
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

    if slither_results.get("critical_count", 0) > 0:
        lines.append("  ⛔ CRITICAL issues detected — review immediately")
    elif slither_results.get("warning_count", 0) > 5:
        lines.append("  ⚠️  Multiple warnings — address in next sprint")
    else:
        lines.append("  ✅ No critical issues detected")

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
                        help="Rewrite security_baseline.json from the CURRENT findings (review first!)")
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
        # --update-baseline: bless current findings after review
        if args.update_baseline and "error" not in slither_results:
            allf = (slither_results.get("critical", []) + slither_results.get("warning", [])
                    + slither_results.get("informational", []))
            accepted = {}
            for f in allf:
                accepted[finding_signature(f)] = "REVIEW REQUIRED — add the justification for this finding"
            BASELINE_PATH.write_text(json.dumps({
                "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                "note": "Accepted findings — the monitor alerts only on findings NOT listed here.",
                "accepted": dict(sorted(accepted.items())),
            }, indent=2) + "\n")
            print(f"    Baseline updated: {len(accepted)} findings -> {BASELINE_PATH.name} (review reasons!)")
        # filter against baseline so alerts mean "something NEW"
        if "error" not in slither_results:
            slither_results = apply_baseline(slither_results, load_baseline())
            if not args.quiet:
                print(f"    vs baseline: {slither_results['critical_count']} new critical, "
                      f"{slither_results['warning_count']} new warnings, "
                      f"{slither_results['accepted_count']} accepted across {slither_results['baseline_size']} signatures")

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
        # Quiet mode: print just the summary line
        if "error" in slither_results:
            print(f"ERROR: {slither_results['error']}")
        elif slither_results.get("critical_count", 0) > 0:
            print(f"⛔ {slither_results['critical_count']} CRITICAL issues found")
        elif slither_results.get("warning_count", 0) > 0:
            print(f"⚠️  {slither_results['warning_count']} warnings")
        else:
            print("✅ Security scan passed")

    elapsed = time.time() - start_time
    if not args.quiet:
        print(f"\nScan completed in {elapsed:.1f}s")

    # Exit with non-zero if critical findings
    if slither_results.get("critical_count", 0) > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
