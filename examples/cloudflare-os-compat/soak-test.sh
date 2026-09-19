#!/usr/bin/env bash
# The long-run half of the fleet gates: sustained load through a fleet while
# nodes are killed, rejoined, and the store injects faults.
#
# The short gates answer "does a failover work". This one answers the questions
# that only time can answer: does an acknowledged write stay durable across
# repeated turnovers, does a transient-capability bridge leak, does the bucket
# or a node's memory grow without bound, and do storage faults become lost
# writes.
#
#   CELLD_SOAK_BUCKET=s3://bucket/prefix \
#   CELLD_SOAK_ENDPOINT=http://127.0.0.1:19100 \
#   CELLD_SOAK_DURATION_S=3600 \
#     bash soak-test.sh /path/to/celld
#
# Bars, all overridable, all reported as one PASS/FAIL line each:
#   - every acknowledged write is readable after every turnover (RPO=0), reads
#     never move backwards, and a read never exceeds what was acknowledged;
#   - calls fail only inside the window that a kill opens;
#   - every node's rpc_bridge_handles returns to 0 after the load stops, and the
#     fleet-wide sum never exceeds CELLD_SOAK_BRIDGE_MAX while it runs;
#   - the bucket holds no more than CELLD_SOAK_BYTES_PER_WRITE_MAX bytes per
#     acknowledged write, and a node's RSS grows by no more than
#     CELLD_SOAK_RSS_GROWTH_MB over the run.
set -euo pipefail

CELLD_BIN="${1:-}"
if [[ -z "$CELLD_BIN" || ! -x "$CELLD_BIN" ]]; then
  echo "usage: CELLD_SOAK_BUCKET=s3://bucket/prefix $0 /path/to/celld" >&2
  exit 2
fi
: "${CELLD_SOAK_BUCKET:?set CELLD_SOAK_BUCKET to a dedicated S3-compatible bucket prefix}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
REGION="${CELLD_SOAK_REGION:-us-east-1}"
TTL_MS="${CELLD_SOAK_TTL_MS:-4000}"
NODES="${CELLD_SOAK_NODES:-2}"
PORT_A="${CELLD_SOAK_PORT_A:-19871}"
PORT_B="${CELLD_SOAK_PORT_B:-19872}"
PEER_A="${CELLD_SOAK_PEER_A:-19881}"
PEER_B="${CELLD_SOAK_PEER_B:-19882}"
PROXY_PORT="${CELLD_SOAK_PROXY_PORT:-19891}"
DURATION_S="${CELLD_SOAK_DURATION_S:-1800}"
KILL_EVERY_S="${CELLD_SOAK_KILL_EVERY_S:-90}"
RESTART_AFTER_S="${CELLD_SOAK_RESTART_AFTER_S:-30}"
WRITERS="${CELLD_SOAK_WRITERS:-2}"
READERS="${CELLD_SOAK_READERS:-4}"
PACE_MS="${CELLD_SOAK_PACE_MS:-50}"
QUIESCE_S="${CELLD_SOAK_QUIESCE_S:-30}"
# How long a returning node may still fail calls before they are unexpected.
SETTLE_S="${CELLD_SOAK_SETTLE_S:-10}"
FAULT_PERCENT="${CELLD_SOAK_S3_FAULT_PERCENT:-0}"
FAULT_LATENCY_MS="${CELLD_SOAK_S3_FAULT_LATENCY_MS:-0}"
FAULT_SEED="${CELLD_SOAK_S3_FAULT_SEED:-1}"
BRIDGE_MAX="${CELLD_SOAK_BRIDGE_MAX:-64}"
BYTES_PER_WRITE_MAX="${CELLD_SOAK_BYTES_PER_WRITE_MAX:-65536}"
RSS_GROWTH_MB="${CELLD_SOAK_RSS_GROWTH_MB:-200}"

TMP="$(mktemp -d)"
PROXY_PID=""
FAILURES=0
declare -a PIDS

cleanup() {
  # SIGKILL, not SIGTERM: a signalled node drains before exiting, which leaves
  # the listener held past the end of the run and breaks the next one.
  for pid in "${PIDS[@]:-}" "$PROXY_PID"; do
    [[ -n "$pid" ]] && kill -9 "$pid" >/dev/null 2>&1 || true
  done
  if [[ "${CELLD_SOAK_KEEP_TMP:-0}" == "1" ]]; then
    echo "kept run artifacts in $TMP" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL %-32s %s\n' "$1" "$2" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'PASS %-32s %s\n' "$1" "$2"
}

# One node's ports, derived from its index so the soak runs a fleet of any size.
node_port() { [[ "$1" == "0" ]] && echo "$PORT_A" || echo "$((PORT_A + $1))"; }
node_peer() { [[ "$1" == "0" ]] && echo "$PEER_A" || echo "$((PEER_A + $1))"; }
node_log() { echo "$TMP/node$1.log"; }
node_watch() { echo "$TMP/watch$1"; }

