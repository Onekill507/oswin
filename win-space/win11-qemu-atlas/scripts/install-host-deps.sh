#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing host packages"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools \
  seabios ipxe-qemu \
  genisoimage xorriso p7zip-full wimtools \
  python3-minimal python3-pil \
  netcat-openbsd socat curl jq aria2 \
  websockify novnc \
  >/dev/null

echo "==> Versions"
qemu-system-x86_64 --version | head -1
swtpm --version | head -1
python3 -c "import PIL, PIL.Image; print('pillow', PIL.__version__)"
wiminfo --version 2>/dev/null | head -1 || true

echo "==> OVMF firmware"
ls -l /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_VARS_4M.ms.fd 2>/dev/null \
  || ls -l /usr/share/OVMF/

echo "==> cloudflared (tokenless quick tunnel)"
curl -fsSL --retry 3 -o /tmp/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
cloudflared --version

echo "==> KVM sanity"
[ -w /dev/kvm ] || { echo "::error::/dev/kvm is not writable - no nested virt on this runner."; exit 1; }
echo "OK"
