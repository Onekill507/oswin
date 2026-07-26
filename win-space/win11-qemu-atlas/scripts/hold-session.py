#!/usr/bin/env python3
"""Keep the VM alive for the requested window, supervising it the whole time.

Every cycle:
  * confirm QEMU is still running (fail fast if it BSOD'd / exited)
  * capture a screenshot for the artifact trail
  * track guest heartbeats to spot a hung desktop
  * re-print the access URL so it is never buried in scrollback
  * stop early and cleanly if the guest powers itself off (an Atlas playbook
    finishing with a shutdown is a legitimate end state)
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def qmp(sock: str, *args: str) -> tuple[int, str]:
    try:
        p = subprocess.run(
            [sys.executable, os.path.join(HERE, "qmp.py"), sock, *args],
            capture_output=True, text=True, timeout=120,
        )
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 2, "qmp timeout"


def last_heartbeat(state: str) -> float | None:
    if not os.path.exists(state):
        return None
    ts = None
    with open(state, encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("stage") in ("heartbeat", "ready", "atlas_staged", "checklist"):
                ts = rec.get("ts", ts)
    return ts


def hms(sec: float) -> str:
    sec = int(max(sec, 0))
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, required=True)
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--shots", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--tunnel", default="")
    ap.add_argument("--shot-interval", type=float, default=300.0)
    a = ap.parse_args()

    total = a.minutes * 60
    t0 = time.time()
    deadline = t0 + total
    next_shot = t0
    next_banner = t0
    os.makedirs(a.shots, exist_ok=True)

    print(f"Holding the VM open for {a.minutes:.0f} minutes "
          f"(until {time.strftime('%H:%M:%S UTC', time.gmtime(deadline))}).", flush=True)

    while time.time() < deadline:
        now = time.time()
        remaining = deadline - now

        rc, out = qmp(a.qmp, "status")

        # The QMP socket disappearing / refusing means the QEMU process is gone.
        # That is a legitimate end state (a playbook can finish by shutting the
        # guest down), but only once the guest actually reached the desktop -
        # otherwise it means the VM died and the operator needs to know.
        gone = rc != 0 and (
            "cannot connect" in out.lower()
            or "no such file" in out.lower()
            or "closed" in out.lower()
        )
        if gone:
            if not os.path.exists(a.qmp):
                booted = last_heartbeat(a.state) is not None
                if booted:
                    print("\nQEMU is gone and the guest had reached the desktop - "
                          "treating this as a guest-initiated shutdown. "
                          "Ending the session early.", flush=True)
                    return 0
                print("::error::QEMU exited before the guest ever checked in. "
                      "The VM died during the session.", flush=True)
                return 1
        if rc != 0:
            try:
                st = json.loads(out)
            except Exception:
                st = {}
            if st.get("status") in ("shutdown", "guest-panicked"):
                print(f"\nGuest reached state '{st['status']}'. Ending session.", flush=True)
                return 0
            print(f"::warning::QMP status returned rc={rc}: {out[:300]}", flush=True)

        if now >= next_shot:
            tag = f"live-{int((now - t0) // 60):04d}m"
            qmp(a.qmp, "screenshot", os.path.join(a.shots, f"{tag}.png"))
            next_shot = now + a.shot_interval

        if now >= next_banner:
            hb = last_heartbeat(a.state)
            age = f"{int(now - hb)}s ago" if hb else "none yet"
            print(f"[+{hms(now - t0)}] remaining {hms(remaining)} | "
                  f"guest heartbeat: {age}", flush=True)
            if a.tunnel:
                print(f"          console: {a.tunnel}/vnc.html", flush=True)
            if hb and (now - hb) > 900:
                print("::warning::No guest heartbeat for 15+ minutes - the desktop "
                      "may be hung, or a reboot is in progress.", flush=True)
            next_banner = now + 600

        time.sleep(15)

    print(f"\nSession window of {a.minutes:.0f} minutes elapsed. Shutting down.",
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
