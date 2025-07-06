// Copyright 2024 Ekorau LLC

import tftp show TFTPClient SHA256Summer
import encoding.json
import encoding.tison
import encoding.hex
import host.file
import io.writer show Writer
import io
SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER

  client.open

  open_file := file.Stream.for_read "./assets.json"
  byte_array := open_file.in.read
  map := json.decode byte-array
  open-file.close

  summer := SHA256Summer
  sha-writer := summer  // The summer object itself implements write


  map.do : | key value| 
    filename := "./temp/$key"
    test_out := file.Stream.for-write filename
    count := client.read key --to-writer=test-out.out
    test-out.close
    print "Read $key from server, $count bytes"
  
    filer := file.Stream.for-read filename
    bytes := filer.in.read
    while bytes != null:
      sha-writer.write bytes
      bytes = filer.in.read
    filer.close
  
    sha256sum := summer.sum
    sum-found := hex.encode sha256sum
    print "SHA256: $sum-found computed is correct: $(sum-found == value)"
    summer.close

