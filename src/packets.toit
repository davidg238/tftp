// Copyright 2023 Ekorau LLC

import bytes
import reader
import binary

RRQ ::= 0x01
WRQ ::= 0x02
DATA ::= 0x03
ACK ::= 0x04
ERROR ::= 0x05
OPACK ::= 0x06 // Option acknowledgement

UNKNOWN ::= 0x0D // This is not a TFTP opcode, it is used internally to indicate an unknown opcode.
TIMEOUT ::= 0x0E // This is not a TFTP opcode, it is used internally to indicate a timeout.
EXIT ::= 0x0F // This is not a TFTP opcode, it is used internally to indicate exchange terminations.

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

abstract class Packet:
  opcode /int := -1

  static deserialize reader/reader.BufferedReader -> Packet?:
    if not reader.can_ensure 2: return PacketERROR 0 "Unknown packet"
    opcode := decode_uint16 reader
    if opcode == RRQ:   return PacketRRQ.deserialize_ reader
    if opcode == WRQ:   return PacketWRQ.deserialize_ reader
    if opcode == DATA:  return PacketDATA.deserialize_ reader
    if opcode == ACK:   return PacketACK.deserialize_ reader
    if opcode == ERROR: return PacketERROR.deserialize_ reader
    if opcode == TIMEOUT: return PacketTIMEOUT.deserialize_ reader
    return PacketERROR 0 "Invalid opcode: $opcode"

  static decode_uint16 reader/reader.BufferedReader -> int:
    length_bytes := reader.read_bytes 2
    return binary.BIG_ENDIAN.uint16 length_bytes 0

  abstract payload -> ByteArray

  serialize -> ByteArray:
    buffer := bytes.Buffer
    buffer.write_int16_big_endian opcode
    buffer.write payload

    return buffer.bytes

class PacketRRQ extends Packet:
  filename /string?
  mode /string?

  constructor .filename .mode:
    opcode = RRQ

  constructor.deserialize_ reader/reader.BufferedReader:
    filename := reader.read_until 0
    mode := reader.read_until 0
    return PacketRRQ filename mode

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write filename.to_byte_array
    buffer.write_byte 0
    buffer.write mode.to_byte_array
    buffer.write_byte 0
    return buffer.bytes

class PacketWRQ extends Packet:
  filename /string?
  mode /string?

  constructor .filename .mode:
    opcode = WRQ

  constructor.deserialize_ reader/reader.BufferedReader:
    filename := reader.read_until 0
    mode := reader.read_until 0
    return PacketWRQ filename mode

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write filename.to_byte_array
    buffer.write_byte 0
    buffer.write mode.to_byte_array
    buffer.write_byte 0
    return buffer.bytes

class PacketDATA extends Packet:
  block_num /int?
  data /ByteArray?

  constructor .block_num .data:
    opcode = DATA

  constructor.deserialize_ reader/reader.BufferedReader:
    block_num := Packet.decode_uint16 reader
    data := reader.read --max_size=508
    return PacketDATA block_num data

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write_int16_big_endian block_num
    buffer.write data
    return buffer.bytes

class PacketACK extends Packet:
  block_num /int?

  constructor .block_num:
    opcode = ACK

  constructor.deserialize_ reader/reader.BufferedReader:
    block_num := Packet.decode_uint16 reader
    return PacketACK block_num

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write_int16_big_endian block_num
    return buffer.bytes


class PacketERROR extends Packet:
  error_code /int?
  error_msg /string?

  constructor .error_code .error_msg:
    opcode = ERROR

  constructor.deserialize_ reader/reader.BufferedReader:
    error_code := Packet.decode_uint16 reader
    error_msg := reader.read_until 0
    return PacketERROR error_code error_msg

  payload -> ByteArray:
    buffer := bytes.Buffer
    buffer.write_int16_big_endian error_code
    buffer.write error_msg.to_byte_array
    buffer.write_byte 0
    return buffer.bytes


// Not a real TFTPPacket, but used to signal a timeout has occured and to resend last packet.
class PacketTIMEOUT extends Packet:
  constructor:
    opcode = TIMEOUT

  constructor.deserialize_ reader/reader.BufferedReader:
    return PacketTIMEOUT

  payload -> ByteArray:
    return #[]


class Result:

  pass_ /bool?
  message /string?

  constructor.fail .message:
    pass_ = false
  
  constructor.pass:
    pass_ = true
    message = "complete"

  passed -> bool:
    return pass_

  stringify -> string:
    return message
