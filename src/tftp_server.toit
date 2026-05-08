// Copyright 2026 Ekorau LLC.

import io
import log
import monitor
import net
import net.udp

import .packets
import .storage

/**
TFTP server.

Listens on a single UDP port (default $TFTP-DEFAULT-PORT) and accepts
  initial RRQ/WRQ datagrams. Each request will, in a later milestone,
  spawn a per-transfer task on its own ephemeral UDP socket so the
  listen port is freed for the next request immediately. Concurrent
  transfers run as concurrent tasks on independent ports — the standard
  TFTP server fan-out.

Storage is provided via the $Storage interface; the bundled
  $FilesystemStorage serves a directory tree, and separate packages can
  implement other backends (e.g. SqliteStorage in tftp-sqlite).

This skeleton handles the listen loop and dispatcher; RRQ/WRQ requests
  currently receive a placeholder TFTP error 4 ("Server not yet
  implemented"). Per-transfer logic lands in the next milestone.

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
  Decodes $msg, applies the concurrency cap, and replies with the
    placeholder error for RRQ/WRQ. Malformed datagrams are dropped with
    a warning; unsupported opcodes get TFTP error 4.
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
    try:
      // Placeholder until ServerExchange lands. The slot is released in
      // this finally for now; once a per-transfer task is spawned the
      // release will move into that task's finally and this synchronous
      // try/finally will go away.
      reply := PacketERROR 4 "Server not yet implemented"
      listen-socket_.send (udp.Datagram reply.serialize msg.address)
    finally:
      capacity_.release

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
