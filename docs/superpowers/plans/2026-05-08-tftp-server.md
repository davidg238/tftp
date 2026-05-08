# TFTP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land `TFTPServer` in this package, complementing the existing `TFTPClient`. Server supports both RRQ and WRQ, full RFC 2347/2348/2349 option negotiation, `Storage`-backed I/O, bounded concurrency, and `Storage`-error mapping per the spec.

**Architecture:** One listen socket on `:69` accepts initial RRQ/WRQ datagrams. Each request spawns a Toit task on its own ephemeral UDP socket; an abstract `Exchange` base class (extracted from `ClientExchange`) drives the per-transfer state machine. Subclasses fill in direction-specific frame building and packet handling.

**Tech Stack:** Toit (Toit conventions: `kebab-case` for vars/funcs, `PascalCase` for classes, `KEBAB-CASE` for constants, `_` suffix for private). `monitor.Semaphore` for concurrency cap. `log.Logger` for observability (matches MQTT broker convention). External tests: bash + `atftp` reference client.

**Spec:** `docs/superpowers/specs/2026-05-08-tftp-server-design.md`

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `src/exchange.toit` | new | `abstract class Exchange` — shared per-transfer state machine, retry/cache, TID enforcement, OACK validation |
| `src/tftp_client.toit` | modified | `ClientExchange` extends `Exchange`; removes duplicated logic |
| `src/tftp_server.toit` | new | `TFTPServer` (listen loop, dispatcher, semaphore) and `ServerExchange` (per-transfer) |
| `src/tftp.toit` | modified | `import .tftp-server` + `export *` |
| `examples/server-host.toit` | new | runnable server binary; takes `--root`, `--port`, `--max-concurrent` |
| `tests/server_atftpd_test.sh` | new | round-trip smoke (atftp put + get + sha256) |
| `tests/server_atftpd_blksize_test.sh` | new | OACK negotiation via `atftp --option "blksize 1428"` |
| `tests/server_burst_test.sh` | new | N parallel atftp puts; `--server` flag for local or remote target |
| `CHANGELOG.md` | modified | new entry for the server release |
| `README.md` | modified | server section + atftp prerequisite + port-69 caveat |

The implementation order is one commit per task. Each task ends with a passing test gate (or a clean compile when no test applies yet).

---

## Test gate notes

The existing client tests (`tests/roundtrip_test.toit`, `large_transfer_test.toit`, etc.) run against an external `tftp-go` server. They are the gate during the refactor. The plan's commands assume `tftp-go` is running locally on `127.0.0.1:69` rooted at `../assets` (per the README). If the engineer doesn't have it running, the commands to start it are:

```bash
cd ~/apps/tftp-go && sudo ./tftp-go -root ~/workspaceToit/tftp/assets -ow -server &
```

The server binary the new tests build (`examples/server-host.toit`) does *not* need root because it binds to `:6969`.

---

## Task 1: Extract abstract `Exchange` base from `ClientExchange`

**Files:**
- Create: `src/exchange.toit`
- Modify: `src/tftp_client.toit` (replace `ClientExchange` definition with one that extends `Exchange`)

**Goal:** Behavior-preserving refactor. Existing tests against `tftp-go` stay green. No new behavior.

- [ ] **Step 1: Pre-flight — verify existing tests pass before any change**

Run the existing client suite as the green baseline. `tftp-go` must be running on `127.0.0.1:69`.

```bash
cd /home/david/workspaceToit/tftp/tests
jag run -d host roundtrip_test.toit
```

Expected: `All ... assets round-tripped with matching SHA256.` (Last line of test output.)

If this baseline fails, stop and fix the environment before proceeding — the refactor's gate depends on this passing afterwards.

- [ ] **Step 2: Create `src/exchange.toit`**

```toit
// Copyright 2026 Ekorau LLC.

import io
import log
import monitor
import net
import net.udp

import .packets

/**
Abstract per-transfer state machine for the TFTP client and server.

Owns the wire-level state shared by both sides: the UDP socket, the locked
  peer transfer ID (TID), the block counter, the cached frame for
  retransmission on timeout, and the retry counter. Subclasses provide the
  direction-specific frame building ($next-frame) and packet handling
  ($handle).

# Block-number range
TFTP block numbers are unsigned 16-bit, so a single transfer is limited to
  $MAX-BLOCK-NUM_ blocks. Subclasses convert overflow into an appropriate
  TFTP error.
*/

/** Default per-receive timeout, in milliseconds. */
DEFAULT-TIMEOUT-MS_ ::= 1_000

/** Maximum retransmissions before giving up on a packet. */
MAX-TRIES_ ::= 12

/** Maximum block number that fits in the 16-bit block field. */
MAX-BLOCK-NUM_ ::= 0xFFFF

abstract class Exchange:
  socket_/udp.Socket
  logger_/log.Logger
  peer-tid_/net.SocketAddress? := null
  opcode_/int := -1
  block-num_/int := 0
  tries_/int := 0
  drained_/bool := false
  blksize_/int := DEFAULT-BLKSIZE
  cached_/ByteArray := #[]
  /** Options that were sent in the most recent RRQ/WRQ (client) or echoed in OACK (server). */
  requested-options_/Map? := null

  constructor .socket_ .logger_:

  /**
  Returns the next outbound frame.

  Called when $tries_ is 0 (build a fresh frame) or > 0 (retransmit
    $cached_). Subclasses decide the payload based on $opcode_.
  */
  abstract next-frame -> ByteArray

  /**
  Reacts to an incoming $received packet.

  Subclasses update $opcode_, $block-num_, $tries_ and $drained_ as
    appropriate, or set $opcode_ to $EXIT to terminate the loop.
  */
  abstract handle received/Packet -> none

  /**
  Whether $source is acceptable as a peer source.

  Called from $receive_ before $peer-tid_ is locked. Default returns true;
    the client overrides to check that $source.ip matches the resolved
    server IP, rejecting datagrams from any other IP as part of RFC 1350
    §4 TID enforcement.
  */
  is-acceptable-source_ source/net.SocketAddress -> bool:
    return true

  /** Drives the exchange to completion. */
  drive_ -> none:
    while opcode_ != EXIT:
      send_ next-frame
      handle receive_

  /** Sends $payload to $peer-tid_. */
  send_ payload/ByteArray -> none:
    socket_.send (udp.Datagram payload peer-tid_)

  /**
  Receives the next packet relevant to this transfer.

  Datagrams from end-points other than the locked $peer-tid_ are answered
    with TFTP error 5 ("Unknown transfer ID") and skipped, as required by
    RFC 1350 §4. Returns $PacketTIMEOUT if no relevant datagram arrives
    within $DEFAULT-TIMEOUT-MS_.
  */
  receive_ -> Packet:
    deadline-us := Time.monotonic-us + DEFAULT-TIMEOUT-MS_ * 1000
    while true:
      remaining-us := deadline-us - Time.monotonic-us
      if remaining-us <= 0: return PacketTIMEOUT
      msg/udp.Datagram? := null
      err := catch:
        with-timeout --us=remaining-us:
          msg = socket_.receive
      if err == DEADLINE-EXCEEDED-ERROR or msg == null:
        return PacketTIMEOUT
      if err != null:
        throw err
      if peer-tid_ == null:
        if not is-acceptable-source_ msg.address:
          send-unknown-tid_ msg.address
          continue
        peer-tid_ = msg.address
      else if msg.address != peer-tid_:
        send-unknown-tid_ msg.address
        continue
      packet := Packet.deserialize (io.Reader msg.data)
      if packet == null: continue
      return packet

  send-unknown-tid_ source/net.SocketAddress -> none:
    err := PacketERROR 5 "Unknown transfer ID"
    socket_.send (udp.Datagram err.serialize source)

  retry-or-abort_ -> none:
    tries_++
    if tries_ >= MAX-TRIES_:
      opcode_ = EXIT
      throw "TFTP: timed out at block $block-num_ after $MAX-TRIES_ retries"

  /**
  Forces the next outbound send to reuse $cached_ instead of building a
    fresh frame.
  */
  schedule-retransmit_ -> none:
    if tries_ == 0: tries_ = 1

  exit-error_ err/PacketERROR -> none:
    opcode_ = EXIT
    throw "TFTP: peer error $err.error-code at block $block-num_: $err.resolved-msg"

  /**
  Applies a server's OACK to local state on the client side, or validates
    a client's options for OACK construction on the server side.

  Validates that no OACK option was returned without being requested
    (RFC 2347 §3) and that any blksize is in range and not greater than
    requested.
  */
  apply-oack_ oack/PacketOACK -> none:
    requested := requested-options_ or {:}
    oack.options.do: | name/string value/string |
      if not requested.contains name:
        throw "TFTP: peer returned unrequested option '$name'"
      if name == OPT-BLKSIZE:
        n := int.parse value
        if not MIN-BLKSIZE <= n <= MAX-BLKSIZE:
          throw "TFTP: peer negotiated blksize $n out of range"
        requested-blksize := int.parse requested[OPT-BLKSIZE]
        if n > requested-blksize:
          throw "TFTP: peer raised blksize from $requested-blksize to $n"
        blksize_ = n
      else if name == OPT-TSIZE:
        on-tsize_ (int.parse value)
      else if name == OPT-TIMEOUT:
        // Negotiated timeout is informational; the underlying receive
        // timeout is fixed at DEFAULT-TIMEOUT-MS_ for predictable retry.

  /**
  Hook called when an OACK reports a tsize value.

  Default does nothing. The client overrides to record the value for
    user inspection.
  */
  on-tsize_ value/int -> none:
```

