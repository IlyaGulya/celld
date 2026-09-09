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

# Config-level compatibility used by the real Workshop backend.
run_case "Wrangler JSON var" "/json-var" '"enabled":true'
run_case "KV preview_id" "/kv-preview" 'preview-id'

# First isolate the transport problem from ctx.props semantics.
run_case "service env transport" "/service?value=hello" 'service:hello'

# Cloudflare OS uses props-bearing ServiceStubs for Gadget/Gatekeeper loopbacks.
run_case "service env with props" "/capability?value=hello" 'capability:hello'

# Cloudflare OS executeCode() passes a transient RpcTarget (RestoreForgerImpl)
# as an argument to the loaded Code Mode Worker.
run_case "transient RPC argument" "/transient" 'transient:hello'

# Cloudflare OS Code Mode attaches a props-bearing tail ServiceStub to each
# loaded worker and waits for its TraceItem after verify()/run().
run_case "loader tail trace" "/tail" '"method":"run","log":"tail-probe"'

# Cloudflare OS Gatekeepers instantiate props-bearing DurableObjectClass values
# from ctx.exports and hand them to ctx.facets.get().
run_case "ctx.exports facet class" "/facet" 'facet:hello'

# Cloudflare OS reaches ordinary exported Durable Objects through the same
# ctx.exports surface, using namespace-style getByName()/get() methods.
run_case "ctx.exports DO namespace" "/ctx-exports-do" 'direct:hello'

# Cloudflare OS Durable Objects return RpcTarget capabilities (e.g. Overseer.open()).
# The caller must be able to invoke the returned stub from another isolate.
run_case "DO returns RPC target" "/do-return-rpc" 'returned:hello'

# Cloudflare OS wraps facet stubs in a Proxy that emulates RpcTarget and synthesizes
# wildcard methods from its get trap before wrapping it in a native RpcStub.
run_case "Proxy-emulated RPC target" "/proxy-rpc-target" 'proxy:hello'

# Cloudflare OS Gadget server.js modules export only a named DurableObject class;
# Loader must accept them even though they have no stateless default export.
run_case "Loader DO-only module" "/loader-do-only" 'do-only:hello'

if [[ "$failures" -ne 0 ]]; then
  echo >&2
  echo "$failures Cloudflare OS compatibility case(s) failed." >&2
  echo "--- celld log (tail) ---" >&2
  tail -n 200 "$LOG" >&2 || true
  exit 1
fi

echo "All Cloudflare OS compatibility cases passed."
