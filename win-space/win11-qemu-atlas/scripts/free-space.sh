#!/usr/bin/env bash
# GitHub's ubuntu-24.04 image ships ~25 GB used on / plus a large /mnt scratch.
# We need room for: ISO (~6 GB) + qcow2 growth (~25 GB) + virtio (~0.8 GB).
set -euo pipefail

echo "==> Before:"; df -h / /mnt

sudo rm -rf \
  /usr/share/dotnet \
  /usr/local/lib/android \
  /opt/ghc \
  /usr/local/share/boost \
  /usr/local/.ghcup \
  /usr/share/swift \
  /usr/local/lib/node_modules \
  "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}" 2>/dev/null || true

sudo docker image prune -af >/dev/null 2>&1 || true
sudo apt-get clean

echo "==> After:"; df -h / /mnt

# /mnt is the big ephemeral SSD on Azure-hosted runners - that is where the VM lives.
avail=$(df -BG --output=avail /mnt | tail -1 | tr -dc '0-9')
echo "==> /mnt available: ${avail} GiB"
if [ "${avail:-0}" -lt 40 ]; then
  echo "::warning::Only ${avail} GiB free on /mnt. Reduce disk_gb if the run fails on ENOSPC."
fi
