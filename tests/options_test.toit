// Copyright 2026 Ekorau LLC.
//
// Verifies RFC 2347/2348/2349 option negotiation against a local TFTP server
// that supports options (e.g. tftp-go without -rfc1350).

import encoding.hex
import expect show *
import host.file
import tftp show SHA256Summer TFTPClient

SERVER ::= "127.0.0.1"

main:
  test-default-blksize_
  test-large-blksize_
  test-tsize-on-read_
  print "All options tests passed."

test-default-blksize_ -> none:
  client := TFTPClient --host=SERVER
  client.open
  try:
    client.write-string "hello-default" --filename="opts-default.txt"
    bytes := client.read-bytes "opts-default.txt"
    expect-equals "hello-default" bytes.to-string
  finally:
    client.close

test-large-blksize_ -> none:
  // Round-trip a 1 MB blob with a 4096-byte negotiated block size. Block
  // count goes from ~2048 (at 512) down to ~256 (at 4096).
  source := ByteArray 1_048_576: it & 0xff
  expected-sha := sha-of-bytes_ source

  client := TFTPClient --host=SERVER --blksize=4096
  client.open
  try:
    written := client.write-bytes source --filename="opts-blk4096.bin"
    expect-equals source.size written
    expect-equals source.size client.last-tsize  // server confirmed our advertised size
    bytes := client.read-bytes "opts-blk4096.bin"
    expect-equals source.size bytes.size
    expect-equals expected-sha (sha-of-bytes_ bytes)
    expect-equals source.size client.last-tsize  // server reported the file size on RRQ
  finally:
    client.close

test-tsize-on-read_ -> none:
  // Without --blksize the option is omitted, but tsize=0 is always sent on
  // RRQ so the server reports the file size in OACK.
  payload := "tsize-probe-payload"
  client := TFTPClient --host=SERVER
  client.open
  try:
    client.write-string payload --filename="opts-tsize.txt"
    bytes := client.read-bytes "opts-tsize.txt"
    expect-equals payload bytes.to-string
    expect-equals payload.size client.last-tsize
  finally:
    client.close

sha-of-bytes_ data/ByteArray -> string:
  summer := SHA256Summer
  summer.write data
  return hex.encode summer.sum
