// Copyright 2024 Ekorau LLC

import encoding.tison
import tftp show TFTPClient

SERVER ::= "192.168.0.217"

main:

  client := TFTPClient --host=SERVER
  client.open

  read-bytes := client.read-bytes "map.tison"
  map := tison.decode read-bytes
  print "Read tison encoded map, result: $map"

  client.close
