# TFTP server — design spec

**Status**: design approved 2026-05-08; implementation pending.
**Companion**: `docs/thread-sqlite-deployment.md` covers the use case (Thread devices
pushing telemetry) and the deployment-time IPv6 question. This spec covers only
what we build inside the package.

## Goal

Land a `TFTPServer` class in this package that complements the existing
`TFTPClient`. Both directions (RRQ and WRQ), full option negotiation
(RFC 2347/2348/2349), `Storage`-backed I/O.

The motivating consumer is `SqliteStorage` (separate package) for telemetry
collection from a Thread mesh, but the server itself takes any `Storage`.

## Non-goals

- IPv6 listener support — blocked on the Toit SDK's UDP API; deployment uses
  NAT64 / relay on the border router (see deployment doc).
- Authentication / authorization — TFTP has none; out of scope.
- `netascii` / `mail` transfer modes — only `octet`.
- Cancelling in-flight transfers from `stop`. Per-transfer tasks finish on
  their own (success, peer error, or timeout). `stop` only closes the
  listener so no new transfers begin.
- Hand-crafted wire-level conformance tests (e.g. wrong-TID injection).
  Deferred. The base-class refactor preserves the logic that the existing
  client tests already exercise against `tftp-go`.

## Public API

```toit
class TFTPServer:
  constructor
      --storage/Storage
      --port/int = TFTP-DEFAULT-PORT     // 69
      --max-concurrent/int = 64
      --logger/log.Logger = log.default

  start -> none      // Blocks until stop or fatal listener error.
  stop  -> none      // Idempotent; closes the listen socket.
```

- `Storage` is the interface already in `src/storage.toit`. The bundled
  `FilesystemStorage` is the obvious test backend; future `SqliteStorage`
  lives in a separate package.
- `port=69` is the default but requires `cap_net_bind_service` on Linux.
  Tests use 6969; the `examples/server-host.toit` binary takes `--port`.
- `max-concurrent=64` defaults a bounded semaphore (see *Concurrency*).
- `logger` follows the MQTT broker convention (`log.Logger` injected with
  `log.default`).
- `start` is synchronous and blocks; callers wrap it in `task::` if they
  need to run other work alongside.

## Architecture

```
                        +------------------+
        UDP/69 -------> | listen socket    |  receives RRQ/WRQ datagrams
                        | (one per server) |
                        +---------+--------+
                                  | dispatch_ (task::, semaphore-gated)
                                  v
                        +------------------+
                        | ServerExchange   |  one per transfer
                        | + ephemeral UDP  |
                        +---------+--------+
                                  |
                                  v
                        +------------------+
                        | Storage          |
                        +------------------+
```

The listen socket on `:69` *only* receives initial RRQ/WRQ datagrams. Each
becomes a `ServerExchange` running on its own ephemeral UDP socket. The
listen port is therefore free for the next request immediately, and N
concurrent transfers run as N concurrent tasks on N ephemeral ports.

This matches `tftp-go`'s server architecture and is the standard TFTP
fan-out shape.

### Listen loop

```toit
start -> none:
  network_ = net.open
  listen-socket_ = network_.udp-open --port=port_
  semaphore_ = monitor.Semaphore --count=max-concurrent_
  try:
    while not stopping_:
      msg := listen-socket_.receive   // blocks
      dispatch_ msg
  finally:
    listen-socket_.close
    network_.close
```

`dispatch_` decodes the opcode, validates that it's RRQ or WRQ, applies the
concurrency cap, and spawns the per-transfer task. Anything that goes
wrong on the listen socket is logged and dropped — the listen loop never
throws.

### Concurrency cap

Bounded by default. Implemented as a `monitor.Semaphore --count=max-concurrent_`.

- On dispatch: `if not semaphore_.try-down: reject_ msg` — reject sends a
  `PacketERROR 0 "Server busy"` to the source and drops the request.
  Queueing would just grow under sustained overload (the client's own
  retransmit timer would push more requests behind it).
- On per-transfer task completion: `semaphore_.up` in a `finally`.

Default 64 is a sensible host-side number. Tunable via constructor. ESP32
deployments would lower it; high-fan-in Linux servers may raise it.

### Per-transfer task