# The nodes talk to whatever the store is: the endpoint itself, or the fault
# proxy in front of it.
NODE_ENDPOINT="${CELLD_SOAK_ENDPOINT:-}"
if [[ "$FAULT_PERCENT" != "0" || "$FAULT_LATENCY_MS" != "0" ]]; then
  [[ -n "$CELLD_SOAK_ENDPOINT" ]] || {
    echo "fault injection needs CELLD_SOAK_ENDPOINT to proxy" >&2
    exit 2
  }
  python3 "$ROOT/s3-fault-proxy.py" \
    --listen "$PROXY_PORT" --target "$CELLD_SOAK_ENDPOINT" \
    --error-percent "$FAULT_PERCENT" --latency-ms "$FAULT_LATENCY_MS" \
    --seed "$FAULT_SEED" >"$TMP/proxy.log" 2>&1 &
  PROXY_PID=$!
  NODE_ENDPOINT="http://127.0.0.1:$PROXY_PORT"
  for _ in $(seq 1 60); do
    grep -q "proxy listening" "$TMP/proxy.log" 2>/dev/null && break
    sleep 0.25
  done
  printf '     %-32s %s\n' "storage faults" \
    "${FAULT_PERCENT}% errors, ${FAULT_LATENCY_MS}ms latency through $NODE_ENDPOINT"
fi

endpoint_args=()
if [[ -n "$NODE_ENDPOINT" ]]; then
  endpoint_args=(--endpoint "$NODE_ENDPOINT")
fi

common_env=(
  "AWS_REGION=$REGION"
  "CELLD_TTL_MS=$TTL_MS"
  "CELLD_REBALANCE_INTERVAL_MS=0"
  "CELLD_READY_FLEET_GATE_MS=15000"
  "CELLD_DURABILITY=fleet"
)

start_node() {
  local index="$1"
  local node="cfos-soak-$index-$$"
  local log
  log="$(node_log "$index")"
  # Appended, not truncated: a long run restarts each identity many times, and
  # the log of the generation that was killed is the evidence for its exit.
  printf -- '--- %s starting at %s\n' "$node" "$(date -u +%FT%TZ)" >>"$log"
  env "${common_env[@]}" CELLD_NODE="$node" CELLD_WATCH="$(node_watch "$index")" \
    "$CELLD_BIN" --bucket "$CELLD_SOAK_BUCKET" "${endpoint_args[@]}" \
      --listen "127.0.0.1:$(node_port "$index")" \
      --internal-listen "127.0.0.1:$(node_peer "$index")" \
      --advertise "127.0.0.1:$(node_peer "$index")" >>"$log" 2>&1 &
  echo $!
}

wait_ready() {
  local port="$1" log="$2" pid="$3"
  for _ in $(seq 1 240); do
    if curl -fsS "http://127.0.0.1:$port/.well-known/celld/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "celld node exited before readiness" >&2
      cat "$log" >&2
      return 1
    fi
    sleep 0.25
  done
  echo "celld node did not become ready" >&2
  cat "$log" >&2
  return 1
}

rss_kb() {
  ps -o rss= -p "$1" 2>/dev/null | tr -d ' ' || echo 0
}

"$CELLD_BIN" deploy "$ROOT/wrangler.ha.jsonc" \
  --bucket "$CELLD_SOAK_BUCKET" "${endpoint_args[@]}" --region "$REGION" >/dev/null

for index in $(seq 0 $((NODES - 1))); do
  PIDS[index]="$(start_node "$index")"
done
for index in $(seq 0 $((NODES - 1))); do
  wait_ready "$(node_port "$index")" "$(node_log "$index")" "${PIDS[index]}"
done

prime="$(curl -fsS "http://127.0.0.1:$PORT_A/prime")"
[[ "$prime" == *'"result":"primed"'* ]] || { echo "unexpected prime: $prime" >&2; exit 1; }

REPORT="$TMP/report.json"
driver_args=()
for index in $(seq 0 $((NODES - 1))); do
  driver_args+=(--base "http://127.0.0.1:$(node_port "$index")")
  # Every node is sampled: a transient capability's origin can be any of them.
  driver_args+=(--state-url "http://127.0.0.1:$(node_peer "$index")/state")
done
python3 "$ROOT/soak-driver.py" "${driver_args[@]}" \
  --duration "$DURATION_S" --writers "$WRITERS" --readers "$READERS" \
  --pace-ms "$PACE_MS" --quiesce-s "$QUIESCE_S" --settle-s "$SETTLE_S" \
  --output "$REPORT" \
  >"$TMP/driver.log" 2>&1 &
DRIVER_PID=$!

