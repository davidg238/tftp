// Copyright 2024, 2026 Ekorau LLC.

import encoding.tison
import tftp show TFTPClient

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    bytes := client.read-bytes "map.tison"
    map := tison.decode bytes
    print "Read tison-encoded map: $map"
  finally:
    client.close