- [ ] **Step 3: Modify `src/tftp_client.toit` — make `ClientExchange` extend `Exchange`**

Replace the entire `ClientExchange` class (currently lines 332-553 of `src/tftp_client.toit`) with the version below. Keep everything before line 332 (the `TFTPClient` class) unchanged for now.

Also remove the now-redundant constants and methods from `TFTPClient`:
- Delete the `DEFAULT-TIMEOUT-MS_` and `MAX-TRIES_` constants (now in `exchange.toit`).
- Delete `TFTPClient.send_`, `TFTPClient.receive_`, `TFTPClient.is-from-server_`, `TFTPClient.send-unknown-tid_` — they move into `Exchange`.
- Delete the `server-tid_` field on `TFTPClient` — it moves into `Exchange.peer-tid_`.

Additionally, add a top-of-file import:

```toit
import .exchange
```

The new `ClientExchange`:

```toit
/**
State machine driving a single TFTP request/response exchange initiated by
  the client. Inherits the shared loop, retry, and TID-enforcement logic
  from $Exchange.
*/
class ClientExchange extends Exchange:
  client_/TFTPClient

  constructor .client_/TFTPClient:
    super client_.socket_ client_.logger_

  /** Drives a write (WRQ) exchange to completion. */
  start-with-wrq -> none:
    opcode_ = WRQ
    block-num_ = 0
    tries_ = 0
    drained_ = false
    blksize_ = DEFAULT-BLKSIZE
    requested-options_ = client_.build-options_ --is-write
    drive_

  /** Drives a read (RRQ) exchange to completion. */
  start-with-rrq -> none:
    opcode_ = RRQ
    block-num_ = 1
    tries_ = 0
    drained_ = false
    blksize_ = DEFAULT-BLKSIZE
    requested-options_ = client_.build-options_ --no-is-write
    drive_

  is-acceptable-source_ source/net.SocketAddress -> bool:
    return source.ip == client_.host-ip_

  on-tsize_ value/int -> none:
    client_.last-tsize_ = value

  next-frame -> ByteArray:
    if tries_ > 0: return cached_
    if opcode_ == WRQ: return wrq-frame_
    if opcode_ == RRQ: return rrq-frame_
    if opcode_ == DATA: return next-data-frame_
    if opcode_ == ACK: return ack-frame_
    return (PacketERROR 0 "Invalid opcode: $opcode_").serialize

  handle received/Packet -> none:
    if received.opcode == ERROR:
      exit-error_ (received as PacketERROR)
      return
    if received.opcode == TIMEOUT:
      retry-or-abort_
      return
    if opcode_ == WRQ:
      handle-write_ received
      return
    if opcode_ == DATA:
      handle-write_ received
      return
    if opcode_ == RRQ or opcode_ == ACK:
      handle-read_ received
      return

  // ---- write side ---------------------------------------------------------

  wrq-frame_ -> ByteArray:
    options := requested-options_ or {:}
    cached_ = (PacketWRQ client_.filename_ client_.mode_ --options=options).serialize
    return cached_

  next-data-frame_ -> ByteArray:
    chunk := client_.bytes-to-send_ blksize_
    if chunk.size < blksize_: drained_ = true
    cached_ = (PacketDATA block-num_ chunk).serialize
    client_.bytes-written_ chunk.size
    return cached_

  handle-write_ received/Packet -> none:
    if opcode_ == WRQ and received.opcode == OACK:
      apply-oack_ (received as PacketOACK)
      // Per RFC 2347, treat OACK as if it were ACK 0 for a WRQ.
      opcode_ = DATA
      block-num_ = 1
      tries_ = 0
      return
    if opcode_ == WRQ and received.opcode == ACK:
      start-writing_ (received as PacketACK)
      return
    if opcode_ == DATA and received.opcode == ACK:
      keep-writing_ (received as PacketACK)
      return
    schedule-retransmit_

  start-writing_ ack/PacketACK -> none:
    if ack.block-num != 0:
      throw "TFTP: invalid ACK block-num $ack.block-num for WRQ (expected 0)"
    opcode_ = DATA
    block-num_ = 1
    tries_ = 0

  keep-writing_ ack/PacketACK -> none:
    if ack.block-num != block-num_:
      schedule-retransmit_
      return
    if drained_:
      opcode_ = EXIT
      return
    next := block-num_ + 1
    if next > MAX-BLOCK-NUM_:
      throw "TFTP: block number would exceed $MAX-BLOCK-NUM_; file too large for negotiated block size"
    block-num_ = next
    tries_ = 0

  // ---- read side ----------------------------------------------------------

  rrq-frame_ -> ByteArray:
    options := requested-options_ or {:}
    cached_ = (PacketRRQ client_.filename_ client_.mode_ --options=options).serialize
    return cached_

  ack-frame_ -> ByteArray:
    cached_ = (PacketACK block-num_).serialize
    block-num_ += 1
    tries_ = 0
    return cached_

  handle-read_ received/Packet -> none:
    if opcode_ == RRQ and received.opcode == OACK:
      apply-oack_ (received as PacketOACK)
      // Per RFC 2347, ACK block 0 to confirm the OACK, then expect DATA 1.
      opcode_ = ACK
      block-num_ = 0
      tries_ = 0
      return
    if received.opcode == DATA:
      handle-data_ (received as PacketDATA)
      return
    schedule-retransmit_

  handle-data_ data/PacketDATA -> none:
    if data.block-num == block-num_:
      if data.data.size < blksize_: drained_ = true
      client_.bytes-received_ data.data
      tries_ = 0
      opcode_ = ACK
      if drained_:
        send_ ack-frame_
        opcode_ = EXIT
      return
    if data.block-num < block-num_:
      if cached_.size > 0: schedule-retransmit_
      return
    schedule-retransmit_
```

- [ ] **Step 4: Update the call sites in `TFTPClient`**

Replace `exchange.read` / `exchange.write` calls (currently at lines 188 and 207 of `tftp_client.toit`) with `exchange.start-with-wrq` and `exchange.start-with-rrq`:

```toit
// In write-stream:
try:
  exchange := ClientExchange this
  exchange.start-with-wrq
finally:
  reset-state_
```

```toit
// In read-bytes:
try:
  exchange := ClientExchange this
  exchange.start-with-rrq
  return buffer_.bytes
finally:
  reset-state_
```

```toit
// In read:
try:
  exchange := ClientExchange this
  exchange.start-with-rrq
finally:
  reset-state_
```

Also: `TFTPClient` needs a `logger_` field for the new `ClientExchange` `super` call. Add to the class:

```toit
logger_/log.Logger
```

Add `--logger/log.Logger=log.default` to the `TFTPClient` constructor's named parameters and assign `logger_ = logger`. Also add `import log` at the top of the file.

`TFTPClient.reset-state_` no longer touches `server-tid_` (gone). Update it to:

```toit
reset-state_ -> none:
  reader_ = null
  writer_ = null
  buffer_ = null
  filename_ = null
  streaming-reads_ = false
  pending-tsize_ = null
  blksize_ = DEFAULT-BLKSIZE
```

- [ ] **Step 5: Compile cleanly**

```bash
cd /home/david/workspaceToit/tftp
jag compile src/tftp.toit
```

Expected: No errors.

If errors appear, fix them before proceeding. Common likely errors after this step:
- Field references to `server-tid_` or `socket_.send` left over in `TFTPClient` — should now be in `Exchange`.
- Reference to `DEFAULT-TIMEOUT-MS_` from inside `TFTPClient` — now lives in `exchange.toit` (re-import or move inline if needed).

- [ ] **Step 6: Run existing tests against `tftp-go` to confirm no regression**

```bash
cd /home/david/workspaceToit/tftp/tests
jag run -d host roundtrip_test.toit
```

Expected: Same `All ... assets round-tripped with matching SHA256.` line as Step 1.

Then the options test:

```bash
jag run -d host options_test.toit
```

Expected: same passing output as before this task started.

Then the large transfer:

```bash
jag run -d host large_transfer_test.toit
```

Expected: passes.

If any of these fail, the refactor introduced a regression. Diff against the pre-refactor version of `tftp_client.toit` and trace which moved method or field lost coverage.

- [ ] **Step 7: Commit**

```bash
git add src/exchange.toit src/tftp_client.toit
git commit -m "$(cat <<'EOF'
Extract abstract Exchange base from ClientExchange

Pulls the shared per-transfer state machine (UDP socket, peer-TID lock,
retry/cache, OACK validation, RFC 1350 §4 TID enforcement) into a new
abstract Exchange in src/exchange.toit. ClientExchange now extends it
and overrides next-frame, handle, and is-acceptable-source_.

No behavior change. All existing tftp-go round-trip tests pass.

Prepares for adding ServerExchange as a parallel subclass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add minimal `TFTPServer` skeleton + example + export

**Files:**
- Create: `src/tftp_server.toit`
- Create: `examples/server-host.toit`
- Modify: `src/tftp.toit`

**Goal:** A `TFTPServer` that binds, accepts datagrams, and replies to any RRQ/WRQ with `ERROR 4 "Server not yet implemented"` (placeholder until Task 3). This proves the listen loop and dispatcher work end-to-end.

- [ ] **Step 1: Create `src/tftp_server.toit` skeleton**

```toit
// Copyright 2026 Ekorau LLC.

import io
import log
import monitor
import net
import net.udp

import .exchange
import .packets
import .storage

/**
TFTP server.

Listens on a single UDP port (default 69) and accepts initial RRQ/WRQ
  datagrams. Each request spawns a $ServerExchange task running on its
  own ephemeral UDP socket, freeing the listen port for the next request
  immediately. Concurrent transfers run as concurrent tasks on
  independent ports — the standard TFTP server fan-out.

Storage is provided via the $Storage interface; bundled $FilesystemStorage
  serves a directory tree, separate packages can implement other backends
  (e.g. SqliteStorage in tftp-sqlite).

# Privileged port
On Linux, binding port 69 requires the CAP_NET_BIND_SERVICE capability or
  root. For testing and ESP32 deployments use a non-privileged port via
  `--port=`. The bundled `examples/server-host.toit` exposes a `--port`
  flag for this reason.

# IPv6
The current Toit SDK does not expose IPv6 listener support; the bound
  socket is IPv4. For IPv6/Thread deployments use NAT64 or a small relay
  on the border router; see `docs/thread-sqlite-deployment.md`.
*/
class TFTPServer:
  storage_/Storage
  port_/int
  max-concurrent_/int
  logger_/log.Logger

  network_/net.Interface? := null
  listen-socket_/udp.Socket? := null
  semaphore_/monitor.Semaphore? := null
  stopping_/bool := false

  /**
  Constructs a server that serves $storage on $port.

  $max-concurrent caps the number of in-flight transfers; new requests
    that arrive when the cap is hit receive a TFTP error 0 ("Server
    busy") and are dropped.
  $logger is used for transfer-level logging (matches the MQTT broker's
    convention of injecting a $log.Logger).
  */
  constructor
      --storage/Storage
      --port/int=TFTP-DEFAULT-PORT
      --max-concurrent/int=64
      --logger/log.Logger=log.default:
    storage_ = storage
    port_ = port
    max-concurrent_ = max-concurrent
    logger_ = logger

  /**
  Binds the listen socket and runs the dispatch loop.

  Blocks until $stop is called or a fatal listener error occurs.
  */
  start -> none:
    if listen-socket_ != null: throw "TFTP server already started"
    network_ = net.open
    listen-socket_ = network_.udp-open --port=port_
    semaphore_ = monitor.Semaphore --count=max-concurrent_
    logger_.info "tftp server listening" --tags={"port": port_}
    try:
      while not stopping_:
        msg/udp.Datagram? := null
        err := catch:
          msg = listen-socket_.receive
        if err != null:
          if stopping_: break
          logger_.warn "listen receive failed" --tags={"error": err}
          continue
        if msg == null: continue
        dispatch_ msg
    finally:
      if listen-socket_ != null:
        listen-socket_.close
        listen-socket_ = null
      if network_ != null:
        network_.close
        network_ = null
      stopping_ = false
      logger_.info "tftp server stopped"

  /** Closes the listen socket; $start returns. Idempotent. */
  stop -> none:
    if stopping_: return
    stopping_ = true
    if listen-socket_ != null:
      listen-socket_.close

  dispatch_ msg/udp.Datagram -> none:
    packet := Packet.deserialize (io.Reader msg.data)
    if packet is not PacketRRQ and packet is not PacketWRQ:
      err := PacketERROR 4 "Illegal TFTP operation"
      listen-socket_.send (udp.Datagram err.serialize msg.address)
      return
    if not semaphore_.try-down:
      err := PacketERROR 0 "Server busy"
      listen-socket_.send (udp.Datagram err.serialize msg.address)
      logger_.warn "rejected: max-concurrent reached" --tags={"peer": msg.address}
      return
    // Placeholder until Task 3.
    err := PacketERROR 4 "Server not yet implemented"
    listen-socket_.send (udp.Datagram err.serialize msg.address)
    semaphore_.up
```

- [ ] **Step 2: Create `examples/server-host.toit`**

```toit
// Copyright 2026 Ekorau LLC.

import cli
import host.directory
import host.file
import log
import tftp show FilesystemStorage TFTPServer

main args/List:
  cmd := cli.Command "tftp-server"
      --help="A TFTP server for host-side use."
      --options=[
        cli.Option "root"
            --help="Directory served as the TFTP root."
            --default="/tmp/tftp-server-test",
        cli.OptionInt "port"
            --help="UDP port to listen on. 69 needs root or cap_net_bind_service."
            --default=6969,
        cli.OptionInt "max-concurrent"
            --help="Maximum simultaneous transfers."
            --default=64,
        cli.Flag "allow-overwrite"
            --help="Permit clients to replace existing files."
            --default=true,
        cli.Flag "read-only"
            --help="Refuse all WRQ requests."
            --default=false,
      ]
      --run=:: serve it
  cmd.run args

