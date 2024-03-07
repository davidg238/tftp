// Copyright 2024 Ekorau LLC

import tftp show TFTPClient
import encoding.json
import encoding.tison
import writer
import host.file 
SERVER ::= "192.168.0.217"  // pidev

main:
  client := TFTPClient --host=SERVER

  client.open

  filename := "macbeth.txt"
  print "read $filename from server"
  test_out := file.Stream.for-write "./temp/$filename"
  count := client.read filename --to-writer=(writer.Writer test-out)
  test-out.close
  print "Read $count bytes"

  client.close

