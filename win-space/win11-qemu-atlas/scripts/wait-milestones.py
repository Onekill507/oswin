#!/usr/bin/env python3
"""Block until the guest reports the requested boot milestones.

This is the "make sure Windows boots successfully" gate. It does not merely
check that QEMU is alive - it waits for beacons the guest itself sends:

    winpe       Windows Setup (WinPE) executed our unattend
    specialize  image applied, first real boot of the installed OS
    firstlogon  OOBE finished, autologon into the admin account
    desktop     PowerShell running on the interactive desktop
    checklist   AtlasOS readiness checks completed

While waiting it captures periodic screenshots and fails loudly (with the last
frame) if QEMU dies, the guest stalls, or a milestone times out.

usage: wait-milestones.py --state F --qmp S --shots D --require name:timeout ...
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def read_beacons(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def qmp(sock: str, *args: str) -> tuple[int, str]:
    p = subprocess.run(
        [sys.executable, os.path.join(HERE, "qmp.py"), sock, *args],
        capture_output=True, text=True, timeout=120,
    )
    return p.returncode, (p.stdout + p.stderr).strip()


def shot(sock: str, shots_dir: str, tag: str) -> str | None:
    os.makedirs(shots_dir, exist_ok=True)
    path = os.path.join(shots_dir, f"{time.strftime('%H%M%S')}-{tag}.png")
    rc, _ = qmp(sock, "screenshot", path)
    return path if rc == 0 and os.path.exists(path) else None


def vm_alive(sock: str) -> bool:
    rc, _ = qmp(sock, "status")
    return rc == 0


def gh(kind: str, msg: str) -> None:
    print(f"::{kind}::{msg}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--shots", required=True)
    ap.add_argument("--require", action="append", default=[],
                    help="milestone:timeout_seconds")
    ap.add_argument("--poll", type=float, default=10.0)
    ap.add_argument("--shot-every", type=float, default=120.0)
    a = ap.parse_args()

    targets = []
    for spec in a.require:
        name, _, tmo = spec.partition(":")
        targets.append((name, int(tmo or 900)))

    for name, timeout in targets:
        print(f"\n=== waiting for milestone '{name}' (timeout {timeout}s)", flush=True)
        t0 = time.time()
        last_shot = 0.0
        hit = None

        while True:
            beacons = read_beacons(a.state)
            hit = next((b for b in beacons if b.get("stage") == name), None)
            if hit:
                break

            elapsed = time.time() - t0

            if not vm_alive(a.qmp):
                p = shot(a.qmp, a.shots, f"dead-{name}")
                gh("error",
                   f"QEMU is no longer running while waiting for '{name}' "
                   f"after {elapsed:.0f}s. Last frame: {p}")
                return 1

            if elapsed > timeout:
                p = shot(a.qmp, a.shots, f"timeout-{name}")
                seen = sorted({b["stage"] for b in beacons})
                gh("error",
                   f"Timed out after {timeout}s waiting for '{name}'. "
                   f"Milestones seen so far: {seen or 'none'}. Last frame: {p}")
                print("\nHint: open the noVNC URL from the previous step - the guest "
                      "is probably sitting on a Setup prompt that the unattend did "
                      "not answer.", flush=True)
                return 1

            if time.time() - last_shot > a.shot_every:
                shot(a.qmp, a.shots, f"wait-{name}")
                last_shot = time.time()
                mins = elapsed / 60
                print(f"    ... {mins:5.1f} min elapsed, still waiting for '{name}'",
                      flush=True)

            time.sleep(a.poll)

        took = time.time() - t0
        print(f"    [x] '{name}' reached after {took:.0f}s", flush=True)
        if hit.get("data"):
            print("        " + json.dumps(hit["data"])[:800], flush=True)
        shot(a.qmp, a.shots, f"ok-{name}")

    print("\n=== all required milestones reached - Windows booted successfully",
          flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
