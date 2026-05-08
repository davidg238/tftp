// Copyright 2023, 2026 Ekorau LLC.

import io show BIG-ENDIAN Reader
import io.buffer show Buffer

/**
TFTP packet types and serialization, per RFC 1350.

The opcodes $RRQ, $WRQ, $DATA, $ACK and $ERROR are wire-level.
$TIMEOUT is a synthetic opcode used only inside the client to model a
  receive timeout as just another packet kind, so the state machine
  does not need a separate code path for it.
*/

/** Read request opcode. */
RRQ ::= 0x01
/** Write request opcode. */
WRQ ::= 0x02
/** Data packet opcode. */
DATA ::= 0x03
/** Acknowledgement opcode. */
ACK ::= 0x04
/** Error opcode. */
ERROR ::= 0x05
/** Option acknowledgement (RFC 2347). Not currently produced by this client. */
OPACK ::= 0x06

/** Synthetic opcode signalling the client has exited the state machine. */
EXIT ::= 0x0F
/** Synthetic opcode signalling a receive timeout. Never appears on the wire. */
TIMEOUT ::= 0x0E

/** Default block size, RFC 1350. */
DEFAULT-BLKSIZE ::= 512

/** Maximum block number that fits in the 16-bit block field. */
MAX-BLOCK-NUM_ ::= 0xFFFF

/** Octet (binary) transfer mode. The only mode this client supports. */
OCTET ::= "octet"
/** Netascii transfer mode. Not supported. */
NETASCII ::= "netascii"
/** Mail transfer mode. Obsolete, not supported. */
MAIL ::= "mail"

/** Standard TFTP error messages, indexed by error code 0..7 (RFC 1350). */
ERRORS ::= [
  "Not defined.",
  "File not found.",
  "Access violation.",
  "Disk full or allocation exceeded.",
  "Illegal TFTP operation.",
  "Unknown transfer ID.",
  "File already exists.",
  "No such user.",
]

/**
Abstract base class of all TFTP packets.

The factory $deserialize returns the concrete packet for the bytes in its
  reader argument. Subclasses provide $payload and $stringify; $serialize
  prepends the opcode and returns the full datagram.
*/
abstract class Packet:
  opcode/int := -1

  /**
  Deserializes the next packet from $reader.

  Returns null if the input is too short or the opcode is not recognized; the
    caller should treat that as a transient receive error and retry.
  */
  static deserialize reader/Reader -> Packet?:
    if reader.content-size != null and reader.content-size < 2: return null
    opcode := decode-uint16_ reader
    if opcode == RRQ:   return PacketRRQ.deserialize_ reader
    if opcode == WRQ:   return PacketWRQ.deserialize_ reader
    if opcode == DATA:  return PacketDATA.deserialize_ reader
    if opcode == ACK:   return PacketACK.deserialize_ reader
    if opcode == ERROR: return PacketERROR.deserialize_ reader
    return null

  static decode-uint16_ reader/Reader -> int:
    bytes := reader.read-bytes 2
    return BIG-ENDIAN.uint16 bytes 0

  abstract payload -> ByteArray

  /** Serializes this packet to a byte array suitable for sending in a UDP datagram. */
  serialize -> ByteArray:
    buffer := Buffer
    buffer.big-endian.write-int16 opcode
    buffer.write payload
    return buffer.bytes

  abstract stringify -> string

/** Read request, sent from client to server to start a download. */
class PacketRRQ extends Packet:
  filename/string
  mode/string

  constructor .filename .mode:
    opcode = RRQ

  constructor.deserialize_ reader/Reader:
    filename = reader.read-string-up-to 0
    mode = reader.read-string-up-to 0
    opcode = RRQ

  stringify -> string:
    return "RRQ | $filename | $mode"

  payload -> ByteArray:
    buffer := Buffer
    buffer.write filename.to-byte-array
    buffer.write-byte 0
    buffer.write mode.to-byte-array
    buffer.write-byte 0
    return buffer.bytes

/** Write request, sent from client to server to start an upload. */
class PacketWRQ extends Packet:
  filename/string
  mode/string

  constructor .filename .mode:
    opcode = WRQ

  constructor.deserialize_ reader/Reader:
    filename = reader.read-string-up-to 0
    mode = reader.read-string-up-to 0
    opcode = WRQ

  stringify -> string:
    return "WRQ | $filename | $mode"

  payload -> ByteArray:
    buffer := Buffer
    buffer.write filename.to-byte-array
    buffer.write-byte 0
    buffer.write mode.to-byte-array
    buffer.write-byte 0
    return buffer.bytes

/** Data packet carrying $data for block $block-num. */
class PacketDATA extends Packet:
  block-num/int
  data/ByteArray

  constructor .block-num .data:
    opcode = DATA
    if not 0 <= block-num <= MAX-BLOCK-NUM_:
      throw "Block number $block-num out of range 0..$MAX-BLOCK-NUM_"

  constructor.deserialize_ reader/Reader:
    block-num = Packet.decode-uint16_ reader
    // The remaining bytes of the datagram are the payload. The reader is
    // backed by a single UDP datagram, so read-all returns exactly the
    // data segment with no further blocking.
    data = reader.read-all or #[]
    opcode = DATA

  stringify -> string:
    return "DATA | $block-num | $data.size bytes"

  payload -> ByteArray:
    buffer := Buffer
    buffer.big-endian.write-int16 block-num
    buffer.write data
    return buffer.bytes

/** Acknowledgement of $block-num. */
class PacketACK extends Packet:
  block-num/int

  constructor .block-num:
    opcode = ACK

  constructor.deserialize_ reader/Reader:
    block-num = Packet.decode-uint16_ reader
    opcode = ACK

  stringify -> string:
    return "ACK | $block-num"

  payload -> ByteArray:
    buffer := Buffer
    buffer.big-endian.write-int16 block-num
    return buffer.bytes

/**
Error packet.

If $error-msg is empty and $error-code is in 0..7, $stringify falls back to the
  RFC 1350 standard message in $ERRORS.
*/
class PacketERROR extends Packet:
  error-code/int
  error-msg/string

  constructor .error-code .error-msg:
    opcode = ERROR

  constructor.deserialize_ reader/Reader:
    error-code = Packet.decode-uint16_ reader
    error-msg = reader.read-string-up-to 0
    opcode = ERROR

  /** Returns the message, falling back to $ERRORS for the standard codes. */
  resolved-msg -> string:
    if error-msg != "": return error-msg
    if 0 <= error-code < ERRORS.size: return ERRORS[error-code]
    return "Unknown error $error-code"

  stringify -> string:
    return "ERROR | $error-code | $resolved-msg"

  payload -> ByteArray:
    buffer := Buffer
    buffer.big-endian.write-int16 error-code
    buffer.write error-msg.to-byte-array
    buffer.write-byte 0
    return buffer.bytes

/**
Internal synthetic packet representing a receive timeout.

Never read from or written to the wire; it lets the state machine treat
  timeouts as just another packet type.
*/
class PacketTIMEOUT extends Packet:
  constructor:
    opcode = TIMEOUT

  payload -> ByteArray:
    return #[]

  stringify -> string:
    return "TIMEOUT"
