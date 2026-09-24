#!/usr/bin/env bash
# run_battery.sh — ISOLATED full-battery runner.
#
# Runs the complete contract test battery against a FRESH, disposable anvil
# chain — never touches the live persistent chain on 8545, never writes the
# live deployed_addresses.json.
#
# Designed for three consumers:
#   1. Humans / CI:  scripts/run_battery.sh            (exit 0 = all green)
#   2. Mutation testing: slither-mutate --test-cmd <this script>
#   3. Cold-start regression: proves the full stack deploys & passes from zero.
#
# Usage:
#   scripts/run_battery.sh [--keep] [--with-deploy] [--suites "a.js b.js"]
#
# Env:
#   BATTERY_PORT    port for the disposable anvil        (default 8547)
#   BATTERY_SUITES  override suite list (space-separated file names in scripts/)
#   BATTERY_WITH_DEPLOY  1 = also exercise deploy_v2.js cold-start (isolated manifest)
#   BATTERY_KEEP   1 = leave anvil running after the run (debugging)
#   SUITE_TIMEOUT  per-suite timeout in seconds          (default 900)
#
# Exit: 0 iff every suite passed; 1 otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${BATTERY_PORT:-8547}"
RPC="http://localhost:$PORT"
export HYPEREVM_RPC_URL="$RPC"
# Isolate any manifest-writing consumer (deploy_v2) from the live manifest.
export DEPLOY_MANIFEST="${DEPLOY_MANIFEST:-$ROOT/.battery_manifest.json}"

ANVIL_BIN="${ANVIL_BIN:-$(command -v anvil || echo /home/user/.config/.foundry/bin/anvil)}"
CAST_BIN="${CAST_BIN:-$(command -v cast || echo /home/user/.config/.foundry/bin/cast)}"
LOG_DIR="${BATTERY_LOGS:-$ROOT/.battery_logs}"
mkdir -p "$LOG_DIR"

KEEP=0; WITH_DEPLOY="${BATTERY_WITH_DEPLOY:-0}"
SUITES="${BATTERY_SUITES:-integration_tests.js dn_strategy_tests.js dn_adapter_tests.js pyd_demand_tests.js dn_keeper_dryrun_test.js dn_keeper_unwind_test.js vault_caps_test.js test_all.js dn_realread_replay.js ecosystem_journey_test.js ecosystem_audit.js chainid_guard_test.js}"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --with-deploy) WITH_DEPLOY=1 ;;
    --suites) shift; SUITES="$1" ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
  shift
done
SUITE_TIMEOUT="${SUITE_TIMEOUT:-900}"

rpc() { # rpc <method> [params...]
  local m="$1"; shift
  local args=""
  for p in "$@"; do args="$args,\"$p\""; done
  curl -s -m 5 -X POST "$RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$m\",\"params\":[${args#,}],\"id\":1}"
}

echo "═══ ProYield battery — isolated run ═══"
echo "chain: $RPC (fresh) · logs: $LOG_DIR"

# ── 1. Stop any leftover anvil squatting on our port ─────────────────────
if rpc web3_clientVersion | grep -q -i anvil; then
  echo "· anvil already on $PORT — stopping it (disposable port)"
  pkill -f "anvil --port $PORT" 2>/dev/null || true
  sleep 1
fi

# ── 2. Fresh anvil (no state load — cold start every time) ───────────────
"$ANVIL_BIN" --port "$PORT" --chain-id 998 --silent > "$LOG_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "· BATTERY_KEEP=1 — leaving anvil (pid $ANVIL_PID) on $PORT"
  else
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── 3. Wait for readiness (chainId 0x3e6 = 998) ──────────────────────────
ready=0
for _ in $(seq 1 100); do
  if rpc eth_chainId | grep -q '0x3e6'; then ready=1; break; fi
  sleep 0.2
done
if [ "$ready" != "1" ]; then
  echo "✗ anvil failed to start on $PORT — see $LOG_DIR/anvil.log"
  exit 1
fi

# ── 4. Fund the deployer (signer[0]) — fresh anvil only funds its dev set ─
# Key from env (CI) or the local key file (this box).
DEPLOYER_KEY="${DEPLOYER_PRIVATE_KEY:-}"
DEPLOYER_KEY_FILE="/home/user/.hermes/vault_keys/hyperevm_testnet.deployer"
if [ -z "$DEPLOYER_KEY" ] && [ -f "$DEPLOYER_KEY_FILE" ]; then
  DEPLOYER_KEY="$(tr -d '\n' < "$DEPLOYER_KEY_FILE")"
fi
if [ -n "$DEPLOYER_KEY" ]; then
  DEPLOYER="$("$CAST_BIN" wallet address --private-key "$DEPLOYER_KEY" 2>/dev/null)"
  if [ -n "$DEPLOYER" ]; then
    rpc anvil_setBalance "$DEPLOYER" "0x3635C9ADC5DEA00000" > /dev/null   # 1000 ETH
    echo "· deployer funded: $DEPLOYER"
  fi
fi

# ── 5. Compile (recompiles only changed sources) ─────────────────────────
if ! npx hardhat compile > "$LOG_DIR/compile.log" 2>&1; then
  echo "✗ compile FAILED — see $LOG_DIR/compile.log"
  tail -20 "$LOG_DIR/compile.log"
  exit 1
fi
echo "· compile ok"

# ── 6. Optional: cold-start deploy via the real deploy script ────────────
if [ "$WITH_DEPLOY" = "1" ]; then
  echo "· deploy_v2 (cold start, manifest → $DEPLOY_MANIFEST)"
  if ! timeout "$SUITE_TIMEOUT" npx hardhat run scripts/deploy_v2.js --network hyperTestnet > "$LOG_DIR/deploy_v2.log" 2>&1; then
    echo "✗ deploy_v2 FAILED — see $LOG_DIR/deploy_v2.log"; tail -15 "$LOG_DIR/deploy_v2.log"; exit 1
  fi
fi

# ── 7. Run the suites ─────────────────────────────────────────────────────
FAILED=0; TOTAL=0; T_SUM=0
declare -a ROWS
for s in $SUITES; do
  TOTAL=$((TOTAL+1))
  t0=$(date +%s)
  timeout "$SUITE_TIMEOUT" npx hardhat run "scripts/$s" --network hyperTestnet > "$LOG_DIR/$s.log" 2>&1
  rc=$?
  t1=$(date +%s); dt=$((t1-t0)); T_SUM=$((T_SUM+dt))
  tail_line=$(grep -E 'passed.*failed|passed, ' "$LOG_DIR/$s.log" | tail -1)
  [ -z "$tail_line" ] && tail_line="(no summary line)"
  if [ $rc -eq 0 ]; then
    echo "  ✓ $s  [${dt}s]  $tail_line"
  else
    echo "  ✗ $s  [${dt}s, exit $rc]  $tail_line"
    echo "    last output:"
    tail -6 "$LOG_DIR/$s.log" | sed 's/^/    | /'
    FAILED=$((FAILED+1))
  fi
  ROWS+=("$s|$rc|${dt}s|$tail_line")
done

echo "──────────────────────────────────────────"
echo "battery: $((TOTAL-FAILED))/$TOTAL suites passed · total ${T_SUM}s · chain $RPC"
if [ "$FAILED" -gt 0 ]; then
  echo "RESULT: FAIL ($FAILED suite(s))"
  exit 1
fi
echo "RESULT: PASS"
exit 0
