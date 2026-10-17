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
#   BATTERY_LOCK   lock file guarding the port (default /tmp/proyield-battery-<port>.lock)
#   SUITE_TIMEOUT  per-suite timeout in seconds          (default 900)
#
# Retry policy: a suite that dies with the connection-loss signature (HH108
# "Cannot connect to the network" / ECONNREFUSED) — i.e. the disposable chain
# vanished under it — is retried ONCE against a freshly restarted anvil, and the
# retry is printed as `↻` + `[retried-after-rpc-loss]`. Assertion failures are
# never retried. Rationale + evidence: card t_d09a097f, PROYIELD_RUNBOOK.
# The failed attempt's log is preserved as <suite>.log.rpc-loss-attempt1.
#
# Exit: 0 iff every suite passed; 1 = suite failure(s); 2 = bad usage/setup;
#       3 = another battery run holds the port lock (refused to collide).
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
# (public export) book_policy_test.js / vault_status_books_test.js are internal-dep
# suites (the book registry is not published) — they run in the dev battery only.
SUITES="${BATTERY_SUITES:-integration_tests.js dn_strategy_tests.js dn_adapter_tests.js pyd_demand_tests.js dn_keeper_dryrun_test.js dn_keeper_unwind_test.js dn_keeper_hedgedprofit_test.js vault_caps_test.js test_all.js dn_realread_replay.js ecosystem_journey_test.js ecosystem_audit.js chainid_guard_test.js dn_keeper_roster_test.js dn_keeper_hedge_sizing_test.js dn_keeper_rebalance_min_test.js dn_keeper_alert_throttle_test.js dn_keeper_fresh_open_test.js}"
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

# ── 0. Exclusive run lock ─────────────────────────────────────────────────
# The disposable anvil sits on a FIXED port and step 1 below kills whatever is
# listening there. Two battery runs on one box therefore used to yank each
# other's anvil out mid-suite: the victim's suites died with
# "HH108: Cannot connect to the network hyperTestnet" while the other run went
# green (reproduced 2026-10-16, card t_d09a097f). Hold a per-port lock so a
# second run refuses to start instead of colliding. Released on exit (FD close).
LOCK_FILE="${BATTERY_LOCK:-/tmp/proyield-battery-$PORT.lock}"
exec 9>"$LOCK_FILE" || { echo "✗ cannot create lock file $LOCK_FILE"; exit 2; }
if ! flock -n 9; then
  echo "✗ another battery run already owns port $PORT (lock $LOCK_FILE)."
  echo "  Refusing to start — that run's anvil would be killed mid-suite by step 1."
  echo "  Wait for it to finish, or pick another port: BATTERY_PORT=8548 scripts/run_battery.sh"
  exit 3
fi

# ── helpers (shared by the initial start and the mid-battery restart) ────
start_anvil() { # fresh disposable chain on $PORT, no state load — cold start
  "$ANVIL_BIN" --port "$PORT" --chain-id 998 --silent > "$LOG_DIR/anvil.log" 2>&1 &
  ANVIL_PID=$!
}

wait_ready() { # chainId 0x3e6 = 998
  local ready=0
  for _ in $(seq 1 100); do
    if rpc eth_chainId | grep -q '0x3e6'; then ready=1; break; fi
    sleep 0.2
  done
  [ "$ready" = "1" ]
}

# Fund the deployer (signer[0]) — a fresh anvil only funds its dev set.
# Key from env (CI) or the local key file (this box).
DEPLOYER_KEY_FILE="/home/user/.hermes/vault_keys/hyperevm_testnet.deployer"
fund_deployer() {
  local key="${DEPLOYER_PRIVATE_KEY:-}" addr
  if [ -z "$key" ] && [ -f "$DEPLOYER_KEY_FILE" ]; then
    key="$(tr -d '\n' < "$DEPLOYER_KEY_FILE")"
  fi
  [ -z "$key" ] && return 0
  addr="$("$CAST_BIN" wallet address --private-key "$key" 2>/dev/null)"
  [ -z "$addr" ] && return 0
  rpc anvil_setBalance "$addr" "0x3635C9ADC5DEA00000" > /dev/null   # 1000 ETH
  echo "· deployer funded: $addr"
}

# ── 1. Stop any leftover anvil squatting on our port ─────────────────────
# Safe under the lock: anything still listening here belongs to a run that
# already exited (or crashed), never to a live battery run.
# The bracket in the pattern keeps pkill from also matching a wrapper shell
# whose own command line happens to spell the pattern out.
if rpc web3_clientVersion | grep -q -i anvil; then
  echo "· anvil already on $PORT — stopping it (disposable port, no live lock holder)"
  pkill -f "[a]nvil --port $PORT" 2>/dev/null || true
  sleep 1
fi

# ── 2. Fresh anvil (no state load — cold start every time) ───────────────
start_anvil
cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "· BATTERY_KEEP=1 — leaving anvil (pid $ANVIL_PID) on $PORT"
  else
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── 3. Wait for readiness ────────────────────────────────────────────────
if ! wait_ready; then
  echo "✗ anvil failed to start on $PORT — see $LOG_DIR/anvil.log"
  exit 1
