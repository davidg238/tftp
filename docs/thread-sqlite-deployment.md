# Thread + TFTP + SQLite deployment design

Captures the design discussion for using this TFTP package as the data-collection
endpoint for a network of Thread devices that periodically push small telemetry
payloads into a SQLite database. Decisions deferred for confirmation are flagged
in the **Open questions** section.

## Use case

- A fleet of Thread (IPv6 / 6LoWPAN) devices, each periodically pushing
  ~100-byte telemetry frames to a central server.
- Pushes are short and frequent: a single TFTP DATA per push fits the payload
  with the default 512-byte block size.
- The server stores everything durably in a single SQLite database for later
  query and analysis.
- The server host is conventional Linux/x86; storage requirements are modest
  (millions of small rows, append-only, time-series-shaped).

## Why TFTP

- Tiny code footprint on the device side (state machine fits in a few hundred
  lines; this package's `TFTPClient` is the implementation).
- UDP — no TCP handshake, no TLS handshake, low memory on the radio.
- No authentication or authorization in the protocol. Acceptable on a
  closed Thread mesh; **not** suitable for an open WAN.
- Existing tooling (`tftp-go`, `atftpd`, IETF compliance suites) makes the
  protocol easy to interoperate with and inspect.

The flip side: TFTP is lockstep (1-DATA / 1-ACK), so per-packet airtime is
real. For 100-byte payloads with a single DATA, that's just two packets per
push (DATA + ACK), which is fine.

## Architecture

### Three components

```
+----------------+   IPv6/UDP/69    +-----------------+   IPv4/UDP/69    +-------------+
| Thread device  | ---------------> | Border Router / | ---------------> | TFTP server |
| TFTPClient     |                  | NAT64 or relay  |                  | (this pkg)  |
+----------------+                  +-----------------+                  +-----+-------+
                                                                               |
                                                                          +----v-----+
                                                                          | SQLite   |
                                                                          | (WAL)    |
                                                                          +----------+
```

- **Device side**: `TFTPClient` opens a UDP socket, sends a WRQ to the server,
  receives ACK 0, sends one DATA, gets ACK 1. Done. (RRQ flow is symmetric.)
- **Border router**: bridges the IPv6 Thread network to the IPv4 server.
  The "how" is the load-bearing question — see *Network family* below.
- **Server side**: `TFTPServer` (to be built) accepts requests on UDP/69,
  spawns a Toit task per transfer with a fresh ephemeral UDP port, and
  delegates the actual file I/O to a pluggable `Storage` backend.

### Storage abstraction

Already landed in `src/storage.toit` (commits `322f3df`, `012bcf8`). Key shape:

```toit
abstract class Storage:
  abstract exists      name/string                       -> bool
  abstract size        name/string                       -> int?
  abstract reader-for  name/string                       -> io.Reader
  abstract writer-for  name/string --tsize-hint/int?=null -> io.Writer
  reads-allowed  -> bool: return true
  writes-allowed -> bool: return true
```

Sentinel exception strings (`STORAGE-FILE-NOT-FOUND`, `STORAGE-FILE-EXISTS`,
`STORAGE-ACCESS-DENIED`, `STORAGE-NO-SPACE`) let an implementation signal
well-known conditions; the server maps each to the appropriate TFTP error code.

`FilesystemStorage` is the bundled implementation, rooted at a directory and
parameterised with `--allow-overwrite` and `--read-only`. `SqliteStorage` is a
future implementation, sketched below.

### Server design

Planned (not yet implemented). The shape:

- One UDP socket on `:69` accepting requests.
- For each WRQ/RRQ datagram, the server spawns a Toit task that:
  1. Opens its own ephemeral UDP socket — the per-transfer TID.
  2. Performs the rest of the exchange on that ephemeral port; the device's
     reply path goes server-ephemeral ↔ device-ephemeral, freeing port 69
     for the next request.
  3. Calls `storage.reader-for` (RRQ) or `storage.writer-for` (WRQ) and
     streams data through.
  4. Closes the storage handle and the ephemeral socket on completion or
     error.
- N concurrent transfers run as N concurrent tasks on N ephemeral ports.
  This matches what `tftp-go` does and is the standard TFTP server
  architecture.

This per-transfer fan-out is what makes the server scale to many Thread
devices pushing simultaneously without head-of-line blocking on the
well-known port.

## Network family — the IPv6 constraint

Thread is IPv6 only at the link layer; the Toit TFTP server runs over IPv4.
A packet's destination address is one or the other, so v6 is not "routable
to" a v4 address — it has to be **translated** somewhere.

Toit's current UDP API does not expose IPv6 socket-family selection:

- `net.Interface.udp-open` returns whatever socket the SDK's defaults pick.
- There is no `--ipv6` flag, no `IPV6_V6ONLY` knob.
- On the host SDK that's an IPv4-only socket. On ESP32 it depends on the IDF
  build (typically v4 unless `LWIP_IPV6=1`).
- `net.modules.dns.dns-lookup` does have `--accept-ipv6/bool=false`; the
  client could opt in. The bigger problem is the server-side bind, not the
  client's destination resolution.

This rules out the most natural deployment ("dual-stack the server, bind
`[::]:69`") until the Toit SDK gains IPv6 listener support. That's an
upstream change, not something this package can fix.

### Three viable deployments

**Option A — Dual-stack server** *(blocked on Toit SDK)*
The Toit server binds `[::]:69` and accepts both v4 and v6. Cleanest, but
not buildable with the current `net.Interface.udp-open`. Revisit when /
if the SDK exposes family selection.

**Option B — NAT64 on the Border Router** *(recommended)*
- Configure the BR (OpenThread Border Router, Linux box with `tayga` or
  kernel `nf_nat64`, ...) with a NAT64 prefix, e.g. `64:ff9b::/96`.
- Thread devices target a synthetic v6 address that embeds the v4 server
  address, e.g. `64:ff9b::c000:0201` for `192.0.2.1`.
- The BR rewrites v6 → v4 on egress and v4 → v6 on the return path.
- No code changes in this package; the server stays IPv4. DNS64 is
  needed if devices use names instead of literals.

**Option C — Tiny v6 → v4 UDP relay on the Border Router**
- ~30 lines of Python or Go listening on `[::]:69`, forwarding each
  datagram to `127.0.0.1:69` (or wherever the Toit server lives) and
  shuttling replies back keyed by the source address.
- Easiest if NAT64 on your BR is awkward to configure.
- Slightly more moving parts than B, but isolates the IPv6 surface to a
  process you control.

### Recommendation

Use **Option B** unless your BR doesn't support NAT64, in which case fall
back to **Option C**. Document Option A as the eventual target if/when
the Toit SDK gains IPv6 listener support.

## SQLite backend (`SqliteStorage`)

### Where it lives

Recommended split:

- `tftp` (this package) — protocol, server, `Storage` interface,
  `FilesystemStorage`. No SQLite dependency.
- `tftp-sqlite` (separate package, depends on `tftp`) — `SqliteStorage`.
  Keeps anyone who just wants the protocol from pulling in a SQLite
  binding they don't need.

### Schema

Telemetry is time-series, append-only. The TFTP filename encodes the
device key; e.g. `dev-7e2/sensor.bin` ⇒ device `dev-7e2`, sensor name
`sensor.bin`. Each push is a new row, not an upsert:

```sql
CREATE TABLE telemetry(
  device  TEXT NOT NULL,
  name    TEXT NOT NULL,
  ts_ns   INTEGER NOT NULL,
  payload BLOB NOT NULL
);
CREATE INDEX telemetry_device_ts ON telemetry(device, ts_ns);
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
```

- `WAL` lets readers and a single writer overlap; without it the
  rollback journal serialises everything.
- `synchronous=NORMAL` is the right durability/performance trade-off
  for telemetry — losses on crash are bounded to the most recent
  WAL frames, not the whole transaction stream.
- The per-device + ts index supports the typical query
  ("latest N readings for device X") cheaply.

### Read semantics

`reader-for "dev-7e2/sensor.bin"` returns the latest `payload` for that
key. If you need historical reads via TFTP, the filename will need to
encode a timestamp or row id; otherwise, do bulk reads via the SQLite
file directly.

### Write path

Because payloads are tiny (~100 B), use the simple buffer-then-INSERT
pattern, *not* incremental BLOB I/O:

```toit
class BlobWriter_ extends io.Writer:
  buffer_/Buffer := Buffer
  ...
  write_ data from to:
    buffer_.write data from to
    return to - from
  close_:
    db_.execute "INSERT INTO telemetry(device, name, ts_ns, payload) VALUES (?, ?, ?, ?)"
        device_
        name_
        Time.monotonic-us * 1000
        buffer_.bytes
```

`tsize-hint` was added to `Storage.writer-for` for backends that
*pre-allocate* (S3 multipart, fixed-region flash, SQLite `zeroblob`
when payloads are large). At 100 B, `tsize-hint` is over-engineering;
ignore it in `BlobWriter_.constructor`.

### Concurrency

- Spawn a fresh SQLite `Connection` per server task, or share one and
  serialise via a mutex. WAL mode handles many short writes well in
  either model.
- A burst of N devices pushing at once will serialise on the writer
  lock for ~microseconds each. With 100 B payloads and SQLite's ~10⁵
  inserts/s on commodity SSD, this is comfortably below the saturation
  point for any plausible Thread mesh.

## Device-side considerations

### Energy / airtime

Every air-time second on a battery radio costs joules. Two settings
worth being deliberate about:

1. **Skip option negotiation when the payload fits the default block.**
   Sending `--blksize` or `--timeout-secs` on `TFTPClient` triggers an
   OACK round trip:

   ```
   without options:  RRQ → DATA1 → ACK1                       (3 packets)
   with options:     RRQ+opts → OACK → ACK0 → DATA1 → ACK1    (5 packets)
   ```

   For a 100 B push, no negotiation is needed; pass nothing but
   `--host`. Saves ~40% of the air-time per push.

2. **Don't request `tsize=0` on RRQ if you don't need the size.**
   Currently the client always sends `tsize=0` on RRQ to learn the
   server's file size. That triggers an OACK on every read. If
   devices are write-only (telemetry push), this is moot — only WRQ
   matters. If devices ever read, consider gating tsize behind a
   constructor flag.

### Block size

For 100 B payloads the default 512 is fine. The negotiated 1428-byte
or 4096-byte block sizes only pay off for transfers that span many
blocks; one-block transfers see no benefit and pay the OACK overhead.

### IPv6 client paths

`TFTPClient.open` calls `dns-lookup host --network=network_` without
`--accept-ipv6=true`, so today the client only resolves A records.
Two-line change to also resolve AAAA:

```toit
host-ip_ = dns-lookup host
    --network=network_
    --accept-ipv6=true
```

`IpAddress.parse` already handles literal v6 addresses without needing
the flag; the change matters only when the host is given as a name.

Caveat: link-local addresses (`fe80::/10`) require a zone identifier
(`fe80::1%eth0`) on multi-interface hosts. Toit's `IpAddress` does not
appear to model the zone separately. Practical implication: target the
device-routable Thread prefix (ULA / GUA) advertised by the BR, not
link-local.

## What's currently in this repo

- `src/packets.toit` — RFC 1350 + 2347 + 2348 + 2349 packet types.
- `src/tftp_client.toit` — full-featured client, TID validation,
  option negotiation, retry/timeout, DNS resolution.
- `src/storage.toit` — `Storage` abstract class, `FilesystemStorage`,
  sentinel exceptions, `tsize-hint`.
- `src/sdcard.toit`, `src/sha256_summer.toit` — auxiliary helpers
  (kept from prior versions).
- `tests/` — smoke, options, round-trip, large-transfer, blksize
  perf. All use `expect.*` so failures are visible to CI.
- `examples/` — small read/write demos for host and ESP32.

Recent commits relevant to this design:

- `72a4631` — original review fixes (correctness, robustness, perf).
- `322f3df` — DNS, RFC 2347/2348/2349 options, Storage scaffolding.
- `012bcf8` — `--tsize-hint` on `Storage.writer-for`.

## Open questions / pending decisions

1. **Server lands here or as a sub-package?** Lean: here. The protocol
   layer and the server share enough machinery that splitting them
   would mean lifting `Packet`, `parse-options_`, `MAX-TRIES_`, etc.
   into a third "common" package nobody asked for.
2. **`SqliteStorage` lands here or as `tftp-sqlite`?** Lean: separate
   package, so `tftp` stays free of a SQLite binding choice.
3. **Client `--accept-ipv6=true`?** Lean: yes, it's a two-line change
   and it's harmless when only A records exist.
4. **NAT64 vs relay on the BR?** Deployment-time choice; doesn't
   change any code in either repo.
5. **Schema details for telemetry — append-style as described, or
   upsert-on-name?** Lean: append. Devices producing one observation
   per push want history; upserts throw it away.

The next session decides which of (1) – (3) to land first.
