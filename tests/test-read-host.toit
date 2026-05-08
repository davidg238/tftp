// Copyright 2024, 2026 Ekorau LLC.
//
// Reads each asset listed in tests/assets.json from the TFTP server, writes
// it to ./temp/, and verifies the SHA256 against the expected value.
// Exits non-zero on any mismatch.

import encoding.hex
import encoding.json
import expect show *
import host.file
import tftp show TFTPClient SHA256Summer

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    map := load-expected-hashes_
    failures := 0
    map.do: | key/string expected/string |
      if not check-file_ client key expected: failures++
    expect-equals 0 failures
    print "All $map.size files match their expected SHA256."
  finally:
    client.close

load-expected-hashes_ -> Map:
  stream := file.Stream.for-read "./assets.json"
  bytes := stream.in.read-all
  stream.close
  return json.decode bytes

check-file_ client/TFTPClient key/string expected/string -> bool:
  out-path := "./temp/$key"
  out-stream := file.Stream.for-write out-path
  count := 0
  try:
    count = client.read key --to-writer=out-stream.out
  finally:
    out-stream.close
  print "Read $key from server, $count bytes"

  summer := SHA256Summer
  in-stream := file.Stream.for-read out-path
  try:
    while bytes := in-stream.in.read: summer.write bytes
  finally:
    in-stream.close

  computed := hex.encode summer.sum
  if computed == expected:
    print "  SHA256 OK: $computed"
    return true
  print "  SHA256 MISMATCH for $key: expected $expected got $computed"
  return false
