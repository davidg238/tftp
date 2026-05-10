#!/usr/bin/env bash
# Concurrency burst test. Launches N parallel atftp puts of distinct
# remote files, waits for all to finish, and verifies sha256 of each
# landed file. Exercises the per-transfer task fan-out and the
# --max-concurrent semaphore in TFTPServer.
#
# Topology flags (mirror the round-trip and blksize gates):
#   --concurrent=N
#       Number of parallel puts. Default 20.
#
#   --server=HOST:PORT
#       Don't spawn a local server. Drive atftp at HOST:PORT. Hash
#       verification still runs locally on $ROOT, so HOST:PORT must
#       serve writes into a directory accessible at $ROOT.
#
#   --client-from=USER@HOST
#       Drive atftp over ssh from a remote box. The remote box must
#       have atftp installed and the source asset pre-staged at
#       $REMOTE_ASSET_DIR (default /tmp/tftp-z170-assets). Useful
#       when local-loopback bursts saturate the kernel UDP receive
#       buffer (the same rmem ceiling seen on the round-trip gate
#       at high packet rates).
#
# Canonical reliable invocation (when local load is high):
#   tests/server_burst_test.sh --client-from=david@z170 --concurrent=20

set -euo pipefail

cd "$(dirname "$0")"
TESTS_DIR=$PWD
REPO=$(cd .. && pwd)

CONCURRENT=20
SERVER_OVERRIDE=""
CLIENT_FROM=""
REMOTE_ASSET_DIR=${REMOTE_ASSET_DIR:-/tmp/tftp-z170-assets}

for arg in "$@"; do
  case "$arg" in
    --concurrent=*)  CONCURRENT="${arg#--concurrent=}" ;;
    --server=*)      SERVER_OVERRIDE="${arg#--server=}" ;;
    --client-from=*) CLIENT_FROM="${arg#--client-from=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

PORT=${PORT:-6969}
HOST=127.0.0.1
SPAWN_SERVER=1
if [[ -n "$SERVER_OVERRIDE" ]]; then
  HOST=${SERVER_OVERRIDE%:*}
  PORT=${SERVER_OVERRIDE##*:}
  SPAWN_SERVER=0
elif [[ -n "$CLIENT_FROM" ]]; then
  HOST=$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1)
  if [[ -z "$HOST" ]]; then
    echo "[fail] could not determine local LAN IP for --client-from"; exit 2
  fi
fi

ROOT=$(mktemp -d -t tftp-burst.XXXXXX)
WORK_DIR=$(mktemp -d -t tftp-burst-work.XXXXXX)

cleanup() {
  rm -rf "$ROOT" "$WORK_DIR"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# A small asset keeps each transfer cheap (10 blocks at default
# blksize=512); the test stresses concurrent fan-out, not
# per-transfer throughput.
ASSET="numbers.txt"
SRC="$REPO/assets/$ASSET"
if [[ ! -f "$SRC" ]]; then
  echo "[fail] missing source asset: $SRC"
  exit 1
fi

EXPECTED=$(python3 -c "import json; print(json.load(open('assets.json'))['$ASSET'])")

echo "[setup] target=$HOST:$PORT root=$ROOT concurrent=$CONCURRENT spawn_server=$SPAWN_SERVER client_from=${CLIENT_FROM:-local}"

if [[ "$SPAWN_SERVER" = "1" ]]; then
  setsid jag run -d host "$REPO/examples/server-host.toit" -- \
      --root="$ROOT" --port="$PORT" --allow-overwrite \
      > "$WORK_DIR/server.log" 2>&1 &
  SERVER_PID=$!

  for i in $(seq 1 100); do
    if grep -q "tftp server listening" "$WORK_DIR/server.log" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[fail] server did not start; log:"
    cat "$WORK_DIR/server.log"
    exit 1
  fi
fi

# Run a single atftp put. In remote mode, dispatch via ssh; the
# remote box reads the source from $REMOTE_ASSET_DIR.
do_put() {
  local idx=$1
  local remote_name="burst-$idx.bin"
  local errfile="$WORK_DIR/atftp-${idx}.err"
  if [[ -n "$CLIENT_FROM" ]]; then
    ssh -n -o BatchMode=yes "$CLIENT_FROM" \
      "atftp --put --local-file '$REMOTE_ASSET_DIR/$ASSET' \
             --remote-file '$remote_name' \
             '$HOST' '$PORT'" 2>"$errfile"
  else
    atftp --put --local-file "$SRC" --remote-file "$remote_name" \
          "$HOST" "$PORT" 2>"$errfile"
  fi
}

echo "[test] launching $CONCURRENT parallel puts"
PIDS=()
for i in $(seq 1 "$CONCURRENT"); do
  do_put "$i" &
  PIDS+=($!)
done

put_failures=0
for idx in "${!PIDS[@]}"; do
  pid=${PIDS[$idx]}
  if ! wait "$pid"; then
    put_failures=$((put_failures + 1))
    echo "[fail] put $((idx + 1)) exited non-zero; atftp stderr:"
    sed 's/^/        /' "$WORK_DIR/atftp-$((idx + 1)).err" || true
  fi
done

# Verify sha256 of every landed file (only when we control the
# server's storage).
sha_failures=0
if [[ "$SPAWN_SERVER" = "1" ]]; then
  for i in $(seq 1 "$CONCURRENT"); do
    landed="$ROOT/burst-$i.bin"
    if [[ ! -f "$landed" ]]; then
      echo "[fail] burst-$i.bin missing in server root"
      sha_failures=$((sha_failures + 1))
      continue
    fi
    computed=$(sha256sum "$landed" | awk '{print $1}')
    if [[ "$computed" != "$EXPECTED" ]]; then
      echo "[fail] burst-$i.bin sha256 mismatch (expected=$EXPECTED got=$computed)"
      sha_failures=$((sha_failures + 1))
    fi
  done
else
  echo "[note] --server mode: skipping local sha verification (server root not on this host)"
fi

total_failures=$((put_failures + sha_failures))
echo
if [[ "$total_failures" -eq 0 ]]; then
  echo "[ok]   $CONCURRENT/$CONCURRENT burst puts succeeded"
  exit 0
else
  echo "[summary] $((CONCURRENT - put_failures))/$CONCURRENT puts succeeded; $sha_failures sha mismatches"
  exit 1
fi
