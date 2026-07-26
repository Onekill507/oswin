#!/usr/bin/env bash
# Prove the ISO really is bootable Windows 11 25H2 x64 and contains the chosen
# edition - BEFORE we spend an hour installing it.
#
# AtlasOS 0.5.x requires build 26100 (24H2) or 26200 (25H2), x64/ARM64.
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
ISO="$VM_DIR/iso/windows.iso"
WANT_EDITION=${WINDOWS_EDITION:-Windows 11 Pro}
LOG="$VM_DIR/logs/iso-verify.txt"
# NB: must return 0 even when GITHUB_OUTPUT is unset (local runs), otherwise
# `set -e` aborts the script on the very last statements.
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }

exec > >(tee -a "$LOG") 2>&1
echo "==> Inspecting $(basename "$ISO")"

7z l -ba "$ISO" > "$VM_DIR/logs/iso-listing.txt" 2>/dev/null || true
listing=$(tr 'A-Z' 'a-z' < "$VM_DIR/logs/iso-listing.txt")

need_any() { # any-of these paths must exist
  for p in "$@"; do grep -qF "$p" <<<"$listing" && return 0; done
  return 1
}

echo "--- structure"
need_any "sources/install.wim" "sources/install.esd" \
  || { echo "::error::No sources/install.wim|esd - this is not a Windows installation ISO."; exit 1; }
need_any "sources/boot.wim"    || { echo "::error::No sources/boot.wim - WinPE boot media missing, the ISO cannot boot."; exit 1; }
need_any "efi/boot/bootx64.efi" || { echo "::error::No EFI/Boot/bootx64.efi - the ISO is not UEFI x64 bootable (32-bit or hybrid-only media)."; exit 1; }
echo "    sources/install.*  OK"
echo "    sources/boot.wim   OK"
echo "    EFI x64 bootloader OK"

# Extract the install image so wiminfo can read real metadata.
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
img=""
if need_any "sources/install.wim"; then
  7z e -y -o"$work" "$ISO" "sources/install.wim" >/dev/null && img="$work/install.wim"
else
  7z e -y -o"$work" "$ISO" "sources/install.esd" >/dev/null && img="$work/install.esd"
fi
[ -s "$img" ] || { echo "::error::Failed to extract the install image from the ISO (corrupt download?)."; exit 1; }

echo "--- image metadata"
info=$(wiminfo "$img" 2>/dev/null || true)
[ -n "$info" ] || { echo "::error::wiminfo could not read the image - the ISO is corrupt."; exit 1; }
grep -E '^(Index|Name|Description|Architecture|Build|Service Pack Build|Display Name|Edition ID)' <<<"$info" || true

arch=$(grep -m1 -E '^Architecture' <<<"$info" | awk -F': *' '{print $2}' | tr -d '\r' || true)
build=$(grep -m1 -E '^Build' <<<"$info" | awk -F': *' '{print $2}' | tr -d '\r' || true)
spbuild=$(grep -m1 -E '^Service Pack Build' <<<"$info" | awk -F': *' '{print $2}' | tr -d '\r' || true)

echo "--- checks"
# [x] 64-bit (x64)
case "${arch,,}" in
  x86_64|x64|amd64) echo "    [x] Architecture: $arch (64-bit)";;
  *) echo "::error::Architecture is '$arch'. AtlasOS and this workflow require x64."; exit 1;;
esac

# [x] Windows 11 25H2 (build 26200). 26100 = 24H2, also Atlas-supported.
case "$build" in
  26200) echo "    [x] Build $build -> Windows 11 25H2";;
  26100)
    echo "::warning::Build 26100 = Windows 11 24H2, not 25H2. AtlasOS 0.5.x supports it, so continuing."
    echo "    [~] Build $build -> Windows 11 24H2";;
  2[2-9][0-9][0-9][0-9])
    echo "::warning::Build $build is a Win11 build newer/other than 26100/26200. AtlasOS may refuse it."
    echo "    [~] Build $build";;
  22621|22631|22000)
    echo "::error::Build $build is Windows 11 21H2/22H2/23H2. AtlasOS 0.5.x requires 24H2 (26100) or 25H2 (26200)."; exit 1;;
  1[0-9][0-9][0-9][0-9])
    echo "::error::Build $build is Windows 10. This workflow targets Windows 11 25H2."; exit 1;;
  *) echo "::error::Unrecognised build '$build'."; exit 1;;
esac
[ -n "$spbuild" ] && echo "    UBR / SP build: $spbuild"

# Requested edition must exist in the image, otherwise Setup halts on a picker.
echo "--- editions in image"
mapfile -t editions < <(grep -E '^Name:' <<<"$info" | sed 's/^Name: *//' | tr -d '\r')
printf '    - %s\n' "${editions[@]}"
idx=""
for i in "${!editions[@]}"; do
  if [ "${editions[$i],,}" = "${WANT_EDITION,,}" ]; then idx=$((i+1)); break; fi
done
if [ -z "$idx" ]; then
  echo "::error::Requested edition '$WANT_EDITION' is not in this ISO. Re-run and pick one of the editions listed above."
  exit 1
fi
echo "    [x] '$WANT_EDITION' present (image index $idx)"

out iso_build "$build"
out iso_arch "$arch"
out image_index "$idx"
# Persist for the unattend builder (steps do not share step-outputs by default).
mkdir -p "$VM_DIR/media"
printf '%s' "$idx"   > "$VM_DIR/media/image-index.txt"
printf '%s' "$build" > "$VM_DIR/media/build.txt"
echo "==> ISO verified: Windows 11 build $build $arch, edition '$WANT_EDITION'"
