// Copyright 2024 Ekorau LLC

import encoding.tison
import tftp show TFTPClient

SERVER ::= "127.0.0.1"

main:

  client := TFTPClient --host=SERVER
  client.open

  read-bytes := client.read-bytes "map.tison"
  map := tison.decode read-bytes
  print "Read tison encoded map, result: $map"

  client.close
