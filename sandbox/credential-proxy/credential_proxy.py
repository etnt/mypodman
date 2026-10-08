#!/usr/bin/env python3
"""Credential-aware API forwarder for isolated Podman sandboxes.

The proxy listens on a Unix socket in a volume shared only with its sandbox.
The sandbox has no network interface. A loopback bridge inside the sandbox
forwards its TCP connections to this socket.
"""

from __future__ import annotations

import argparse
import hmac
import http.client
import os
import select
import signal
import socket
import ssl
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote, urlsplit

MAX_REQUEST_BYTES = 64 * 1024 * 1024
UPSTREAM_TIMEOUT_SECONDS = 300
TUNNEL_IDLE_SECONDS = 120
CONNECT_TIMEOUT_SECONDS = 15
# Requests that name the proxy itself in absolute form (for example through
# an HTTP proxy setting) are accepted. The destination is never taken from them.
LOCAL_AUTHORITY_HOSTS = {"127.0.0.1", "localhost", "credential-proxy"}

PROVIDERS = {
    "openrouter": {
        "route_prefix": "/openrouter/api/v1",
        "upstream_host": "openrouter.ai",
        "upstream_prefix": "/api/v1",
        "methods": {
            "GET": {"/api/v1/models"},
            "POST": {
                "/api/v1/chat/completions",
                "/api/v1/completions",
                "/api/v1/embeddings",
            },
        },
    },
    "openai": {
        "route_prefix": "/openai/v1",
        "upstream_host": "api.openai.com",
        "upstream_prefix": "/v1",
        "methods": {
            "GET": {"/v1/models"},
            "POST": {
                "/v1/chat/completions",
                "/v1/responses",
                "/v1/completions",
                "/v1/embeddings",
                "/v1/images/generations",
                "/v1/audio/transcriptions",
                "/v1/audio/speech",
                "/v1/moderations",
            },
        },
    },
}

CONNECT_ALLOWLIST = {
    ("github.com", 22),
    ("github.com", 443),
    ("api.github.com", 443),
    ("api.githubcopilot.com", 443),
    ("codeload.github.com", 443),
    ("cli.github.com", 443),
    ("copilot-proxy.githubusercontent.com", 443),
    ("github-releases.githubusercontent.com", 443),
    ("objects.githubusercontent.com", 443),
    ("raw.githubusercontent.com", 443),
    ("uploads.github.com", 443),
    ("deb.debian.org", 443),
    ("security.debian.org", 443),
    ("registry.npmjs.org", 443),
    ("pypi.org", 443),
    ("files.pythonhosted.org", 443),
    ("nodejs.org", 443),
}

REQUEST_HEADERS = {
    "accept",
    "accept-encoding",
    "content-type",
    "user-agent",
    "http-referer",
    "x-title",
    "openai-organization",
    "openai-project",
}
RESPONSE_HEADERS = {
    "cache-control",
    "content-encoding",
    "content-length",
    "content-type",
    "date",
    "openrouter-model-id",
    "openrouter-provider-name",
    "retry-after",
    "www-authenticate",
    "x-request-id",
    "request-id",
}


class CredentialProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "SandboxCredentialProxy"
    sys_version = ""

    def log_message(self, format_string: str, *args: object) -> None:
        # Unix socket clients have no address. Do not log headers, bodies,
        # sentinel values, or API keys.
        sys.stderr.write("sandbox %s %s\n" % (self.command, self.path.split("?", 1)[0]))

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_bytes(200, b"ok\n", "text/plain")
            return
        self._forward_api_request()

    def do_HEAD(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._forward_api_request(send_body=False)

    def do_POST(self) -> None:
        self._forward_api_request()

    def do_CONNECT(self) -> None:
        host, separator, port_text = self.path.rpartition(":")
        if not separator:
            self.send_error(400, "CONNECT requires host:port")
            return
        host = host.strip("[]").rstrip(".").lower()
        try:
            port = int(port_text)
        except ValueError:
            self.send_error(400, "Invalid CONNECT port")
            return
        if (host, port) not in CONNECT_ALLOWLIST:
            self.send_error(403, "Destination is not allowed")
            return

        upstream: socket.socket | None = None
        try:
            upstream = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT_SECONDS)
        except OSError:
            if not self.wfile.closed:
                self.send_error(502, "Could not connect to the allowed destination")
            return
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.close_connection = True
        self._tunnel(upstream)

    def _tunnel(self, upstream: socket.socket) -> None:
        # Keep blocking sockets with a timeout. sendall() then completes large
        # writes. Non-blocking sendall() can stop partway through a transfer.
        client = self.connection
        client.settimeout(TUNNEL_IDLE_SECONDS)
        upstream.settimeout(TUNNEL_IDLE_SECONDS)
        sockets = [client, upstream]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], TUNNEL_IDLE_SECONDS)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    destination = upstream if source is client else client
                    destination.sendall(data)
        except OSError:
            return
        finally:
            upstream.close()

    def _send_bytes(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _request_path(self) -> str | None:
        target = self.path
        parsed = urlsplit(target)
        if parsed.scheme:
            if parsed.scheme != "http" or parsed.hostname not in LOCAL_AUTHORITY_HOSTS:
                return None
            target = parsed.path
            if parsed.query:
                target += "?" + parsed.query
        elif parsed.netloc:
            return None

        parsed = urlsplit(target)
        decoded_path = unquote(parsed.path)
        if "\\" in decoded_path or any(part == ".." for part in decoded_path.split("/")):
            return None
        path = decoded_path
        if parsed.query:
            path += "?" + parsed.query
        return path

    def _forward_api_request(self, send_body: bool = True) -> None:
        path = self._request_path()
        if path is None:
            self.send_error(400, "Invalid proxy request target")
            return
        parsed = urlsplit(path)
        provider_name = ""
        provider: dict[str, object] | None = None
        upstream_path = ""
        for candidate_name, candidate in PROVIDERS.items():
            prefix = str(candidate["route_prefix"])
            if parsed.path == prefix or parsed.path.startswith(prefix + "/"):
                provider_name = candidate_name
                provider = candidate
                suffix = parsed.path[len(prefix) :]
                upstream_path = str(candidate["upstream_prefix"]) + suffix
                if parsed.query:
                    upstream_path += "?" + parsed.query
                break
        if provider is None:
            self.send_error(404, "API route is not enabled")
            return

        allowed_paths = provider["methods"].get(self.command, set())  # type: ignore[union-attr]
        bare_upstream_path = urlsplit(upstream_path).path
        if bare_upstream_path not in allowed_paths:
            self.send_error(404, "API route is not enabled")
            return

        sentinel = str(getattr(self.server, "sentinel", ""))
        authorization = self.headers.get("Authorization", "")
        supplied = authorization.removeprefix("Bearer ") if authorization.startswith("Bearer ") else ""
        if not sentinel or not hmac.compare_digest(supplied, sentinel):
            self.send_error(401, "Use the sandbox proxy token")
            return

        keys = getattr(self.server, "keys", {})
        api_key = keys.get(provider_name, "")
        if not api_key:
            self.send_error(503, "No host credential is configured for this provider")
            return

        if self.headers.get("Transfer-Encoding"):
            # Chunked request bodies are not decoded. Refuse them rather than
            # forward an empty body.
            self.send_error(411, "Chunked request bodies are not supported. Send Content-Length.")
            return
        raw_length = self.headers.get("Content-Length")
        try:
            content_length = int(raw_length or "0")
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return
        if content_length < 0 or content_length > MAX_REQUEST_BYTES:
            self.send_error(413, "Request body is too large")
            return
        body = self.rfile.read(content_length) if content_length else None

        request_headers = {
            name: value
            for name, value in self.headers.items()
            if name.lower() in REQUEST_HEADERS
        }
        request_headers["Authorization"] = f"Bearer {api_key}"

        upstream: http.client.HTTPSConnection | None = None
        try:
            upstream = http.client.HTTPSConnection(
                str(provider["upstream_host"]),
                timeout=UPSTREAM_TIMEOUT_SECONDS,
                context=ssl.create_default_context(),
            )
            upstream.request(self.command, upstream_path, body=body, headers=request_headers)
            response = upstream.getresponse()
            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() in RESPONSE_HEADERS:
                    self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            if send_body:
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (OSError, http.client.HTTPException):
            if not self.wfile.closed:
                self.send_error(502, "The provider request failed")
        finally:
            if upstream is not None:
                upstream.close()


class UnixCredentialProxyServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, socket_path: str, keys: dict[str, str], sentinel: str) -> None:
        if os.path.lexists(socket_path):
            os.unlink(socket_path)
        super().__init__(socket_path, CredentialProxyHandler)
        # The sandbox user is a different UID. Any local client that reaches
        # this socket must still present the sandbox token.
        os.chmod(socket_path, 0o666)
        self.keys = keys
        self.sentinel = sentinel


def read_secret_file(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def check_socket(socket_path: str) -> bool:
    """Return True when the proxy answers /health on its socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(socket_path)
            client.sendall(b"GET /health HTTP/1.0\r\n\r\n")
            data = b""
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                data += chunk
    except OSError:
        return False
    return data.startswith(b"HTTP/1.0 200") or data.startswith(b"HTTP/1.1 200")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="Unix socket path to serve")
    parser.add_argument("--token-file", default="", help="File that contains the sandbox proxy token")
    parser.add_argument("--openrouter-key-file", default="")
    parser.add_argument("--openai-key-file", default="")
    parser.add_argument("--check", action="store_true", help="Exit 0 when the socket answers /health")
    args = parser.parse_args()

    if args.check:
        return 0 if check_socket(args.socket) else 1

    sentinel = read_secret_file(args.token_file) if args.token_file else ""
    if not sentinel:
        print("credential proxy: no sandbox token was provided", file=sys.stderr, flush=True)
        return 1

    keys: dict[str, str] = {}
    if args.openrouter_key_file:
        keys["openrouter"] = read_secret_file(args.openrouter_key_file)
    if args.openai_key_file:
        keys["openai"] = read_secret_file(args.openai_key_file)

    server = UnixCredentialProxyServer(args.socket, keys, sentinel)
    # Podman stops the container with SIGTERM. Shut down cleanly.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    print(f"credential proxy ready on {args.socket}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        if os.path.lexists(args.socket):
            os.unlink(args.socket)
    return 0


if __name__ == "__main__":
    sys.exit(main())
