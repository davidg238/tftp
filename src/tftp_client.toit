// Copyright 2023, 2026 Ekorau LLC.

import io
import io.buffer show Buffer
import io.reader show Reader
import io.writer show Writer
import net
import net.udp

import .packets

/**
TFTP client supporting read and write requests, per RFC 1350.

Only octet (binary) mode is supported. The client is single-shot per call: a
  read or write occupies the underlying socket from request to last
  acknowledgement; the client may be reused for further transfers afterwards.

The server's transfer ID (TID) is locked to the source of the first reply and
  enforced for the rest of the exchange; datagrams from any other end-point
  are answered with TFTP error 5 ("Unknown transfer ID") and otherwise
  ignored, as required by RFC 1350 §4.

# Block-number range
TFTP block numbers are unsigned 16-bit. With the default 512-byte block size,
  this implementation can transfer up to about 33.5 MB per call before the
  block counter exhausts. Variable block size (RFC 2348) is not yet
  implemented; see the package README.
*/

/** Default TFTP port. */
TFTP-DEFAULT-PORT ::= 69

/**
Default per-receive timeout, in milliseconds.
Kept short so transient packet loss is recovered from quickly. The
  retransmission budget is $DEFAULT-TIMEOUT-MS_ * $MAX-TRIES_ ms in total.
*/
DEFAULT-TIMEOUT-MS_ ::= 1_000

/**
Maximum retransmissions before giving up on a packet.
Set higher than the typical RFC 1350 value of 3 to better tolerate localhost
  UDP buffer pressure and similar transient losses on lossy links.
*/
MAX-TRIES_ ::= 12

