#!/usr/bin/env bash
# The long-run half of the fleet gates: sustained load through two nodes while
# the owner is killed, the fleet is rejoined, and the store injects faults.
#
# The short gates answer "does a failover work". This one answers the questions
# that only time can answer: does an acknowledged write stay durable across
# repeated turnovers, does a transient-capability bridge leak, does the bucket
# or a node's memory grow without bound, and do storage faults turn into lost
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
#   - the origin node's rpc_bridge_handles returns to 0 after the load stops and
#     never exceeds CELLD_SOAK_BRIDGE_MAX while it runs;
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
# How long a returning node may still fail calls before the failures are
# unexpected.
SETTLE_S="${CELLD_SOAK_SETTLE_S:-10}"
FAULT_PERCENT="${CELLD_SOAK_S3_FAULT_PERCENT:-0}"
FAULT_LATENCY_MS="${CELLD_SOAK_S3_LATENCY_MS:-0}"
FAULT_SEED="${CELLD_SOAK_S3_FAULT_SEED:-1}"
BRIDGE_MAX="${CELLD_SOAK_BRIDGE_MAX:-64}"
BYTES_PER_WRITE_MAX="${CELLD_SOAK_BYTES_PER_WRITE_MAX:-65536}"
RSS_GROWTH_MB="${CELLD_SOAK_RSS_GROWTH_MB:-200}"

TMP="$(mktemp -d)"
PID_A=""
PID_B=""
PROXY_PID=""
FAILURES=0

