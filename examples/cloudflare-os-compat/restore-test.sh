#!/usr/bin/env bash
set -euo pipefail

CELLD_BIN="${1:-}"
if [[ -z "$CELLD_BIN" || ! -x "$CELLD_BIN" ]]; then
  echo "usage: CELLD_BACKUP_SOURCE=s3://bucket/source CELLD_BACKUP_RESTORE=s3://bucket/restore CELLD_BACKUP_ENDPOINT=http://... $0 /path/to/celld" >&2
  exit 2
fi
: "${CELLD_BACKUP_SOURCE:?set CELLD_BACKUP_SOURCE to a dedicated source S3 prefix}"
: "${CELLD_BACKUP_RESTORE:?set CELLD_BACKUP_RESTORE to a different restore S3 prefix}"
: "${CELLD_BACKUP_ENDPOINT:?set CELLD_BACKUP_ENDPOINT for the S3-compatible store}"
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"

if [[ "$CELLD_BACKUP_SOURCE" != s3://* || "$CELLD_BACKUP_RESTORE" != s3://* ]]; then
  echo "backup source and restore must both be s3:// bucket prefixes" >&2
  exit 2
fi
if [[ "$CELLD_BACKUP_SOURCE" == "$CELLD_BACKUP_RESTORE" ]]; then
  echo "backup restore prefix must differ from the source prefix" >&2
  exit 2
fi

MC="${CELLD_MC:-mc}"
command -v "$MC" >/dev/null 2>&1 || { echo "MinIO mc is required (set CELLD_MC)" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
REGION="${CELLD_BACKUP_REGION:-us-east-1}"
PORT_SOURCE="${CELLD_BACKUP_PORT_SOURCE:-19771}"
PORT_RESTORE="${CELLD_BACKUP_PORT_RESTORE:-19772}"
PEER_SOURCE="${CELLD_BACKUP_PEER_SOURCE:-19781}"
PEER_RESTORE="${CELLD_BACKUP_PEER_RESTORE:-19782}"
TMP="$(mktemp -d)"
ALIAS="celld-backup-$$"
PID=""

cleanup() {
  [[ -n "$PID" ]] && kill "$PID" >/dev/null 2>&1 || true
  "$MC" alias remove "$ALIAS" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

start_node() {
  local bucket="$1" node="$2" watch="$3" port="$4" peer="$5" log="$6"
  env AWS_REGION="$REGION" CELLD_NODE="$node" CELLD_WATCH="$watch" \
    CELLD_READY_FLEET_GATE_MS=0 CELLD_REBALANCE_INTERVAL_MS=0 CELLD_DURABILITY=bucket \
    "$CELLD_BIN" --bucket "$bucket" --endpoint "$CELLD_BACKUP_ENDPOINT" \
      --listen "127.0.0.1:$port" --internal-listen "127.0.0.1:$peer" \
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

"$CELLD_BIN" deploy "$ROOT/wrangler.upgrade.jsonc" \
  --bucket "$CELLD_BACKUP_SOURCE" --endpoint "$CELLD_BACKUP_ENDPOINT" --region "$REGION" >/dev/null

PID="$(start_node "$CELLD_BACKUP_SOURCE" "cfos-backup-source-$$" "$TMP/source" "$PORT_SOURCE" "$PEER_SOURCE" "$TMP/source.log")"
wait_ready "$PORT_SOURCE" "$TMP/source.log" "$PID"
prime="$(curl -fsS "http://127.0.0.1:$PORT_SOURCE/prime")"
[[ "$prime" == *'"value":3'* ]] || { echo "unexpected source value: $prime" >&2; exit 1; }

# Deliberately crash the source node. Bucket durability means the acknowledged
# value is already in the backup boundary; no node-local state may be required.
kill -9 "$PID" >/dev/null 2>&1 || true
wait "$PID" >/dev/null 2>&1 || true
PID=""

"$MC" alias set "$ALIAS" "$CELLD_BACKUP_ENDPOINT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null
source_path="${CELLD_BACKUP_SOURCE#s3://}"
restore_path="${CELLD_BACKUP_RESTORE#s3://}"
"$MC" rm --recursive --force "$ALIAS/$restore_path" >/dev/null 2>&1 || true
"$MC" mirror --overwrite "$ALIAS/$source_path" "$ALIAS/$restore_path" >/dev/null
printf 'PASS %-32s %s -> %s\n' "object-store prefix copy" "$CELLD_BACKUP_SOURCE" "$CELLD_BACKUP_RESTORE"

# The restore node gets no copied CELLD_WATCH directory. Everything it needs
# must come from the restored object-store prefix.
PID="$(start_node "$CELLD_BACKUP_RESTORE" "cfos-backup-restore-$$" "$TMP/empty-restore" "$PORT_RESTORE" "$PEER_RESTORE" "$TMP/restore.log")"
wait_ready "$PORT_RESTORE" "$TMP/restore.log" "$PID"
restored="$(curl --max-time 30 -fsS "http://127.0.0.1:$PORT_RESTORE/get")"
[[ "$restored" == *'"value":3'* ]] || { echo "restored node returned unexpected state: $restored" >&2; exit 1; }
printf 'PASS %-32s %s\n' "empty-node object restore" "$restored"
