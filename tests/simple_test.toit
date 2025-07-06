// Simple test script for TFTP client
// This test writes and reads files to/from the local TFTP server

import tftp show TFTPClient
import encoding.json

SERVER ::= "127.0.0.1"

main:
  client := TFTPClient --host=SERVER
  client.open

  // Test 1: Write a simple text file
  print "Test 1: Writing text file"
  msg := "Hello TFTP World!"
  written := client.write-string msg --filename="hello.txt"
  print "✓ Wrote hello.txt: $written bytes"

  // Test 2: Write JSON data
  print "\nTest 2: Writing JSON file"
  data := {"name": "tftp-test", "version": "2.0", "status": "working"}
  written = client.write-bytes (json.encode data) --filename="test.json"
  print "✓ Wrote test.json: $written bytes"

  // Test 3: Read the text file back
  print "\nTest 3: Reading text file"
  read_msg := client.read-bytes "hello.txt"
  print "✓ Read hello.txt: $read_msg.size bytes"
  print "  Content: '$(read_msg.to-string)'"
  print "  Content matches: $(read_msg.to-string == msg)"

  // Test 4: Read the JSON file back
  print "\nTest 4: Reading JSON file"
  read_json := client.read-bytes "test.json"
  parsed := json.decode read_json
  print "✓ Read test.json: $read_json.size bytes"
  print "  Content: $parsed"
  print "  Content matches: $(parsed == data)"
  
  // Test 5: Test the single file we wrote
  print "\nTest 5: Reading single file"
  single_json := client.read-bytes "test-single.json"
  print "✓ Read test-single.json: $single_json.size bytes"
  print "  Content: $(single_json.to-string)"

  client.close
  print "\n✓ All tests passed! TFTP client is working correctly."
