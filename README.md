# Trivial File Transfer Protocol

A Toit implementation of [RFC 1350](https://www.rfc-editor.org/rfc/rfc1350)
plus the option-negotiation extensions of RFC 2347, RFC 2348 (variable block
size), and RFC 2349 (transfer size, timeout interval).

The package provides both a `TFTPClient` and a `TFTPServer`. The client has
been validated against [TFTP-GO](https://github.com/lfkeitel/tftp-go); the
server is validated against `tftp-hpa` (round-trip) and `atftp` (option
negotiation, concurrency).

## TFTP Server

```toit
import log
import tftp show FilesystemStorage TFTPServer

main:
  storage := FilesystemStorage --root="/srv/tftp" --allow-overwrite
  server := TFTPServer
      --storage=storage
      --port=69
      --max-concurrent=64
      --logger=log.default
  server.start
```

`server.start` blocks until `server.stop` is called; the listen socket
accepts initial RRQ/WRQ datagrams and spawns one task per transfer on
its own ephemeral UDP socket so the listen port is freed for the next
request immediately.

`Storage` is a pluggable backend interface (see `src/storage.toit`). The
bundled `FilesystemStorage` serves a directory tree; other backends
(e.g. an out-of-tree `SqliteStorage`) can implement the same interface.

### Privileged port

On Linux, binding port 69 needs root or `cap_net_bind_service`. The
bundled `examples/server-host.toit` binary takes a `--port` flag so you
can run on 6969 (or any unprivileged port) for testing:

```bash
jag run -d host examples/server-host.toit -- \
    --root=/tmp/tftp --port=6969 --allow-overwrite
```

### IPv6 / Thread

The current Toit SDK does not expose IPv6 listener support; the server
binds IPv4. For Thread / IPv6 deployments use NAT64 or a small UDP
relay on the border router. See `docs/thread-sqlite-deployment.md`.

### Running the server tests

The server is exercised by three reference-implementation gates under
`tests/`:

| script | tool | what it gates |
|---|---|---|
| `server_tftphpa_test.sh` | `tftp` (tftp-hpa) | RRQ + WRQ round-trip for every asset in `assets.json` |
| `server_blksize_test.sh` | `atftp` | RFC 2347/2348 option negotiation; asserts the OACK is on the wire |
| `server_burst_test.sh` | `atftp` | N parallel puts, exercises per-transfer task fan-out |

Install: `apt install tftp-hpa atftp` (Debian / Ubuntu).

Local invocation works for the round-trip gate. The blksize and burst
gates push the local UDP receive buffer near saturation under loopback;
on a busy workstation prefer driving the client over a real LAN with
`--client-from=USER@HOST` (the remote box must have the asset directory
staged at `/tmp/tftp-z170-assets` by default; override with
`REMOTE_ASSET_DIR=...`):

```bash
tests/server_tftphpa_test.sh --client-from=david@z170
tests/server_blksize_test.sh --client-from=david@z170
tests/server_burst_test.sh   --client-from=david@z170 --concurrent=20
```

All three gates also accept `--server=HOST:PORT` to target a server
running on another host.

## TFTP Client

### Running the client tests
A test server is required, assumed to be on the development machine, at `localhost`.  

1. On the test server:  
  - Install the TFTP-GO server, for example in a `/tftp-go` directory in the root.
  - Create an `assets` directory in the root directory.  Then create a `/assets/temp` directory.
  - The command below runs a server, serving files out of the `../assets` directory and allowing files to be overwritten (great to testing).  
    `sudo ./tftp-go -root ../assets -ow -server`
  - Install flask, via `pip install flask`

2. On your development machine:  
  - Install TFTP-GO as a transport mechanism.
  - Change into the `TFTP/tests` directory and copy the `sha_serve.py` file to the test server with something like:
    `~/apps/tftp-go/tftp-go put localhost:sha_serve.py ./sha_serve.py`
  - Run the `assets_populate.sh` script to copy all the assets from your development machine to the test server, adjusting for your setup.  
    You should see something like:  
```
david@MSI-7D43:~/workspaceToit/tftp/tests$ ./populate.sh
2024/03/05 22:05:37 Starting transfer of 48 bytes
2024/03/05 22:05:37 Transfer completed in 1.249929ms
2024/03/05 22:05:37 Starting transfer of 104327 bytes
2024/03/05 22:05:37 Transfer completed in 72.795387ms
2024/03/05 22:05:37 Starting transfer of 1068158 bytes
2024/03/05 22:05:37 Transfer completed in 628.730019ms
2024/03/05 22:05:37 Starting transfer of 21141605 bytes
2024/03/05 22:05:50 Transfer completed in 12.85032291s
2024/03/05 22:05:50 Starting transfer of 106538 bytes
2024/03/05 22:05:50 Transfer completed in 63.650833ms
2024/03/05 22:05:50 Starting transfer of 54 bytes
2024/03/05 22:05:50 Transfer completed in 2.97857ms
2024/03/05 22:05:50 Starting transfer of 886 bytes
2024/03/05 22:05:50 Transfer completed in 1.88329ms
2024/03/05 22:05:50 Starting transfer of 5609087 bytes
2024/03/05 22:05:54 Transfer completed in 3.242393388s
2024/03/05 22:05:54 Starting transfer of 4805 bytes
2024/03/05 22:05:54 Transfer completed in 6.143091ms
2024/03/05 22:05:54 Starting transfer of 722 bytes
2024/03/05 22:05:54 Transfer completed in 1.808616ms
david@MSI-7D43:~/workspaceToit/tftp/tests$ 
```    

3. Then on the test server:
  - Move the `sha_serve.py` file out of the `/assets` directory (I put it in the root).
  - Run the sha server with `python ./sha_serve.py`.  You can test everything is working, by pointing your browser at `http://192.168.0.217:8080/` and you should get:  
```
{
    "example.html": "5a03c85231e303886c6dcd23c3d4c7f563f91ff55712bbc5645ec82c0f46145c",
    "openwrt-23.05.0-ath79-generic-openmesh_om2p-hs-v1-initramfs-kernel.bin": "78fb5aa7d9ab4db7e205c9189f4e2167a787ef0c96cc989674e2937ba70e609a",
    "map.json": "bf4d2dd788d69001722b5368f484b7f397cd79a19d6e2ae9d73b4484998fbd4a",
    "numbers.txt": "f882ef1da55f52b97a2b85876319e1d02a7d7398dd7faba3b8e3c1162c5b1546",
    "sample-png-image_20mb.png": "b513390efecc4acdc69e2c9ac101b7cfbbaf4aad75a9ce7300be75e19c6704ef",
    "macbeth.txt": "2189f6b93022baf7214f6f02c9b6798129f0fb94accc634df26af05fe9b887b8",
    "README.txt": "7914a4e5dfe619ab07eae41efb3d2d9e60c327cbbe5ca3f23f6fc4d3950892da",
    "sample-png-image-100kb.png": "9021aa0a5357a32939ca21dae8d163f67c702d8aef6c229623990936ee9d476f",
    "map.tison": "f216486ce0eba9db802c44298bc6398873b75509a28dffd8a1420bf3638a97d8",
    "sample-png-image_1mb.png": "9d7ee1b614ac0a95d818c94ddac61f0bc326148a59754834659695a1d7dbef8d"
}
```
This is a list of the sample files and the known good SHAs, generated previously on the development machine with `sha_calculate.py`, but included in the project files for convenience.

4. Then on the development machine:
  - To test reading files from the server, run `jag run -d host test-read-host.toit`.  
You should see something like:  

```
david@MSI-7D43:~/workspaceToit/tftp/tests$ jag run -d host test-read-host.toit
Read numbers.txt from server, 4805 bytes
SHA256: f882ef1da55f52b97a2b85876319e1d02a7d7398dd7faba3b8e3c1162c5b1546 computed is correct: true
Read map.tison from server, 48 bytes
SHA256: f216486ce0eba9db802c44298bc6398873b75509a28dffd8a1420bf3638a97d8 computed is correct: true
Read map.json from server, 54 bytes
SHA256: bf4d2dd788d69001722b5368f484b7f397cd79a19d6e2ae9d73b4484998fbd4a computed is correct: true
Read example.html from server, 886 bytes
SHA256: 5a03c85231e303886c6dcd23c3d4c7f563f91ff55712bbc5645ec82c0f46145c computed is correct: true
Read macbeth.txt from server, 106538 bytes
SHA256: 2189f6b93022baf7214f6f02c9b6798129f0fb94accc634df26af05fe9b887b8 computed is correct: true
Read README.txt from server, 722 bytes
SHA256: 7914a4e5dfe619ab07eae41efb3d2d9e60c327cbbe5ca3f23f6fc4d3950892da computed is correct: true
Read sample-png-image-100kb.png from server, 104327 bytes
SHA256: 9021aa0a5357a32939ca21dae8d163f67c702d8aef6c229623990936ee9d476f computed is correct: true
rcvd 1000 blocks
rcvd 2000 blocks
Read sample-png-image_1mb.png from server, 1068158 bytes
SHA256: 9d7ee1b614ac0a95d818c94ddac61f0bc326148a59754834659695a1d7dbef8d computed is correct: true
rcvd 1000 blocks
rcvd 2000 blocks
...
rcvd 40000 blocks
rcvd 41000 blocks
Read sample-png-image_20mb.png from server, 21141605 bytes
SHA256: b513390efecc4acdc69e2c9ac101b7cfbbaf4aad75a9ce7300be75e19c6704ef computed is correct: true
rcvd 1000 blocks
rcvd 2000 blocks
...
rcvd 9000 blocks
rcvd 10000 blocks
Read openwrt-23.05.0-ath79-generic-openmesh_om2p-hs-v1-initramfs-kernel.bin from server, 5609087 bytes
SHA256: 78fb5aa7d9ab4db7e205c9189f4e2167a787ef0c96cc989674e2937ba70e609a computed is correct: true
```

5. To test writing files to the server, run: `jag run -d host test-write-host.toit`.  
You should see something like:  

```
david@MSI-7D43:~/workspaceToit/tftp/tests$ jag run -d host test-write-host.toit
Wrote numbers.txt to server, 4805 bytes
Wrote map.tison to server, 48 bytes
Wrote map.json to server, 54 bytes
Wrote example.html to server, 886 bytes
Wrote macbeth.txt to server, 106538 bytes
Wrote README.txt to server, 722 bytes
Wrote sample-png-image-100kb.png to server, 104327 bytes
Wrote sample-png-image_1mb.png to server, 1068158 bytes
Wrote sample-png-image_20mb.png to server, 21141605 bytes
Wrote openwrt-23.05.0-ath79-generic-openmesh_om2p-hs-v1-initramfs-kernel.bin to server, 5609087 bytes
All hashes compared: true
david@MSI-7D43:~/workspaceToit/tftp/tests$ 
```
6. To test reading files onto the ESP32, you should setup an ESP32 with an SDcard.  
Then run `jag run test-read-esp32.toit`.  
On the JAG console, you should see something like:  
```
[jaguar] INFO: program ab24c154-8c9d-ec4d-edc0-395eb200d93e started
Wrote example.html to SDcard, 886 bytes
Wrote map.json to SDcard, 54 bytes
Wrote numbers.txt to SDcard, 4805 bytes
Wrote macbeth.txt to SDcard, 106538 bytes
Wrote README.txt to SDcard, 722 bytes
Wrote sample-png-image-100kb.png to SDcard, 104327 bytes
Wrote map.tison to SDcard, 48 bytes
All hashes compared: true
[jaguar] INFO: program ab24c154-8c9d-ec4d-edc0-395eb200d93e stopped

```