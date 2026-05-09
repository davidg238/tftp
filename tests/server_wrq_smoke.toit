// Copyright 2026 Ekorau LLC.
//
// Quick smoke test for Toit TFTPServer's WRQ path, using the Toit client.
// Expects the server to be running on 127.0.0.1:7069 with --allow-overwrite.

import encoding.hex
import expect show *
import host.file
import tftp show SHA256Summer TFTPClient

main:
  client := TFTPClient --host="127.0.0.1"
  client.port = 7069
  client.open
  try:
    upload-and-verify_ client "macbeth.txt"
    print "OK"
  finally:
    client.close

upload-and-verify_ client/TFTPClient name/string -> none:
  source := "../assets/$name"
  in-stream := file.Stream.for-read source
  written := 0
  try:
    written = client.write-stream in-stream.in --filename=name
  finally:
    in-stream.close
  print "Uploaded $name ($written bytes)"