/**
TFTP client to a remote server.

Construct with --host=, then call $open before issuing reads or writes, and
  $close when done.
*/
class TFTPClient:
  host/string
  host-ip_/net.IpAddress

  /**
  The TFTP port for outbound requests. Reset to $TFTP-DEFAULT-PORT after each
    transfer so the client can be reused.
  */
  port/int := TFTP-DEFAULT-PORT

  network_/net.Interface? := null
  socket_/udp.Socket? := null
  server-address_/net.SocketAddress? := null
  server-tid_/net.SocketAddress? := null

  blksize_/int := DEFAULT-BLKSIZE
  reader_/Reader? := null
  writer_/io.Writer? := null
  buffer_/Buffer? := null
  streaming-reads_/bool := false
  byte-count_/int := 0

  filename_/string? := null
  mode_/string := OCTET

  constructor --.host:
    host-ip_ = net.IpAddress.parse host

  /** Opens the network and UDP socket. Idempotent. */
  open -> none:
    if socket_ != null: return
    network_ = net.open
    socket_ = network_.udp-open
    server-address_ = net.SocketAddress host-ip_ port

  /** Closes the UDP socket and the network. Idempotent. */
  close -> none:
    if socket_ != null:
      socket_.close
      socket_ = null
    if network_ != null:
      network_.close
      network_ = null

  /**
  Writes the string $msg to the remote server as $filename.
  Returns the number of bytes written.
  */
  write-string msg/string --filename/string -> int:
    return write-bytes msg.to-byte-array --filename=filename

  /**
  Writes the byte array $data to the remote server as $filename.
  Returns the number of bytes written.
  */
  write-bytes data/ByteArray --filename/string -> int:
    return write-stream (io.Reader data) --filename=filename

  /**
  Writes everything readable from $source to the remote server as $filename.
  Returns the number of bytes written.
  */
  write-stream source/Reader --filename/string -> int:
    ensure-open_
    validate-filename_ filename
    filename_ = filename.trim
    mode_ = OCTET
    reader_ = source
    byte-count_ = 0
    try:
      exchange := ClientExchange this
      exchange.write
    finally:
      reset-state_
    return byte-count_

  /**
  Reads $filename from the remote server and returns its bytes.

  The whole file is buffered in memory; for large files prefer $read.
  */
  read-bytes filename/string -> ByteArray:
    ensure-open_
    validate-filename_ filename
    filename_ = filename.trim
    mode_ = OCTET
    buffer_ = Buffer
    streaming-reads_ = false
    byte-count_ = 0
    try:
      exchange := ClientExchange this
      exchange.read
      return buffer_.bytes
    finally:
      reset-state_

  /**
  Reads $filename from the remote server and writes its contents to $to-writer.

  Returns the number of bytes read.
  */
  read filename/string --to-writer/io.Writer -> int:
    ensure-open_
    validate-filename_ filename
    filename_ = filename.trim
    mode_ = OCTET
    writer_ = to-writer
    streaming-reads_ = true
    byte-count_ = 0
    try:
      exchange := ClientExchange this
      exchange.read
    finally:
      reset-state_
    return byte-count_

  ensure-open_ -> none:
    if socket_ == null: throw "TFTP: client not open"

  validate-filename_ name/string -> none:
    if name.size == 0: throw "TFTP: filename is empty"
    if name.size > 128: throw "TFTP: filename too long ($name.size > 128)"

  /** Sends $payload to the current $server-address_ (or the locked TID once known). */
  send_ payload/ByteArray -> none:
    target := server-tid_ != null ? server-tid_ : server-address_
    socket_.send (udp.Datagram payload target)

  /**
  Receives the next packet relevant to this transfer.

  Datagrams from end-points other than the locked $server-tid_ are answered
    with TFTP error 5 and skipped, as required by RFC 1350 §4. Returns
    $PacketTIMEOUT if no relevant datagram arrives within $DEFAULT-TIMEOUT-MS_.
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
      if not is-from-server_ msg.address:
        // Datagram from an unexpected source. RFC 1350 §4: reply with
        // error 5 and continue waiting on the original transfer.
        send-unknown-tid_ msg.address
        continue
      // First reply locks the server's TID for the rest of the exchange.
      if server-tid_ == null: server-tid_ = msg.address
      packet := Packet.deserialize (io.Reader msg.data)
      if packet == null: continue  // Malformed; treat as if not received.
      return packet

  is-from-server_ source/net.SocketAddress -> bool:
    if source.ip != host-ip_: return false
    if server-tid_ == null: return true
    return source == server-tid_

  send-unknown-tid_ source/net.SocketAddress -> none:
    err := PacketERROR 5 "Unknown transfer ID"
    socket_.send (udp.Datagram err.serialize source)

  /** Reads up to $size bytes from the current source reader; returns an empty array at EOF. */
  bytes-to-send_ size/int -> ByteArray:
    chunk := reader_.read --max-size=size
    return chunk == null ? #[] : chunk

  /** Called by the exchange when a DATA payload has been received. */
  bytes-received_ data/ByteArray -> none:
    byte-count_ += data.size
    if streaming-reads_:
      writer_.write data
    else:
      buffer_.write data

  /** Called by the exchange when DATA has been sent successfully. */
  bytes-written_ size/int -> none:
    byte-count_ += size

  reset-state_ -> none:
    server-tid_ = null
    reader_ = null
    writer_ = null
    buffer_ = null
    filename_ = null
    streaming-reads_ = false

