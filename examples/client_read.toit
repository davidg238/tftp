import tftp show TFTPClient
import encoding.json
import encoding.tison

SERVER ::= "192.168.0.179"

main:
  client := TFTPClient --host=SERVER

  client.open
  result := client.read_string --name="example.html"
  print "Write msg, result: $result"
  client.close

/*
  client.open
  result = client.write (json.encode map) --name="map.json"
  print "Write json, result: $result"
  client.close

  client.open
  result = client.write (tison.encode map) --name="map.tison"
  print "Write tison, result: $result"
  client.close
*/
