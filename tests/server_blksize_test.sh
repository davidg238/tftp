#!/usr/bin/env bash
# Round-trip test for RFC 2347/2348 option negotiation. Drives the Toit
# TFTPServer with `atftp --option "blksize <N>"` for both put and get,
# and verifies the round-tripped file matches the asset's recorded
# sha256.
#
# Why atftp and not tftp-hpa: tftp-hpa 5.2 has no `--option` flag and
# its interactive command list does not include any blksize/option
# primitive, so it can't drive RFC 2347 negotiation at all. atftp is
# the only common Linux client that exposes options on the command
# line.
#
# Prerequisites:
#   - atftp installed (Debian/Ubuntu: `apt install atftp`).
#   - jag on PATH; a host-side toit toolchain working.
#   - tests/assets.json populated.
#
# Topology flags
#   --server=HOST:PORT
#       Don't spawn a local server. Drive atftp at HOST:PORT.
#       Hash verification still runs locally on $ROOT, so HOST:PORT
#       must serve writes into a directory accessible at $ROOT.
#
#   --client-from=USER@HOST
#       Drive atftp over ssh from a remote box (matches the round-trip
#       gate's pattern). The remote box must have atftp installed and
#       the asset pre-staged at $REMOTE_ASSET_DIR
#       (default /tmp/tftp-z170-assets).

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

ROOT=$(mktemp -d -t tftp-blksize-test.XXXXXX)
DOWNLOAD_DIR=$(mktemp -d -t tftp-blksize-dl.XXXXXX)

cleanup() {
  rm -rf "$ROOT" "$DOWNLOAD_DIR"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Block sizes to exercise:
#   100  — OpenThread / 6LoWPAN realism (single 6LoWPAN frame minus
#          IPv6+UDP headers leaves ~92-100 byte payload)
#   1428 — Ethernet-friendly (1500 MTU minus IPv4+UDP headers)
#   8192 — large block size, exercises the upper end
# All three keep the 1 MB asset under the 16-bit block-number ceiling
# (1068158/100 ≈ 10682 < 65535). Smaller values + 1 MB asset would
# stuff the local UDP receive buffer faster than Toit can drain
# under loopback (the same rmem flake seen on tests/server_tftphpa
# when run locally), so prefer --client-from=USER@HOST for low values.
BLKSIZES=(100 1428 8192)

# A single 1 MB asset is enough to exercise multi-block transfer at
# any of the chosen block sizes without becoming flaky on rmem.
ASSET="sample-png-image_1mb.png"
SRC="$REPO/assets/$ASSET"

if [[ ! -f "$SRC" ]]; then
  echo "[fail] $ASSET missing on disk at $SRC" >&2
  exit 1
fi

EXPECTED=$(python3 -c "import json; print(json.load(open('assets.json'))['$ASSET'])")

echo "[setup] root=$ROOT host=$HOST port=$PORT spawn_server=$SPAWN_SERVER asset=$ASSET"

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

failures=0
total=0

# Run a single atftp put with the given blksize. Captures atftp's
# --trace output to $errfile so the caller can assert OACK was
# received with the correct blksize (otherwise atftp silently falls
# back to default 512 on a server that ignores options, which would
# let a broken server pass byte-level checks).
do_put() {
  local bs=$1 remote_name=$2 errfile=$3
  if [[ -n "$CLIENT_FROM" ]]; then
    ssh -n -o BatchMode=yes "$CLIENT_FROM" \
      "atftp --trace --option 'blksize $bs' \
             --put --local-file '$REMOTE_ASSET_DIR/$ASSET' \
             --remote-file '$remote_name' \
             '$HOST' '$PORT'" 2>"$errfile"
  else
    atftp --trace --option "blksize $bs" \
          --put --local-file "$SRC" --remote-file "$remote_name" \
          "$HOST" "$PORT" 2>"$errfile"
  fi
}

do_get_to() {
  local bs=$1 remote_name=$2 local_name=$3 errfile=$4
  if [[ -n "$CLIENT_FROM" ]]; then
    ssh -n -o BatchMode=yes "$CLIENT_FROM" \
      "rm -f '/tmp/$remote_name' && \
       atftp --trace --option 'blksize $bs' \
             --get --remote-file '$remote_name' \
             --local-file '/tmp/$remote_name' \
             '$HOST' '$PORT'" 2>"$errfile" || return $?
    scp -q "$CLIENT_FROM:/tmp/$remote_name" "$local_name" 2>>"$errfile"
  else
    atftp --trace --option "blksize $bs" \
          --get --remote-file "$remote_name" --local-file "$local_name" \
          "$HOST" "$PORT" 2>"$errfile"
  fi
}

# Confirm atftp actually negotiated the blksize: its --trace stderr
# logs `received OACK <blksize: N, ...>` on success. Anything else
# (no OACK, OACK without blksize, OACK with a different blksize)
# means the server didn't honor the option.
assert_oack_blksize() {
  local bs=$1 errfile=$2 phase=$3
  if ! grep -q "received OACK <blksize: $bs" "$errfile"; then
    echo "[fail] $phase blksize=$bs: expected OACK with blksize=$bs in atftp trace"
    echo "       --- relevant trace lines ---"
    grep -E "OACK|blksize" "$errfile" | sed 's/^/       /'
    return 1
  fi
  return 0
}

for bs in "${BLKSIZES[@]}"; do
  total=$((total + 2))  # one put + one get per blksize
  remote_name="bs${bs}-${ASSET}"

  put_err="$DOWNLOAD_DIR/atftp-put-${bs}.err"
  echo "[test] put $remote_name with blksize=$bs"
  if ! do_put "$bs" "$remote_name" "$put_err"; then
    echo "[fail] put blksize=$bs failed; atftp stderr:"
    cat "$put_err"
    failures=$((failures + 1))
    continue
  fi
  if ! assert_oack_blksize "$bs" "$put_err" "put"; then
    failures=$((failures + 1))
    continue
  fi
  if [[ "$SPAWN_SERVER" = "1" ]]; then
    computed=$(sha256sum "$ROOT/$remote_name" | awk '{print $1}')
    if [[ "$computed" != "$EXPECTED" ]]; then
      echo "[fail] blksize=$bs put: sha256 mismatch (expected=$EXPECTED got=$computed)"
      failures=$((failures + 1))
      continue
    fi
  fi
  echo "[ok]   put blksize=$bs (OACK echoed, sha matches)"

  local_name="$DOWNLOAD_DIR/bs${bs}-${ASSET}"
  get_err="$DOWNLOAD_DIR/atftp-get-${bs}.err"
  echo "[test] get $remote_name with blksize=$bs"
  if ! do_get_to "$bs" "$remote_name" "$local_name" "$get_err"; then
    echo "[fail] get blksize=$bs failed; atftp stderr:"
    cat "$get_err"
    failures=$((failures + 1))
    continue
  fi
  if ! assert_oack_blksize "$bs" "$get_err" "get"; then
    failures=$((failures + 1))
    continue
  fi
  computed=$(sha256sum "$local_name" | awk '{print $1}')
  if [[ "$computed" != "$EXPECTED" ]]; then
    echo "[fail] blksize=$bs get: sha256 mismatch (expected=$EXPECTED got=$computed)"
    failures=$((failures + 1))
    continue
  fi
  echo "[ok]   get blksize=$bs (OACK echoed, sha matches)"
done

echo
echo "[summary] $((total - failures))/$total passed"
exit "$failures"
