#!/usr/bin/env bash
set -euo pipefail

OLD_BIN="${1:-}"
NEW_BIN="${2:-}"
if [[ -z "$OLD_BIN" || -z "$NEW_BIN" || ! -x "$OLD_BIN" || ! -x "$NEW_BIN" ]]; then
  echo "usage: CELLD_UPGRADE_BUCKET=s3://bucket/prefix [CELLD_UPGRADE_ENDPOINT=http://...] $0 /path/to/old-celld /path/to/new-celld" >&2
  exit 2
fi
: "${CELLD_UPGRADE_BUCKET:?set CELLD_UPGRADE_BUCKET to a dedicated S3-compatible bucket prefix}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
REGION="${CELLD_UPGRADE_REGION:-us-east-1}"
TTL_MS="${CELLD_UPGRADE_TTL_MS:-4000}"
PORT_OLD="${CELLD_UPGRADE_PORT_OLD:-19971}"
PORT_NEW="${CELLD_UPGRADE_PORT_NEW:-19972}"
PEER_OLD="${CELLD_UPGRADE_PEER_OLD:-19981}"
PEER_NEW="${CELLD_UPGRADE_PEER_NEW:-19982}"
TMP="$(mktemp -d)"
OLD_NODE="cfos-up-old-$$"
NEW_NODE="cfos-up-new-$$"
PID_OLD=""
PID_NEW=""

cleanup() {
  [[ -n "$PID_OLD" ]] && kill "$PID_OLD" >/dev/null 2>&1 || true
  [[ -n "$PID_NEW" ]] && kill "$PID_NEW" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

endpoint_args=()
if [[ -n "${CELLD_UPGRADE_ENDPOINT:-}" ]]; then
  endpoint_args=(--endpoint "$CELLD_UPGRADE_ENDPOINT")
fi

# Publish with the old binary so the test also proves the new runtime can read
# the deployment format produced by the version it replaces.
"$OLD_BIN" deploy "$ROOT/wrangler.upgrade.jsonc" \
  --bucket "$CELLD_UPGRADE_BUCKET" "${endpoint_args[@]}" --region "$REGION" >/dev/null

common_env=(
  "AWS_REGION=$REGION"
  "CELLD_TTL_MS=$TTL_MS"
  "CELLD_REBALANCE_INTERVAL_MS=0"
  "CELLD_READY_FLEET_GATE_MS=0"
  # Keep the protocol test about routing. Bucket acknowledgements make the
  # primed value durable without requiring mixed-version follower transport.
  "CELLD_DURABILITY=bucket"
)

start_node() {
  local bin="$1" node="$2" watch="$3" port="$4" peer="$5" log="$6"
  env "${common_env[@]}" CELLD_NODE="$node" CELLD_WATCH="$watch" \
    "$bin" --bucket "$CELLD_UPGRADE_BUCKET" "${endpoint_args[@]}" \
      --listen "127.0.0.1:$port" \
      --internal-listen "127.0.0.1:$peer" \
      --advertise "127.0.0.1:$peer" >"$log" 2>&1 &
  echo $!
}

wait_ready() {
  local port="$1" log="$2" pid="$3"
  for _ in $(seq 1 120); do
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

# A v0.5.0 node refuses to boot while any live lease is in the bucket, because
# the version it replaces cannot honour the format migration lock. The refusal
# is the mixed-version gate now: it is stronger than a per-request protocol
# rejection, and it is what an operator sees when a fleet is not stopped.
expect_refusal() {
  local log="$1" pid="$2" reason="$3"
  for _ in $(seq 1 120); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      grep -q "$reason" "$log" || {
        echo "node refused to start without the documented reason:" >&2
        cat "$log" >&2
        return 1
      }
      return 0
    fi
    sleep 0.25
  done
  echo "node kept running although the quiet-fleet precondition was unmet" >&2
  cat "$log" >&2
  return 1
}

PID_OLD="$(start_node "$OLD_BIN" "$OLD_NODE" "$TMP/old" "$PORT_OLD" "$PEER_OLD" "$TMP/old.log")"
wait_ready "$PORT_OLD" "$TMP/old.log" "$PID_OLD"
prime="$(curl -fsS "http://127.0.0.1:$PORT_OLD/prime")"
[[ "$prime" == *'"value":3'* ]] || { echo "unexpected old-owner prime response: $prime" >&2; exit 1; }

PID_NEW="$(start_node "$NEW_BIN" "$NEW_NODE" "$TMP/new" "$PORT_NEW" "$PEER_NEW" "$TMP/new.log")"
expect_refusal "$TMP/new.log" "$PID_NEW" "is still live"
printf 'PASS %-32s %s\n' "live-lease boot refusal" \
  "new node refused to start while the old lease was live"

kill -9 "$PID_OLD" >/dev/null 2>&1 || true
wait "$PID_OLD" >/dev/null 2>&1 || true
PID_OLD=""
started_ms="$(date +%s%3N)"
recovered=""
# The old lease expires after CELLD_TTL_MS, so the replacement retries the boot
# instead of assuming the first attempt after the kill can succeed.
for _ in $(seq 1 120); do
  if ! kill -0 "$PID_NEW" >/dev/null 2>&1; then
    PID_NEW="$(start_node "$NEW_BIN" "$NEW_NODE" "$TMP/new" "$PORT_NEW" "$PEER_NEW" "$TMP/new.log")"
  fi
  candidate="$(curl --max-time 5 -fsS "http://127.0.0.1:$PORT_NEW/get" 2>/dev/null || true)"
  if [[ "$candidate" == *'"value":3'* ]]; then
    recovered="$candidate"
    break
  fi
  sleep 0.25
done
finished_ms="$(date +%s%3N)"
[[ -n "$recovered" ]] || { echo "new node failed to recover old-owner state after lease turnover" >&2; exit 1; }
printf 'PASS %-32s %s (%sms)\n' "old-owner replacement recovery" "$recovered" "$((finished_ms-started_ms))"

# Bring the replaced slot back on the new runtime. Reusing the node name is
# intentional: the process generation must change while the fleet identity is
# allowed to rejoin safely.
PID_OLD="$(start_node "$NEW_BIN" "$OLD_NODE" "$TMP/replaced" "$PORT_OLD" "$PEER_OLD" "$TMP/replaced.log")"
wait_ready "$PORT_OLD" "$TMP/replaced.log" "$PID_OLD"
rejoined="$(curl -fsS "http://127.0.0.1:$PORT_OLD/get")"
still_new="$(curl -fsS "http://127.0.0.1:$PORT_NEW/get")"
[[ "$rejoined" == *'"value":3'* && "$still_new" == *'"value":3'* ]] || {
  echo "replacement did not converge: old-slot=$rejoined new-slot=$still_new" >&2
  exit 1
}
printf 'PASS %-32s old-slot=%s new-slot=%s\n' "replacement rejoin" "$rejoined" "$still_new"