```toit
dispatch_ msg/udp.Datagram:
  packet := Packet.deserialize (io.Reader msg.data)
  if packet is not PacketRRQ and packet is not PacketWRQ:
    listen-socket_.send (PacketERROR 4 "Illegal TFTP operation").serialize-to msg.address
    return
  if not semaphore_.try-down:
    reject_ msg
    return
  task::
    try:
      ServerExchange.run packet msg.address storage_ logger_ network_
    finally:
      semaphore_.up
```

`ServerExchange.run`:

1. Receive the already-parsed `PacketRRQ` or `PacketWRQ` and the source
   address from the dispatcher.
2. Validate filename, mode (`octet` only), options.
3. Open the ephemeral UDP socket.
4. Open the `Storage` reader (RRQ) or writer (WRQ); on WRQ pass
   `--tsize-hint` from the option if present so backends that
   pre-allocate can fail fast. Map sentinel exceptions to TFTP error
   codes (table below) and short-circuit if the open fails — the failure
   reply is sent on the ephemeral socket, with the listen-socket source
   as destination.
5. If options were requested, build OACK (only the options we accept and
   the values we negotiated); otherwise jump straight into the standard
   exchange.
6. Drive the loop until EXIT.
7. On WRQ completion: `writer.close` *before* the final ACK is sent (see
   *Commit-before-final-ACK*).
8. `finally`: close ephemeral socket and any open Storage handle. Errors
   in `finally` are logged, not propagated.

### Commit-before-final-ACK (WRQ)

TFTP has no third handshake — the final ACK from server to client is the
"transfer succeeded" signal. If the storage commit fires *after* that ACK
and fails (SQLite INSERT error, fsync-time disk-full), the client believes
the upload landed but it didn't.

We close the `Storage.writer-for` handle before sending the final ACK. If
`close` throws, we send `ERROR 3` (or the storage's mapped error) instead
of an ACK; the client surfaces the error. This costs ~one round-trip of
latency at end-of-transfer; for 100 B telemetry payloads it is invisible.
This is the right trade-off for any backend whose commit can fail
post-receive.

## State machine: abstract Exchange + Client/Server subclasses

The current `ClientExchange` is tightly coupled to `TFTPClient`. The
server's state machine has substantial overlap (retry/cache, block
counter, OACK validation, TID enforcement, `ERROR 5` on stranger
datagrams). The chosen approach is to extract an abstract `Exchange` base
that both subclasses inherit.

### What the base owns

```toit
abstract class Exchange:
  // Wire state.
  socket_/udp.Socket
  peer-tid_/net.SocketAddress? := null
  block-num_/int := 0
  tries_/int := 0
  drained_/bool := false
  blksize_/int := DEFAULT-BLKSIZE
  cached_/ByteArray := #[]
  logger_/log.Logger
  opcode_/int := -1

  // Hooks.
  abstract receive-timeout-ms -> int        // 1_000 for both
  abstract max-tries -> int                  // 12 for both
  abstract handle received/Packet -> none    // direction-specific dispatcher
  abstract next-frame -> ByteArray           // build the next outbound frame

  // Shared helpers.
  drive_ -> none                              // the while opcode_ != EXIT loop
  send_ payload/ByteArray -> none             // sends to peer-tid_
  receive_ -> Packet                           // timeout, TID enforcement, ERROR 5 on stranger
  retry-or-abort_ -> none                      // tries_++ vs throw "timed out"
  schedule-retransmit_ -> none
  exit-error_ err/PacketERROR -> none
  apply-oack_ oack/PacketOACK requested/Map -> none
  build-error-packet_ code/int msg/string -> ByteArray
```

### What stays in `ClientExchange`

- Entry points (renamed `read` / `write` → `start-with-rrq` / `start-with-wrq`).
- Direction-specific frame builders: `wrq-frame_`, `rrq-frame_`,
  `next-data-frame_`, `ack-frame_`.
- `handle-write_` / `handle-read_` (now overrides of `handle`).
- Reference back to `TFTPClient` for filename, mode, byte counters, options
  building, the source/sink reader/writer.

### What's new in `ServerExchange`

- Constructor takes the initial datagram (raw bytes + source address), the
  `Storage` backend, and the logger.
- `run` (the entry point called from the per-transfer task) parses the
  initial packet, opens the ephemeral socket and the storage handle,
  builds and sends the first frame (OACK or ACK 0 for WRQ; OACK or first
  DATA for RRQ), then calls `drive_`.
- Direction-specific frame builders mirror the client: server-side RRQ
  produces DATA from `Storage.reader-for`; server-side WRQ produces ACKs
  while consuming DATA into `Storage.writer-for`.
