from http.server import HTTPServer, BaseHTTPRequestHandler
import os
import socket


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return

        self.send_response(200)
        self.end_headers()
        hostname = socket.gethostname()
        self.wfile.write(f"hello from {hostname}\n".encode())

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {args[0]}")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on :{port}")
    server.serve_forever()
