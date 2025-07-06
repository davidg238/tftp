# TFTP SDK Upgrade Summary, v2.1.2

## Issues Fixed

### 1. API Deprecation Issues
- **Import changes**: Updated from deprecated `reader`/`writer` modules to `io.reader`/`io.writer`
- **Reader/Writer classes**: Replaced `bytes.Reader`/`bytes.Writer` with `io.Reader`/`io.Writer`
- **Stream API**: Updated `Stream.read` calls to use `stream.in.read`
- **Writer adaptation**: Changed file streams to use `.out` property for writing

### 2. Streaming Implementation
- **Removed buffer-all approach**: The old API used `buffer-all()` which would load entire files into memory
- **Implemented true streaming**: Now reads files in chunks (block size) to support large files without memory issues
- **Fixed Reader methods**: Replaced deprecated `can-ensure`/`buffered` with streaming-compatible logic

### 3. Naming Conflicts
- **Field naming**: Renamed class field `filename` to `filename_` to avoid conflicts with method parameters
- **Parameter handling**: Fixed parameter vs field confusion in write methods

## Files Modified

### Core Library
- `src/tftp_client.toit`: Main client implementation with streaming fixes
- `src/sha256_summer.toit`: No changes needed (already compatible)

### Examples
- `examples/client-read-host.toit`: Updated to use localhost and new API
- `examples/client-read.toit`: Updated to use localhost
- `examples/client-read-esp32.toit`: Updated API (ESP32 hardware still required)
- `examples/client-write.toit`: Updated to use localhost

### Tests
- `tests/test-read-host.toit`: Updated to use new API and localhost
- `tests/test-write-host.toit`: Updated to use new API and localhost
- `tests/test-read-esp32.toit`: Updated API (ESP32 hardware still required)
- `tests/simple_test.toit`: New simplified test for basic functionality

## Simplified Test Procedure

### Prerequisites
1. Start a TFTP server on localhost (127.0.0.1:69)
2. Ensure the server allows read/write operations

### Running Tests

#### Quick Test
```bash
cd tests
jag run -d host simple_test.toit
```

#### Individual Examples
```bash
cd examples
jag run -d host client-write.toit    # Write test files
jag run -d host client-read.toit     # Read a small file
jag run -d host client-read-host.toit # Read with file output
```

#### Full Test Suite (if server supports large files)
```bash
cd tests
jag run -d host test-write-host.toit  # Write various files
jag run -d host test-read-host.toit   # Read and verify files
```

## Key Improvements

1. **Memory Efficiency**: No longer loads entire files into memory
2. **Streaming Support**: Can handle files of any size within available storage
3. **Simplified Testing**: Single test file for basic functionality verification
4. **Localhost Usage**: No longer requires external server setup for basic testing
5. **API Compatibility**: Fully compatible with latest Toit SDK

## Compatibility Notes

- The public API remains unchanged - existing code using the TFTP client will continue to work
- ESP32 functionality is preserved but requires ESP32 hardware for testing
- Large file transfers now use less memory but may be slightly slower due to streaming
- All original RFC 1350 TFTP functionality is maintained
