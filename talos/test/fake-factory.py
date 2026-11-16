#!/usr/bin/env python3
"""A stand-in for the Talos Image Factory, for offline tests of fetch-assets.sh.

POST /schematics            -> {"id": "<ID>"}
GET  /image/<ID>/<ver>/<f>  -> fixed bytes (different for the secureboot file)

Usage: fake-factory.py <id> <port-file>
Binds to 127.0.0.1 on a free port, writes the port into <port-file>, serves
until it is killed.
"""
import http.server
import sys

ID = sys.argv[1]
PORT_FILE = sys.argv[2]
PLAIN = b"fake plain iso " * 1024
SECURE = b"fake secureboot iso " * 1024


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        body = f'{{"id":"{ID}"}}'.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "image" and parts[1] == ID:
            data = SECURE if "secureboot" in parts[3] else PLAIN
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.end_headers()


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
