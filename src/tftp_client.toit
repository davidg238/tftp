// Copyright 2023 Ekorau LLC

import bytes
import reader
import binary
import net
import net.udp

import .packets

DEFAULT_BLKSIZE ::= 512

TFTP_DEFAULT_PORT ::= 69

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

  read --name --mode="octet":
    exchange := ClientExchange.read --name=name --mode=mode
    exchange.read_with this
    update_host_port_ TFTP_DEFAULT_PORT  // Reset to the default, after an exchange, to enable client reuse.
    return exchange.result

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
  read_with client /TFTPClient -> none:  // Reads are initiated from the client.
    while opcode != EXIT:
      client.send_ reader_bytes
      reader_handle client.receive_

  write_with client /TFTPClient -> none:
    while opcode != EXIT:
      client.send_ writer_bytes
      writer_handle client.receive_

  // WRQ state machine -----------------------------------------------------
  writer_handle received_bytes/ByteArray -> none:
    breader := reader.BufferedReader (bytes.Reader received_bytes)
    received := Packet.deserialize breader
    // write exchange  -----------------------------------------
    if      opcode == WRQ   and received.opcode == ACK:     start_writing (received as PacketACK)
    else if opcode == WRQ   and received.opcode == TIMEOUT: resend_WRQ
    else if opcode == DATA  and received.opcode == ACK:     keep_writing (received as PacketACK)
    else if opcode == DATA  and received.opcode == TIMEOUT: resend_write
    else if opcode == DATA  and received.opcode == ERROR:   exit_error (received as PacketERROR)
    // WRQ packet failed --------------------------------
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
      delay_on tries
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

  writer_bytes -> ByteArray:
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

/* RRQ state machine -----------------------------------------------------
      RRQ:DATA, (ACK:DATA)+
*/
  reader_handle received_bytes/ByteArray -> none:
    breader := reader.BufferedReader (bytes.Reader received_bytes)
    received := Packet.deserialize breader
    // write exchange  -----------------------------------------
    if      opcode == WRQ   and received.opcode == ACK:     start_writing (received as PacketACK)
    else if opcode == WRQ   and received.opcode == TIMEOUT: resend_WRQ
    else if opcode == DATA  and received.opcode == ACK:     keep_writing (received as PacketACK)
    else if opcode == DATA  and received.opcode == TIMEOUT: resend_write
    else if opcode == DATA  and received.opcode == ERROR:   exit_error (received as PacketERROR)
    // WRQ packet failed --------------------------------
    else if received.opcode == ERROR:                       exit_error (received as PacketERROR)                


  reader_bytes -> ByteArray:


  rrq_frame -> ByteArray:
    cached = (PacketRRQ name mode).serialize
    return cached

  
  // --------------------------------------------------------------------------

  delay_on tries/int -> none:
    if tries == 1: 
      sleep --ms=1500
      return
    if tries == 2: 
      sleep --ms=3000
      return