fi

# ── 4. Fund the deployer ─────────────────────────────────────────────────
fund_deployer

# ── 5. Compile (FULL — never trust a warm cache) ─────────────────────────
# A source change that updates a committed artifact can be masked: with a warm
# cache/solidity-files-cache.json, hardhat's incremental compile sees the source
# hash already in the cache and skips the file, so the STALE committed artifact
# is used at runtime. Proven (F1 / t_dd131407): the committed MockSpotBalance
# ABI lacked setToken() and 4 dn_* suites died with "setToken is not a function";
# `git checkout -- artifacts/` re-stales the tree while the cache stays warm.
# Dropping the hardhat cache forces a full recompile, so a battery run can never
# exercise an artifact that disagrees with source (~28s, cheap vs a lie).
# Only the hardhat cache is removed — cache/dn_*.json keeper markers are kept.
rm -f "$ROOT/cache/solidity-files-cache.json"
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
# A suite that dies with the connection-loss signature (the disposable chain
# vanished under it — HH108/ECONNREFUSED) is retried ONCE on a freshly restarted
# anvil; assertion failures are never retried. See the header + card t_d09a097f.
# Re-running a *whole* suite against a fresh chain is safe: every suite deploys
# its own mocks and re-writes the fixed precompile addresses, so it is equally
# valid on a cold chain as it was on the first attempt. (A half-run *keeper
# child* cannot be retried inside the suite — by then the parent's venue
# emulation has already advanced the mock state — which is why the retry lives
# at suite granularity, and only after a clean anvil.)
rpc_loss() { grep -qE "Cannot connect to the network|HH108|ECONNREFUSED" "$LOG_DIR/$1.log" 2>/dev/null; }

restart_anvil() {
  kill "$ANVIL_PID" 2>/dev/null || true
  pkill -f "[a]nvil --port $PORT" 2>/dev/null || true
  sleep 1
  start_anvil
  if ! wait_ready; then
    echo "    ! anvil failed to restart on $PORT (see $LOG_DIR/anvil.log)"
    return 1
  fi
  fund_deployer
  echo "    · fresh anvil up (pid $ANVIL_PID) — chain reset to zero"
}

FAILED=0; TOTAL=0; T_SUM=0; RETRIED=0
declare -a ROWS
for s in $SUITES; do
  TOTAL=$((TOTAL+1))
  retried=""
  run_suite() { # $1 = suite file name; sets rc/dt/out
    t0=$(date +%s)
    timeout "$SUITE_TIMEOUT" npx hardhat run "scripts/$1" --network hyperTestnet > "$LOG_DIR/$1.log" 2>&1
    rc=$?
    t1=$(date +%s); dt=$((t1-t0)); T_SUM=$((T_SUM+dt))
  }
  # Liveness: if the anvil is already gone before the suite starts, say so
  # plainly instead of letting the suite report an opaque RPC error.
  if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
    echo "  ! anvil (pid $ANVIL_PID) is NOT running — the shared disposable chain died"
  fi
  run_suite "$s"
  if [ $rc -ne 0 ] && rpc_loss "$s"; then
    RETRIED=$((RETRIED+1))
    retried="retried-after-rpc-loss"
    echo "  ↻ $s  [${dt}s, exit $rc]  RPC loss mid-suite — restarting a fresh anvil and retrying once"
    cp "$LOG_DIR/$s.log" "$LOG_DIR/$s.log.rpc-loss-attempt1" 2>/dev/null || true
    restart_anvil || true
    run_suite "$s"
  fi
  tail_line=$(grep -E 'passed.*failed|passed, ' "$LOG_DIR/$s.log" | tail -1)
  [ -z "$tail_line" ] && tail_line="(no summary line)"
  if [ $rc -eq 0 ]; then
    echo "  ✓ $s  [${dt}s]  $tail_line${retried:+   [$retried]}"
  else
    echo "  ✗ $s  [${dt}s, exit $rc]  $tail_line${retried:+   [$retried]}"
    echo "    last output:"
    tail -6 "$LOG_DIR/$s.log" | sed 's/^/    | /'
    if rpc_loss "$s"; then
      echo "    ! classified: RPC LOSS (endpoint refused / anvil gone) — not a suite-logic failure;"
      echo "      the A1/keeper assertions in this log are NOT evidence of a keeper regression."
    fi
    FAILED=$((FAILED+1))
  fi
  ROWS+=("$s|$rc|${dt}s|$tail_line${retried:+,retried}")
done

echo "──────────────────────────────────────────"
echo "battery: $((TOTAL-FAILED))/$TOTAL suites passed · total ${T_SUM}s · chain $RPC"
[ "$RETRIED" -gt 0 ] && echo "note: $RETRIED suite(s) retried after RPC loss (see ↻ lines) — the chain was not stable under this run"
if [ "$FAILED" -gt 0 ]; then
  echo "RESULT: FAIL ($FAILED suite(s))"
  exit 1
fi
echo "RESULT: PASS"
exit 0