serve invocation/cli.Invocation -> none:
  root := invocation["root"]
  port := invocation["port"]
  max-concurrent := invocation["max-concurrent"]
  allow-overwrite := invocation["allow-overwrite"]
  read-only := invocation["read-only"]
  if not file.is-directory root:
    catch: directory.mkdir --recursive root
  storage := FilesystemStorage
      --root=root
      --allow-overwrite=allow-overwrite
      --read-only=read-only
  server := TFTPServer
      --storage=storage
      --port=port
      --max-concurrent=max-concurrent
      --logger=log.default
  print "tftp-server: serving $root on UDP/$port (max-concurrent=$max-concurrent)"
  server.start
```

(If `cli` isn't already a dependency, the next step adds it.)

- [ ] **Step 3: Verify `cli` is available**

```bash
cd /home/david/workspaceToit/tftp/examples
cat package.yaml 2>/dev/null
```

If `package.yaml` does not list `cli` as a dependency, add it. The existing root `package.yaml` only lists `host`. The `cli` package ships with the SDK and may already be on the import path.

If `jag compile` later complains about `cli`, add to `package.yaml`:

```yaml
dependencies:
  cli:
    url: github.com/toitlang/pkg-cli
    version: ^2.0.0
  host:
    url: github.com/toitlang/pkg-host
    version: ^1.16.2
```

then `cd /home/david/workspaceToit/tftp && jag pkg install`.

- [ ] **Step 4: Re-export `TFTPServer` from `src/tftp.toit`**

Edit `src/tftp.toit` to be:

```toit
import .packets
import .sdcard
import .sha256-summer
import .storage
import .tftp-client
import .tftp-server

export *
```

(Adds the `import .tftp-server` line. `export *` was already there.)

- [ ] **Step 5: Compile cleanly**

```bash
cd /home/david/workspaceToit/tftp
jag compile src/tftp.toit
jag compile examples/server-host.toit
```

Expected: No errors.

- [ ] **Step 6: Smoke-test the binary**

```bash
cd /home/david/workspaceToit/tftp
jag run -d host examples/server-host.toit -- --port=6969 &
sleep 0.5
echo "--- atftp probe ---"
echo "test" > /tmp/probe.txt
atftp --put --local-file /tmp/probe.txt --remote-file probe.txt 127.0.0.1 6969 ; echo "exit=$?"
kill %1 2>/dev/null
wait 2>/dev/null
```

Expected:
- The Toit binary prints `tftp-server: serving /tmp/tftp-server-test on UDP/6969 ...`.
- `atftp` exits with `Server says: Server not yet implemented` (or similar — atftp may or may not echo the error message but will exit non-zero).
- The probe file does **not** appear in `/tmp/tftp-server-test/` (because Task 3 hasn't been written yet).

This proves the listen loop and dispatcher receive datagrams, decode them, and reply on the right path.

- [ ] **Step 7: Commit**

```bash
git add src/tftp_server.toit examples/server-host.toit src/tftp.toit
# also stage examples/package.yaml or root package.yaml if you modified for cli.
git commit -m "$(cat <<'EOF'
Add TFTPServer skeleton with listen loop and dispatcher

Binds a UDP socket on the configured port, decodes incoming opcodes, and
replies to non-RRQ/WRQ datagrams with TFTP error 4. Applies the
max-concurrent semaphore. RRQ/WRQ currently return a placeholder
"Server not yet implemented" error; ServerExchange lands in the next
commit.

Adds examples/server-host.toit as the runnable host binary used by the
new test scripts. Re-exports TFTPServer from src/tftp.toit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `ServerExchange` WRQ path + round-trip test (WRQ-only)

**Files:**
- Modify: `src/tftp_server.toit` (add `ServerExchange`; replace placeholder in `dispatch_`)
- Create: `tests/server_atftpd_test.sh`

**Goal:** A device can `atftp --put` a file to our server, the file lands in the storage backend, sha256 matches.

- [ ] **Step 1: Add `ServerExchange` (write side only) to `src/tftp_server.toit`**

Append this class to the end of `src/tftp_server.toit`:

```toit
/**
Per-transfer state machine running on a server-side ephemeral UDP socket.

Inherits the shared loop, retry, and TID-enforcement logic from $Exchange.
Direction-specific frame building and packet handling live here.
*/
class ServerExchange extends Exchange:
  storage_/Storage
  initial-/Packet                     // PacketRRQ or PacketWRQ
  source-/net.SocketAddress
  filename_/string
  mode_/string

  storage-writer_/io.Writer? := null
  storage-reader_/io.Reader? := null
  /** Set when $next-frame should send the OACK once and only once. */
  pending-oack_/PacketOACK? := null

  /**
  Builds an exchange for the request in $initial received from $source.

  Caller (the dispatcher) opens $socket as the per-transfer ephemeral
    socket. $storage is the shared backend.
  */
  constructor .initial- .source- .storage_ socket/udp.Socket logger/log.Logger:
    super socket logger
    if initial- is PacketRRQ:
      filename_ = (initial- as PacketRRQ).filename
      mode_ = (initial- as PacketRRQ).mode
    else:
      filename_ = (initial- as PacketWRQ).filename
      mode_ = (initial- as PacketWRQ).mode
    peer-tid_ = source-

  /** Drives the request to completion. Maps storage exceptions to TFTP errors. */
  run -> none:
    err := catch --trace=false:
      validate-request_
      if initial- is PacketWRQ:
        run-wrq_ (initial- as PacketWRQ)
      else:
        // RRQ path lands in Task 4.
        send-error_ 4 "RRQ not yet implemented"
    if err != null:
      handle-storage-error_ err

  validate-request_ -> none:
    if mode_ != OCTET:
      send-error_ 4 "Only octet mode supported"
      throw "validation: bad mode"
    if filename_.size == 0 or filename_.size > 128:
      send-error_ 4 "Bad filename length"
      throw "validation: bad filename length"

  run-wrq_ wrq/PacketWRQ -> none:
    tsize-hint := null
    if wrq.options.contains OPT-TSIZE:
      tsize-hint = int.parse wrq.options[OPT-TSIZE]
    storage-writer_ = storage_.writer-for filename_ --tsize-hint=tsize-hint
    // No options handling yet — send ACK 0 and start receiving DATA.
    opcode_ = WRQ
    block-num_ = 0
    tries_ = 0
    drained_ = false
    blksize_ = DEFAULT-BLKSIZE
    drive_

  /**
  Maps a thrown sentinel string from the $Storage backend (or other
    failure) to a TFTP error sent on the ephemeral socket.
  */
  handle-storage-error_ err -> none:
    if err == STORAGE-FILE-NOT-FOUND:
      send-error_ 1 "File not found"
    else if err == STORAGE-ACCESS-DENIED:
      send-error_ 2 "Access violation"
    else if err == STORAGE-NO-SPACE:
      send-error_ 3 "Disk full or allocation exceeded"
    else if err == STORAGE-FILE-EXISTS:
      send-error_ 6 "File already exists"
    else:
      send-error_ 0 "$err"
    logger_.warn "transfer failed" --tags={"error": err, "peer": source-}

  send-error_ code/int msg/string -> none:
    catch:
      err := PacketERROR code msg
      socket_.send (udp.Datagram err.serialize peer-tid_)

  next-frame -> ByteArray:
    if tries_ > 0: return cached_
    if pending-oack_ != null:
      cached_ = pending-oack_.serialize
      pending-oack_ = null
      return cached_
    if opcode_ == WRQ: return wrq-ack0-frame_
    if opcode_ == ACK: return ack-frame_
    return (PacketERROR 0 "Invalid opcode: $opcode_").serialize

  wrq-ack0-frame_ -> ByteArray:
    cached_ = (PacketACK 0).serialize
    return cached_

  ack-frame_ -> ByteArray:
    cached_ = (PacketACK block-num_).serialize
    return cached_

  handle received/Packet -> none:
    if received.opcode == ERROR:
      exit-error_ (received as PacketERROR)
      return
    if received.opcode == TIMEOUT:
      retry-or-abort_
      return
    if received.opcode == DATA:
      handle-data_ (received as PacketDATA)
      return
    schedule-retransmit_

  handle-data_ data/PacketDATA -> none:
    expected := block-num_ + 1
    if data.block-num == expected:
      storage-writer_.write data.data
      block-num_ = expected
      if data.data.size < blksize_: drained_ = true
      tries_ = 0
      opcode_ = ACK
      if drained_:
        // Commit before the final ACK; if close throws, the client must
        // not see success.
        commit-err := catch:
          storage-writer_.close
          storage-writer_ = null
        if commit-err != null:
          handle-storage-error_ commit-err
          opcode_ = EXIT
          return
        send_ ack-frame_
        opcode_ = EXIT
      return
    if data.block-num <= block-num_:
      // Duplicate — re-ACK the highest committed block.
      if cached_.size > 0: schedule-retransmit_
      return
    // Out of order ahead.
    schedule-retransmit_
```

