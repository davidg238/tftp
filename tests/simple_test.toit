// Copyright 2025, 2026 Ekorau LLC.
//
// Smoke test for the TFTP client against a local server on 127.0.0.1:69.
// Writes two small files, reads them back, and verifies content.
// Exits non-zero on any mismatch so it can be wired into CI.

import expect show *
import encoding.json
import tftp show TFTPClient

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    test-text-roundtrip_ client
    test-json-roundtrip_ client
    print "All TFTP smoke tests passed."
  finally:
    client.close

test-text-roundtrip_ client/TFTPClient -> none:
  msg := "Hello TFTP World!"
  written := client.write-string msg --filename="hello.txt"
  expect-equals msg.size written
  read := client.read-bytes "hello.txt"
  expect-equals msg read.to-string

test-json-roundtrip_ client/TFTPClient -> none:
  data := {"name": "tftp-test", "version": "2.0", "status": "working"}
  encoded := json.encode data
  written := client.write-bytes encoded --filename="test.json"
  expect-equals encoded.size written
  read := client.read-bytes "test.json"
  // Compare via re-encoding: Map equality in Toit is identity, not deep.
  expect-equals encoded.to-string (json.encode (json.decode read)).to-string
