// Copyright 2024 Ekorau LLC

import tftp show TFTPClient SHA256Summer SDCard
import encoding.json
import encoding.hex
import host.file
import io.writer show Writer
import io
import http
import net
import gpio

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open

  sdcard := SDCard 
      --miso=gpio.Pin 19
      --mosi=gpio.Pin 23
      --clk=gpio.Pin 18
      --cs=gpio.Pin 5

// Read the list of files (and their hashes) avaiilable at the server
  network := net.open
  web-client := http.Client network
  response := web-client.get "$SERVER:8080" "/"
  data := #[]
  while chunk := response.body.read:
    data += chunk
  web-client.close
  map-svr := json.decode data
// Prune out the larger files, as they just take too long to transfer //TODO performance issue
  map-svr.remove "sample-png-image_1mb.png"
  map-svr.remove "sample-png-image_20mb.png"
  map-svr.remove "openwrt-23.05.0-ath79-generic-openmesh_om2p-hs-v1-initramfs-kernel.bin"

  summer := SHA256Summer
  sha-writer := summer

// Write the set of files from the server to SDcard
  map-svr.do : | key value| 
    filer := sdcard.openw "/sd/$key"
    count := client.read key --to-writer=filer.out
    filer.close
    print "Wrote $key to SDcard, $count bytes"


// Compare the hashes of the files on the SDcard with the server hashes.
  hash-svr := ""
  result := true
  map-svr.do : | key value| 
    filer := sdcard.openr "/sd/$key"
    bytes := filer.in.read
    while bytes != null:
      sha-writer.write bytes
      bytes = filer.in.read
    filer.close

    sha256sum := summer.sum
    hash-found := hex.encode sha256sum
    summer.close

    if value != hash-found:
      print "For file: $key expected: $value  got: $hash-found"
      result = false
  print "All hashes compared: $result"
  
  