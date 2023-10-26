import tftp show TFTPClient
import encoding.json
import encoding.tison
import host.file 
SERVER ::= "192.168.0.179"

main:
  client := TFTPClient --host=SERVER

  client.open
  
  read-bytes := client.read-bytes "map.tison"
  map := tison.decode read-bytes
  print "Write map, result: $map"

  
  test_out := file.Stream.for-write "macbeth-read.txt"
  count := client.read "macbeth.txt" --to-writer=test-out
  test-out.close
  print "Read $count bytes"

  /*
  result = client.write (tison.encode map) --name="map.tison"
  print "Write tison, result: $result"
  */
  client.close

