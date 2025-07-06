// Copyright 2023, 2024 Ekorau LLC

import tftp show TFTPClient
import encoding.json
import encoding.tison

SERVER ::= "127.0.0.1"

/*
The filename below refers to the filename at the remote server.
*/

main:
  client := TFTPClient --host=SERVER

  client.open
  result := client.write-string msg --filename="msg.txt"
  print "Write msg, written $result bytes"

  result = client.write-bytes (json.encode map) --filename="map.json"
  print "Write json, written $result bytes"

  result = client.write-bytes (tison.encode map) --filename="map.tison"
  print "Write tison, written $result bytes"
  client.close

msg := "Hello World!"

map := {
  "val1":12,
  "val2": 45,
  "status": "ok",
  "completion": false,
  }
