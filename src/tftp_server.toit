// Copyright 2026 Ekorau LLC.

import io
import io.buffer show Buffer
import log
import monitor
import net
import net.udp

import .exchange
import .packets
import .storage

/**
TFTP server.

Listens on a single UDP port (default $TFTP-DEFAULT-PORT) and accepts
  initial RRQ/WRQ datagrams. Each request spawns a per-transfer task on
  its own ephemeral UDP socket so the listen port is freed for the next
  request immediately. Concurrent transfers run as concurrent tasks on
  independent ports — the standard TFTP server fan-out.

Storage is provided via the $Storage interface; the bundled
  $FilesystemStorage serves a directory tree, and separate packages can
  implement other backends (e.g. SqliteStorage in tftp-sqlite).

The per-transfer state machine is $ServerExchange. The current
  implementation handles WRQ end-to-end; RRQ replies with TFTP error 4
  ("RRQ not yet implemented") until the read path lands.

# Privileged port
On Linux, binding port 69 requires the CAP_NET_BIND_SERVICE capability or
  root. For testing and ESP32 deployments use a non-privileged port via
  the constructor's `--port` argument. The bundled
  `examples/server-host.toit` exposes a `--port` flag for this reason.

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
  capacity_/Capacity_? := null
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
    if max-concurrent < 1: throw "max-concurrent must be >= 1"
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
    capacity_ = Capacity_ max-concurrent_
    logger_.info "tftp server listening" --tags={"port": port_}
    try:
      while not stopping_:
        msg/udp.Datagram? := null
        err := catch:
          msg = listen-socket_.receive
        if err != null:
          if stopping_: break
          logger_.warn "listen receive failed" --tags={"error": err}
          sleep --ms=10
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
      capacity_ = null
      stopping_ = false
      logger_.info "tftp server stopped"

  /** Closes the listen socket; $start returns. Idempotent. */
  stop -> none:
    if stopping_: return
    stopping_ = true
    if listen-socket_ != null:
      listen-socket_.close

  /**
  Decodes $msg and, on a valid RRQ/WRQ, spawns a per-transfer task that
    drives a $ServerExchange to completion on its own ephemeral UDP
    socket. Malformed datagrams are dropped with a warning; unsupported
    opcodes get TFTP error 4. Requests rejected by the concurrency cap
    receive TFTP error 0 ("Server busy").
  */
  dispatch_ msg/udp.Datagram -> none:
    packet/Packet? := null
    err := catch: packet = Packet.deserialize (io.Reader msg.data)
    if err != null:
      logger_.warn "malformed datagram" --tags={"peer": msg.address, "error": err}
      return
    if packet == null:
      logger_.warn "unrecognized opcode" --tags={"peer": msg.address}
      return
    if packet is not PacketRRQ and packet is not PacketWRQ:
      reply := PacketERROR 4 "Illegal TFTP operation"
      listen-socket_.send (udp.Datagram reply.serialize msg.address)
      return
    if not capacity_.try-acquire:
      reply := PacketERROR 0 "Server busy"
      listen-socket_.send (udp.Datagram reply.serialize msg.address)
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
        capacity_.release

