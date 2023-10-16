// Copyright (C) 2023 Ekorau LLC.

import math
import device
import esp32
import system.storage as storage

DEFAULT-VAL ::= 0.0

class RingStore:

  buffer_/storage.Bucket
  cache_ /List? := null
  name /string
  head-name /string
  count-name /string

  head/int := 0
  count/int := 0
  size_ /int?

  constructor .name size:
    if size < 1: throw "RingBuffer size must be larger then 0"
    size_ = size
    head-name = "head_$name"
    count-name = "count_$name"
    buffer_ = storage.Bucket.open --flash "/admin"
    buffer_.get name --init= : List size DEFAULT-VAL
    head = buffer_.get head-name --init= : 0
    count = buffer_.get count-name --init= : 0

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
    buffer_[head-name] = head
    buffer_[count-name] = count

  clear -> none:
    buffer_[name] = List size_ DEFAULT-VAL
    cache_ = null    
    head = 0
    count = 0
    buffer_[head-name] = head
    buffer_[count-name] = count
    
  is-empty -> bool:
    return count == 0

  reduce [block]:
    if is-empty: throw "Not enough elements"
    result := null
    is-first := true
    for i := 0; i < count; i++:
      if is-first: result = cache[i]; is-first = false
      else: result = block.call result cache[i]
    return result


  minimum -> float:
    return reduce : | a b | min a b

  maximum -> float:
    return reduce : | a b | max a b

