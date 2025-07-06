// Copyright 2024 Ekorau LLC

import tftp show TFTPClient SHA256Summer
import encoding.json
import encoding.hex
import host.file
import io.writer show Writer
import io
import http
import net

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER

  client.open

  open_file := file.Stream.for_read "./assets.json"
  byte_array := open_file.in.read
  map := json.decode byte-array
  open-file.close

  summer := SHA256Summer
  sha-writer := summer

// Write the set of files to the server
  map.do : | key value| 
    inputfile := "../assets/$key"
    reader := file.Stream.for-read inputfile
    count := client.write-stream reader.in --filename="./temp/$key"
    reader.close
    print "Wrote $key to server, $count bytes"

// Read the list of files received and their hashes
  network := net.open
  web-client := http.Client network
  response := web-client.get "$SERVER:8080" "/"
  data := #[]
  while chunk := response.body.read:
    data += chunk
  web-client.close
  
  map-svr := json.decode data

// Compare the hashes of the files received at the server with the hashes of the files sent.
  hash-str := ""
  result := true
  map.do : | key value| 
    hash-str = map-svr.get key
    if hash_str != value:
      print "For file: $key expected: $value  got: $hash_str"
      result = false
  print "All hashes compared: $result"
  

  