# Supervise: kill a node so ownership has to move, then bring the same identity
# back as a new process generation.
KILLS=0
REJOINS=0
REJOIN_ATTEMPTS=0
NEXT_KILL=$((SECONDS + KILL_EVERY_S))
VICTIM=""
RESTART_AT=0
printf '     %-32s %ss, %s nodes, kill every %ss, restart after %ss\n' \
  "soak plan" "$DURATION_S" "$NODES" "$KILL_EVERY_S" "$RESTART_AFTER_S"
while kill -0 "$DRIVER_PID" >/dev/null 2>&1; do
  if [[ -n "$VICTIM" && "$RESTART_AT" != "0" && "$SECONDS" -ge "$RESTART_AT" ]]; then
    [[ -z "${PIDS[$VICTIM]}" ]] && PIDS[VICTIM]="$(start_node "$VICTIM")"
    if wait_ready "$(node_port "$VICTIM")" "$(node_log "$VICTIM")" "${PIDS[VICTIM]}"; then
      REJOINS=$((REJOINS + 1))
      printf 'rejoin %s\n' "$(date +%s%3N)" >>"$REPORT.signal"
      VICTIM=""
      RESTART_AT=0
    else
      # Retry on the next pass: the node comes back when it can, and until then
      # the window stays open because the identity really is absent.
      REJOIN_ATTEMPTS=$((REJOIN_ATTEMPTS + 1))
      RESTART_AT=$SECONDS
    fi
  fi
  if [[ -z "$VICTIM" && "$SECONDS" -ge "$NEXT_KILL" ]]; then
    # Written, then given a moment to be seen: the driver polls this file, and a
    # kill's own failures land within milliseconds of it.
    printf 'kill %s\n' "$(date +%s%3N)" >>"$REPORT.signal"
    sleep 0.3
    # Round-robin over the fleet, so every node's identities move during the run
    # and the cells they own move with them.
    VICTIM=$((KILLS % NODES))
    kill -9 "${PIDS[VICTIM]}" >/dev/null 2>&1 || true
    wait "${PIDS[VICTIM]}" >/dev/null 2>&1 || true
    PIDS[VICTIM]=""
    KILLS=$((KILLS + 1))
    RESTART_AT=$((SECONDS + RESTART_AFTER_S))
    NEXT_KILL=$((SECONDS + KILL_EVERY_S))
    printf '     %-32s node %s killed at %ss (kill %s)\n' "turnover" "$VICTIM" "$SECONDS" "$KILLS"
  fi
  {
    printf '%s' "$SECONDS"
    for index in $(seq 0 $((NODES - 1))); do
      printf ' %s' "$(rss_kb "${PIDS[index]:-0}")"
    done
    printf '\n'
  } >>"$TMP/rss.log"
  sleep 1
done
driver_status=0
wait "$DRIVER_PID" || driver_status=$?

[[ -s "$REPORT" ]] || { echo "the driver produced no report" >&2; cat "$TMP/driver.log" >&2; exit 1; }

