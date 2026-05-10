## 2.3.0 - 2026-05-09
Add TFTPServer.

- Server-side RRQ + WRQ with full RFC 2347/2348/2349 option
  negotiation (blksize, tsize, timeout).
- Pluggable Storage backend interface; FilesystemStorage bundled.
  `Storage.reader-for` returns `io.CloseableReader` so the
  per-transfer state machine can close the handle on every exit.
- Bounded concurrency via `--max-concurrent` (default 64); requests
  beyond the cap receive TFTP error 0 ("Server busy").
- Storage-error sentinels (`STORAGE-FILE-NOT-FOUND`,
  `STORAGE-ACCESS-DENIED`, `STORAGE-NO-SPACE`,
  `STORAGE-FILE-EXISTS`) map to TFTP error codes 1/2/3/6.
- Commit-before-final-ACK on WRQ: a backend `close` failure on the
  last block surfaces as a TFTP error rather than a silent partial
  write.
- Silent abort (no ERROR packet) on max-retry timeout, per RFC 1350
  convention; client still surfaces a descriptive throw.
- Refactor: extract abstract `Exchange` base from `ClientExchange`;
  client and server share retry, OACK validation, and TID
  enforcement.
- Reference-impl gates under `tests/`: `server_tftphpa_test.sh`
  (round-trip), `server_blksize_test.sh` (option negotiation),
  `server_burst_test.sh` (concurrency).

## 2.2.0 - 2024-03-06
Improve tests

## 2.1.1 - 2023-10-26
Read/write working

## 2.0.0 - 2023-10-16
Improve api.
Support for streaming writes.

## 1.0.0 - 2023-04-13
Initial public release