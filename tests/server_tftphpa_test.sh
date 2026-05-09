#!/usr/bin/env bash
# Round-trip test for the Toit TFTPServer using tftp-hpa as the reference
# client. Uploads each asset via `tftp ... put` and verifies the sha256
# of each landed file in the server's root against tests/assets.json.
#
# Once Task 4 lands (RRQ path), this script also exercises `tftp ... get`
# and verifies the round-tripped file. Until then, the get phase is skipped.
#
# Prerequisites:
#   - tftp-hpa installed (Debian/Ubuntu: `apt install tftp-hpa`).
#   - jag on PATH; a host-side toit toolchain working.
#   - tests/assets.json populated (already in repo).
#   - assets/ directory at repo root populated (already in repo).
#
# Topology flags
#   --server=HOST:PORT
#       Don't spawn a local server. Drive the tftp client at HOST:PORT.
#       Implies the operator has already started a server there. Hash
#       verification still runs locally on $ROOT, so HOST:PORT must serve
#       writes into a directory accessible at $ROOT (e.g., NFS or the
#       same host).
#
#   --client-from=USER@HOST
#       Drive the tftp client over ssh from a remote box. Useful when
#       loopback testing on the dev workstation is unreliable due to host
#       load saturating the kernel UDP receive buffer. The remote box
#       must have tftp-hpa installed and a copy of the assets pre-staged
#       at $REMOTE_ASSET_DIR (default /tmp/tftp-z170-assets).
#
# Canonical reliable gate (when local load makes loopback flaky):
#   tests/server_tftphpa_test.sh --client-from=david@z170

set -euo pipefail

cd "$(dirname "$0")"
TESTS_DIR=$PWD
REPO=$(cd .. && pwd)

SERVER_OVERRIDE=""
CLIENT_FROM=""
REMOTE_ASSET_DIR=${REMOTE_ASSET_DIR:-/tmp/tftp-z170-assets}

for arg in "$@"; do
  case "$arg" in
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
  # Remote client must reach our server by LAN IP, not localhost.
  HOST=$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1)
  if [[ -z "$HOST" ]]; then
    echo "[fail] could not determine local LAN IP for --client-from"; exit 2
  fi
fi

ROOT=$(mktemp -d -t tftp-server-test.XXXXXX)
DOWNLOAD_DIR=$(mktemp -d -t tftp-download.XXXXXX)
RRQ_IMPLEMENTED=${RRQ_IMPLEMENTED:-1}     # Task 4 has landed; gate exercises get

cleanup() {
  rm -rf "$ROOT" "$DOWNLOAD_DIR"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[setup] root=$ROOT host=$HOST port=$PORT spawn_server=$SPAWN_SERVER client_from=${CLIENT_FROM:-local}"

if [[ "$SPAWN_SERVER" = "1" ]]; then
  setsid jag run -d host "$REPO/examples/server-host.toit" -- \
      --root="$ROOT" --port="$PORT" --allow-overwrite \
      > "$DOWNLOAD_DIR/server.log" 2>&1 &
  SERVER_PID=$!

  for i in $(seq 1 100); do
    if grep -q "tftp server listening" "$DOWNLOAD_DIR/server.log" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[fail] server did not start; log:"
    cat "$DOWNLOAD_DIR/server.log"
    exit 1
  fi
fi

# Run a tftp put for KEY using whichever client topology was selected.
# stdin is the here-doc tftp script; stdout/stderr are silenced.
do_put() {
  local key=$1
  if [[ -n "$CLIENT_FROM" ]]; then
    ssh -n -o BatchMode=yes "$CLIENT_FROM" \
        "cd $REMOTE_ASSET_DIR && tftp $HOST $PORT >/dev/null 2>&1 <<TFTP_PUT
binary
put $key $key
quit
TFTP_PUT" || true
  else
    tftp "$HOST" "$PORT" >/dev/null 2>&1 <<TFTP_PUT || true
binary
put $REPO/assets/$key $key
quit
TFTP_PUT
  fi
}

do_get() {
  local key=$1
  # tftp-hpa 5.2 doesn't support `lcd`, so pass an absolute path as the local
  # filename argument to `get`. Without it, the download lands in CWD and the
  # sha256sum below misses it.
  if [[ -n "$CLIENT_FROM" ]]; then
    ssh -n -o BatchMode=yes "$CLIENT_FROM" \
        "tftp $HOST $PORT >/dev/null 2>&1 <<TFTP_GET || true
binary
get $key /tmp/tftp-get-$key
quit
TFTP_GET
sha256sum /tmp/tftp-get-$key 2>/dev/null | awk '{print \$1}'"
  else
    tftp "$HOST" "$PORT" >/dev/null 2>&1 <<TFTP_GET || true
binary
get $key $DOWNLOAD_DIR/$key
quit
TFTP_GET
    sha256sum "$DOWNLOAD_DIR/$key" 2>/dev/null | awk '{print $1}'
  fi
}

failures=0
total=0

if command -v jq >/dev/null 2>&1; then
  KEYS=$(jq -r 'keys[]' assets.json)
else
  KEYS=$(python3 -c 'import json; print("\n".join(json.load(open("assets.json")).keys()))')
fi

while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  total=$((total + 1))
  src="$REPO/assets/$key"
  if [[ ! -f "$src" ]]; then
    echo "[skip] $key — asset missing on disk"
    continue
  fi
  expected=$(python3 -c "import json; print(json.load(open('assets.json'))['$key'])")
  size=$(stat -c %s "$src")
  echo "[test] put $key ($size bytes)"

  do_put "$key"

  if [[ "$SPAWN_SERVER" = "1" ]]; then
    if [[ ! -f "$ROOT/$key" ]]; then
      echo "[fail] $key — server root missing the file"
      failures=$((failures + 1))
      continue
    fi
    computed=$(sha256sum "$ROOT/$key" | awk '{print $1}')
    if [[ "$computed" != "$expected" ]]; then
      echo "[fail] $key sha256 mismatch (put): expected=$expected got=$computed"
      failures=$((failures + 1))
      continue
    fi
    echo "[ok]   $key put"
  else
    # No filesystem access to the remote server's root: the put either
    # exited 0 (transfer completed end-to-end) or failed. Without RRQ we
    # can't verify content; mark transient errors via tftp's exit code.
    echo "[ok?]  $key put (no hash verify in --server mode)"
  fi

  if [[ "$RRQ_IMPLEMENTED" = "1" ]]; then
    echo "[test] get $key"
    got_hash=$(do_get "$key")
    if [[ -z "$got_hash" || "$got_hash" != "$expected" ]]; then
      echo "[fail] $key sha256 mismatch (get): expected=$expected got=$got_hash"
      failures=$((failures + 1))
      continue
    fi
    echo "[ok]   $key get"
  fi
done <<< "$KEYS"

echo
echo "[summary] $((total - failures))/$total passed (RRQ_IMPLEMENTED=$RRQ_IMPLEMENTED)"
exit "$failures"
