#!/usr/bin/env python3
"""A store in front of the S3 endpoint that fails a share of the requests.

The fleet gates run against healthy storage, which is not what a real node
meets. This proxy forwards every request to the endpoint it is given and, for
the configured share of them, answers 503 (or delays first) without touching
the origin, so a soak can prove that a node retries instead of losing an
acknowledged write.

    s3-fault-proxy.py --listen 19101 --target http://127.0.0.1:19100 \
        --error-percent 2 --latency-ms 0 --seed 1

Every injected fault is written to stdout as one line, and the proxy exits when
stdin closes so a supervisor can stop it with the soak.
"""
import argparse
import http.client
import random
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "error_percent": 0.0,
    "latency_ms": 0,
    "target": "",
    "random": random.Random(0),
    "faults": 0,
    "requests": 0,
    "lock": threading.Lock(),
}


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _forward(self):
        parsed = urllib.parse.urlsplit(STATE["target"])
        connection = http.client.HTTPConnection(
            parsed.hostname, parsed.port or 80, timeout=60
        )
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        headers = {
            name: value
            for name, value in self.headers.items()
            if name.lower() not in ("host", "connection")
        }
        with STATE["lock"]:
            STATE["requests"] += 1
            fault = STATE["random"].uniform(0, 100) < STATE["error_percent"]
            if fault:
                STATE["faults"] += 1
            latency = STATE["latency_ms"]
        if latency:
            time.sleep(latency / 1000)
        if fault:
            payload = b"injected storage fault"
            self.send_response(503)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(payload)
            print(f"fault {self.command} {self.path}", flush=True)
            connection.close()
            return
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
        except OSError as error:
            payload = f"proxy could not reach the origin: {error}".encode()
            self.send_response(502)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(response.status)
        for name, value in response.getheaders():
            if name.lower() in ("content-length", "connection", "transfer-encoding"):
                continue
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        connection.close()

    do_GET = _forward
    do_PUT = _forward
    do_POST = _forward
    do_DELETE = _forward
    do_HEAD = _forward


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--error-percent", type=float, default=0)
    parser.add_argument("--latency-ms", type=int, default=0)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument(
        "--watch-stdin",
        action="store_true",
        help="exit when stdin closes, so a supervising script stops the proxy",
    )
    arguments = parser.parse_args()
    STATE["target"] = arguments.target
    STATE["error_percent"] = arguments.error_percent
    STATE["latency_ms"] = arguments.latency_ms
    STATE["random"] = random.Random(arguments.seed)
    server = ThreadingHTTPServer(("127.0.0.1", arguments.listen), Proxy)
    print(
        f"proxy listening on 127.0.0.1:{arguments.listen} -> {arguments.target} "
        f"(error {arguments.error_percent}%, latency {arguments.latency_ms}ms)",
        flush=True,
    )
    if arguments.watch_stdin:
        def watch():
            sys.stdin.read()
            print(
                f"proxy stopping: {STATE['faults']} faults of {STATE['requests']} requests",
                flush=True,
            )
            server.shutdown()

        threading.Thread(target=watch, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
