// Copyright 2023 Ekorau LLC

import bytes
import reader
import binary
import net
import net.udp

RRQ ::= 0x01
WRQ ::= 0x02
DATA ::= 0x03
ACK ::= 0x04
ERROR ::= 0x05
OPACK ::= 0x06 // Option acknowledgement

DEFAULT_BLKSIZE ::= 512

UNKNOWN ::= 0x0D // This is not a TFTP opcode, it is used internally to indicate an unknown opcode.
TIMEOUT ::= 0x0E // This is not a TFTP opcode, it is used internally to indicate a timeout.
EXIT ::= 0x0F // This is not a TFTP opcode, it is used internally to indicate exchange terminations.

TFTP_DEFAULT_PORT ::= 69

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

class TFTPClient:
  host /string?
  host_address /net.IpAddress?
  port /int := TFTP_DEFAULT_PORT
  
  network := null
  udp_socket := null
  host_SocketAddress := null
  packet_id := 0

  blksize := DEFAULT_BLKSIZE

  constructor --.host:
    host_address = net.IpAddress.parse host

  open -> none:
    network = net.open
    udp_socket = network.udp_open
    host_SocketAddress = net.SocketAddress host_address port

  write_string msg /string --name -> Result:
    return write_ --name=name --data=msg.to_byte_array --mode=OCTET

  write data /ByteArray --name -> Result:
    return write_ --name=name --data=data --mode=OCTET

/*
// Arbitary limit for in-memory transfers.
    See RFC2347 (4GB limit). 
    Todo: impl a send_file method (to support ESP32 with attached storage or host installs)
*/
  write_ --name --data --mode=OCTET -> Result:
    if name.size > 128: return Result.fail "Filename too long"
    if data.size > 65536: return Result.fail "Data too long"
    if mode != OCTET: return Result.fail "Go server only supports Octet mode"

    exchange := ClientExchange.write --name=name --data=data --mode=mode
    exchange.write_with this
    update_host_port_ TFTP_DEFAULT_PORT  // Reset to the default, after an exchange, to enable client reuse.
    return exchange.result
/*
  read --name --mode="octet":
    exchange := ClientExchange.read --name=name --mode=mode
    exchange.run_with this
    update_host_port_ TFTP_DEFAULT_PORT  // Reset to the default, after an exchange, to enable client reuse.
    return exchange.result
*/
  close -> none:
    udp_socket.close    

  send_ payload/ByteArray -> none:
    msg := udp.Datagram payload host_SocketAddress
    udp_socket.send msg

  receive_ -> ByteArray:
    exception := catch:
      with_timeout --ms=5000:
        msg := udp_socket.receive
        update_host_port_ msg.address.port  // The server assigns a new port for subsequent transfers.
        return msg.data
    if exception == DEADLINE_EXCEEDED_ERROR:
      to := PacketTIMEOUT
      return to.serialize
    else:
      other := PacketERROR 0 exception.message
      return other.serialize

  update_host_port_ assigned_num/int -> none:
    port = assigned_num
    host_SocketAddress = net.SocketAddress host_address port

/*
Correct client exchanges comprise a series of handshakes:
  WRQ:ACK, (DATA:ACK)+
  RRQ:DATA, (ACK:DATA)+
  Receiving an error packet at any time aborts the transfer.
  Receiving a packet with an invalid opcode aborts the transfer.
  Receiving a packet with an invalid block number aborts the transfer.
  On timeout, the client should retry the last packet up to 3 times, then abort the transfer.
  The timeout is 5 seconds.

*/
class ClientExchange:
  name /string?
  data /ByteArray := #[]
  mode /string?

  opcode /int := -1
  cached /ByteArray := #[]
  dreader /reader.BufferedReader? := null

  block_num := 1
  result /Result? := null
  last_frame /ByteArray := #[]
  tries := 0
  drained := false
  blksize /int := DEFAULT_BLKSIZE

  constructor.write --.name --.data --.mode:
    opcode = WRQ
    dreader = reader.BufferedReader (bytes.Reader data)  //todo:  hardcoded to octet mode

  constructor.read --.name --.mode:
    opcode = RRQ

  /* 
  There is only one outstanding request at a time.
  This is the exchange entry point, so the opcode has been set for read or write.
  */
  write_with client /TFTPClient -> none:
    while opcode != EXIT:
      client.send_ next_bytes
      respond_to client.receive_

  // WRQ state machine -----------------------------------------------------
  respond_to received_bytes/ByteArray -> none:
    breader := reader.BufferedReader (bytes.Reader received_bytes)
    received := Packet.deserialize breader
    // write exchange  -----------------------------------------
    if      opcode == WRQ   and received.opcode == ACK:     start_writing (received as PacketACK)
    else if opcode == WRQ   and received.opcode == TIMEOUT: resend_WRQ
    else if opcode == DATA  and received.opcode == ACK:     keep_writing (received as PacketACK)
    else if opcode == DATA  and received.opcode == TIMEOUT: resend_write
    else if opcode == DATA  and received.opcode == ERROR:   exit_error (received as PacketERROR)
    // read ----------------------------------------------------

    // WRQ or RRQ packet failed --------------------------------
    else if received.opcode == ERROR:                       exit_error (received as PacketERROR)                
  
  // WRQ state machine helpers ---------------------------------------------
  start_writing received /PacketACK -> none:
    if received.block_num == 0:
      opcode = DATA // The WRQ was accepted, send the first DATA packet.
      tries = 0
    else:
      opcode = EXIT
      result = Result.fail "Invalid block number for WRQ: $block_num"

  keep_writing received /PacketACK -> none:
    if received.block_num == block_num:
      if drained:
        opcode = EXIT
        result = Result.pass
      else:
        block_num += 1
        tries = 0
    else:
        opcode = EXIT
        result = Result.fail "Invalid block number: $block_num"
  
  resend_write -> none:
    tries += 1
    if tries < 3:
      return  // The last cached frame will be resent, since not drained.
    else:
      opcode = EXIT
      result = Result.fail "Timeout sending data"

  resend_WRQ -> none:
    tries += 1
    if tries < 3: 
      delay_on tries
    else:
      opcode = EXIT
      result = Result.fail "Timeout establishing connection"

  exit_error received /PacketERROR -> none:
    opcode = EXIT
    result = Result.fail "Server error while sending data: $received.error_msg"

  // --------------------------------------------------------------------------

  delay_on tries/int -> none:
    if tries == 1: 
      sleep --ms=1500
      return
    if tries == 2: 
      sleep --ms=3000
      return

  next_bytes -> ByteArray:
    if tries > 0: return cached
    if opcode == WRQ: return wrq_frame
    if opcode == DATA: return next_data_frame
    return (PacketERROR 0 "Invalid opcode: $opcode").serialize // Not necessary to resend an error packet, hence not cached.

  wrq_frame -> ByteArray:
    cached = (PacketWRQ name mode).serialize
    return cached

  next_data_frame -> ByteArray:
    barray := #[]
    if dreader.can_ensure blksize:
      barray = dreader.read_bytes blksize
    else:
      dreader.buffer_all
      // if dreader.buffered == 0: return null  // already called has_more_data, refer https://libs.toit.io/#read_bytes(1%2C0%2C0%2C)
      barray = dreader.read_bytes dreader.buffered
      drained = true
    cached = (PacketDATA block_num barray).serialize
    return cached

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
