// Copyright 2023, 2026 Ekorau LLC.

import io
import io.buffer show Buffer
import io.reader show Reader
import io.writer show Writer
import net
import net.modules.dns show dns-lookup
import net.udp

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
Default per-receive timeout, in milliseconds.

Kept short so transient packet loss is recovered from quickly. The
  retransmission budget is $DEFAULT-TIMEOUT-MS_ * $MAX-TRIES_ ms in total.
*/
DEFAULT-TIMEOUT-MS_ ::= 1_000

/**
Maximum retransmissions before giving up on a packet.

Set higher than the typical RFC 1350 value of 3 to better tolerate UDP
  buffer pressure and similar transient losses on lossy links.
*/
MAX-TRIES_ ::= 12

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
  server-tid_/net.SocketAddress? := null

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
      --timeout-secs/int?=null:
    if blksize != null and not MIN-BLKSIZE <= blksize <= MAX-BLKSIZE:
      throw "TFTP: blksize $blksize out of range $MIN-BLKSIZE..$MAX-BLKSIZE"
    if timeout-secs != null and not 1 <= timeout-secs <= 255:
      throw "TFTP: timeout-secs $timeout-secs out of range 1..255"
    requested-blksize_ = blksize
    requested-timeout-secs_ = timeout-secs

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
    last-tsize_ = null
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
    last-tsize_ = null
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
        send-unknown-tid_ msg.address
        continue
      if server-tid_ == null: server-tid_ = msg.address
      packet := Packet.deserialize (io.Reader msg.data)
      if packet == null: continue
      return packet

  is-from-server_ source/net.SocketAddress -> bool:
    if source.ip != host-ip_: return false
    if server-tid_ == null: return true
    return source == server-tid_

  send-unknown-tid_ source/net.SocketAddress -> none:
    err := PacketERROR 5 "Unknown transfer ID"
    socket_.send (udp.Datagram err.serialize source)

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
    server-tid_ = null
    reader_ = null
    writer_ = null
    buffer_ = null
    filename_ = null
    streaming-reads_ = false
    pending-tsize_ = null
    blksize_ = DEFAULT-BLKSIZE

/**
State machine driving a single TFTP request/response exchange.

Owns the per-transfer state (block number, retry counter, cached frame for
  retransmission) and is destroyed at the end of each call to $TFTPClient
  read or write.

# Protocol summary
Without options:
- Write: WRQ -> ACK0, then DATA(n)/ACK(n) until DATA shorter than blksize.
- Read:  RRQ -> DATA(1)/ACK(1) ... last DATA shorter than blksize.

With RFC 2347 options:
- Write: WRQ+opts -> OACK -> (treat as ACK0) DATA(1)/ACK(1) ...
- Read:  RRQ+opts -> OACK -> ACK(0) -> DATA(1)/ACK(1) ...

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
  /** Options that were sent in the most recent RRQ/WRQ. */
  requested-options_/Map? := null

  constructor .client_/TFTPClient:

  /** Drives a write (WRQ) exchange to completion. */
  write -> none:
    opcode_ = WRQ
    block-num_ = 0
    tries_ = 0
    drained_ = false
    blksize_ = DEFAULT-BLKSIZE
    requested-options_ = client_.build-options_ --is-write
    while opcode_ != EXIT:
      client_.send_ writer-bytes_
      handle-write_ client_.receive_

  /** Drives a read (RRQ) exchange to completion. */
  read -> none:
    opcode_ = RRQ
    block-num_ = 1
    tries_ = 0
    drained_ = false
    blksize_ = DEFAULT-BLKSIZE
    requested-options_ = client_.build-options_ --no-is-write
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
    if received.opcode == ERROR:
      exit-error_ (received as PacketERROR)
      return
    if received.opcode == TIMEOUT:
      retry-or-abort_
      return
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

  reader-bytes_ -> ByteArray:
    if tries_ > 0: return cached_
    if opcode_ == RRQ: return rrq-frame_
    if opcode_ == ACK: return ack-frame_
    return (PacketERROR 0 "Invalid opcode: $opcode_").serialize

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
    if received.opcode == ERROR:
      exit-error_ (received as PacketERROR)
      return
    if received.opcode == TIMEOUT:
      retry-or-abort_
      return
    if opcode_ == RRQ and received.opcode == OACK:
      apply-oack_ (received as PacketOACK)
      // Per RFC 2347, ACK block 0 to confirm the OACK, then expect DATA 1.
      // Stage the ACK in the loop's normal send/receive cadence by setting
      // block-num_ back to 0; ack-frame_ on the next iteration will emit
      // ACK 0 and advance block-num_ to 1, ready for DATA 1.
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
        client_.send_ ack-frame_
        opcode_ = EXIT
      return
    if data.block-num < block-num_:
      if cached_.size > 0: schedule-retransmit_
      return
    schedule-retransmit_

  // ---- options ------------------------------------------------------------

  /**
  Applies a server's OACK to local state.

  Validates that the server hasn't returned options the client never
    requested (RFC 2347 §3 forbids that), and that any blksize is in range.
  */
  apply-oack_ oack/PacketOACK -> none:
    requested := requested-options_ or {:}
    oack.options.do: | name/string value/string |
      if not requested.contains name:
        throw "TFTP: server returned unrequested option '$name'"
      if name == OPT-BLKSIZE:
        n := int.parse value
        if not MIN-BLKSIZE <= n <= MAX-BLKSIZE:
          throw "TFTP: server negotiated blksize $n out of range"
        // Server may negotiate down but never up.
        requested-blksize := int.parse requested[OPT-BLKSIZE]
        if n > requested-blksize:
          throw "TFTP: server raised blksize from $requested-blksize to $n"
        blksize_ = n
      else if name == OPT-TSIZE:
        client_.last-tsize_ = int.parse value
      else if name == OPT-TIMEOUT:
        // Negotiated timeout is informational; the underlying receive
        // timeout is fixed at DEFAULT-TIMEOUT-MS_ for predictable retry.

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
