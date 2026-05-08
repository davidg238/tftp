// Copyright 2024, 2026 Ekorau LLC.
//
// Uploads each asset listed in tests/assets.json to the TFTP server's ./temp/
// directory, then queries the server-side SHA256 service on port 8080 and
// verifies the round-trip. Exits non-zero on any mismatch.

import encoding.json
import expect show *
import host.file
import http
import net
import tftp show TFTPClient

SERVER ::= "127.0.0.1"
SHA-SERVICE-PORT ::= 8080

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    map := load-expected-hashes_
    upload-all_ client map
    server-hashes := fetch-server-hashes_
    verify-all_ map server-hashes
    print "All $map.size files uploaded and hashed correctly."
  finally:
    client.close

load-expected-hashes_ -> Map:
  stream := file.Stream.for-read "./assets.json"
  bytes := stream.in.read-all
  stream.close
  return json.decode bytes

upload-all_ client/TFTPClient map/Map -> none:
  map.do: | key/string _ |
    in-path := "../assets/$key"
    in-stream := file.Stream.for-read in-path
    count := 0
    try:
      count = client.write-stream in-stream.in --filename="./temp/$key"
    finally:
      in-stream.close
    print "Wrote $key to server, $count bytes"

fetch-server-hashes_ -> Map:
  network := net.open
  try:
    web-client := http.Client network
    response := web-client.get SERVER --port=SHA-SERVICE-PORT "/"
    data := #[]
    while chunk := response.body.read: data += chunk
    web-client.close
    return json.decode data
  finally:
    network.close

verify-all_ expected/Map actual/Map -> none:
  failures := 0
  expected.do: | key/string want/string |
    got := actual.get key
    if got != want:
      print "Mismatch for $key: expected $want got $got"
      failures++
  expect-equals 0 failures
