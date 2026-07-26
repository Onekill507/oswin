#!/usr/bin/env bash
# qcow2 system disk + per-VM UEFI SecureBoot NVRAM + software TPM 2.0.
# Windows 11 genuinely wants TPM 2.0 and SecureBoot; we give it real ones
# rather than relying purely on the LabConfig bypasses.
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
DISK_GB=${DISK_GB:-64}

echo "==> qcow2 system disk (${DISK_GB}G, thin-provisioned)"
qemu-img create -f qcow2 -o cluster_size=2M,preallocation=off \
  "$VM_DIR/disk/win11.qcow2" "${DISK_GB}G"
qemu-img info "$VM_DIR/disk/win11.qcow2"

echo "==> UEFI variable store (Microsoft keys enrolled)"
CODE=""; VARS=""
for c in /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
         /usr/share/OVMF/OVMF_CODE.secboot.fd \
         /usr/share/OVMF/OVMF_CODE_4M.fd; do
  [ -f "$c" ] && { CODE="$c"; break; }
done
for v in /usr/share/OVMF/OVMF_VARS_4M.ms.fd \
         /usr/share/OVMF/OVMF_VARS.ms.fd \
         /usr/share/OVMF/OVMF_VARS_4M.fd \
         /usr/share/OVMF/OVMF_VARS.fd; do
  [ -f "$v" ] && { VARS="$v"; break; }
done
[ -n "$CODE" ] && [ -n "$VARS" ] || { echo "::error::OVMF firmware not found."; exit 1; }
case "$VARS" in *.ms.fd) echo "    SecureBoot: MS keys pre-enrolled";; *) echo "::warning::Using non-MS OVMF vars - SecureBoot will be off.";; esac

cp "$VARS" "$VM_DIR/OVMF_VARS.fd"
chmod 0644 "$VM_DIR/OVMF_VARS.fd"
printf '%s' "$CODE" > "$VM_DIR/ovmf_code.path"
echo "    CODE=$CODE"
echo "    VARS=$VM_DIR/OVMF_VARS.fd"

echo "==> swtpm (TPM 2.0)"
mkdir -p "$VM_DIR/tpm"
swtpm socket \
  --tpmstate dir="$VM_DIR/tpm" \
  --ctrl type=unixio,path="$VM_DIR/tpm/swtpm-sock" \
  --tpm2 \
  --log file="$VM_DIR/logs/swtpm.log",level=1 \
  --daemon
for _ in $(seq 1 40); do [ -S "$VM_DIR/tpm/swtpm-sock" ] && break; sleep 0.25; done
[ -S "$VM_DIR/tpm/swtpm-sock" ] || { echo "::error::swtpm socket never appeared."; tail -20 "$VM_DIR/logs/swtpm.log"; exit 1; }
echo "    socket ready: $VM_DIR/tpm/swtpm-sock"
