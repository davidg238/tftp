// Copyright 2024, 2026 Ekorau LLC.

import host.file
import tftp show TFTPClient

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    filename := "msg.txt"
    print "Reading $filename from $SERVER"
    out := file.Stream.for-write "./temp/$filename"
    count := 0
    try:
      count = client.read filename --to-writer=out.out
    finally:
      out.close
    print "Read $count bytes."
  finally:
    client.close
