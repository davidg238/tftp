// Copyright 2026 Ekorau LLC.

import host.directory
import host.file
import io

/**
Storage backend for the TFTP server.

Implementations decide where files come from (a directory, an in-memory map,
  a remote object store, ...). The server uses the methods on this interface
  to satisfy RRQ and WRQ requests.

Methods may throw the sentinel exception strings defined here to signal
  well-known conditions; the server maps these to the corresponding TFTP
  error codes.
*/

/** Sentinel: requested file does not exist. Mapped to TFTP error 1. */
STORAGE-FILE-NOT-FOUND ::= "STORAGE_FILE_NOT_FOUND"
/** Sentinel: file already exists and overwrite is not allowed. Mapped to TFTP error 6. */
STORAGE-FILE-EXISTS ::= "STORAGE_FILE_EXISTS"
/** Sentinel: the operation is forbidden by policy. Mapped to TFTP error 2. */
STORAGE-ACCESS-DENIED ::= "STORAGE_ACCESS_DENIED"
/** Sentinel: storage has no room for the requested write. Mapped to TFTP error 3. */
STORAGE-NO-SPACE ::= "STORAGE_NO_SPACE"

/**
Abstract storage backend.

Subclass to provide a custom file source. See $FilesystemStorage for the
  bundled implementation that maps a directory tree onto the protocol.
*/
abstract class Storage:
  /**
  Returns true if a file with the given $name is currently readable.
  Implementations should be cheap; the server may call this several times
    during a single request.
  */
  abstract exists name/string -> bool

  /**
  Returns the size of $name in bytes, or null if it cannot be determined.
  Used to populate the RFC 2349 tsize option in OACK on RRQ.
  */
  abstract size name/string -> int?

  /**
  Opens $name for reading and returns a $io.Reader.

  Throws $STORAGE-FILE-NOT-FOUND when the file does not exist, or
    $STORAGE-ACCESS-DENIED when reads are forbidden by policy.
  The caller must close the returned reader when done.
  */
  abstract reader-for name/string -> io.Reader

  /**
  Opens $name for writing and returns a $io.Writer.

  Throws $STORAGE-FILE-EXISTS when the file already exists and overwrite is
    not allowed, or $STORAGE-ACCESS-DENIED when writes are forbidden by
    policy.
  The caller must close the returned writer when done; the contents become
    observable via $exists once the writer is closed.
  */
  abstract writer-for name/string -> io.Writer

  /** Whether the storage is willing to serve any read request. */
  reads-allowed -> bool: return true

  /** Whether the storage is willing to accept any write request. */
  writes-allowed -> bool: return true

/**
A $Storage rooted at a filesystem directory.

Filenames are resolved against the configured root. To prevent path traversal
  the resolved path must remain inside the root; absolute paths and ".."
  segments are rejected with $STORAGE-ACCESS-DENIED.

# Construction
- Pass --root for the directory to serve.
- Pass --allow-overwrite to permit clients to replace existing files.
  Defaults to false (matches `tftp-go` without the `-ow` flag).
- Pass --read-only to refuse all WRQ requests.
*/
class FilesystemStorage extends Storage:
  root_/string
  allow-overwrite_/bool
  read-only_/bool

  constructor --root/string --allow-overwrite/bool=false --read-only/bool=false:
    root_ = normalize-root_ root
    allow-overwrite_ = allow-overwrite
    read-only_ = read-only

  exists name/string -> bool:
    catch:
      return file.is-file (resolve_ name)
    return false

  size name/string -> int?:
    catch:
      return file.size (resolve_ name)
    return null

  reader-for name/string -> io.Reader:
    path := resolve_ name
    if not file.is-file path: throw STORAGE-FILE-NOT-FOUND
    return (file.Stream.for-read path).in

  writer-for name/string -> io.Writer:
    if read-only_: throw STORAGE-ACCESS-DENIED
    path := resolve_ name
    if file.is-file path and not allow-overwrite_:
      throw STORAGE-FILE-EXISTS
    ensure-parent-dir_ path
    return (file.Stream.for-write path).out

  reads-allowed -> bool: return true
  writes-allowed -> bool: return not read-only_

  /**
  Resolves $name against $root_, rejecting paths that escape the root.

  Treats forward and backward slashes as separators. Absolute paths and any
    ".." component cause $STORAGE-ACCESS-DENIED.
  */
  resolve_ name/string -> string:
    if name.size == 0: throw STORAGE-ACCESS-DENIED
    if name[0] == '/' or name[0] == '\\': throw STORAGE-ACCESS-DENIED
    if name.size >= 2 and name[1] == ':': throw STORAGE-ACCESS-DENIED  // Windows drive letter.
    parts := split-path_ name
    parts.do: | part/string |
      if part == "..": throw STORAGE-ACCESS-DENIED
      if part == "" or part == ".": throw STORAGE-ACCESS-DENIED
    return "$root_/$(parts.join "/")"

  /** Creates parent directories of $path on demand, ignoring "already exists". */
  ensure-parent-dir_ path/string -> none:
    last := path.index-of --last "/"
    if last < 0 or last == 0: return
    dir := path[..last]
    if file.is-directory dir: return
    catch: directory.mkdir --recursive dir

/** Splits a path on '/' and '\\'; collapses runs of separators. */
split-path_ name/string -> List:
  result := []
  start := 0
  i := 0
  while i < name.size:
    c := name[i]
    if c == '/' or c == '\\':
      if i > start: result.add name[start..i]
      start = i + 1
    i++
  if start < name.size: result.add name[start..]
  return result

/** Strips trailing path separators from the root so resolution joins cleanly. */
normalize-root_ root/string -> string:
  end := root.size
  while end > 0 and (root[end - 1] == '/' or root[end - 1] == '\\'): end--
  return root[..end]
