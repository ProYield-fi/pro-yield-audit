#!/bin/bash
# Auto-regenerate dashboard only when rates change
# Called by cron. Reads/writes state in yield_scout/data/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
STATE_FILE="$DATA_DIR/last_rates_state.json"
DASHBOARD="$SCRIPT_DIR/dashboard.html"
DASH_BACKUP="$DATA_DIR/dashboard_backup.html"
HIST="$DATA_DIR/history.jsonl"

cd "$SCRIPT_DIR"

# Snapshot current state before running
HIST_LINES_BEFORE=$(wc -l < "$HIST" 2>/dev/null || echo 0)
if [ -f "$DASHBOARD" ]; then
    cp "$DASHBOARD" "$DASH_BACKUP"
fi

# Run renderer and capture blend from stdout
OUTPUT=$(python3 render_dashboard.py 2>&1)
BLEND=$(echo "$OUTPUT" | grep -oP 'blend=\K[0-9.]+(?=%)' | head -1)

if [ -z "$BLEND" ]; then
    echo "ERROR: Could not extract blend from render_dashboard.py output"
    echo "$OUTPUT" >&2
    # Restore on failure
    cp "$DASH_BACKUP" "$DASHBOARD" 2>/dev/null || true
    exit 1
fi

# Read last known blend
LAST_BLEND=""
if [ -f "$STATE_FILE" ]; then
    LAST_BLEND=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['blend'])" 2>/dev/null || echo "")
fi

if [ "$BLEND" = "$LAST_BLEND" ]; then
    # Rates unchanged — restore previous dashboard and undo history.jsonl append
    cp "$DASH_BACKUP" "$DASHBOARD"
    HIST_LINES_AFTER=$(wc -l < "$HIST" 2>/dev/null || echo 0)
    if [ "$HIST_LINES_AFTER" -gt "$HIST_LINES_BEFORE" ]; then
        head -n "$HIST_LINES_BEFORE" "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
    fi
    echo "[$(date -Iseconds)] Rates unchanged (blend=${BLEND}%). Skipped regeneration."
else
    # Rates changed — keep the new dashboard, save state, update backup
    echo "$OUTPUT" | head -1
    python3 -c "import json; json.dump({'blend': $BLEND, 'ts': '$(date -Iseconds)'}, open('$STATE_FILE', 'w'))"
    cp "$DASHBOARD" "$DASH_BACKUP"
    echo "[$(date -Iseconds)] Regenerated: blend=${BLEND}% (was ${LAST_BLEND:-none})"
fi
