// Copyright 2023, 2024, 2026 Ekorau LLC.
//
// Filenames refer to paths at the remote server.

import encoding.json
import encoding.tison
import tftp show TFTPClient

SERVER ::= "127.0.0.1"

MSG ::= "Hello World!"
MAP ::= {
  "val1": 12,
  "val2": 45,
  "status": "ok",
  "completion": false,
}

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    written := client.write-string MSG --filename="msg.txt"
    print "Wrote msg.txt: $written bytes."

    written = client.write-bytes (json.encode MAP) --filename="map.json"
    print "Wrote map.json: $written bytes."

    written = client.write-bytes (tison.encode MAP) --filename="map.tison"
    print "Wrote map.tison: $written bytes."
  finally:
    client.close
