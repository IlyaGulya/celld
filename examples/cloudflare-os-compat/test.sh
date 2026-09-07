#!/usr/bin/env bash
set -euo pipefail

CELLD_BIN="${1:-${CELLD_BIN:-}}"
if [[ -z "$CELLD_BIN" ]]; then
  echo "usage: $0 /path/to/celld" >&2
  exit 2
fi
CELLD_BIN="$(cd "$(dirname "$CELLD_BIN")" && pwd)/$(basename "$CELLD_BIN")"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${CELLD_COMPAT_PORT:-9876}"
LOG="${TMPDIR:-/tmp}/celld-cloudflare-os-compat.log"
PID=""

cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT"
rm -rf .celld/dev

CELLD_WORKER_LOADER=LOADER \
  "$CELLD_BIN" dev --host 127.0.0.1 --port "$PORT" --logs >"$LOG" 2>&1 &
PID=$!

base="http://127.0.0.1:$PORT"
for _ in $(seq 1 120); do
  if curl -sS "$base/" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    echo "celld exited before becoming ready" >&2
    cat "$LOG" >&2 || true
    exit 1
  fi
  sleep 0.5
done

if ! curl -sS "$base/" >/dev/null 2>&1; then
  echo "celld did not become ready" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

failures=0

run_case() {
  local name="$1" path="$2" expected="$3"
  local body_file status body
  body_file="$(mktemp)"
  status="$(curl -sS -o "$body_file" -w '%{http_code}' "$base$path" || true)"
  body="$(cat "$body_file")"
  rm -f "$body_file"

  if [[ "$status" == "200" && "$body" == *"$expected"* ]]; then
    printf 'PASS %-28s HTTP %s %s\n' "$name" "$status" "$body"
  else
    printf 'FAIL %-28s HTTP %s %s\n' "$name" "$status" "$body" >&2
    failures=$((failures + 1))
  fi
}

run_case "plain dynamic worker" "/plain" 'plain-dynamic-worker'

# First isolate the transport problem from ctx.props semantics.
run_case "service env transport" "/service?value=hello" 'service:hello'

# Cloudflare OS uses props-bearing ServiceStubs for Gadget/Gatekeeper loopbacks.
run_case "service env with props" "/capability?value=hello" 'capability:hello'

# Cloudflare OS executeCode() passes a transient RpcTarget (RestoreForgerImpl)
# as an argument to the loaded Code Mode Worker.
run_case "transient RPC argument" "/transient" 'transient:hello'

# Cloudflare OS Gatekeepers instantiate props-bearing DurableObjectClass values
# from ctx.exports and hand them to ctx.facets.get().
run_case "ctx.exports facet class" "/facet" 'facet:hello'

if [[ "$failures" -ne 0 ]]; then
  echo >&2
  echo "$failures Cloudflare OS compatibility case(s) failed." >&2
  echo "--- celld log (tail) ---" >&2
  tail -n 200 "$LOG" >&2 || true
  exit 1
fi

echo "All Cloudflare OS compatibility cases passed."
