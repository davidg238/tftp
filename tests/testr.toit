// Copyright 2023 Ekorau LLC

import .ringstore

main:
  store := RingStore "fred" 5
  print store.minimum
  print store.maximum