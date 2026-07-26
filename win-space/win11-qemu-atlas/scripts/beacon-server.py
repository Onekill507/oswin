#!/usr/bin/env python3
"""Tiny HTTP endpoint the Windows guest phones home to.

The guest reaches the runner at 10.0.2.2 (QEMU SLIRP gateway alias), so we get
real boot telemetry instead of guessing from screenshots. Every hit is appended
to a JSONL file that the waiter/summary steps read.

    GET /health
    GET /beacon?stage=<name>[&data=<url-encoded json>]
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
STATE_PATH = "/mnt/vm/logs/beacons.jsonl"
START = time.time()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, ctype: str = "text/plain") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        u = urlparse(self.path)

        if u.path == "/health":
            self._send(200, b"ok")
            return

        if u.path != "/beacon":
            self._send(404, b"not found")
            return

        qs = parse_qs(u.query)
        stage = (qs.get("stage") or ["unknown"])[0]
        raw = (qs.get("data") or [""])[0]
        data = None
        if raw:
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                data = {"_unparsed": raw[:2000]}

        rec = {
            "ts": time.time(),
            "elapsed": round(time.time() - START, 1),
            "stage": stage,
            "data": data,
        }
        with LOCK:
            with open(STATE_PATH, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")

        if stage != "heartbeat":
            print(f"[beacon +{rec['elapsed']:>7.1f}s] {stage}", flush=True)
            if data:
                print("    " + json.dumps(data)[:600], flush=True)

        self._send(200, b"ack")

    def log_message(self, *_args) -> None:  # silence per-request noise
        pass


def main() -> int:
    global STATE_PATH
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--state", default=STATE_PATH)
    a = ap.parse_args()
    STATE_PATH = a.state

    open(STATE_PATH, "a", encoding="utf-8").close()
    srv = ThreadingHTTPServer(("0.0.0.0", a.port), Handler)
    srv.daemon_threads = True
    print(f"beacon server listening on 0.0.0.0:{a.port} -> {STATE_PATH}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
