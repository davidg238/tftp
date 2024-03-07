// Copyright 2024 Ekorau LLC

import crypto.sha256

class SHA256Summer:
  count_ := 0
  summer_ := sha256.Sha256

  write data /ByteArray -> int:
    summer_.add data
    count_ += data.size
    return data.size

  close:
    count_ = 0
    summer_ = sha256.Sha256

  sum -> ByteArray:
    return summer_.get