// Copyright 2023 Ekorau LLC


import tftp show TFTPClient
import host.file
import encoding.tison show encode

SERVER ::= "192.168.0.179"


main:

  print "Publishing via TFTP to $SERVER"

  client := TFTPClient --host=SERVER
  client.open

  result := client.write-string "Hello World" --filename="hello.txt"
  print "Write msg, result: $result"

  data := [1.23, 45, 6.7, "off"]
  result = client.write-bytes (encode data) --filename="data.tison"
  print "Write msg, result: $result"

  astream := file.Stream.for_read "./macbeth.txt"
  result = client.write-stream astream --filename="macbeth.txt"
  print "Write msg, result: $result"


  client.close


