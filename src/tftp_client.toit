// Copyright 2023, 2026 Ekorau LLC.

import io
import io.buffer show Buffer
import io.reader show Reader
import io.writer show Writer
import log
import net
import net.modules.dns show dns-lookup
import net.udp

import .exchange
import .packets

/**
TFTP client supporting read and write requests.

Implements RFC 1350 (base protocol) plus the option extensions of RFC 2347
  (option negotiation), RFC 2348 (block size) and RFC 2349 (transfer size,
  timeout interval). Only octet (binary) transfer mode is supported.

The server's transfer ID (TID) is locked to the source of the first reply
  and enforced for the rest of the exchange; datagrams from any other
  end-point are answered with TFTP error 5 ("Unknown transfer ID") and
  otherwise ignored, as required by RFC 1350 §4.

# Block-number range
TFTP block numbers are unsigned 16-bit, so a single transfer is limited to
  $MAX-BLOCK-NUM_ blocks. With the default 512-byte block size that is about
  33.5 MB; with the maximum 65464-byte block size it is about 4.3 GB. To use
  a larger block size set the constructor's `--blksize` option; the server
  is free to negotiate it down.
*/

/** Default TFTP port. */
TFTP-DEFAULT-PORT ::= 69

/**
TFTP client to a remote server.

Construct with --host=, then call $open before issuing reads or writes,
  and $close when done. Optionally pass --blksize and --timeout-secs to
  request RFC 2348 / RFC 2349 negotiation.
*/
class TFTPClient:
  host/string
  host-ip_/net.IpAddress? := null

  /**
  The TFTP port for outbound requests. Reset to $TFTP-DEFAULT-PORT after each
    transfer so the client can be reused.
  */
  port/int := TFTP-DEFAULT-PORT

  network_/net.Interface? := null
  socket_/udp.Socket? := null
  server-address_/net.SocketAddress? := null
  logger_/log.Logger

  /**
  Block size requested via RFC 2348. If null, the request is sent without
    the option and the protocol uses the 512-byte default.
  */
  requested-blksize_/int? := null

  /**
  Timeout interval requested via RFC 2349, in seconds. If null, the option is
    omitted from the request.
  */
  requested-timeout-secs_/int? := null

  /** Block size in effect for the current exchange. */
  blksize_/int := DEFAULT-BLKSIZE

  /**
  Tsize the client should advertise on the next WRQ, or null. Set
    automatically by $write-string / $write-bytes; may be set explicitly via
    the $write-stream `--tsize` parameter.
  */
  pending-tsize_/int? := null

  /**
  Tsize learned from the server's most recent OACK. For RRQ this is the
    file size the server is about to send; for WRQ it confirms the size the
    client advertised. Null when no OACK was received or no tsize option
    was negotiated.
  */
  last-tsize_/int? := null

  reader_/Reader? := null
  writer_/io.Writer? := null
  buffer_/Buffer? := null
  streaming-reads_/bool := false
  byte-count_/int := 0

  filename_/string? := null
  mode_/string := OCTET

  constructor
      --.host/string
      --blksize/int?=null
      --timeout-secs/int?=null
      --logger/log.Logger=log.default:
    if blksize != null and not MIN-BLKSIZE <= blksize <= MAX-BLKSIZE:
      throw "TFTP: blksize $blksize out of range $MIN-BLKSIZE..$MAX-BLKSIZE"
    if timeout-secs != null and not 1 <= timeout-secs <= 255:
      throw "TFTP: timeout-secs $timeout-secs out of range 1..255"
    requested-blksize_ = blksize
    requested-timeout-secs_ = timeout-secs
    logger_ = logger

  /**
  Opens the network and UDP socket, resolving $host via DNS if it is a name
    rather than an IP literal. Idempotent.
  */
  open -> none:
    if socket_ != null: return
    network_ = net.open
    // dns-lookup short-circuits when host is already a numeric address.
    host-ip_ = dns-lookup host --network=network_
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
  Returns the file size the server reported in OACK on the most recent read,
    or that the client advertised on the most recent write, or null when no
    tsize option was negotiated.
  */
  last-tsize -> int?:
    return last-tsize_

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
    return write-stream (io.Reader data) --filename=filename --tsize=data.size

  /**
  Writes everything readable from $source to the remote server as $filename.

  Pass --tsize when you know the source's total size in advance; the value
    is advertised via the RFC 2349 tsize option so the server can detect
    insufficient space early. Returns the number of bytes written.
  */
  write-stream source/Reader --filename/string --tsize/int?=null -> int:
    ensure-open_
    validate-filename_ filename
    filename_ = filename.trim
    mode_ = OCTET
    reader_ = source
    pending-tsize_ = tsize
    byte-count_ = 0
    last-tsize_ = null
    try:
      exchange := ClientExchange this
      exchange.start-with-wrq
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
    last-tsize_ = null
    try:
      exchange := ClientExchange this
      exchange.start-with-rrq
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
    last-tsize_ = null
    try:
      exchange := ClientExchange this
      exchange.start-with-rrq
    finally:
      reset-state_
    return byte-count_

  ensure-open_ -> none:
    if socket_ == null: throw "TFTP: client not open"

  validate-filename_ name/string -> none:
    if name.size == 0: throw "TFTP: filename is empty"
    if name.size > 128: throw "TFTP: filename too long ($name.size > 128)"

  /**
  Reads exactly $size bytes from the current source reader, or fewer if the
    stream ends first. Returns an empty array at EOF.

  $Reader.read may return a partial chunk even when more data is available, so
    we loop until we either fill the request or hit end-of-stream.
  */
  bytes-to-send_ size/int -> ByteArray:
    result := Buffer
    while result.size < size:
      chunk := reader_.read --max-size=(size - result.size)
      if chunk == null: break
      result.write chunk
    return result.bytes

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

  /** Builds the option map to send for the upcoming WRQ/RRQ, or null if none. */
  build-options_ --is-write/bool -> Map?:
    options := {:}
    if requested-blksize_ != null:
      options[OPT-BLKSIZE] = "$requested-blksize_"
    if requested-timeout-secs_ != null:
      options[OPT-TIMEOUT] = "$requested-timeout-secs_"
    if is-write:
      if pending-tsize_ != null: options[OPT-TSIZE] = "$pending-tsize_"
    else:
      // For RRQ, tsize=0 asks the server to report the file size.
      options[OPT-TSIZE] = "0"
    return options.is-empty ? null : options

  reset-state_ -> none:
    reader_ = null
    writer_ = null
    buffer_ = null
    filename_ = null
    streaming-reads_ = false
    pending-tsize_ = null
    blksize_ = DEFAULT-BLKSIZE

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
    dest_ = client_.server-address_
    requested-options_ = client_.build-options_ --is-write
    drive_

  /** Drives a read (RRQ) exchange to completion. */
  start-with-rrq -> none:
    opcode_ = RRQ
    block-num_ = 1
    tries_ = 0
    drained_ = false
    blksize_ = DEFAULT-BLKSIZE
    dest_ = client_.server-address_
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