- [ ] **Step 2: Replace the placeholder in `TFTPServer.dispatch_`**

Modify `dispatch_` in `src/tftp_server.toit` to spawn the per-transfer task instead of returning `ERROR 4`:

```toit
dispatch_ msg/udp.Datagram -> none:
  packet := Packet.deserialize (io.Reader msg.data)
  if packet is not PacketRRQ and packet is not PacketWRQ:
    err := PacketERROR 4 "Illegal TFTP operation"
    listen-socket_.send (udp.Datagram err.serialize msg.address)
    return
  if not semaphore_.try-down:
    err := PacketERROR 0 "Server busy"
    listen-socket_.send (udp.Datagram err.serialize msg.address)
    logger_.warn "rejected: max-concurrent reached" --tags={"peer": msg.address}
    return
  task::
    try:
      ephemeral := network_.udp-open
      try:
        exchange := ServerExchange packet msg.address storage_ ephemeral logger_
        exchange.run
      finally:
        ephemeral.close
    finally:
      semaphore_.up
```

(The `try / finally` chain ensures both the socket is closed and the semaphore is released even if the exchange throws.)

- [ ] **Step 3: Compile**

```bash
cd /home/david/workspaceToit/tftp
jag compile src/tftp.toit
jag compile examples/server-host.toit
```

Expected: clean.

- [ ] **Step 4: Create `tests/server_atftpd_test.sh`**

```bash
#!/usr/bin/env bash
# Round-trip test for the Toit TFTPServer using atftp as the reference
# client. Spawns examples/server-host.toit, uploads each asset via
# `atftp --put`, downloads it back via `atftp --get`, and verifies the
# sha256 against tests/assets.json.
#
# Prerequisites:
#   - atftp installed (Debian/Ubuntu: `apt install atftp`).
#   - jag on PATH; a host-side toit toolchain working.
#   - tests/assets.json populated (already in repo).

set -euo pipefail

cd "$(dirname "$0")"
TESTS_DIR=$PWD
REPO=$(cd .. && pwd)

PORT=${PORT:-6969}
ROOT=$(mktemp -d -t tftp-server-test.XXXXXX)
DOWNLOAD_DIR=$(mktemp -d -t tftp-download.XXXXXX)
trap 'rm -rf "$ROOT" "$DOWNLOAD_DIR"; if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi' EXIT

echo "[setup] root=$ROOT port=$PORT"

# Start the server in the background. Use `setsid` so kill cleans up the
# whole process group; jag may spawn helper processes.
setsid jag run -d host "$REPO/examples/server-host.toit" -- \
    --root="$ROOT" --port="$PORT" --allow-overwrite \
    > "$DOWNLOAD_DIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the listener to come up. Probe up to 5 seconds.
for i in $(seq 1 50); do
  if grep -q "tftp server listening" "$DOWNLOAD_DIR/server.log" 2>/dev/null \
      || grep -q "tftp-server: serving" "$DOWNLOAD_DIR/server.log" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "[fail] server did not start; log:"
  cat "$DOWNLOAD_DIR/server.log"
  exit 1
fi

failures=0
total=0

# Iterate over assets.json. Use jq if available; otherwise fall back to
# a python one-liner.
if command -v jq >/dev/null 2>&1; then
  KEYS=$(jq -r 'keys[]' assets.json)
else
  KEYS=$(python3 -c 'import json,sys; print("\n".join(json.load(open("assets.json")).keys()))')
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
  echo "[test] put $key ($(stat -c %s "$src") bytes)"
  atftp --put --local-file "$src" --remote-file "$key" 127.0.0.1 "$PORT"
  echo "[test] get $key"
  atftp --get --remote-file "$key" --local-file "$DOWNLOAD_DIR/$key" 127.0.0.1 "$PORT"
  computed=$(sha256sum "$DOWNLOAD_DIR/$key" | awk '{print $1}')
  if [[ "$computed" != "$expected" ]]; then
    echo "[fail] $key sha256 mismatch: expected=$expected got=$computed"
    failures=$((failures + 1))
  else
    echo "[ok]   $key"
  fi
done <<< "$KEYS"

echo
echo "[summary] $((total - failures))/$total passed"
exit "$failures"
```

Make it executable:

```bash
chmod +x tests/server_atftpd_test.sh
```

Note: this test script exercises both put and get, so it covers Task 4 (RRQ) once that lands. Until then, the `atftp --get` line will fail on every asset (server returns ERROR 4 "RRQ not yet implemented"). That's expected — the script exits non-zero. We rely on inspecting the log to verify puts worked.

For Task 3 specifically, run a `--put`-only verification first (Step 5).

- [ ] **Step 5: Verify WRQ works end-to-end**

```bash
cd /home/david/workspaceToit/tftp/tests
ROOT=$(mktemp -d)
setsid jag run -d host ../examples/server-host.toit -- --root="$ROOT" --port=6969 --allow-overwrite > /tmp/server.log 2>&1 &
SERVER_PID=$!
sleep 1
atftp --put --local-file ../assets/numbers.txt --remote-file numbers.txt 127.0.0.1 6969
echo "exit=$?"
sha256sum "$ROOT/numbers.txt"
python3 -c "import json; print(json.load(open('assets.json'))['numbers.txt'])"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
rm -rf "$ROOT"
```

Expected: the two `sha256sum` and the `json.load` output match (e.g. both end in `f882ef1da55f52b97a2b85876319e1d02a7d7398dd7faba3b8e3c1162c5b1546` for `numbers.txt`).

If they don't match, the WRQ path has a bug. Common suspects:
- DATA block ordering: `expected = block-num_ + 1` — make sure `block-num_` starts at 0, not 1.
- Final ACK timing: must be sent *after* `storage-writer_.close`.

- [ ] **Step 6: Commit**