/**
State machine driving a single TFTP request/response exchange.

Owns the per-transfer state (block number, retry counter, cached frame for
  retransmission) and is destroyed at the end of each call to $TFTPClient
  read or write.

# Protocol summary
- Write: WRQ -> ACK0, then DATA(n)/ACK(n) until a DATA shorter than blksize.
- Read:  RRQ -> DATA(1)/ACK(1) ... last DATA shorter than blksize.

A timeout retransmits the cached frame up to $MAX-TRIES_ before aborting.
*/
class ClientExchange:
  client_/TFTPClient

  opcode_/int := -1
  cached_/ByteArray := #[]
  block-num_/int := 0
  tries_/int := 0
  drained_/bool := false
  blksize_/int := DEFAULT-BLKSIZE

  constructor .client_/TFTPClient:

  /** Drives a write (WRQ) exchange to completion. */
  write -> none:
    opcode_ = WRQ
    block-num_ = 0
    tries_ = 0
    drained_ = false
    while opcode_ != EXIT:
      client_.send_ writer-bytes_
      handle-write_ client_.receive_

  /** Drives a read (RRQ) exchange to completion. */
  read -> none:
    opcode_ = RRQ
    block-num_ = 1
    tries_ = 0
    drained_ = false
    while opcode_ != EXIT:
      client_.send_ reader-bytes_
      handle-read_ client_.receive_

  // ---- write side ---------------------------------------------------------

  writer-bytes_ -> ByteArray:
    if tries_ > 0: return cached_
    if opcode_ == WRQ: return wrq-frame_
    if opcode_ == DATA: return next-data-frame_
    return (PacketERROR 0 "Invalid opcode: $opcode_").serialize

  wrq-frame_ -> ByteArray:
    cached_ = (PacketWRQ client_.filename_ client_.mode_).serialize
    return cached_

  next-data-frame_ -> ByteArray:
    chunk := client_.bytes-to-send_ blksize_
    if chunk.size < blksize_: drained_ = true
    cached_ = (PacketDATA block-num_ chunk).serialize
    client_.bytes-written_ chunk.size
    return cached_

  handle-write_ received/Packet -> none:
    if received.opcode == ERROR:
      exit-error_ (received as PacketERROR)
      return
    if received.opcode == TIMEOUT:
      retry-or-abort_
      return
    if opcode_ == WRQ and received.opcode == ACK:
      start-writing_ (received as PacketACK)
      return
    if opcode_ == DATA and received.opcode == ACK:
      keep-writing_ (received as PacketACK)
      return
    // Anything else is unexpected; treat as a stale packet and resend cached.
    schedule-retransmit_

  start-writing_ ack/PacketACK -> none:
    if ack.block-num != 0:
      throw "TFTP: invalid ACK block-num $ack.block-num for WRQ (expected 0)"
    opcode_ = DATA
    block-num_ = 1
    tries_ = 0

  keep-writing_ ack/PacketACK -> none:
    if ack.block-num != block-num_:
      // Stale or duplicate ACK; do not advance the data reader. Force the
      // next iteration to resend the cached DATA frame.
      schedule-retransmit_
      return
    if drained_:
      opcode_ = EXIT
      return
    next := block-num_ + 1
    if next > MAX-BLOCK-NUM_:
      throw "TFTP: block number would exceed $MAX-BLOCK-NUM_; file too large"
    block-num_ = next
    tries_ = 0

  // ---- read side ----------------------------------------------------------

  reader-bytes_ -> ByteArray:
    if tries_ > 0: return cached_
    if opcode_ == RRQ: return rrq-frame_
    if opcode_ == ACK: return ack-frame_
    return (PacketERROR 0 "Invalid opcode: $opcode_").serialize

  rrq-frame_ -> ByteArray:
    cached_ = (PacketRRQ client_.filename_ client_.mode_).serialize
    return cached_

  ack-frame_ -> ByteArray:
    cached_ = (PacketACK block-num_).serialize
    block-num_ += 1
    tries_ = 0
    return cached_

  handle-read_ received/Packet -> none:
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
    if data.block-num == block-num_:
      // Expected block.
      if data.data.size < blksize_: drained_ = true
      client_.bytes-received_ data.data
      tries_ = 0
      opcode_ = ACK
      if drained_:
        // Send final ACK directly; the loop must not advance to read another
        // datagram from the now-closed transfer.
        client_.send_ ack-frame_
        opcode_ = EXIT
      return
    if data.block-num < block-num_:
      // Duplicate of an already-ACKed block; resend the last cached ACK if we
      // have one. Otherwise drop silently.
      if cached_.size > 0: schedule-retransmit_
      return
    // data.block-num > block-num_: future block, server is out of sync.
    schedule-retransmit_

  // ---- shared helpers -----------------------------------------------------

  exit-error_ err/PacketERROR -> none:
    opcode_ = EXIT
    throw "TFTP: server error $err.error-code at block $block-num_: $err.resolved-msg"

  retry-or-abort_ -> none:
    tries_++
    if tries_ >= MAX-TRIES_:
      opcode_ = EXIT
      throw "TFTP: timed out at block $block-num_ after $MAX-TRIES_ retries"

  /**
  Forces the next outbound send to reuse $cached_ instead of building a fresh
    frame. Used when an unexpected reply arrives and the safe action is to
    retransmit our last packet.
  */
  schedule-retransmit_ -> none:
    if tries_ == 0: tries_ = 1
