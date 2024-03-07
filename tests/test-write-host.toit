// Copyright 2024 Ekorau LLC

import tftp show TFTPClient SHA256Summer
import encoding.json
import encoding.hex
import host.file
import writer
import http
import net

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

// Write the set of files to the server
  map.do : | key value| 
    inputfile := "../assets/$key"
    reader := file.Stream.for-read inputfile
    count := client.write-stream reader --filename="./temp/$key"
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
  

  