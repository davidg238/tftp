// Copyright 2024 Ekorau LLC

import tftp show TFTPClient SDCard
import encoding.json
import encoding.tison
import writer
import host.file
import gpio

SERVER ::= "192.168.0.217"  // pidev

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
  count := client.read filename --to-writer=(writer.Writer filer)
  filer.close
  print "Read $count bytes"

  client.close