#!/usr/bin/env bash
# Graceful ACPI shutdown, then escalate. Never let a stuck guest fail the job -
# artifacts still need to upload.
set -uo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
[ -f "$VM_DIR/qemu.pid" ] || { echo "No VM pidfile - nothing to shut down."; exit 0; }
PID=$(cat "$VM_DIR/qemu.pid")

if ! kill -0 "$PID" 2>/dev/null; then
  echo "QEMU (pid $PID) already exited."
  exit 0
fi

echo "==> Final screenshot"
python3 scripts/qmp.py "$VM_DIR/qmp.sock" screenshot "$VM_DIR/shots/zz-final.png" || true

echo "==> ACPI powerdown"
python3 scripts/qmp.py "$VM_DIR/qmp.sock" powerdown || true

GRACE=${SHUTDOWN_GRACE:-120}       # seconds to let Windows land cleanly
for i in $(seq 1 "$GRACE"); do
  kill -0 "$PID" 2>/dev/null || { echo "    guest powered off cleanly after ${i}s"; break; }
  sleep 1
done

if kill -0 "$PID" 2>/dev/null; then
  echo "::warning::Guest ignored ACPI shutdown - sending QMP quit."
  python3 scripts/qmp.py "$VM_DIR/qmp.sock" quit || true
  sleep 5
fi
if kill -0 "$PID" 2>/dev/null; then
  echo "::warning::Escalating to SIGKILL."
  kill -9 "$PID" 2>/dev/null || true
fi

pkill -f 'cloudflared tunnel' 2>/dev/null || true
pkill -f websockify 2>/dev/null || true
pkill -f beacon-server.py 2>/dev/null || true
pkill swtpm 2>/dev/null || true

echo "==> Beacon timeline"
if [ -f "$VM_DIR/logs/beacons.jsonl" ]; then
  python3 - "$VM_DIR/logs/beacons.jsonl" <<'PY'
import json, sys, collections
counts = collections.Counter()
first = {}
for line in open(sys.argv[1], encoding="utf-8"):
    try: r = json.loads(line)
    except Exception: continue
    s = r["stage"]; counts[s] += 1
    first.setdefault(s, r["elapsed"])
for s, e in sorted(first.items(), key=lambda kv: kv[1]):
    print(f"  +{e:>8.1f}s  {s}  (x{counts[s]})")
PY
fi

echo "==> Done"
exit 0
