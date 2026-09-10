#!/usr/bin/env bash
set -euo pipefail

CELLD_BIN="${1:-}"
if [[ -z "$CELLD_BIN" || ! -x "$CELLD_BIN" ]]; then
  echo "usage: CELLD_HA_BUCKET=s3://bucket/prefix [CELLD_HA_ENDPOINT=http://...] $0 /path/to/celld" >&2
  exit 2
fi
: "${CELLD_HA_BUCKET:?set CELLD_HA_BUCKET to a dedicated S3-compatible bucket prefix}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
REGION="${CELLD_HA_REGION:-us-east-1}"
TTL_MS="${CELLD_HA_TTL_MS:-4000}"
PORT_A="${CELLD_HA_PORT_A:-19871}"
PORT_B="${CELLD_HA_PORT_B:-19872}"
PEER_A="${CELLD_HA_PEER_A:-19881}"
PEER_B="${CELLD_HA_PEER_B:-19882}"
TMP="$(mktemp -d)"
PID_A=""
PID_B=""
cleanup() {
  [[ -n "$PID_A" ]] && kill "$PID_A" >/dev/null 2>&1 || true
  [[ -n "$PID_B" ]] && kill "$PID_B" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

endpoint_args=()
if [[ -n "${CELLD_HA_ENDPOINT:-}" ]]; then
  endpoint_args=(--endpoint "$CELLD_HA_ENDPOINT")
fi

"$CELLD_BIN" deploy "$ROOT/wrangler.ha.jsonc" \
  --bucket "$CELLD_HA_BUCKET" "${endpoint_args[@]}" --region "$REGION" >/dev/null

common_env=(
  "AWS_REGION=$REGION"
  "CELLD_TTL_MS=$TTL_MS"
  "CELLD_REBALANCE_INTERVAL_MS=0"
  "CELLD_READY_FLEET_GATE_MS=15000"
  "CELLD_DURABILITY=fleet"
)

start_node() {
  local node="$1" watch="$2" port="$3" peer="$4" log="$5"
  env "${common_env[@]}" CELLD_NODE="$node" CELLD_WATCH="$watch" \
    "$CELLD_BIN" --bucket "$CELLD_HA_BUCKET" "${endpoint_args[@]}" \
      --listen "127.0.0.1:$port" \
      --internal-listen "127.0.0.1:$peer" \
      --advertise "127.0.0.1:$peer" >"$log" 2>&1 &
  echo $!
}

PID_A="$(start_node "cfos-ha-a-$$" "$TMP/a" "$PORT_A" "$PEER_A" "$TMP/a.log")"
PID_B="$(start_node "cfos-ha-b-$$" "$TMP/b" "$PORT_B" "$PEER_B" "$TMP/b.log")"

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
wait_ready "$PORT_A" "$TMP/a.log" "$PID_A"
wait_ready "$PORT_B" "$TMP/b.log" "$PID_B"

prime="$(curl -fsS "http://127.0.0.1:$PORT_A/prime")"
[[ "$prime" == *'"result":"primed"'* ]] || { echo "unexpected prime: $prime" >&2; exit 1; }

remote="$(curl -fsS "http://127.0.0.1:$PORT_B/call")"
[[ "$remote" == *'"result":"cap:hello:3"'* ]] || { echo "cross-node capability failed: $remote" >&2; exit 1; }
printf 'PASS %-32s %s\n' "cross-node transient capability" "$remote"

kill -9 "$PID_A" >/dev/null 2>&1 || true
wait "$PID_A" >/dev/null 2>&1 || true
PID_A=""
started_ms="$(date +%s%3N)"
after="$(curl --max-time 30 -fsS "http://127.0.0.1:$PORT_B/call")"
finished_ms="$(date +%s%3N)"
[[ "$after" == *'"result":"cap:hello:3"'* ]] || { echo "post-crash failover failed: $after" >&2; exit 1; }
printf 'PASS %-32s %s (%sms)\n' "SIGKILL owner failover" "$after" "$((finished_ms-started_ms))"
