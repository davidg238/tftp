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
  storage-reader_/io.Reader? := null
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
      validate-request_
      if initial_ is PacketWRQ:
        run-wrq_ (initial_ as PacketWRQ)
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
