// Copyright 2023 Ekorau LLC

import .ringstore

main:
  store := RingStore "fred" 5
  store.append 1.1
  store.append 2.2
  store.append 3.3

  print store.minimum
  print store.maximum