# Bucket growth, measured with the same shim the restore gate uses.
SHIM="$ROOT/mc-shim.py"
STATE_FILE="$TMP/aliases.json"
if [[ -n "${CELLD_SOAK_ENDPOINT:-}" && -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  MC_SHIM_STATE="$STATE_FILE" "$SHIM" alias set soak "$CELLD_SOAK_ENDPOINT" \
    "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null 2>&1 || true
  bucket_path="${CELLD_SOAK_BUCKET#s3://}"
  du_out="$(MC_SHIM_STATE="$STATE_FILE" "$SHIM" du "soak/$bucket_path" 2>/dev/null || echo "0 bytes in 0 objects")"
  bucket_bytes="$(awk '{print $1}' <<<"$du_out")"
  bucket_objects="$(awk '{print $4}' <<<"$du_out")"
else
  bucket_bytes=0
  bucket_objects=0
fi

writes="$(jq -r '.writes' "$REPORT")"
unexpected="$(jq -r '.unexpected_errors | length' "$REPORT")"
rollbacks="$(jq -r '.rollbacks' "$REPORT")"
acked="$(jq -r '.max_acknowledged' "$REPORT")"
max_read="$(jq -r '.max_read' "$REPORT")"
handles_after="$(jq -r '.bridge_handles.after_load' "$REPORT")"
handles_max="$(jq -r '.bridge_handles.max' "$REPORT")"
p99="$(jq -r '.latency_ms.p99' "$REPORT")"

printf '\nsoak report (%ss, %s nodes, %s calls ok, %s errors of which %s inside turnover windows)\n' \
  "$DURATION_S" "$NODES" "$(jq -r '.ok' "$REPORT")" "$(jq -r '.errors' "$REPORT")" \
  "$(jq -r '.turnover_errors' "$REPORT")"
printf '  nodes %s  writes %s  reads %s  kills %s  rejoins %s  p99 %sms\n' \
  "$NODES" "$writes" "$(jq -r '.reads' "$REPORT")" "$KILLS" "$REJOINS" "$p99"
printf '  acknowledged value %s  highest read %s  bucket %s bytes in %s objects\n' \
  "$acked" "$max_read" "$bucket_bytes" "$bucket_objects"
printf '  rpc_bridge_handles max %s fleet-wide, after load %s\n' "$handles_max" "$handles_after"

# A node's first minutes are warmup - V8 pools, bundler caches, the boot index -
# so the leak bar is the change after the first quarter of the run, averaged
# over the fleet.
rss_start=0
rss_warm=0
rss_end=0
rss_rows="$(wc -l <"$TMP/rss.log")"
warm_row=$((rss_rows / 4 + 1))
for index in $(seq 0 $((NODES - 1))); do
  column=$((index + 2))
  rss_start=$((rss_start + $(awk -v c="$column" 'NR==1 {print $c}' "$TMP/rss.log")))
  rss_warm=$((rss_warm + $(awk -v c="$column" -v r="$warm_row" 'NR==r {print $c}' "$TMP/rss.log")))
  rss_end=$((rss_end + $(awk -v c="$column" 'END {print $c}' "$TMP/rss.log")))
done
rss_growth_kb=$(( (rss_end - rss_warm) / NODES ))
rss_total_kb=$(( (rss_end - rss_start) / NODES ))
rss_limit_kb=$((RSS_GROWTH_MB * 1024))

[[ "$driver_status" == "0" ]] || fail "driver" "exited $driver_status"
[[ "$unexpected" == "0" ]] && pass "no unexpected errors" "$(jq -r '.ok' "$REPORT") calls, $(jq -r '.turnover_errors' "$REPORT") inside turnover windows" \
  || fail "no unexpected errors" "$(jq -c '.unexpected_errors' "$REPORT")"
[[ "$rollbacks" == "0" ]] && pass "no rollback" "no read moved backwards" \
  || fail "no rollback" "$rollbacks reads went backwards"
[[ "$max_read" -le "$acked" ]] && pass "no invented state" "highest read $max_read, highest acknowledged $acked" \
  || fail "no invented state" "read $max_read was never acknowledged (highest $acked)"
# RPO=0 under load: the last acknowledged write is the value the fleet serves
# after every kill, every restart and every injected storage fault.
final_read="$(jq -r '.final_read' "$REPORT")"
if [[ "$final_read" == "$acked" && "$acked" != "0" && "$acked" != "null" ]]; then
  pass "acknowledged write survived" "value $acked read back after the load stopped"
else
  fail "acknowledged write survived" "acknowledged $acked, read back $final_read"
fi
[[ "$KILLS" -ge 1 && "$REJOINS" -eq "$KILLS" ]] \
  && pass "turnover exercised" "$KILLS kills, $REJOINS rejoins" \
  || fail "turnover exercised" "$KILLS kills, $REJOINS rejoins, $REJOIN_ATTEMPTS retries"
[[ "$handles_after" == "0" ]] && pass "bridges retired" "rpc_bridge_handles=0 on every node after load" \
  || fail "bridges retired" "$(jq -c '.bridge_handles.per_node' "$REPORT")"
[[ "$handles_max" != "null" && "$handles_max" -le "$BRIDGE_MAX" ]] \
  && pass "bridges bounded" "max $handles_max fleet-wide during load (limit $BRIDGE_MAX)" \
  || fail "bridges bounded" "max $handles_max during load (limit $BRIDGE_MAX)"
if [[ "$writes" -gt 0 && "$bucket_bytes" -gt 0 ]]; then
  per_write=$((bucket_bytes / writes))
  [[ "$per_write" -le "$BYTES_PER_WRITE_MAX" ]] \
    && pass "bucket growth bounded" "$per_write bytes per acknowledged write (limit $BYTES_PER_WRITE_MAX)" \
    || fail "bucket growth bounded" "$per_write bytes per acknowledged write (limit $BYTES_PER_WRITE_MAX)"
else
  printf '     %-32s %s\n' "bucket growth bounded" "skipped: no S3 endpoint to measure"
fi
[[ "$rss_growth_kb" -le "$rss_limit_kb" ]] \
  && pass "node memory bounded" "average RSS ${rss_growth_kb}KB after warmup, ${rss_total_kb}KB including it (limit ${rss_limit_kb}KB)" \
  || fail "node memory bounded" "average RSS ${rss_growth_kb}KB after warmup (limit ${rss_limit_kb}KB)"

if [[ "$FAILURES" != "0" ]]; then
  echo "soak failed: $FAILURES bar(s)" >&2
  exit 1
fi
echo "soak passed"
