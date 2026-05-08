// Copyright 2024, 2026 Ekorau LLC.

import gpio
import tftp show SDCard TFTPClient

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    sdcard := SDCard
        --miso=gpio.Pin 19
        --mosi=gpio.Pin 23
        --clk=gpio.Pin 18
        --cs=gpio.Pin 5

    filename := "macbeth.txt"
    print "Reading $filename from $SERVER"
    out := sdcard.openw "/sd/$filename"
    count := 0
    try:
      count = client.read filename --to-writer=out.out
    finally:
      out.close
    print "Read $count bytes."
  finally:
    client.close
