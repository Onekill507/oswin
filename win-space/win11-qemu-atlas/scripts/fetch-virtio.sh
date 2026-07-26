#!/usr/bin/env bash
# virtio-win: paravirtualised storage/net/balloon drivers. Without viostor,
# WinPE cannot see a virtio disk and Setup dies at "no drives were found".
set -euo pipefail
VM_DIR=${VM_DIR:-/mnt/vm}
DEST="$VM_DIR/iso/virtio-win.iso"
URL=${VIRTIO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}

echo "==> Downloading virtio-win (stable)"
curl -fL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 -o "$DEST" "$URL"
size=$(stat -c%s "$DEST")
echo "    $(numfmt --to=iec "$size")"
[ "$size" -gt 100000000 ] || { echo "::error::virtio-win.iso looks truncated ($size bytes)."; exit 1; }
n=$(7z l -ba "$DEST" 2>/dev/null | grep -icE 'viostor|netkvm' || true)
echo "    viostor/netkvm driver files found: ${n:-0}"
[ "${n:-0}" -gt 0 ] || echo "::warning::No viostor/netkvm entries listed - unexpected virtio ISO layout."
