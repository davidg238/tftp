// Copyright 2026 Ekorau LLC.

import cli
import host.directory
import host.file
import log
import tftp show FilesystemStorage TFTPServer

main args/List:
  cmd := cli.Command "tftp-server"
      --help="A TFTP server for host-side use."
      --options=[
        cli.Option "root"
            --help="Directory served as the TFTP root."
            --default="/tmp/tftp-server-test",
        cli.OptionInt "port"
            --help="UDP port to listen on. 69 needs root or cap_net_bind_service."
            --default=6969,
        cli.OptionInt "max-concurrent"
            --help="Maximum simultaneous transfers."
            --default=64,
        cli.Flag "allow-overwrite"
            --help="Permit clients to replace existing files."
            --default=true,
        cli.Flag "read-only"
            --help="Refuse all WRQ requests."
            --default=false,
      ]
      --run=:: serve it
  cmd.run args

serve invocation/cli.Invocation -> none:
  root := invocation["root"]
  port := invocation["port"]
  max-concurrent := invocation["max-concurrent"]
  allow-overwrite := invocation["allow-overwrite"]
  read-only := invocation["read-only"]
  if not file.is-directory root:
    directory.mkdir --recursive root
  storage := FilesystemStorage
      --root=root
      --allow-overwrite=allow-overwrite
      --read-only=read-only
  server := TFTPServer
      --storage=storage
      --port=port
      --max-concurrent=max-concurrent
      --logger=log.default
  print "tftp-server: serving $root on UDP/$port (max-concurrent=$max-concurrent)"
  server.start