- TID enforcement is inherited from the base — `peer-tid_` is locked to
  the address of the device's first reply (its ephemeral port), and any
  stranger datagram receives `ERROR 5`.

### Refactor risk

Touching the working client is the real risk. Mitigation:

- **Refactor in its own commit.** Step 1 of *Implementation order* lands
  the base class and migrates `ClientExchange` to inherit from it, with
  no behaviour change. Existing tftp-go round-trip tests stay green
  throughout.
- **Test gate.** The refactor commit runs the existing client suite
  against tftp-go before being built upon. Subsequent server commits
  inherit the safety.

## Error mapping

| Source                              | TFTP error                          | Notes                                                                          |
|-------------------------------------|-------------------------------------|--------------------------------------------------------------------------------|
| `STORAGE-FILE-NOT-FOUND`            | 1 — File not found                  | RRQ; sent on listen socket, no ephemeral, no transfer started.                 |
| `STORAGE-ACCESS-DENIED`             | 2 — Access violation                | Either direction.                                                              |
| `STORAGE-NO-SPACE`                  | 3 — Disk full or allocation exceeded| WRQ; before any DATA accepted, or mid-transfer if backend signals later.       |
| `STORAGE-FILE-EXISTS`               | 6 — File already exists             | WRQ when overwrite disabled.                                                   |
| Mode != `octet`                     | 4 — Illegal TFTP operation          | "Only octet mode supported".                                                   |
| Filename empty / >128 chars         | 4                                   | Mirrors client validation.                                                     |
| Listen-port datagram, opcode ≠ RRQ/WRQ | 4                                | Includes stale-TID DATA/ACKs; reply 4 and drop.                                |
| Stranger TID during transfer        | 5 — Unknown transfer ID             | RFC 1350 §4; handled in `Exchange.receive_`.                                   |
| Unknown option                      | (silently dropped from OACK)        | RFC 2347 §3 — server returns only options it accepts.                          |
| Block-num overflow (>65535)         | 3 + "transfer too large for blksize"| Client throws; server converts to ERROR 3 to peer.                             |
| Timeout after `MAX-TRIES_` retransmits | (log warning, no error packet)   | Peer is gone; sending into the void wastes airtime.                            |
| `Storage.writer.close` throws       | mapped per sentinel, fallback ERROR 0 | Sent **instead of final ACK**, see *Commit-before-final-ACK*.                |

Two specifics:

1. **Concurrency-cap reject** sends `ERROR 0 "Server busy"`. The client
   reads this and aborts (per `ClientExchange.exit-error_`). On the device
   side this surfaces as a thrown exception; the device retries on its own
   schedule. This is the right back-pressure signal.

2. **Storage-error sentinels are strings, not exceptions with metadata.**
   The mapping is a `catch` + string compare in `ServerExchange.run`. If
   the thrown value matches a known sentinel, map to the corresponding
   TFTP error; otherwise log + ERROR 0 with the throw's stringification.

## Option negotiation (RFC 2347 / 2348 / 2349)

Server side accepts any subset of the three options the client requested.

| Option   | RFC  | Server behaviour                                                                                        |
|----------|------|---------------------------------------------------------------------------------------------------------|
| blksize  | 2348 | Accept; clamp to `[MIN-BLKSIZE, MAX-BLKSIZE]`. Server may negotiate down, never up. Echo accepted value. |
| tsize    | 2349 | On RRQ (`tsize=0`): respond with `Storage.size name` if known; omit otherwise. On WRQ: pass the value to `Storage.writer-for --tsize-hint=…` and echo it back in OACK. |
| timeout  | 2349 | Accept the value; informational only. Receive timeout stays at `DEFAULT-TIMEOUT-MS_` so retry budget is predictable. (Same as the client.) |

If at least one option is accepted, build OACK with the accepted subset.
- **WRQ + OACK**: sent in lieu of ACK 0; client treats it as ACK 0 (RFC 2347).
- **RRQ + OACK**: sent in lieu of DATA 1; client ACKs block 0 to confirm,
  then we send DATA 1.

If no options were requested or none are accepted, skip OACK and use the
standard exchange.

## Bind address

`network.udp-open --port=port_` picks the bind address. With the current
Toit SDK that's IPv4 wildcard; ESP32 builds depend on the IDF config.
We don't expose `--bind` in this MVP — the deployment doc explicitly
documents that IPv6 dual-stack is blocked upstream and the workaround is
NAT64 / relay on the BR.