```bash
git add src/tftp_server.toit tests/server_atftpd_test.sh
git commit -m "$(cat <<'EOF'
Add ServerExchange WRQ path and atftpd-driven round-trip test

ServerExchange handles WRQ end-to-end: parses the initial packet, opens
Storage.writer-for with the tsize hint, drives ACK/DATA exchange,
commits the writer (close) before sending the final ACK so a storage
failure surfaces as a TFTP error rather than a silent loss.

Adds tests/server_atftpd_test.sh which spawns the server binary and
exercises put + get against each asset in tests/assets.json. RRQ
(get) is still ERROR 4 "RRQ not yet implemented"; lands in the next
commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add `ServerExchange` RRQ path

**Files:**
- Modify: `src/tftp_server.toit`

**Goal:** The same round-trip script (`server_atftpd_test.sh`) now passes for both `--put` and `--get`.

- [ ] **Step 1: Add RRQ branch in `ServerExchange.run`**

Replace the RRQ stub branch in `ServerExchange.run` (the line `send-error_ 4 "RRQ not yet implemented"`) with:

```toit
run-rrq_ (initial- as PacketRRQ)
```

And add the method to the class:

```toit
run-rrq_ rrq/PacketRRQ -> none:
  if not storage_.exists filename_:
    throw STORAGE-FILE-NOT-FOUND
  storage-reader_ = storage_.reader-for filename_
  // No options handling yet — send DATA 1 directly.
  opcode_ = RRQ
  block-num_ = 1
  tries_ = 0
  drained_ = false
  blksize_ = DEFAULT-BLKSIZE
  drive_
```

- [ ] **Step 2: Add RRQ frame builder and handler**

Modify `next-frame` to add a DATA case for the RRQ side. Replace the current `next-frame`:

```toit
next-frame -> ByteArray:
  if tries_ > 0: return cached_
  if pending-oack_ != null:
    cached_ = pending-oack_.serialize
    pending-oack_ = null
    return cached_
  if opcode_ == WRQ: return wrq-ack0-frame_
  if opcode_ == ACK: return ack-frame_
  if opcode_ == RRQ or opcode_ == DATA: return next-data-frame_
  return (PacketERROR 0 "Invalid opcode: $opcode_").serialize
```

Add the method to the class:

```toit
next-data-frame_ -> ByteArray:
  chunk := bytes-to-send_ blksize_
  if chunk.size < blksize_: drained_ = true
  cached_ = (PacketDATA block-num_ chunk).serialize
  return cached_

bytes-to-send_ size/int -> ByteArray:
  result := io.Buffer
  while result.size < size:
    chunk := storage-reader_.read --max-size=(size - result.size)
    if chunk == null: break
    result.write chunk
  return result.bytes
```

(The `bytes-to-send_` helper mirrors the one in `TFTPClient` — `Reader.read` may return a partial chunk even when more data is available, so loop until the request is filled or EOF is hit.)

Modify `handle` to route ACKs to the RRQ side:

```toit
handle received/Packet -> none:
  if received.opcode == ERROR:
    exit-error_ (received as PacketERROR)
    return
  if received.opcode == TIMEOUT:
    retry-or-abort_
    return
  if received.opcode == DATA:
    handle-data_ (received as PacketDATA)
    return
  if received.opcode == ACK and (opcode_ == RRQ or opcode_ == DATA):
    handle-rrq-ack_ (received as PacketACK)
    return
  schedule-retransmit_
```

Add `handle-rrq-ack_`:

```toit
handle-rrq-ack_ ack/PacketACK -> none:
  if ack.block-num != block-num_:
    schedule-retransmit_
    return
  if drained_:
    opcode_ = EXIT
    return
  next := block-num_ + 1
  if next > MAX-BLOCK-NUM_:
    throw "TFTP: block number would exceed $MAX-BLOCK-NUM_; file too large for negotiated block size"
  block-num_ = next
  opcode_ = DATA
  tries_ = 0
```

- [ ] **Step 3: Add `io.Buffer` import to the file**

If not already present, add to the imports at the top of `src/tftp_server.toit`:

```toit
import io.buffer show Buffer
```

(Or use `io.Buffer` directly via the `import io` already there — Toit re-exports `Buffer` from `io`. If the compile error references `Buffer not found`, switch to the explicit import.)

- [ ] **Step 4: Add reader cleanup to the dispatch finally**

The dispatcher's `finally` already closes the ephemeral socket. We need `ServerExchange` to also close `storage-reader_` and `storage-writer_` if they're still open. Add to the bottom of `ServerExchange.run`:

```toit
run -> none:
  err := catch --trace=false:
    validate-request_
    if initial- is PacketWRQ:
      run-wrq_ (initial- as PacketWRQ)
    else:
      run-rrq_ (initial- as PacketRRQ)
  if err != null:
    handle-storage-error_ err
  // Best-effort cleanup. Errors here are logged.
  if storage-reader_ != null:
    catch: storage-reader_.close
  if storage-writer_ != null:
    catch: storage-writer_.close
```

(The earlier "commit before final ACK" path nulls `storage-writer_` after a successful close, so this finally-style cleanup only fires on the error / abort paths.)

- [ ] **Step 5: Compile + run the round-trip test**

```bash
cd /home/david/workspaceToit/tftp
jag compile src/tftp.toit
cd tests
./server_atftpd_test.sh
```

Expected: the script's final line is `[summary] N/N passed` (where N is the number of assets in `assets.json`, currently 10), and exit code 0.

If individual assets fail, suspects:
- For small files: drained logic — DATA shorter than blksize must set `drained_ = true`.
- For files larger than 65535*512 bytes (`sample-png-image_20mb.png` is ~20MB but only ~41k blocks at 512 each, fine): block-number overflow.
- For all assets: `bytes-to-send_` not draining the reader correctly.

- [ ] **Step 6: Commit**

```bash
git add src/tftp_server.toit
git commit -m "$(cat <<'EOF'
Add ServerExchange RRQ path; round-trip test now fully passes

Server-side RRQ opens Storage.reader-for, drives DATA/ACK exchange.
End-of-file is detected via DATA shorter than blksize, matching client
behavior. tests/server_atftpd_test.sh now passes for all assets.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Option negotiation (RFC 2347/2348/2349) + blksize test

**Files:**
- Modify: `src/tftp_server.toit`
- Create: `tests/server_atftpd_blksize_test.sh`

**Goal:** Server returns OACK echoing accepted options. `atftp --option "blksize 1428"` puts and gets succeed end-to-end.

- [ ] **Step 1: Add OACK construction in `ServerExchange`**

Replace `run-wrq_` with:

```toit
run-wrq_ wrq/PacketWRQ -> none:
  oack := build-oack_ wrq.options --is-write
  tsize-hint := null
  if wrq.options.contains OPT-TSIZE:
    tsize-hint = int.parse wrq.options[OPT-TSIZE]
  storage-writer_ = storage_.writer-for filename_ --tsize-hint=tsize-hint
  if oack != null:
    pending-oack_ = oack
    blksize_ = int.parse (oack.options.get OPT-BLKSIZE --if-absent=: "$DEFAULT-BLKSIZE")
  opcode_ = WRQ
  block-num_ = 0
  tries_ = 0
  drained_ = false
  drive_
```

Replace `run-rrq_` with:

```toit
run-rrq_ rrq/PacketRRQ -> none:
  if not storage_.exists filename_:
    throw STORAGE-FILE-NOT-FOUND
  storage-reader_ = storage_.reader-for filename_
  oack := build-oack_ rrq.options --no-is-write
  if oack != null:
    pending-oack_ = oack
    blksize_ = int.parse (oack.options.get OPT-BLKSIZE --if-absent=: "$DEFAULT-BLKSIZE")
    // Per RFC 2347, after OACK the client sends ACK 0; we then start with DATA 1.
    opcode_ = RRQ
    block-num_ = 0
    // First incoming will be ACK 0; handle-rrq-ack_ advances to DATA 1.
  else:
    opcode_ = RRQ
    block-num_ = 1
  tries_ = 0
  drained_ = false
  drive_
```

Add the `build-oack_` helper:

