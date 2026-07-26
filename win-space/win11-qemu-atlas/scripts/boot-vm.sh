#!/usr/bin/env bash
# Launch the Windows 11 guest.
#
# Design notes:
#  * -cpu host,+topoext,hv_* : Hyper-V enlightenments cut Windows idle CPU
#    dramatically and stop the "clock watchdog" BSOD under nested virt.
#  * Boot order is expressed with bootindex (install CD=1, system disk=2), NOT
#    `-boot order=`: as soon as any device declares a bootindex, QEMU ignores
#    -boot order entirely. Getting this wrong makes OVMF try the empty disk
#    first and never start Windows Setup.
#  * SATA for the install disk: WinPE from a stock ISO has no virtio-blk driver
#    until the unattend PnP path loads it, and AHCI is boot-safe from frame 0.
#    virtio-net is still used (drivers injected in specialize) for throughput.
#  * SLIRP user networking: no root, no bridges, and 10.0.2.2 gives the guest a
#    free path back to the host beacon.
#  * QMP socket: screenshots, snapshots and ACPI shutdown from the CI steps.
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
RAM_MB=${RAM_MB:-8192}
VCPUS=${VCPUS:-4}
VNC_DISPLAY=${VNC_DISPLAY:-1}
BEACON_PORT=${BEACON_PORT:-8099}
CODE=$(cat "$VM_DIR/ovmf_code.path")

# VNC password: random unless the operator supplied one.
PW=${VNC_PASSWORD:-}
if [ -z "$PW" ]; then
  PW=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
fi
PW=${PW:0:8}                      # VNC protocol truncates beyond 8 chars anyway
printf '%s' "$PW" > "$VM_DIR/vnc.pass"
chmod 600 "$VM_DIR/vnc.pass"
echo "::add-mask::$PW"

ATLAS_CD=()
[ -f "$VM_DIR/media/atlas.iso" ] && ATLAS_CD=(
  -drive "file=$VM_DIR/media/atlas.iso,media=cdrom,readonly=on,index=4"
)

echo "==> Starting QEMU (${VCPUS} vCPU, ${RAM_MB} MiB)"

qemu-system-x86_64 \
  -name "win11-atlas-lab,process=win11vm" \
  -machine q35,accel=kvm,smm=on,vmport=off,hpet=off \
  -cpu host,topoext=on,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_synic,hv_stimer,hv_frequencies,hv_vpindex,hv_runtime,hv_reset \
  -smp "cpus=${VCPUS},sockets=1,cores=${VCPUS},threads=1" \
  -m "${RAM_MB}" \
  -rtc base=localtime,driftfix=slew \
  -global kvm-pit.lost_tick_policy=delay \
  \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=${CODE}" \
  -drive "if=pflash,format=raw,unit=1,file=${VM_DIR}/OVMF_VARS.fd" \
  \
  -chardev "socket,id=chrtpm,path=${VM_DIR}/tpm/swtpm-sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  \
  -device ahci,id=ahci \
  -drive "file=${VM_DIR}/disk/win11.qcow2,if=none,id=osdisk,format=qcow2,cache=writeback,discard=unmap,aio=threads" \
  -device ide-hd,bus=ahci.0,drive=osdisk,bootindex=2 \
  \
  -drive "file=${VM_DIR}/iso/windows.iso,if=none,media=cdrom,readonly=on,id=wincd" \
  -device ide-cd,bus=ahci.1,drive=wincd,bootindex=1 \
  -drive "file=${VM_DIR}/media/provision.iso,media=cdrom,readonly=on,index=2" \
  -drive "file=${VM_DIR}/iso/virtio-win.iso,media=cdrom,readonly=on,index=3" \
  "${ATLAS_CD[@]}" \
  \
  -netdev "user,id=net0,hostfwd=tcp::13389-:3389,dns=8.8.8.8" \
  -device virtio-net-pci,netdev=net0,romfile= \
  \
  -device virtio-balloon-pci \
  -device qemu-xhci,id=xhci \
  -device usb-tablet,bus=xhci.0 \
  -device usb-kbd,bus=xhci.0 \
  -vga std \
  -display "vnc=:${VNC_DISPLAY},password=on" \
  -monitor none \
  -serial "file:${VM_DIR}/logs/serial.log" \
  -qmp "unix:${VM_DIR}/qmp.sock,server=on,wait=off" \
  -boot menu=off,splash-time=1000,strict=off \
  -daemonize \
  -pidfile "${VM_DIR}/qemu.pid" \
  -D "${VM_DIR}/logs/qemu.log" -msg timestamp=on

sleep 3
pid=$(cat "$VM_DIR/qemu.pid")
if ! kill -0 "$pid" 2>/dev/null; then
  echo "::error::QEMU exited immediately."
  tail -50 "$VM_DIR/logs/qemu.log"; exit 1
fi
echo "    QEMU pid $pid"

echo "==> Setting VNC password over QMP"
python3 scripts/qmp.py "$VM_DIR/qmp.sock" set-password "$PW"

VNC_PORT=$((5900 + VNC_DISPLAY))
echo "==> Verifying VNC listener on :${VNC_PORT}"
# Pure-bash TCP probe: no dependency on netcat being present.
tcp_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0 || return 1; }
for _ in $(seq 1 30); do
  tcp_open "$VNC_PORT" && { echo "    listening"; break; }
  sleep 1
done
tcp_open "$VNC_PORT" || { echo "::error::VNC never came up."; tail -40 "$VM_DIR/logs/qemu.log"; exit 1; }

python3 scripts/qmp.py "$VM_DIR/qmp.sock" status
echo "==> VM is running - Windows Setup is booting from the ISO."
