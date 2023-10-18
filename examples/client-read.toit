import tftp show TFTPClient
import encoding.json
import encoding.tison
import host.file 
SERVER ::= "192.168.0.179"

main:
  client := TFTPClient --host=SERVER

  client.open
  
  result := client.read-bytes "map.tison"
  if result.passed:
    map := tison.decode result.data
    print "Read tison, result: $result"
    print "Write map, result: $map"
  else:
    print "Read tison, result: $result"
  
  test_out := file.Stream.for-write "map.tison"
  result = client.read "map.tisn" --to-writer=test-out
  test-out.close
  if result.passed:
    print "Read json passed, result: $result"
  else:
    print "Read json, result: $result"

  /*
  result = client.write (tison.encode map) --name="map.tison"
  print "Write tison, result: $result"
  */
  client.close

