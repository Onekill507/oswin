#!/usr/bin/env bash
# Download the user-provided ISO with resume + integrity checks.
set -euo pipefail

: "${ISO_URL:?}"
VM_DIR=${VM_DIR:-/mnt/vm}
ISO="$VM_DIR/iso/windows.iso"
RESUMABLE=${RESUMABLE:-false}
ISO_SHA256=${ISO_SHA256:-}

echo "==> Downloading Windows ISO"
start=$(date +%s)

if [ "$RESUMABLE" = "true" ]; then
  # 8 parallel connections; aria2 saturates the runner NIC far better than curl.
  aria2c \
    --dir="$VM_DIR/iso" --out=windows.iso \
    --continue=true --max-connection-per-server=8 --split=8 --min-split-size=64M \
    --max-tries=5 --retry-wait=10 --timeout=60 --connect-timeout=30 \
    --auto-file-renaming=false --allow-overwrite=true \
    --summary-interval=30 --console-log-level=warn \
    --user-agent='Mozilla/5.0' \
    "$ISO_URL"
else
  echo "    Server has no Range support - single-stream curl."
  curl -fL --retry 5 --retry-delay 10 --retry-all-errors \
       --connect-timeout 30 -A 'Mozilla/5.0' \
       -o "$ISO" "$ISO_URL"
fi

took=$(( $(date +%s) - start ))
size=$(stat -c%s "$ISO")
echo "==> ${size} bytes in ${took}s ($(awk -v s="$size" -v t="$took" 'BEGIN{printf "%.1f", s/1048576/(t?t:1)}') MiB/s)"

# An HTML error page saved as .iso is the single most common failure mode.
if head -c 512 "$ISO" | grep -qiE '<html|<!doctype html|<\?xml'; then
  echo "::error::Downloaded file is HTML/XML, not an ISO. The URL is a landing page or returned an error body."
  head -c 400 "$ISO"; exit 1
fi

if [ -n "$ISO_SHA256" ]; then
  echo "==> Verifying SHA-256"
  actual=$(sha256sum "$ISO" | awk '{print $1}')
  expected=$(tr 'A-Z' 'a-z' <<<"$ISO_SHA256" | tr -d ' ')
  if [ "$actual" != "$expected" ]; then
    echo "::error::SHA-256 mismatch"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "    OK: $actual"
else
  sha256sum "$ISO" | tee "$VM_DIR/logs/iso.sha256"
fi
