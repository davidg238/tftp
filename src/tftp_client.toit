// Copyright 2023 Ekorau LLC

import bytes
import reader
import writer
import binary
import net
import net.udp
import host.file

import .packets

DEFAULT-BLKSIZE ::= 508

TFTP-DEFAULT-PORT ::= 69

class TFTPClient:
  host /string?
  host-address /net.IpAddress?
  port /int := TFTP-DEFAULT-PORT
  
  network := null
  udp-socket := null
  host-SocketAddress := null
  packet-id := 0

  blksize := DEFAULT-BLKSIZE
  reader_ /reader.BufferedReader? := null
  writer_ /file.Stream? := null
  buffer_ /bytes.Buffer? := null
  streaming-reads /bool := false
  byte-count /int := 0

  filename /string? := null
  mode /string? := OCTET

  constructor --.host:
    host-address = net.IpAddress.parse host

  open -> none:
    network = net.open
    udp-socket = network.udp-open
    host-SocketAddress = net.SocketAddress host-address port

  close -> none:
    udp-socket.close  

/// ----- Client API --------------------------------------------------------
  write-string msg /string --filename -> int:
    return write-bytes msg.to-byte-array --filename=filename

  write-bytes data/ByteArray --filename -> int:
    print "Write bytes $filename"
    areader := bytes.Reader data
    return write-stream areader --filename=filename

  write-stream  areader /reader.Reader --.filename /string  -> int:
    print "Write stream $filename"
    mode = OCTET
    reader_ = reader.BufferedReader areader
    return write_

  read-bytes .filename /string -> ByteArray:
    print "Read bytes $filename"
    if filename.size > 128: throw "Filename too long"
    if mode != OCTET: throw "Only Octet mode supported"
    buffer_ = bytes.Buffer
    streaming-reads = false
    exchange := ClientExchange this
    exchange.read
    update-host-port_ TFTP-DEFAULT-PORT  // Reset to the default, after an exchange, to enable client reuse.
    return buffer_.bytes

  read .filename /string --to-writer -> int:
    print "Read file $filename"
    if filename.size > 128: throw "Filename too long"
    if mode != OCTET: throw "Go server only supports Octet mode"
    writer_ = to-writer
    streaming-reads = true
    exchange := ClientExchange this
    exchange.read              //TODO  can this throw, should following line be in "finally"
    update-host-port_ TFTP-DEFAULT-PORT  // Reset to the default, after an exchange, to enable client reuse.
    return byte-count
  
// --- methods used by ClientExchange state machine ------------------------  
  send_ payload/ByteArray -> none:
    msg := udp.Datagram payload host-SocketAddress
    udp-socket.send msg

  receive_ -> ByteArray:
    exception := catch:
      with-timeout --ms=5000:
        msg := udp-socket.receive
        update-host-port_ msg.address.port  // The server assigns a new port for subsequent transfers.
        return msg.data
    if exception == DEADLINE-EXCEEDED-ERROR:
      to := PacketTIMEOUT
      return to.serialize
    else:
      other := PacketERROR 0 exception.message
      return other.serialize
      
  can-ensure_ size/int -> bool:
    return reader_.can-ensure size

  bytes-to-send_ size/int -> ByteArray:
    return reader_.read-bytes size

  buffer-all_ -> none:
    reader_.buffer-all

  buffered_ -> int:
    return reader_.buffered

  bytes-received data/ByteArray -> none:
    byte-count += data.size
    if streaming-reads:
      writer_.write data
    else:
      buffer_.write-from (bytes.Reader data)

  bytes-written size/int -> none:
    byte-count += size

// --------------------------------------------------------------------------

  write_ -> int:
    if filename.size > 128: throw "Filename too long"
    if mode != OCTET: throw "Only Octet mode supported"
    exchange := ClientExchange this
    exchange.write              //TODO  can this throw, should following line be in "finally"
    update-host-port_ TFTP-DEFAULT-PORT  // Reset to the default, after an exchange, to enable client reuse.
    return byte-count
  

  update-host-port_ assigned-num/int -> none:
    port = assigned-num
    host-SocketAddress = net.SocketAddress host-address port

