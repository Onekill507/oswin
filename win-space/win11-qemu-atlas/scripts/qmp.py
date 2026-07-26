#!/usr/bin/env python3
"""Minimal QMP client - no pip deps, works against QEMU's unix socket.

usage: qmp.py <sock> <command> [args...]
  status                 print running state + guest uptime info
  screenshot <path.ppm>  dump the framebuffer (converted to PNG if Pillow is up)
  set-password <pw>      set the VNC password
  snapshot <name>        internal qcow2 savevm
  powerdown              ACPI shutdown request
  quit                   hard kill
  raw '<json>'           send an arbitrary QMP command
"""
from __future__ import annotations

import json
import os
import socket
import sys
import time


class QMP:
    def __init__(self, path: str, timeout: float = 60.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.f = self.sock.makefile("rwb")
        greeting = self._readline()          # QMP greeting banner
        if "QMP" not in greeting:
            raise RuntimeError(f"not a QMP socket: {greeting!r}")
        self.execute("qmp_capabilities")

    def _readline(self) -> dict:
        line = self.f.readline()
        if not line:
            raise ConnectionError("QMP socket closed")
        return json.loads(line)

    def execute(self, cmd: str, **args) -> dict:
        payload = {"execute": cmd}
        if args:
            payload["arguments"] = args
        self.f.write((json.dumps(payload) + "\n").encode())
        self.f.flush()
        # Events may interleave with the reply; keep reading until we see one.
        while True:
            msg = self._readline()
            if "return" in msg:
                return msg["return"]
            if "error" in msg:
                raise RuntimeError(f"{cmd}: {msg['error'].get('desc', msg['error'])}")
            # else: async event, ignore

    def close(self) -> None:
        try:
            self.f.close()
            self.sock.close()
        except Exception:
            pass


def to_png(ppm: str, png: str) -> bool:
    try:
        from PIL import Image
        Image.open(ppm).save(png, optimize=True)
        os.remove(ppm)
        return True
    except Exception:
        return False


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    sock_path, cmd, rest = sys.argv[1], sys.argv[2], sys.argv[3:]

    try:
        q = QMP(sock_path)
    except (OSError, RuntimeError) as e:
        print(f"qmp: cannot connect to {sock_path}: {e}", file=sys.stderr)
        return 1
    try:
        if cmd == "status":
            st = q.execute("query-status")
            print(json.dumps(st))
            return 0 if st.get("running") else 1

        if cmd == "screenshot":
            out = rest[0] if rest else "screen.png"
            ppm = out[:-4] + ".ppm" if out.endswith(".png") else out + ".ppm"
            q.execute("screendump", filename=os.path.abspath(ppm))
            # screendump is async-ish: wait for the file to settle.
            for _ in range(40):
                if os.path.exists(ppm) and os.path.getsize(ppm) > 1024:
                    s1 = os.path.getsize(ppm)
                    time.sleep(0.3)
                    if os.path.getsize(ppm) == s1:
                        break
                time.sleep(0.25)
            if out.endswith(".png") and to_png(ppm, out):
                print(out)
            else:
                print(ppm)
            return 0

        if cmd == "set-password":
            try:
                q.execute("change-vnc-password", password=rest[0])
            except RuntimeError:
                q.execute("set_password", protocol="vnc", password=rest[0])
            q.execute("expire_password", protocol="vnc", time="never")
            print("vnc password set")
            return 0

        if cmd == "snapshot":
            name = rest[0] if rest else "snap"
            # human-monitor-command is the portable way to reach savevm.
            out = q.execute("human-monitor-command", **{"command-line": f"savevm {name}"})
            print(out.strip() or f"savevm {name}: ok")
            return 0

        if cmd == "powerdown":
            q.execute("system_powerdown")
            print("ACPI powerdown sent")
            return 0

        if cmd == "quit":
            try:
                q.execute("quit")
            except (ConnectionError, RuntimeError):
                pass
            print("quit sent")
            return 0

        if cmd == "raw":
            print(json.dumps(q.execute(**json.loads(rest[0]))))
            return 0

        print(f"unknown command: {cmd}")
        return 2
    finally:
        q.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ConnectionError, OSError) as exc:
        # Callers only care about the message + a non-zero exit, not a traceback.
        print(f"qmp: {exc}", file=sys.stderr)
        sys.exit(1)
