// Copyright 2024 Ekorau LLC

import tftp show TFTPClient SHA256Summer
import encoding.json
import encoding.tison
import encoding.hex
import host.file
import writer
SERVER ::= "192.168.0.217"

main:
  client := TFTPClient --host=SERVER

  client.open

  open_file := file.Stream.for_read "./assets.json"
  byte_array := open_file.read
  map := json.decode byte-array
  open-file.close

  summer := SHA256Summer
  sha-writer := writer.Writer summer


  map.do : | key value| 
    filename := "./temp/$key"
    test_out := file.Stream.for-write filename
    count := client.read key --to-writer=(writer.Writer test-out)
    test-out.close
    print "Read $key from server, $count bytes"
  
    filer := file.Stream.for-read filename
    bytes := filer.read
    while bytes != null:
      sha-writer.write bytes
      bytes = filer.read
    filer.close
  
    sha256sum := summer.sum
    sum-found := hex.encode sha256sum
    print "SHA256: $sum-found computed is correct: $(sum-found == value)"
    summer.close

