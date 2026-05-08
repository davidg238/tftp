// Copyright 2026 Ekorau LLC.
//
// Exercises the client against larger files than the canned assets.
// Round-trips them through the TFTP server, verifies SHA256 from the
// downloaded copy against a SHA256 computed locally on the source,
// and reports any failures (including the expected block-num overflow
// for files larger than ~33.5 MB at the default 512-byte block size).

import crypto.sha256
import encoding.hex
import expect show *
import host.file
import tftp show SHA256Summer TFTPClient

SERVER ::= "127.0.0.1"
MAX-BLKSIZE-512-BYTES ::= 65535 * 512  // ~33.5 MB

main args/List:
  paths := args.is-empty
      ? ["/home/david/Downloads/discord-1.0.137.deb"]
      : args
  client := TFTPClient --host=SERVER
  client.open
  try:
    paths.do: | path/string |
      run-roundtrip_ client path
  finally:
    client.close

run-roundtrip_ client/TFTPClient path/string -> none:
  size := file.size path
  basename := path.copy ((path.index-of --last "/") + 1) path.size
  expect-block-overflow := size > MAX-BLKSIZE-512-BYTES
  print "--- $basename ($size bytes, ~$(size / 1024 / 1024) MB)"
  if expect-block-overflow:
    print "  Note: file exceeds 33.5 MB; expecting block-number overflow at upload."

  expected-sha := sha-of-file_ path

  uploaded := 0
  err := catch:
    in-stream := file.Stream.for-read path
    try:
      uploaded = client.write-stream in-stream.in --filename=basename
    finally:
      in-stream.close

  if err != null:
    if expect-block-overflow:
      print "  Got expected error: $err"
      return
    throw err
  print "  Uploaded $uploaded bytes"

  out-path := "./temp/$basename"
  out-stream := file.Stream.for-write out-path
  downloaded := 0
  try:
    downloaded = client.read basename --to-writer=out-stream.out
  finally:
    out-stream.close
  print "  Downloaded $downloaded bytes"

  expect-equals size downloaded
  computed := sha-of-file_ out-path
  expect-equals expected-sha computed
  print "  SHA256 OK: $computed[..16]…"

sha-of-file_ path/string -> string:
  summer := SHA256Summer
  stream := file.Stream.for-read path
  try:
    while bytes := stream.in.read: summer.write bytes
  finally:
    stream.close
  return hex.encode summer.sum
