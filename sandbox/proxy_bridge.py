#!/usr/bin/env python3
"""Forward loopback TCP connections to the credential proxy Unix socket.

The sandbox has no network interface. Tools in the sandbox connect to
127.0.0.1 and this bridge passes the bytes to the proxy socket.
"""

import argparse
import socket
import socketserver
import threading


def pump(source: socket.socket, destination: socket.socket) -> None:
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            destination.sendall(data)
    except OSError:
        pass
    finally:
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class BridgeHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            upstream.connect(self.server.socket_path)  # type: ignore[attr-defined]
        except OSError:
            upstream.close()
            return
        reader = threading.Thread(target=pump, args=(upstream, self.request), daemon=True)
        reader.start()
        pump(self.request, upstream)
        reader.join()
        upstream.close()


class BridgeServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address: tuple[str, int], socket_path: str) -> None:
        self.socket_path = socket_path
        super().__init__(address, BridgeHandler)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
    # Exits with an error when the port is already in use. The wizard starts
    # the bridge again on every enter, so that error is expected.
    with BridgeServer((args.listen, args.port), args.socket) as server:
        server.serve_forever(poll_interval=0.5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
