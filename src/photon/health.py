#!/usr/bin/env python3
import http.server
import socket
import os

INITIAL_FILE = "/opt/photon/initializing"  # adjust path as needed
CHECK_PORT = 2322

def port_open(port):
    """Return True if something is listening on localhost:port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0

class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if port_open(CHECK_PORT):
            # service is up, remove init file if present
            if os.path.exists(INITIAL_FILE):
                try:
                    os.remove(INITIAL_FILE)
                except OSError:
                    pass
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Service is initializing")
        elif os.path.exists(INITIAL_FILE):
            self.send_response(202)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Service is initializing")
            # FIXME: this does not match spec
        else:
            self.send_response(500)

        self.end_headers()
        self.wfile.write(b"")

    def log_message(self, format, *args):
        # suppress default logging
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 8080), HealthHandler)
    print("Health server listening on port 8080")
    server.serve_forever()