```toit
/**
Builds an OACK echoing the subset of $client-options the server accepts.

Returns null if no options are accepted (in which case the server
  proceeds with the standard exchange — no OACK sent).
*/
build-oack_ client-options/Map --is-write/bool -> PacketOACK?:
  accepted := {:}
  client-options.do: | name/string value/string |
    if name == OPT-BLKSIZE:
      n := int.parse value
      if MIN-BLKSIZE <= n <= MAX-BLKSIZE:
        accepted[OPT-BLKSIZE] = "$n"
    else if name == OPT-TSIZE:
      if is-write:
        // Echo back what the client sent; backend already used the hint.
        accepted[OPT-TSIZE] = value
      else:
        size := storage_.size filename_
        if size != null:
          accepted[OPT-TSIZE] = "$size"
    else if name == OPT-TIMEOUT:
      n := int.parse value
      if 1 <= n <= 255:
        accepted[OPT-TIMEOUT] = "$n"
  if accepted.is-empty: return null
  return PacketOACK accepted
```

- [ ] **Step 2: Update `handle-rrq-ack_` to handle ACK 0 after OACK**

The ACK 0 that arrives after an RRQ-with-OACK confirms the OACK; the next outbound frame is DATA 1. Replace `handle-rrq-ack_`:

```toit
handle-rrq-ack_ ack/PacketACK -> none:
  // ACK 0 after RRQ+OACK means "OACK accepted, send DATA 1".
  if opcode_ == RRQ and block-num_ == 0:
    if ack.block-num != 0:
      schedule-retransmit_
      return
    block-num_ = 1
    opcode_ = DATA
    tries_ = 0
    return
  if ack.block-num != block-num_:
    schedule-retransmit_
    return
  if drained_:
    opcode_ = EXIT
    return
  next := block-num_ + 1
  if next > MAX-BLOCK-NUM_:
    throw "TFTP: block number would exceed $MAX-BLOCK-NUM_; file too large for negotiated block size"
  block-num_ = next
  opcode_ = DATA
  tries_ = 0
```

- [ ] **Step 3: Verify the round-trip test still passes (no-options path unchanged)**

```bash
cd /home/david/workspaceToit/tftp
jag compile src/tftp.toit
cd tests
./server_atftpd_test.sh
```

Expected: `[summary] N/N passed`.

- [ ] **Step 4: Create `tests/server_atftpd_blksize_test.sh`**

```bash
#!/usr/bin/env bash
# Exercises RFC 2348 blksize negotiation. atftp --option "blksize 1428"
# triggers an OACK round-trip; the server must echo the accepted blksize
# and the subsequent DATA stream uses 1428-byte blocks.

set -euo pipefail

cd "$(dirname "$0")"
TESTS_DIR=$PWD
REPO=$(cd .. && pwd)

PORT=${PORT:-6969}
ROOT=$(mktemp -d -t tftp-server-blksize.XXXXXX)
DOWNLOAD_DIR=$(mktemp -d -t tftp-blksize-dl.XXXXXX)
trap 'rm -rf "$ROOT" "$DOWNLOAD_DIR"; if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi' EXIT

echo "[setup] root=$ROOT port=$PORT"

setsid jag run -d host "$REPO/examples/server-host.toit" -- \
    --root="$ROOT" --port="$PORT" --allow-overwrite \
    > "$DOWNLOAD_DIR/server.log" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 50); do
  if grep -q "tftp-server: serving" "$DOWNLOAD_DIR/server.log" 2>/dev/null; then break; fi
  sleep 0.1
done
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "[fail] server did not start; log:"
  cat "$DOWNLOAD_DIR/server.log"
  exit 1
fi

# Pick a single large-ish asset to exercise multi-block transfer.
ASSET="sample-png-image_1mb.png"
src="$REPO/assets/$ASSET"

if [[ ! -f "$src" ]]; then
  echo "[skip] $ASSET missing on disk"
  exit 0
fi

EXPECTED=$(python3 -c "import json; print(json.load(open('assets.json'))['$ASSET'])")

echo "[test] put $ASSET with blksize=1428"
atftp --option "blksize 1428" --put --local-file "$src" --remote-file "$ASSET" 127.0.0.1 "$PORT"

echo "[test] get $ASSET with blksize=1428"
atftp --option "blksize 1428" --get --remote-file "$ASSET" --local-file "$DOWNLOAD_DIR/$ASSET" 127.0.0.1 "$PORT"

computed=$(sha256sum "$DOWNLOAD_DIR/$ASSET" | awk '{print $1}')
if [[ "$computed" != "$EXPECTED" ]]; then
  echo "[fail] $ASSET sha256 mismatch: expected=$EXPECTED got=$computed"
  exit 1
fi

echo "[ok] $ASSET round-trip with blksize=1428 ($(stat -c %s "$src") bytes)"
exit 0
```

```bash
chmod +x tests/server_atftpd_blksize_test.sh
```

- [ ] **Step 5: Run the blksize test**

```bash
cd /home/david/workspaceToit/tftp/tests
./server_atftpd_blksize_test.sh
```

Expected: `[ok] sample-png-image_1mb.png round-trip with blksize=1428 (1068158 bytes)` and exit 0.

If the put hangs after OACK: server isn't transitioning from `pending-oack_` → ACK 0 receive → DATA stream. Check that `handle` is being called for ACK 0 after OACK (the WRQ path uses the same flow as no-options).

If the get works at 512 but not 1428: the OACK side of `build-oack_` is correct but the negotiated `blksize_` isn't being applied to subsequent DATA frames. Verify `blksize_` is set to the OACK value in `run-wrq_` / `run-rrq_`.

- [ ] **Step 6: Commit**

```bash
git add src/tftp_server.toit tests/server_atftpd_blksize_test.sh
git commit -m "$(cat <<'EOF'
Add RFC 2347/2348/2349 option negotiation to ServerExchange

ServerExchange.build-oack_ accepts blksize (clamped to range), tsize
(echoes on WRQ, populates from Storage.size on RRQ), and timeout
(informational; receive timeout stays fixed for retry predictability).
OACK is sent in lieu of ACK 0 (WRQ) or DATA 1 (RRQ); subsequent
exchange uses negotiated blksize.

Adds tests/server_atftpd_blksize_test.sh which round-trips a 1MB asset
with --option "blksize 1428".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Concurrency burst test

**Files:**
- Create: `tests/server_burst_test.sh`

**Goal:** N parallel atftp puts succeed; the server's per-transfer task fan-out and `--max-concurrent` semaphore are exercised. The script also runs against a remote target via `--server`.

The server's `--max-concurrent` cap is already implemented in Task 2's skeleton. This task adds the test that proves it.

- [ ] **Step 1: Create `tests/server_burst_test.sh`**

```bash
#!/usr/bin/env bash
# Concurrency exercise. Launches N parallel atftp puts of distinct
# files, waits for all, verifies sha256 of each landed file. Optionally
# targets a remote server (--server=HOST:PORT), useful for over-the-LAN
# testing against e.g. an SSH-reachable z170 box.
#
# Default: spawns the server locally on 6969.
#
# Usage:
#   ./server_burst_test.sh                    # local, N=20, max-concurrent=64
#   ./server_burst_test.sh --concurrent=20    # tune N
#   ./server_burst_test.sh --server=10.0.0.5:6969 --root=/srv/tftp
#       (with --server, $ROOT is the path on the *remote* host where
#        the server's working directory is — required for sha256
#        verification, which uses ssh.)

set -euo pipefail

cd "$(dirname "$0")"
TESTS_DIR=$PWD
REPO=$(cd .. && pwd)

CONCURRENT=20
SERVER=""
ROOT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --concurrent=*) CONCURRENT="${1#*=}"; shift ;;
    --server=*)     SERVER="${1#*=}"; shift ;;
    --root=*)       ROOT="${1#*=}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SERVER" ]]; then
  PORT=6969
  ROOT=$(mktemp -d -t tftp-burst.XXXXXX)
  trap 'rm -rf "$ROOT"; if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi' EXIT
  setsid jag run -d host "$REPO/examples/server-host.toit" -- \
      --root="$ROOT" --port="$PORT" --allow-overwrite \
      > /tmp/tftp-burst-server.log 2>&1 &
  SERVER_PID=$!
  for i in $(seq 1 50); do
    if grep -q "tftp-server: serving" /tmp/tftp-burst-server.log 2>/dev/null; then break; fi
    sleep 0.1
  done
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[fail] server did not start; log:"
    cat /tmp/tftp-burst-server.log
    exit 1
  fi
  HOST="127.0.0.1"
