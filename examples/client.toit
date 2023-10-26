// Copyright 2023 Ekorau LLC


import tftp show TFTPClient
import host.file
import encoding.tison show encode decode

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

  rstream := file.Stream.for_read "./macbeth.txt"
  result = client.write-stream rstream --filename="macbeth.txt"
  rstream.close
  print "Write msg, result: $result"

  wstream := file.Stream.for_write "./large.txt"
  result = client.read-stream wstream --filename="large.txt"
  wstream.close

  result = client.read-data --filename="data.tison"
  if result.passed:
    print "Read data succeeded, result: $result"
    print "Data: $(decode result.data)"
  else:
    print "Read data failed, result: $result"
  wstream.close

  client.close


  /*
    filename := "./hello.csv"

  test_out := file.Stream.for_write filename
  test_out.write CSV
  test_out.close

  read_back := (file.read_content filename).to_string

  print read_back
  */
