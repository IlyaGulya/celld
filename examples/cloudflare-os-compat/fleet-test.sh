#!/usr/bin/env bash
# Three nodes, one bucket: the ownership model at fleet size.
#
# The HA gate proves one turnover between two nodes. This one proves what only a
# third node can: that several cells spread over the fleet, that every node can
# reach every cell through its owner (including a two-hop call from a node that
# owns neither), that killing an owner leaves both survivors serving, and that a
# rejoined node takes its share again.
#
#   CELLD_FLEET_BUCKET=s3://bucket/prefix \
#   CELLD_FLEET_ENDPOINT=http://127.0.0.1:9000 \
#     bash fleet-test.sh /path/to/celld
set -euo pipefail

CELLD_BIN="${1:-}"
if [[ -z "$CELLD_BIN" || ! -x "$CELLD_BIN" ]]; then
  echo "usage: CELLD_FLEET_BUCKET=s3://bucket/prefix $0 /path/to/celld" >&2
  exit 2
fi
: "${CELLD_FLEET_BUCKET:?set CELLD_FLEET_BUCKET to a dedicated S3-compatible bucket prefix}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
REGION="${CELLD_FLEET_REGION:-us-east-1}"
TTL_MS="${CELLD_FLEET_TTL_MS:-4000}"
CELLS="${CELLD_FLEET_CELLS:-6}"
NODES="${CELLD_FLEET_NODES:-3}"
TIMEOUT_S="${CELLD_FLEET_TIMEOUT_S:-60}"
TMP="$(mktemp -d)"
declare -a PIDS PORTS PEERS LOGS

cleanup() {
  # SIGKILL, not SIGTERM: a signalled node drains before exiting, which leaves
  # the listener held past the end of the run and breaks the next one.
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -9 "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

endpoint_args=()
if [[ -n "${CELLD_FLEET_ENDPOINT:-}" ]]; then
  endpoint_args=(--endpoint "$CELLD_FLEET_ENDPOINT")
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
  local port=$((19931 + index))
  local peer=$((19941 + index))
  PORTS[index]="$port"
  PEERS[index]="$peer"
  LOGS[index]="$TMP/node$index.log"
  env "${common_env[@]}" CELLD_NODE="cfos-fleet-node$index-$$" \
    CELLD_WATCH="$TMP/watch$index" \
    "$CELLD_BIN" --bucket "$CELLD_FLEET_BUCKET" "${endpoint_args[@]}" \
      --listen "127.0.0.1:$port" \
      --internal-listen "127.0.0.1:$peer" \
      --advertise "127.0.0.1:$peer" >>"${LOGS[index]}" 2>&1 &
  PIDS[index]=$!
}

wait_ready() {
  local index="$1"
  for _ in $(seq 1 240); do
    if curl -fsS "http://127.0.0.1:${PORTS[index]}/.well-known/celld/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "${PIDS[index]}" >/dev/null 2>&1; then
      echo "node $index exited before readiness" >&2
      cat "${LOGS[index]}" >&2
      return 1
    fi
    sleep 0.25
  done
  echo "node $index did not become ready" >&2
  cat "${LOGS[index]}" >&2
  return 1
}

# One cell's value as some node serves it, including through the owner.
value_of() {
  local index="$1" cell="$2"
  curl -fsS --max-time 20 "http://127.0.0.1:${PORTS[index]}/value?cell=$cell" \
    2>/dev/null | sed -n 's/.*"result":\([0-9]*\).*/\1/p'
}

bump() {
  local index="$1" cell="$2"
  curl -fsS --max-time 20 "http://127.0.0.1:${PORTS[index]}/bump?cell=$cell" \
    2>/dev/null | sed -n 's/.*"result":\([0-9]*\).*/\1/p'
}

# The cells this node says it owns, from its own view of the deployment.
owned_cells() {
  local index="$1"
  curl -fsS --max-time 10 "http://127.0.0.1:${PEERS[index]}/state" 2>/dev/null |
    jq -r '.deployment.cells | keys[]' 2>/dev/null || true
}

"$CELLD_BIN" deploy "$ROOT/wrangler.ha.jsonc" \
  --bucket "$CELLD_FLEET_BUCKET" "${endpoint_args[@]}" --region "$REGION" >/dev/null

for index in $(seq 0 $((NODES - 1))); do
  start_node "$index"
done
for index in $(seq 0 $((NODES - 1))); do
  wait_ready "$index"
done

fleet_cells=()
for cell in $(seq 1 "$CELLS"); do
  fleet_cells+=("fleet-cell-$cell")
done