## Testing

Per the chosen test strategy: external-binary + atftpd interop. atftp is
the authoritative reference TFTP client.

### Artifacts

- `examples/server-host.toit` — runnable host binary. Constructs
  `FilesystemStorage --root=/tmp/tftp-server-test --allow-overwrite=true`
  and runs `TFTPServer.start --port=6969`. Accepts `--root`, `--port`,
  `--max-concurrent` flags so the same binary serves the burst test and
  on-device deployment.
- `tests/server_atftpd_test.sh` — round-trip smoke test:
  1. Compile `examples/server-host.toit`.
  2. Spawn the binary on `127.0.0.1:6969`; wait until the listener is up.
  3. For each asset in `tests/assets.json`: `atftp --put` it, `atftp --get`
     it back, sha256 the result against the expected hash.
  4. Kill the server; clean up.
- `tests/server_atftpd_blksize_test.sh` — same shape, but exercises
  `atftp --option "blksize 1428"` to confirm OACK negotiation. Failures
  here narrow to OACK construction, not the base state machine.
- `tests/server_burst_test.sh` — concurrency. Launches N parallel
  `atftp --put` clients with distinct filenames, waits for all, verifies
  every file landed correctly via sha256 comparison. Exercises the
  per-transfer task fan-out and the `--max-concurrent` semaphore.
  Standalone script (kept out of the basic suite because timing is more
  sensitive). Also runnable against a remote host (e.g. SSH-targeted
  z170 box) for over-the-network concurrency exercise — the script
  takes a `--server` argument so the same harness drives local and
  remote runs.

### What the existing tests give us, unchanged

The existing `tests/roundtrip_test.toit`, `large_transfer_test.toit`,
`blksize_perf_test.toit`, `options_test.toit`, `simple_test.toit` all use
the Toit client against `tftp-go`. They stay as-is. Together they
guarantee:

- The base-class refactor of `ClientExchange` doesn't regress client
  behaviour.
- Cross-implementation interop with `tftp-go` (the Go reference server)
  remains the cross-vendor signal.

The new server-side tests use atftp (the C reference client) against our
server. Together with the existing tests, both sides of our protocol stack
are continuously validated against an independent reference
implementation.

### Out of scope for the MVP test surface

- **Wrong-TID injection.** Hand-crafted UDP datagrams from a third
  endpoint to verify ERROR 5. The logic is already exercised by the
  existing client tests against tftp-go (the client's `is-from-server_` /
  `send-unknown-tid_` paths) and the base-class extraction preserves the
  code. Add as a follow-up if we want server-side coverage too.
- **Unit tests of individual frame builders / parsers.** `packets.toit` is
  already exercised end-to-end. Adding micro-tests is not justified by
  observed defect density.

## Implementation order

1. **Refactor**: extract `abstract class Exchange` from `ClientExchange`.
   `ClientExchange` inherits and overrides `next-frame` and `handle`. No
   behaviour change. All existing tests stay green.
2. **Server**: add `ServerExchange`, `TFTPServer`, `examples/server-host.toit`.
3. **Tests**: add `server_atftpd_test.sh` and
   `server_atftpd_blksize_test.sh`. Run them locally and in CI.
4. **Burst**: add `tests/server_burst_test.sh`. Standalone.
5. **Export**: re-export `TFTPServer` from `src/tftp.toit`.

Each numbered step is a separate commit. Steps 3 and 4 may be one PR.

## Files touched

- `src/exchange.toit` (new) — abstract `Exchange` base.
- `src/tftp_client.toit` (modified) — `ClientExchange` extends `Exchange`.
- `src/tftp_server.toit` (new) — `TFTPServer` and `ServerExchange`.
- `src/tftp.toit` (modified) — `import .tftp-server` and `export *`.
- `examples/server-host.toit` (new).
- `tests/server_atftpd_test.sh` (new).
- `tests/server_atftpd_blksize_test.sh` (new).
- `tests/server_burst_test.sh` (new).
- `package.yaml` (no change expected; depends only on `pkg-host`).
- `README.md`, `CHANGELOG.md` — server section, atftp prerequisite for
  tests, port-69 caveat.

## Open questions left for implementation

None blocking. The following are tactical decisions to make in code:

- Exact field-by-field split between `Exchange` base and the two
  subclasses — falls out of the refactor.
- The default value for `max-concurrent` (currently 64). Revisit if burst
  tests reveal a different sweet spot.
