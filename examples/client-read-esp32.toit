// Copyright 2024 Ekorau LLC

import tftp show TFTPClient SDCard
import encoding.json
import encoding.tison
import io.writer show Writer
import io
import host.file
import gpio

SERVER ::= "127.0.0.1"  // localhost

main:
  client := TFTPClient --host=SERVER
  client.open

  sdcard := SDCard 
      --miso=gpio.Pin 19
      --mosi=gpio.Pin 23
      --clk=gpio.Pin 18
      --cs=gpio.Pin 5

  filename := "macbeth.txt"
  filer := sdcard.openw "/sd/$filename"

  print "read $filename from server"
  count := client.read filename --to-writer=filer.out
  filer.close
  print "Read $count bytes"

  client.close