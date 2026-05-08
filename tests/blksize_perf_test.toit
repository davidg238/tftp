// Copyright 2026 Ekorau LLC.
//
// Compares transfer time at default 512 vs negotiated 4096 vs 8192 blksize.

import expect show *
import host.file
import tftp show TFTPClient

SERVER ::= "127.0.0.1"

main:
  source-path := "../assets/sample-png-image_20mb.png"
  size := file.size source-path
  print "Transferring $size bytes ($(size / 1024 / 1024) MB) at varying blksize:"

  bench-blksize_ source-path null
  bench-blksize_ source-path 1428    // typical Ethernet-MSS-friendly
  bench-blksize_ source-path 4096
  bench-blksize_ source-path 8192

bench-blksize_ source-path/string blksize/int? -> none:
  client := TFTPClient --host=SERVER --blksize=blksize
  client.open
  try:
    target := blksize == null
        ? "perf-default.bin"
        : "perf-blk$(blksize).bin"

    in-stream := file.Stream.for-read source-path
    start := Time.monotonic-us
    written := 0
    try:
      written = client.write-stream in-stream.in --filename=target
    finally:
      in-stream.close
    upload-ms := (Time.monotonic-us - start) / 1000

    out-stream := file.Stream.for-write "./temp/$target"
    start = Time.monotonic-us
    downloaded := 0
    try:
      downloaded = client.read target --to-writer=out-stream.out
    finally:
      out-stream.close
    download-ms := (Time.monotonic-us - start) / 1000

    expect-equals written downloaded
    expect-equals (file.size source-path) written
    label := blksize == null ? "default(512)" : "$blksize"
    print "  blksize=$label  upload=$upload-ms ms ($written B)  download=$download-ms ms ($downloaded B)"
  finally:
    client.close