else
  HOST="${SERVER%:*}"
  PORT="${SERVER#*:}"
  if [[ -z "$ROOT" ]]; then
    echo "[fail] --root is required when using --server" >&2
    exit 2
  fi
fi

echo "[setup] target=$HOST:$PORT root=$ROOT concurrent=$CONCURRENT"

SRC_ASSET="$REPO/assets/numbers.txt"
if [[ ! -f "$SRC_ASSET" ]]; then
  echo "[fail] missing source asset: $SRC_ASSET"
  exit 1
fi

EXPECTED=$(python3 -c "import json; print(json.load(open('assets.json'))['numbers.txt'])")

# Parallel uploads.
echo "[test] launching $CONCURRENT parallel puts"
PIDS=()
for i in $(seq 1 "$CONCURRENT"); do
  atftp --put --local-file "$SRC_ASSET" --remote-file "burst-$i.bin" "$HOST" "$PORT" &
  PIDS+=($!)
done

# Wait, collect failures.
fails=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    fails=$((fails + 1))
  fi
done

if [[ $fails -gt 0 ]]; then
  echo "[fail] $fails of $CONCURRENT puts failed"
  exit 1
fi

# Verify each landed file's sha256.
echo "[test] verifying $CONCURRENT files"
sha_failures=0
for i in $(seq 1 "$CONCURRENT"); do
  if [[ -z "$SERVER" ]]; then
    computed=$(sha256sum "$ROOT/burst-$i.bin" | awk '{print $1}')
  else
    # Remote: use ssh + sha256sum over the path on the remote box.
    computed=$(ssh "$HOST" "sha256sum '$ROOT/burst-$i.bin'" | awk '{print $1}')
  fi
  if [[ "$computed" != "$EXPECTED" ]]; then
    echo "[fail] burst-$i.bin sha256 mismatch"
    sha_failures=$((sha_failures + 1))
  fi
done

if [[ $sha_failures -gt 0 ]]; then
  echo "[fail] $sha_failures sha256 mismatches"
  exit 1
fi

echo "[ok] $CONCURRENT/$CONCURRENT burst puts succeeded"
exit 0
```

```bash
chmod +x tests/server_burst_test.sh
```

- [ ] **Step 2: Run the burst test locally**

```bash
cd /home/david/workspaceToit/tftp/tests
./server_burst_test.sh --concurrent=20
```

Expected: `[ok] 20/20 burst puts succeeded` and exit 0.

If puts fail under load:
- Most likely: the listen loop is dropping datagrams because the dispatcher takes too long (the `task::` should be returning quickly, but if `network_.udp-open` blocks, requests after the first will be dropped).
- Verify: in `dispatch_`, the `task::` block returns *before* opening the ephemeral socket inside the new task. The current shape (open ephemeral inside the task) is correct.
- If a small number of puts fail with `Server busy`: bump `--concurrent` or raise `--max-concurrent` in the server.

- [ ] **Step 3: Run the burst test against the remote z170 box (if available)**

This is an optional verification that the server works over a real LAN:

```bash
# On the z170 host:
ssh z170 "cd /tmp && rm -rf tftp-burst && mkdir tftp-burst"
ssh z170 "cd /home/david/workspaceToit/tftp && jag run -d host examples/server-host.toit -- --root=/tmp/tftp-burst --port=6969 --allow-overwrite &"
# Then locally:
./server_burst_test.sh --server=z170:6969 --root=/tmp/tftp-burst --concurrent=20
```

Expected: `[ok] 20/20 burst puts succeeded` and exit 0.

This step is optional and not gating; the local-only test is sufficient for the commit.

- [ ] **Step 4: Commit**

```bash
git add tests/server_burst_test.sh
git commit -m "$(cat <<'EOF'
Add server burst concurrency test

Launches N parallel atftp puts, waits for all, verifies sha256 of each
landed file. Defaults to local server on 6969 with N=20; --server
targets a remote host (e.g. SSH-reachable z170) over LAN for stronger
concurrency exercise without changing the script.

Exercises the per-transfer task fan-out and the --max-concurrent
semaphore in TFTPServer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Goal:** Users discover and run the new server.

- [ ] **Step 1: Add a server section to `README.md`**

Open `README.md` and append (after the existing client testing section):

```markdown
## TFTP Server

The package now ships a `TFTPServer` complementing `TFTPClient`. Both directions
(RRQ and WRQ) are supported, with full RFC 2347/2348/2349 option negotiation.

### Quick start

```toit
import log
import tftp show FilesystemStorage TFTPServer

main:
  storage := FilesystemStorage --root="/srv/tftp" --allow-overwrite=true
  server := TFTPServer
      --storage=storage
      --port=69
      --max-concurrent=64
      --logger=log.default
  server.start
```

`server.start` blocks until `server.stop` is called.

`Storage` is the pluggable backend interface (see `src/storage.toit`). The
bundled `FilesystemStorage` serves a directory tree; future backends like
`SqliteStorage` will live in separate packages.

### Privileged port

On Linux, binding port 69 needs root or `cap_net_bind_service`. The bundled
`examples/server-host.toit` binary takes a `--port` flag so you can run on
6969 (or any unprivileged port) for testing.

### IPv6 / Thread

The current Toit SDK does not expose IPv6 listener support; the server binds
IPv4. For Thread / IPv6 deployments use NAT64 or a small UDP relay on the
border router. See `docs/thread-sqlite-deployment.md`.

### Running the server tests

The server tests use `atftp` (the reference C client) as the test harness.

Install: `apt install atftp` (Debian / Ubuntu).

Then:

```bash
cd tests
./server_atftpd_test.sh           # round-trip put + get for every asset
./server_atftpd_blksize_test.sh   # OACK negotiation with blksize=1428
./server_burst_test.sh            # 20 parallel puts (concurrency)
```
```

- [ ] **Step 2: Add CHANGELOG entry**

Insert at the top of `CHANGELOG.md`:

```markdown
## 2.3.0 - 2026-05-08
Add TFTPServer.

- Server-side RRQ + WRQ with full RFC 2347/2348/2349 option negotiation.
- Pluggable Storage backend (FilesystemStorage bundled).
- Bounded concurrency via --max-concurrent (default 64).
- Storage-error sentinel mapping to TFTP error codes.
- Commit-before-final-ACK on WRQ so post-receive backend failures
  surface as TFTP errors rather than silent loss.
- Refactor: extract abstract Exchange base from ClientExchange; both
  Client and Server share retry, OACK validation, and TID enforcement.

```

- [ ] **Step 3: Compile-check (sanity)**

```bash
cd /home/david/workspaceToit/tftp
jag compile src/tftp.toit
```

Expected: clean.

- [ ] **Step 4: Final smoke**

```bash
cd /home/david/workspaceToit/tftp/tests
./server_atftpd_test.sh && ./server_atftpd_blksize_test.sh && ./server_burst_test.sh
echo "all server tests passed"
```

Expected: all three scripts exit 0 and the trailing `all server tests passed` prints.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
Document TFTPServer; release 2.3.0

README gets a server section with quick-start, privileged-port caveat,
IPv6/Thread note pointing to the deployment doc, and instructions for
running the new atftpd-driven test scripts. CHANGELOG entry summarises
the new server, the abstract-Exchange refactor, and the option /
concurrency / commit-before-ack guarantees.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
