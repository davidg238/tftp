// Copyright 2024 Ekorau LLC

import writer
import crypto.sha256
import encoding.hex
import host.file
import tftp show SHA256Summer

/// Compare with `sha256sum` on Linux

main args:

  if args.size < 1:
    print "Usage: jag run -d host file-checker.toit <file>"
    return
  
  filename := args[0]
  summer := SHA256Summer
  writer := writer.Writer summer

  filer := file.Stream.for-read filename
  bytes := filer.read
  while bytes != null:
    writer.write bytes
    bytes = filer.read
  filer.close

  sha256sum := summer.sum
  print "$(hex.encode sha256sum)  $filename"
