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
  direction-specific frame building ($Exchange.next-frame) and packet
  handling ($Exchange.handle).

# Block-number range
TFTP block numbers are unsigned 16-bit, so a single transfer is limited to
  $MAX-BLOCK-NUM_ blocks (defined in `packets.toit`). Subclasses convert
  overflow into an appropriate TFTP error.
*/

/** Default per-receive timeout, in milliseconds. */
DEFAULT-TIMEOUT-MS_ ::= 1_000

/** Maximum retransmissions before giving up on a packet. */
MAX-TRIES_ ::= 12

abstract class Exchange:
  socket_/udp.Socket
  logger_/log.Logger
  /**
  Locked peer transfer ID, captured from the first valid reply.

  Null until the first reply lands; once non-null, every received datagram
    must come from this address or it is rejected with TFTP error 5.
  */
  peer-tid_/net.SocketAddress? := null
  /**
  Destination for outbound sends.

  Subclasses prime this with the well-known address before the first
    $send_, then $receive_ updates it to $peer-tid_ as soon as the TID is
    locked.
  */
  dest_/net.SocketAddress? := null
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
    the client overrides to check that the source's IP matches the resolved
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

  /** Sends $payload to $dest_. */
  send_ payload/ByteArray -> none:
    socket_.send (udp.Datagram payload dest_)

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
        dest_ = msg.address
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