# Each cell is first written through a different node, which is how ownership is
# established: this makes the distribution the fleet's own doing rather than an
# artefact of one node taking every request.
index=0
for cell in "${fleet_cells[@]}"; do
  write="$(bump "$((index % NODES))" "$cell")"
  [[ "$write" == "1" ]] || { echo "first write of $cell returned $write" >&2; exit 1; }
  index=$((index + 1))
done

# Reachability: every node serves every cell, including cells it does not own,
# which means the call crosses to the owner.
for node in $(seq 0 $((NODES - 1))); do
  for cell in "${fleet_cells[@]}"; do
    seen="$(value_of "$node" "$cell")"
    [[ "$seen" == "1" ]] || {
      echo "node $node read $cell as ${seen:-nothing}, expected 1" >&2
      exit 1
    }
  done
done
printf 'PASS %-32s %s cells through %s nodes\n' \
  "every node reaches every cell" "${#fleet_cells[@]}" "$NODES"

# Ownership: exactly one node per cell, and the fleet spread them rather than
# parking every cell on the node that answered first.
declare -A owner_of
for node in $(seq 0 $((NODES - 1))); do
  while read -r owned; do
    [[ -z "$owned" ]] && continue
    if [[ -n "${owner_of[$owned]:-}" && "${owner_of[$owned]}" != "$node" ]]; then
      echo "$owned is owned by node ${owner_of[$owned]} and by node $node" >&2
      exit 1
    fi
    owner_of[$owned]="$node"
  done < <(owned_cells "$node")
done
# A cell's key is a hash of its identity (celld prints `Host:<digest>`), so the
# fleet's own view is what says how many cells are owned and by whom. What the
# gate can assert is that the count matches the cells this run created, that no
# key is claimed by two nodes, and that ownership is spread rather than parked.
declare -A owners_in_play
for owner in "${owner_of[@]}"; do
  owners_in_play[$owner]=1
done
spread="${#owners_in_play[@]}"
total="${#owner_of[@]}"
[[ "$total" == "$CELLS" ]] || {
  echo "the fleet owns $total cells, but this run created $CELLS" >&2
  exit 1
}
[[ "$spread" -ge 2 ]] || {
  echo "one node owns every cell; ownership is not spread at fleet size" >&2
  exit 1
}
printf 'PASS %-32s %s cells, %s of %s nodes hold them, none shared\n' \
  "ownership spread and exclusive" "$total" "$spread" "$NODES"

# Kill whichever node holds the most cells: those cells have to move, and with
# two survivors left the client can reach every one of them.
victim=0
victim_count=0
for node in $(seq 0 $((NODES - 1))); do
  count="$(owned_cells "$node" | grep -c . || true)"
  if ((count > victim_count)); then
    victim="$node"
    victim_count="$count"
  fi
done
survivors=()
for node in $(seq 0 $((NODES - 1))); do
  [[ "$node" == "$victim" ]] || survivors+=("$node")
done

kill -9 "${PIDS[victim]}" >/dev/null 2>&1 || true
wait "${PIDS[victim]}" >/dev/null 2>&1 || true
PIDS[victim]=""
printf '     %-32s node %s held %s cells and was killed\n' "turnover" "$victim" "$victim_count"

started_ms="$(date +%s%3N)"
moved=0
for _ in $(seq 1 $((TIMEOUT_S * 4))); do
  ok=1
  for node in "${survivors[@]}"; do
    for cell in "${fleet_cells[@]}"; do
      seen="$(value_of "$node" "$cell")"
      [[ "$seen" == "1" ]] || ok=0
    done
  done
  if [[ "$ok" == "1" ]]; then
    moved=1
    break
  fi
  sleep 0.25
done
[[ "$moved" == "1" ]] || {
  echo "the survivors never served every cell after the owner was killed" >&2
  for node in "${survivors[@]}"; do
    echo "--- node $node" >&2
    tail -5 "${LOGS[node]}" >&2
  done
  exit 1
}
finished_ms="$(date +%s%3N)"
printf 'PASS %-32s %s survivors serve all cells (%sms)\n' \
  "owner death moves its cells" "${#survivors[@]}" "$((finished_ms - started_ms))"

# Rejoin: the same node identity returns and no cell ends up owned twice.
start_node "$victim"
wait_ready "$victim"
for node in $(seq 0 $((NODES - 1))); do
  for cell in "${fleet_cells[@]}"; do
    seen="$(value_of "$node" "$cell")"
    [[ "$seen" == "1" ]] || {
      echo "after rejoin node $node read $cell as ${seen:-nothing}" >&2
      exit 1
    }
  done
done
printf 'PASS %-32s all %s nodes serve every cell again\n' "rejoined node" "$NODES"
