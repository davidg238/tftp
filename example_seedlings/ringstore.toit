import math


// Copyright (C) 2023 Ekorau LLC.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import device
import esp32
import system.storage as storage

class RingStore:

  buffer_/storage.Bucket
  cache_ /List? := null
  name /string

  head/int := 0
  count/int := 0
  size_ /int?

  constructor .name size:
    if size < 1: throw "RingBuffer size must be larger then 0"
    size_ = size
    buffer_ = storage.Bucket.open --ram "/admin"
    buffer_.get name --init= : List size 0.0

  cache -> List:
    if cache_ == null:
      cache_ = List.from buffer_[name] // tison returns a non-growable collection
    return cache_

  append value/float -> none:
    if cache_ == null:
      cache_ = List.from buffer_[name] // tison returns a non-growable collection
    cache_[head] = value
    head = (head + 1) % size_
    count = (min (count + 1) size_)
    buffer_[name] = cache_

  clear -> none:
    buffer_[name] = List size_ 0.0
    cache_ = null    
    head = 0
    count = 0

  minimum -> float:
    if count == 0: throw "RingBuffer is empty"
    temp := cache[0]
    for i := 1; i <= count - 1; i++:
      temp = min temp cache[i]
    return temp

  maximum -> float:
    if count == 0: throw "RingBuffer is empty"
    temp := cache[0]
    for i := 1; i <= count - 1; i++:
      temp = max temp cache[i]
    return temp

/*
  has_more -> bool:
    return size > 0

  size -> int:
    return buffer_[name].size

  remove_first -> any:
    buffer := buffer_[name]
    entry := buffer.first
    buffer_[name] = buffer[1..].copy  // `copy`, so as not to store a ListSlice_
    return entry
*/
/*
class RingBuffer:
  
  head/int := 0
  count/int := 0
  size_/int
  buffer/List

  constructor size/int:
    if size < 1: throw "RingBuffer size must be larger then 0"
    size_ = size
    buffer = List size 0.0
    
  append value/float:
    buffer[head] = value
    head = (head + 1) % size_
    count = (min (count + 1) size_)

  minimum -> float:
    if count == 0: throw "RingBuffer is empty"
    temp := buffer[0]
    for i := 1; i <= count - 1; i++:
      temp = min temp buffer[i]
    return temp

  maximum -> float:
    if count == 0: throw "RingBuffer is empty"
    temp := buffer[0]
    for i := 1; i <= count - 1; i++:
      temp = max temp buffer[i]
    return temp

  min value1 value2:
    if value1 < value2:
      return value1
    return value2

  average -> float:
    average := 0.0
    for i := 0; i <= count - 1; i++:
      average += buffer[i]
    return average/count

  std_deviation -> float:
    variance := 0.0
    for i := 0; i < count; i++:
      variance += math.pow (buffer[i] - average) 2
    
    return math.sqrt variance / size_

  get_last -> float:
    return buffer[head - 1]
*/