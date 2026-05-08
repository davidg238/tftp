// Copyright 2024, 2026 Ekorau LLC.
//
// Reads files from the TFTP server onto the ESP32's SD card and compares
// each file's SHA256 against the value reported by the server-side hash
// service. Skips the largest assets, which are too slow over Wi-Fi.

import encoding.hex
import encoding.json
import expect show *
import gpio
import http
import net
import tftp show SDCard SHA256Summer TFTPClient

SERVER ::= "127.0.0.1"
SHA-SERVICE-PORT ::= 8080

SKIP-FILES ::= [
  "sample-png-image_1mb.png",
  "sample-png-image_20mb.png",
  "openwrt-23.05.0-ath79-generic-openmesh_om2p-hs-v1-initramfs-kernel.bin",
]

main:
  client := TFTPClient --host=SERVER
  client.open
  try:
    sdcard := SDCard
        --miso=gpio.Pin 19
        --mosi=gpio.Pin 23
        --clk=gpio.Pin 18
        --cs=gpio.Pin 5

    map := fetch-server-hashes_
    SKIP-FILES.do: map.remove it

    failures := 0
    map.do: | key/string expected/string |
      if not check-file_ client sdcard key expected: failures++
    expect-equals 0 failures
    print "All $map.size files match their expected SHA256."
  finally:
    client.close

fetch-server-hashes_ -> Map:
  network := net.open
  try:
    web-client := http.Client network
    response := web-client.get SERVER --port=SHA-SERVICE-PORT "/"
    data := #[]
    while chunk := response.body.read: data += chunk
    web-client.close
    return json.decode data
  finally:
    network.close

check-file_ client/TFTPClient sdcard/SDCard key/string expected/string -> bool:
  path := "/sd/$key"
  writer := sdcard.openw path
  count := 0
  try:
    count = client.read key --to-writer=writer.out
  finally:
    writer.close
  print "Wrote $key to SDcard, $count bytes"

  summer := SHA256Summer
  reader := sdcard.openr path
  try:
    while bytes := reader.in.read: summer.write bytes
  finally:
    reader.close

  computed := hex.encode summer.sum
  if computed == expected: return true
  print "Mismatch for $key: expected $expected got $computed"
  return false