/**
Per-transfer state machine running on a server-side ephemeral UDP socket.

Inherits the shared loop, retry, and TID-enforcement logic from $Exchange.
  Direction-specific frame building and packet handling live here.
*/
class ServerExchange extends Exchange:
  storage_/Storage
  initial_/Packet                     // PacketRRQ or PacketWRQ
  source_/net.SocketAddress
  filename_/string
  mode_/string

  storage-writer_/io.CloseableWriter? := null
  storage-reader_/io.CloseableReader? := null
  /** Set when $next-frame should send the OACK once and only once. */
  pending-oack_/PacketOACK? := null

  /**
  Builds an exchange for the request in $initial_ received from $source_.

  Caller (the dispatcher) opens $socket as the per-transfer ephemeral
    socket. $storage_ is the shared backend.
  */
  constructor initial/Packet source/net.SocketAddress storage/Storage socket/udp.Socket logger/log.Logger:
    initial_ = initial
    source_ = source
    storage_ = storage
    if initial is PacketRRQ:
      filename_ = (initial as PacketRRQ).filename
      mode_ = (initial as PacketRRQ).mode
    else:
      filename_ = (initial as PacketWRQ).filename
      mode_ = (initial as PacketWRQ).mode
    super socket logger
    peer-tid_ = source
    dest_ = source

  /** Drives the request to completion. Maps storage exceptions to TFTP errors. */
  run -> none:
    err := catch --trace=false:
      if not validate-request_: return
      if initial_ is PacketWRQ:
        run-wrq_ (initial_ as PacketWRQ)
      else:
        run-rrq_ (initial_ as PacketRRQ)
    if err != null:
      if peer-gone_:
        logger_.warn "transfer abandoned: peer gone"
            --tags={"peer": source_, "block": block-num_}
      else:
        handle-storage-error_ err

  /**
  Returns true if the request is acceptable, false otherwise.

  On rejection sends an ERROR packet to the peer; the caller must abort
    without invoking $handle-storage-error_ (which would send a second
    ERROR with a different code).
  */
  validate-request_ -> bool:
    if mode_ != OCTET:
      send-error_ 4 "Only octet mode supported"
      return false
    if filename_.size == 0 or filename_.size > 128:
      send-error_ 4 "Bad filename length"
      return false
    return true

  run-wrq_ wrq/PacketWRQ -> none:
    tsize-hint/int? := null
    if wrq.options.contains OPT-TSIZE:
      tsize-hint = int.parse wrq.options[OPT-TSIZE] --if-error=(: null)
    storage-writer_ = storage_.writer-for filename_ --tsize-hint=tsize-hint
    pending-oack_ = build-oack_ wrq.options --is-write
    blksize_ = negotiated-blksize_ pending-oack_
    // First outbound is OACK (if options accepted) or ACK 0 (RFC 1350);
    // either way the peer's first DATA carries block 1.
    opcode_ = WRQ
    block-num_ = 0
    tries_ = 0
    drained_ = false
    try:
      drive_
    finally:
      // The happy WRQ path closes and nulls the writer in handle-data_ on the
      // last block. Any other exit (validation throw, storage error mid-write,
      // peer ERROR, max-retry timeout) lands here with the writer still open.
      if storage-writer_ != null:
        catch: storage-writer_.close
        storage-writer_ = null

  run-rrq_ rrq/PacketRRQ -> none:
    storage-reader_ = storage_.reader-for filename_
    pending-oack_ = build-oack_ rrq.options --no-is-write
    blksize_ = negotiated-blksize_ pending-oack_
    opcode_ = RRQ
    if pending-oack_ != null:
      // Per RFC 2347, the client confirms an RRQ-OACK with ACK 0; we then
      // send DATA 1. With block-num_=0 here, handle-rrq-ack_'s ack-matches
      // branch advances naturally to block 1 and opcode_=DATA.
      block-num_ = 0
    else:
      block-num_ = 1
    tries_ = 0
    drained_ = false
    try:
      drive_
    finally:
      // Close the reader on every exit (happy path included): unlike the
      // writer, there's no commit step so closing here is the only place.
      if storage-reader_ != null:
        catch: storage-reader_.close
        storage-reader_ = null

  /**
  Builds an OACK echoing the subset of $client-options the server accepts.

  Recognized options: blksize (RFC 2348, clamped to MIN/MAX-BLKSIZE),
    tsize (RFC 2349; echoed for WRQ, populated from $Storage.size for
    RRQ), and timeout (RFC 2349; informational — the server's receive
    timeout stays fixed at $DEFAULT-TIMEOUT-MS_ for predictable retry
    pacing). Returns null if no option was accepted, in which case the
    server falls through to the standard RFC 1350 exchange.
  */
  build-oack_ client-options/Map --is-write/bool -> PacketOACK?:
    accepted := {:}
    client-options.do: | name/string value/string |
      if name == OPT-BLKSIZE:
        n := int.parse value --if-error=(: -1)
        if MIN-BLKSIZE <= n <= MAX-BLKSIZE:
          accepted[OPT-BLKSIZE] = "$n"
      else if name == OPT-TSIZE:
        if is-write:
          accepted[OPT-TSIZE] = value
        else:
          size := storage_.size filename_
          if size != null:
            accepted[OPT-TSIZE] = "$size"
      else if name == OPT-TIMEOUT:
        n := int.parse value --if-error=(: -1)
        if 1 <= n <= 255:
          accepted[OPT-TIMEOUT] = "$n"
    if accepted.is-empty: return null
    return PacketOACK accepted

  /** Returns the blksize that should drive subsequent DATA frames. */
  negotiated-blksize_ oack/PacketOACK? -> int:
    if oack == null: return DEFAULT-BLKSIZE
    s := oack.options.get OPT-BLKSIZE
    if s == null: return DEFAULT-BLKSIZE
    return int.parse s

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
    logger_.warn "transfer failed" --tags={"error": err, "peer": source_}

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
    if opcode_ == RRQ or opcode_ == DATA: return next-data-frame_
    return (PacketERROR 0 "Invalid opcode: $opcode_").serialize

  wrq-ack0-frame_ -> ByteArray:
    cached_ = (PacketACK 0).serialize
    return cached_

  ack-frame_ -> ByteArray:
    cached_ = (PacketACK block-num_).serialize
    return cached_

  next-data-frame_ -> ByteArray:
    chunk := bytes-to-send_ blksize_
    if chunk.size < blksize_: drained_ = true
    cached_ = (PacketDATA block-num_ chunk).serialize
    return cached_

  /**
  Reads up to $size bytes from $storage-reader_, looping until the request
    is filled or EOF.

  $io.Reader.read may return fewer bytes than requested even when more data
    is available, so a single call can't be relied on to fill a TFTP DATA
    block.
  */
  bytes-to-send_ size/int -> ByteArray:
    result := Buffer
    while result.size < size:
      chunk := storage-reader_.read --max-size=(size - result.size)
      if chunk == null: break
      result.write chunk
    return result.bytes

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

/**
A small monitor wrapping a counter with non-blocking acquire semantics.

The SDK's $monitor.Semaphore exposes only blocking $monitor.Semaphore.down,
  but the dispatcher must be able to test the cap and either reserve a
  slot or reject the request immediately. This monitor's $try-acquire
  performs that test+take atomically.

# Cancellation contract
A successful $try-acquire must be paired with $release in a `finally` on
  the same task. If the holder is task-cancelled between $try-acquire and
  $release, the slot leaks (this monitor has no per-task ownership tracking).
*/
monitor Capacity_:
  count_/int := 0
  limit_/int

  constructor .limit_:

  /** Atomically reserves a slot if available. Returns whether one was reserved. */
  try-acquire -> bool:
    if count_ >= limit_: return false
    count_++
    return true

  /** Releases a previously acquired slot. */
  release -> none:
    if count_ > 0: count_--
