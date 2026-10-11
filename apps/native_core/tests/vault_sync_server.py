#!/usr/bin/env python3
import hashlib
import http.server
import pathlib
import sys
import time


class SyncHandler(http.server.BaseHTTPRequestHandler):
    store_path = pathlib.Path()
    object_path = "/vault.sync.json"

    def do_HEAD(self):
        self._send_object(head_only=True)

    def do_GET(self):
        self._send_object(head_only=False)

    def do_PUT(self):
        if self.path != self.object_path:
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.store_path.write_bytes(body)
        self.send_response(200)
        self.send_header("ETag", f'"{hashlib.sha256(body).hexdigest()}"')
        self.send_header("Last-Modified", self.date_time_string(time.time()))
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format, *args):
        return

    def _send_object(self, head_only):
        if self.path != self.object_path or not self.store_path.exists():
            self.send_response(404)
            self.end_headers()
            return
        body = self.store_path.read_bytes()
        self.send_response(200)
        self._send_metadata_headers(body)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _send_metadata_headers(self, body):
        digest = hashlib.sha256(body).hexdigest()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", f'"{digest}"')
        self.send_header("Last-Modified", self.date_time_string(time.time()))


def main():
    if len(sys.argv) != 3:
        print("usage: vault_sync_server.py <port-file> <store-file>", file=sys.stderr)
        return 64
    port_file = pathlib.Path(sys.argv[1])
    SyncHandler.store_path = pathlib.Path(sys.argv[2])
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SyncHandler)
    port_file.write_text(str(server.server_port), encoding="utf-8")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
