// Copyright 2026 Ekorau LLC.
//
// Self-contained round-trip test: uploads each asset to the TFTP server,
// reads it back, and verifies the SHA256 against the expected value in
// assets.json. Does not require the server-side Flask hash service.
//
// Server setup expected:
//   sudo ./tftp-go -server -root <some-dir> -ow
// (the -ow flag is needed so re-runs can overwrite uploaded files)

import encoding.hex
import encoding.json
import expect show *
import host.file
import tftp show SHA256Summer TFTPClient

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    map := load-expected-hashes_
    failures := 0
    map.do: | key/string expected/string |
      if not roundtrip-one_ client key expected: failures++
    expect-equals 0 failures
    print "All $map.size assets round-tripped with matching SHA256."
  finally:
    client.close

load-expected-hashes_ -> Map:
  stream := file.Stream.for-read "./assets.json"
  bytes := stream.in.read-all
  stream.close
  return json.decode bytes

roundtrip-one_ client/TFTPClient key/string expected/string -> bool:
  source-path := "../assets/$key"
  out-path := "./temp/$key"

  // Upload.
  in-stream := file.Stream.for-read source-path
  uploaded := 0
  try:
    uploaded = client.write-stream in-stream.in --filename=key
  finally:
    in-stream.close
  print "Uploaded $key ($uploaded bytes)"

  // Download.
  out-stream := file.Stream.for-write out-path
  downloaded := 0
  try:
    downloaded = client.read key --to-writer=out-stream.out
  finally:
    out-stream.close

  if downloaded != uploaded:
    print "  Size mismatch: uploaded $uploaded, downloaded $downloaded"
    return false

  // Verify SHA256 of the downloaded copy.
  summer := SHA256Summer
  reader := file.Stream.for-read out-path
  try:
    while bytes := reader.in.read: summer.write bytes
  finally:
    reader.close
  computed := hex.encode summer.sum

  if computed != expected:
    print "  SHA mismatch for $key: expected $expected got $computed"
    return false
  print "  Round-trip OK ($downloaded bytes, sha256 $computed[..12]…)"
  return true