// --------------------------------------------------------------------------    
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

  opcode /int := -1
  cached /ByteArray := #[]

  block-num := 1
  last-frame /ByteArray := #[]
  tries := 0
  drained := false
  blksize /int := DEFAULT-BLKSIZE

  client /TFTPClient?

  constructor .client /TFTPClient:

  /* 
  There is only one outstanding request at a time.
  This is the exchange entry point, so the opcode has been set for read or write.
  */
  write -> none:
    opcode = WRQ
    while opcode != EXIT:
      client.send_ writer-bytes
      writer-handle client.receive_

  // WRQ state machine -----------------------------------------------------
  writer-handle received-bytes/ByteArray -> none:
    breader := reader.BufferedReader (bytes.Reader received-bytes)
    received := Packet.deserialize breader
    // write exchange  -----------------------------------------
    if      opcode == WRQ   and received.opcode == ACK:     start-writing (received as PacketACK)
    else if opcode == WRQ   and received.opcode == TIMEOUT: resend-last
    else if opcode == DATA  and received.opcode == ACK:     keep-writing (received as PacketACK)
    else if opcode == DATA  and received.opcode == TIMEOUT: resend-last
    else if opcode == DATA  and received.opcode == ERROR:   exit-error (received as PacketERROR)
    // WRQ packet failed --------------------------------
    else if received.opcode == ERROR:                       exit-error (received as PacketERROR)                
  
  // WRQ state machine helpers ---------------------------------------------
  start-writing received /PacketACK -> none:
    if received.block-num == 0:
      opcode = DATA // The WRQ was accepted, send the first DATA packet.
      tries = 0
    else:
      opcode = EXIT
      throw "Invalid block number for WRQ: $block-num"

  keep-writing received /PacketACK -> none:
    if received.block-num == block-num:
      if drained:
        opcode = EXIT
      else:
        block-num += 1
        tries = 0
    else:
        opcode = EXIT
        throw "Invalid block number: $block-num"
  
  exit-error received /PacketERROR -> none:
    opcode = EXIT
    throw "Server error at blknum $block-num, error: $received.error-msg"

  writer-bytes -> ByteArray:
    if tries > 0: return cached
    if opcode == WRQ: return wrq-frame
    if opcode == DATA: return next-send-frame
    return (PacketERROR 0 "Invalid opcode: $opcode").serialize // Not necessary to resend an error packet, hence not cached.

  wrq-frame -> ByteArray:
    cached = (PacketWRQ client.filename client.mode).serialize
    return cached

  next-send-frame -> ByteArray:
    barray := #[]
    if client.can-ensure_ blksize:
      barray = client.bytes-to-send_ blksize
    else:
      client.buffer-all_
      // if reader.buffered == 0: return null  // already called has_more_data, refer https://libs.toit.io/#read_bytes(1%2C0%2C0%2C)
      barray = client.bytes-to-send_ client.buffered_
      drained = true
    cached = (PacketDATA block-num barray).serialize
    client.bytes-written barray.size
    return cached

/* RRQ state machine -----------------------------------------------------
      RRQ:DATA, (ACK:DATA)+
*/
  read -> none:  // Reads are initiated from the client.
    opcode = RRQ
    block-num = 1
    while opcode != EXIT:
      client.send_ reader-bytes
      reader-handle client.receive_

  reader-handle received-bytes/ByteArray -> none:
    breader := reader.BufferedReader (bytes.Reader received-bytes)
    received := Packet.deserialize breader
    print "rcvd $received"
    // write exchange  -----------------------------------------
    if      opcode == RRQ   and received.opcode == DATA:
      opcode = ACK
      read-data (received as PacketDATA)
    else if opcode == RRQ   and received.opcode == TIMEOUT: resend-last
    else if opcode == ACK   and received.opcode == DATA:
      read-data  (received as PacketDATA)
    else if opcode == ACK   and received.opcode == TIMEOUT: resend-last
    else if opcode == ACK   and received.opcode == ERROR:   exit-error    (received as PacketERROR)
    // WRQ packet failed --------------------------------
    else if received.opcode == ERROR:                       exit-error (received as PacketERROR)                

  reader-bytes -> ByteArray:
    if tries > 0: return cached
    if opcode == RRQ: return rrq-frame
    if opcode == ACK: return ack-frame
    return (PacketERROR 0 "Invalid opcode: $opcode").serialize // Not necessary to resend an error packet, hence not cached.

  rrq-frame -> ByteArray:
    rrq := PacketRRQ client.filename client.mode
    print "prep $rrq"
    cached = (rrq).serialize
    return cached

  ack-frame -> ByteArray:
    ack := PacketACK block-num
    print "prep $ack"
    cached = (ack).serialize
    block-num += 1   // The last packet was successfully received, so prepare to receive the next packet.
    tries = 0    
    return cached    

    // RRQ state machine helpers ---------------------------------------------
  read-data received /PacketDATA -> none:
    if received.block-num == block-num:
      accumulate received.data
      if drained:
        client.send_ ack-frame
        opcode = EXIT
    else:
        opcode = EXIT
        throw "Invalid block number: $block-num"

  accumulate data/ByteArray -> none:
    print "add $data.size bytes"
    if data.size < blksize:
      drained = true
    client.bytes-received data

  // --------------------------------------------------------------------------

  resend-last -> none:
    tries += 1
    if tries < 3:
      delay-on tries
      return  // The last cached frame will be resent, since not drained.
    else:
      opcode = EXIT
      throw "Connection to remote server timed out, blknum $block-num"

  delay-on tries/int -> none:
    if tries == 1: 
      sleep --ms=1500
      return
    if tries == 2: 
      sleep --ms=3000
      return




/*
  start-reading received /PacketDATA -> none:
    if received.block-num == 1:
      opcode = ACK              // The RRQ was accepted, prepare to send the first ACK packet.
      tries = 0
      accumulate received.data
      if drained:               // The first packet was the last packet.
        client.send_ ack-frame
        opcode = EXIT
        result = Result.pass
    else:
      opcode = EXIT
      result = Result.fail "Invalid block number: $block-num"
*/