cleanup() {
  for pid in "$PID_A" "$PID_B" "$PROXY_PID"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
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
  local node="$1" watch="$2" port="$3" peer="$4" log="$5"
  # Appended, not truncated: a long run restarts each identity many times, and
  # the log of the generation that was killed is the evidence for its exit.
  printf -- '--- %s starting at %s\n' "$node" "$(date -u +%FT%TZ)" >>"$log"
  env "${common_env[@]}" CELLD_NODE="$node" CELLD_WATCH="$watch" \
    "$CELLD_BIN" --bucket "$CELLD_SOAK_BUCKET" "${endpoint_args[@]}" \
      --listen "127.0.0.1:$port" \
      --internal-listen "127.0.0.1:$peer" \
      --advertise "127.0.0.1:$peer" >>"$log" 2>&1 &
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

NODE_A="cfos-soak-a-$$"
NODE_B="cfos-soak-b-$$"
PID_A="$(start_node "$NODE_A" "$TMP/a" "$PORT_A" "$PEER_A" "$TMP/a.log")"
PID_B="$(start_node "$NODE_B" "$TMP/b" "$PORT_B" "$PEER_B" "$TMP/b.log")"
wait_ready "$PORT_A" "$TMP/a.log" "$PID_A"
wait_ready "$PORT_B" "$TMP/b.log" "$PID_B"

prime="$(curl -fsS "http://127.0.0.1:$PORT_A/prime")"
[[ "$prime" == *'"result":"primed"'* ]] || { echo "unexpected prime: $prime" >&2; exit 1; }

RSS_A_START="$(rss_kb "$PID_A")"
RSS_B_START="$(rss_kb "$PID_B")"

REPORT="$TMP/report.json"
python3 "$ROOT/soak-driver.py" \
  --base-a "http://127.0.0.1:$PORT_A" --base-b "http://127.0.0.1:$PORT_B" \
  --state-url "http://127.0.0.1:$PEER_A/state" \
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
printf '     %-32s %ss, kill every %ss, restart after %ss\n' \
  "soak plan" "$DURATION_S" "$KILL_EVERY_S" "$RESTART_AFTER_S"
while kill -0 "$DRIVER_PID" >/dev/null 2>&1; do
  if [[ "$VICTIM" == "A" && "$RESTART_AT" != "0" && "$SECONDS" -ge "$RESTART_AT" ]]; then
    [[ -z "$PID_A" ]] && PID_A="$(start_node "$NODE_A" "$TMP/a" "$PORT_A" "$PEER_A" "$TMP/a.log")"
    if wait_ready "$PORT_A" "$TMP/a.log" "$PID_A"; then
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
  elif [[ "$VICTIM" == "B" && "$RESTART_AT" != "0" && "$SECONDS" -ge "$RESTART_AT" ]]; then
    [[ -z "$PID_B" ]] && PID_B="$(start_node "$NODE_B" "$TMP/b" "$PORT_B" "$PEER_B" "$TMP/b.log")"
    if wait_ready "$PORT_B" "$TMP/b.log" "$PID_B"; then
      REJOINS=$((REJOINS + 1))
      printf 'rejoin %s\n' "$(date +%s%3N)" >>"$REPORT.signal"
      VICTIM=""
      RESTART_AT=0
    else
      REJOIN_ATTEMPTS=$((REJOIN_ATTEMPTS + 1))
      RESTART_AT=$SECONDS
    fi
  fi
  if [[ -z "$VICTIM" && "$SECONDS" -ge "$NEXT_KILL" ]]; then
    # Written, then given a moment to be seen: the driver polls this file, and a
    # kill's own failures land within milliseconds of it.
    printf 'kill %s\n' "$(date +%s%3N)" >>"$REPORT.signal"
    sleep 0.3
    if [[ $((KILLS % 2)) -eq 0 ]]; then
      VICTIM="A"
      kill -9 "$PID_A" >/dev/null 2>&1 || true
      wait "$PID_A" >/dev/null 2>&1 || true
      PID_A=""
    else
      VICTIM="B"
      kill -9 "$PID_B" >/dev/null 2>&1 || true
      wait "$PID_B" >/dev/null 2>&1 || true
      PID_B=""
    fi
    KILLS=$((KILLS + 1))
    RESTART_AT=$((SECONDS + RESTART_AFTER_S))
    NEXT_KILL=$((SECONDS + KILL_EVERY_S))
    printf '     %-32s node %s killed at %ss (kill %s)\n' "turnover" "$VICTIM" "$SECONDS" "$KILLS"
  fi
  printf '%s %s %s\n' "$SECONDS" "$(rss_kb "${PID_A:-0}")" "$(rss_kb "${PID_B:-0}")" \
    >>"$TMP/rss.log"
  sleep 1
done
driver_status=0
wait "$DRIVER_PID" || driver_status=$?

# A node's first minutes are warmup - V8 pools, bundler caches, the boot index -
# so the leak bar is the change after the first quarter of the run.
RSS_A_START="$(awk 'NR==1 {print $2}' "$TMP/rss.log")"
RSS_B_START="$(awk 'NR==1 {print $3}' "$TMP/rss.log")"
RSS_A_END="$(tail -1 "$TMP/rss.log" | awk '{print $2}')"
RSS_B_END="$(tail -1 "$TMP/rss.log" | awk '{print $3}')"
RSS_A_WARM="$(awk -v n="$(wc -l <"$TMP/rss.log")" 'NR==int(n/4)+1 {print $2}' "$TMP/rss.log")"
RSS_B_WARM="$(awk -v n="$(wc -l <"$TMP/rss.log")" 'NR==int(n/4)+1 {print $3}' "$TMP/rss.log")"

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
max_read="$(jq -r '.max_read' "$REPORT")"
acked="$(jq -r '.max_acknowledged' "$REPORT")"
seen="$max_read"
handles_after="$(jq -r '.bridge_handles.after_load' "$REPORT")"
handles_max="$(jq -r '.bridge_handles.max' "$REPORT")"
p99="$(jq -r '.latency_ms.p99' "$REPORT")"

printf '\nsoak report (%ss, %s calls ok, %s errors of which %s inside turnover windows)\n' \
  "$DURATION_S" "$(jq -r '.ok' "$REPORT")" "$(jq -r '.errors' "$REPORT")" \
  "$(jq -r '.turnover_errors' "$REPORT")"
printf '  writes %s  reads %s  kills %s  rejoins %s  p99 %sms\n' \
  "$writes" "$(jq -r '.reads' "$REPORT")" "$KILLS" "$REJOINS" "$p99"
printf '  acknowledged value %s  highest read %s  bucket %s bytes in %s objects\n' \
  "$acked" "$seen" "$bucket_bytes" "$bucket_objects"
printf '  rpc_bridge_handles max %s, after load %s\n' "$handles_max" "$handles_after"

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
[[ "$handles_after" == "0" ]] && pass "bridges retired" "rpc_bridge_handles=0 after load" \
  || fail "bridges retired" "rpc_bridge_handles=$handles_after after load"
[[ "$handles_max" != "null" && "$handles_max" -le "$BRIDGE_MAX" ]] \
  && pass "bridges bounded" "max $handles_max during load (limit $BRIDGE_MAX)" \
  || fail "bridges bounded" "max $handles_max during load (limit $BRIDGE_MAX)"
if [[ "$writes" -gt 0 && "$bucket_bytes" -gt 0 ]]; then
  per_write=$((bucket_bytes / writes))
  [[ "$per_write" -le "$BYTES_PER_WRITE_MAX" ]] \
    && pass "bucket growth bounded" "$per_write bytes per acknowledged write (limit $BYTES_PER_WRITE_MAX)" \
    || fail "bucket growth bounded" "$per_write bytes per acknowledged write (limit $BYTES_PER_WRITE_MAX)"
else
  printf '     %-32s %s\n' "bucket growth bounded" "skipped: no S3 endpoint to measure"
fi
rss_growth_kb=$(( (${RSS_A_END:-0} + ${RSS_B_END:-0} - ${RSS_A_WARM:-0} - ${RSS_B_WARM:-0}) / 2 ))
rss_total_kb=$(( (${RSS_A_END:-0} + ${RSS_B_END:-0} - ${RSS_A_START:-0} - ${RSS_B_START:-0}) / 2 ))
rss_limit_kb=$((RSS_GROWTH_MB * 1024))
[[ "$rss_growth_kb" -le "$rss_limit_kb" ]] \
  && pass "node memory bounded" "RSS ${rss_growth_kb}KB after warmup, ${rss_total_kb}KB including it (limit ${rss_limit_kb}KB)" \
  || fail "node memory bounded" "RSS ${rss_growth_kb}KB after warmup (limit ${rss_limit_kb}KB)"

if [[ "$FAILURES" != "0" ]]; then
  echo "soak failed: $FAILURES bar(s)" >&2
  exit 1
fi
echo "soak passed"
