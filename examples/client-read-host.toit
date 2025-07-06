// Copyright 2024 Ekorau LLC

import tftp show TFTPClient
import encoding.json
import encoding.tison
import io.writer show Writer
import host.file 
SERVER ::= "127.0.0.1"  // localhost

main:
  client := TFTPClient --host=SERVER

  client.open

  filename := "msg.txt"
  print "read $filename from server"
  test_out := file.Stream.for-write "./temp/$filename"
  count := client.read filename --to-writer=test-out.out
  test-out.close
  print "Read $count bytes"

  client.close

