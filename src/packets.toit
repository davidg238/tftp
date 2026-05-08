// Copyright 2023, 2026 Ekorau LLC.

import io show BIG-ENDIAN Reader
import io.buffer show Buffer

/**
TFTP packet types and serialization.

Implements RFC 1350 (the base protocol), RFC 2347 (option extension),
  RFC 2348 (block size option) and RFC 2349 (transfer size and timeout
  interval options).

The opcodes $RRQ, $WRQ, $DATA, $ACK, $ERROR and $OACK are wire-level.
$TIMEOUT and $EXIT are synthetic opcodes used only inside the client and
  server state machines to model receive timeouts and the loop exit
  condition without needing separate code paths.
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
/** Option acknowledgement opcode (RFC 2347). */
OACK ::= 0x06

/** Synthetic opcode signalling the state machine has exited. */
EXIT ::= 0x0F
/** Synthetic opcode signalling a receive timeout. Never appears on the wire. */
TIMEOUT ::= 0x0E

/** Default block size, RFC 1350. */
DEFAULT-BLKSIZE ::= 512

/** Minimum block size acceptable as a negotiated option, RFC 2348. */
MIN-BLKSIZE ::= 8
/** Maximum block size acceptable as a negotiated option, RFC 2348. */
MAX-BLKSIZE ::= 65464

/** Maximum block number that fits in the 16-bit block field. */
MAX-BLOCK-NUM_ ::= 0xFFFF

/** Octet (binary) transfer mode. The only mode supported. */
OCTET ::= "octet"
/** Netascii transfer mode. Not supported. */
NETASCII ::= "netascii"
/** Mail transfer mode. Obsolete, not supported. */
MAIL ::= "mail"

/** Option name for RFC 2348 block size negotiation. */
OPT-BLKSIZE ::= "blksize"
/** Option name for RFC 2349 transfer size negotiation. */
OPT-TSIZE ::= "tsize"
/** Option name for RFC 2349 timeout interval negotiation. */
OPT-TIMEOUT ::= "timeout"

/** Standard TFTP error messages, indexed by error code 0..8 (RFC 1350, RFC 2347). */
ERRORS ::= [
  "Not defined.",
  "File not found.",
  "Access violation.",
  "Disk full or allocation exceeded.",
  "Illegal TFTP operation.",
  "Unknown transfer ID.",
  "File already exists.",
  "No such user.",
  "No such option.",
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
    if opcode == OACK:  return PacketOACK.deserialize_ reader
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

/**
Reads alternating null-terminated name/value strings from $reader until the
  reader is exhausted, returning a Map. Used for RFC 2347 options.
Lower-cases each name so the lookup is case-insensitive (RFC 2347 §2).
*/
parse-options_ reader/Reader -> Map:
  options := {:}
  while reader.buffered-size > 0:
    name := reader.read-string-up-to 0
    if reader.buffered-size == 0: break  // Malformed: name without value.
    value := reader.read-string-up-to 0
    options[name.to-ascii-lower] = value
  return options

/** Writes the option pairs in $options as alternating null-terminated strings to $buffer. */
write-options_ buffer/Buffer options/Map -> none:
  options.do: | name/string value/string |
    buffer.write name.to-byte-array
    buffer.write-byte 0
    buffer.write value.to-byte-array
    buffer.write-byte 0

/** Read request, sent from client to server to start a download. */
class PacketRRQ extends Packet:
  filename/string
  mode/string
  /** RFC 2347 options. Empty when no options are being negotiated. */
  options/Map

  constructor .filename .mode --.options/Map={:}:
    opcode = RRQ

  constructor.deserialize_ reader/Reader:
    filename = reader.read-string-up-to 0
    mode = reader.read-string-up-to 0
    options = parse-options_ reader
    opcode = RRQ

  stringify -> string:
    return options.is-empty
        ? "RRQ | $filename | $mode"
        : "RRQ | $filename | $mode | $options"

  payload -> ByteArray:
    buffer := Buffer
    buffer.write filename.to-byte-array
    buffer.write-byte 0
    buffer.write mode.to-byte-array
    buffer.write-byte 0
    write-options_ buffer options
    return buffer.bytes

/** Write request, sent from client to server to start an upload. */
class PacketWRQ extends Packet:
  filename/string
  mode/string
  /** RFC 2347 options. Empty when no options are being negotiated. */
  options/Map

  constructor .filename .mode --.options/Map={:}:
    opcode = WRQ

  constructor.deserialize_ reader/Reader:
    filename = reader.read-string-up-to 0
    mode = reader.read-string-up-to 0
    options = parse-options_ reader
    opcode = WRQ

  stringify -> string:
    return options.is-empty
        ? "WRQ | $filename | $mode"
        : "WRQ | $filename | $mode | $options"

  payload -> ByteArray:
    buffer := Buffer
    buffer.write filename.to-byte-array
    buffer.write-byte 0
    buffer.write mode.to-byte-array
    buffer.write-byte 0
    write-options_ buffer options
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

If $error-msg is empty and $error-code is in 0..8, $stringify falls back to the
  RFC 1350 / RFC 2347 standard message in $ERRORS.
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
Option acknowledgement (RFC 2347).

Sent by the server in response to an RRQ or WRQ that included options. The
  $options map contains the subset of options the server has accepted, with
  the values it has chosen (which may be smaller than the requested values
  but never larger, per RFC 2348/2349).
*/
class PacketOACK extends Packet:
  options/Map

  constructor .options/Map:
    opcode = OACK

  constructor.deserialize_ reader/Reader:
    options = parse-options_ reader
    opcode = OACK

  stringify -> string:
    return "OACK | $options"

  payload -> ByteArray:
    buffer := Buffer
    write-options_ buffer options
    return buffer.bytes

/**
Internal synthetic packet representing a receive timeout.

Never read from or written to the wire; it lets state machines treat
  timeouts as just another packet type.
*/
class PacketTIMEOUT extends Packet:
  constructor:
    opcode = TIMEOUT

  payload -> ByteArray:
    return #[]

  stringify -> string:
    return "TIMEOUT"
