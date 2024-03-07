// Copyright 2023 Ekorau LLC

import bytes
import reader
import binary

RRQ ::= 0x01
WRQ ::= 0x02
DATA ::= 0x03
ACK ::= 0x04
ERROR ::= 0x05
/** Option acknowledgement */
OPACK ::= 0x06 
/** $UNKNOWN is not a TFTP opcode, it is used internally to indicate an unknown opcode. */
UNKNOWN ::= 0x0D
/** $TIMEOUT is not a TFTP opcode, it is used internally to indicate a timeout. */
TIMEOUT ::= 0x0E 
/** $EXIT is not a TFTP opcode, it is used internally to indicate the client has exited. */
EXIT ::= 0x0F 


DEFAULT-BLKSIZE ::= 512


NETASCII ::= "netascii"
OCTET ::= "octet"
MAIL ::= "mail"  // Not supported, obsolete

ERRORS ::= [
  "Not defined, see error message (if any).",
  "File not found.",
  "Access violation.",
  "Disk full or allocation exceeded.",
  "Illegal TFTP operation.",
  "Unknown transfer ID.",
  "File already exists.",
  "No such user."
]
/**
Packet is the abstract superclass of all TFTP packets.
Has the factory method $deserialize to return the correct packet type from the reader stream.
*/
abstract class Packet:
  opcode /int := -1

  static deserialize reader/reader.BufferedReader -> Packet?:
    if not reader.can-ensure 2: return PacketERROR 0 "Unknown packet"
    opcode := decode-uint16 reader
    if opcode == RRQ:   return PacketRRQ.deserialize_ reader
    if opcode == WRQ:   return PacketWRQ.deserialize_ reader
    if opcode == DATA:  return PacketDATA.deserialize_ reader
    if opcode == ACK:   return PacketACK.deserialize_ reader
    if opcode == ERROR: return PacketERROR.deserialize_ reader
    if opcode == TIMEOUT: return PacketTIMEOUT.deserialize_ reader
    return PacketERROR 0 "Invalid opcode: $opcode"

  static decode-uint16 reader/reader.BufferedReader -> int:
    length-bytes := reader.read-bytes 2
    return binary.BIG-ENDIAN.uint16 length-bytes 0

  abstract payload -> ByteArray

  serialize -> ByteArray:
    buffer := bytes.Buffer
    buffer.write-int16-big-endian opcode
    buffer.write payload

    return buffer.bytes

  abstract stringify -> string

/**
PacketRRQ is a read request packet, sent from the client to the server to initiate a read.
*/
class PacketRRQ extends Packet:
  filename /string?
  mode /string?

  constructor .filename .mode:
    opcode = RRQ

  constructor.deserialize_ reader/reader.BufferedReader:
    filename := reader.read-until 0
    mode := reader.read-until 0
    return PacketRRQ filename mode

  stringify -> string:
    return "RRQ | $filename | $mode"

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write filename.to-byte-array
    buffer.write-byte 0
    buffer.write mode.to-byte-array
    buffer.write-byte 0
    return buffer.bytes

/**
PacketWRQ is a write request packet, sent from the client to the server to initiate a write.
*/
class PacketWRQ extends Packet:
  filename /string?
  mode /string?

  constructor .filename .mode:
    opcode = WRQ

  constructor.deserialize_ reader/reader.BufferedReader:
    filename := reader.read-until 0
    mode := reader.read-until 0
    return PacketWRQ filename mode

  stringify -> string:
    return "WRQ | $filename | $mode"
  

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write filename.to-byte-array
    buffer.write-byte 0
    buffer.write mode.to-byte-array
    buffer.write-byte 0
    return buffer.bytes

/**
PacketDATA form the payload packets.
*/
class PacketDATA extends Packet:
  block-num /int?
  data /ByteArray?

  constructor .block-num .data:
    opcode = DATA

  constructor.deserialize_ reader/reader.BufferedReader:
    block-num := Packet.decode-uint16 reader
    data := reader.read --max-size=DEFAULT-BLKSIZE  //TODO: max-size should be configurable
    return PacketDATA block-num data

  stringify -> string:
    return "DATA | $block-num | $data.size bytes"
  

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write-int16-big-endian block-num
    buffer.write data
    return buffer.bytes

/**
PacketACK are the acknowledgement packets, used by client and server.
*/
class PacketACK extends Packet:
  block-num /int?

  constructor .block-num:
    opcode = ACK

  constructor.deserialize_ reader/reader.BufferedReader:
    block-num := Packet.decode-uint16 reader
    return PacketACK block-num

  stringify -> string:
    return "ACK | $block-num"
  

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write-int16-big-endian block-num
    return buffer.bytes

/**
PacketERROR are the error packets, used by client and server.
*/
class PacketERROR extends Packet:
  error-code /int?
  error-msg /string?

  constructor .error-code .error-msg:
    opcode = ERROR

  constructor.deserialize_ reader/reader.BufferedReader:
    error-code := Packet.decode-uint16 reader
    error-msg := reader.read-until 0
    return PacketERROR error-code error-msg

  stringify -> string:
    return "ERROR | $error-code | $error-msg"
  
  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write-int16-big-endian error-code
    buffer.write error-msg.to-byte-array
    buffer.write-byte 0
    return buffer.bytes


/** 
PacketTIMEOUT is not a TFTP packet, rather an internal synthetic packet type, used to signal a timeout has occured and to resend last packet.
It simplifies the protocol engine implementation by allowing the protocol engine to treat timeouts as a packet type.
*/
class PacketTIMEOUT extends Packet:
  constructor:
    opcode = TIMEOUT

  constructor.deserialize_ reader/reader.BufferedReader:
    return PacketTIMEOUT

  payload -> ByteArray:
    return #[]

  stringify -> string:
    return "TIMEOUT"
  

