#!/usr/bin/env bash
# Optional: compress the qcow2 for download. GitHub caps a single artifact
# file at 10 GB, so we split into 1.9 GB parts.
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
SRC="$VM_DIR/disk/win11.qcow2"
OUT="$VM_DIR/export"
[ -f "$SRC" ] || { echo "No disk image to export."; exit 0; }
mkdir -p "$OUT"

echo "==> Allocated size before compaction:"
qemu-img info "$SRC" | sed 's/^/    /'

echo "==> Re-compressing (zstd inside qcow2)"
qemu-img convert -p -O qcow2 -c -o compression_type=zstd "$SRC" "$OUT/win11-atlas.qcow2" \
  || qemu-img convert -p -O qcow2 -c "$SRC" "$OUT/win11-atlas.qcow2"

sz=$(stat -c%s "$OUT/win11-atlas.qcow2")
echo "==> Compressed: $(numfmt --to=iec "$sz")"

if [ "$sz" -gt 2000000000 ]; then
  echo "==> Splitting into 1.9G parts"
  split -b 1900M -d "$OUT/win11-atlas.qcow2" "$OUT/win11-atlas.qcow2.part"
  rm -f "$OUT/win11-atlas.qcow2"
  cat > "$OUT/REASSEMBLE.txt" <<'EOF'
cat win11-atlas.qcow2.part* > win11-atlas.qcow2
qemu-img check win11-atlas.qcow2
EOF
fi
ls -lh "$OUT"
