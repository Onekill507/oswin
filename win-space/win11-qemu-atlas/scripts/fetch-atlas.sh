#!/usr/bin/env bash
# Pull AME Wizard + the newest Atlas Playbook on the *host* (fast runner NIC)
# and bake them into a small ATLAS CD-ROM. The guest copies them off it, so a
# flaky in-guest download never blocks the session.
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
A="$VM_DIR/atlas"
mkdir -p "$A"

echo "==> AME Wizard"
curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
  -o "$A/AME_Wizard_Beta.zip" \
  "https://download.amelabs.net/AME%20Wizard%20Beta.zip"
ls -lh "$A/AME_Wizard_Beta.zip"
7z l -ba "$A/AME_Wizard_Beta.zip" | head -20 || true

echo "==> Latest Atlas Playbook (.apbx)"
rel=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/Atlas-OS/Atlas/releases/latest)
tag=$(jq -r '.tag_name' <<<"$rel")
url=$(jq -r '.assets[] | select(.name|endswith(".apbx")) | .browser_download_url' <<<"$rel" | head -1)
name=$(basename "$url")
echo "    release $tag -> $name"

if [ -n "$url" ] && [ "$url" != "null" ]; then
  curl -fL --retry 5 -o "$A/$name" "$url"
  ls -lh "$A/$name"
else
  echo "::warning::No .apbx asset in the latest release; the guest will retry on its own."
fi

# The Atlas docs ship this alongside the playbook - it stops Windows Update
# from silently re-installing OEM drivers mid-playbook.
regurl=$(jq -r '.assets[] | select(.name|endswith(".reg")) | .browser_download_url' <<<"$rel" | head -1)
[ -n "$regurl" ] && [ "$regurl" != "null" ] && curl -fsSL -o "$A/$(basename "$regurl")" "$regurl" || true

printf '%s\n' "$tag" > "$A/ATLAS_RELEASE.txt"

echo "==> Building ATLAS.iso"
genisoimage -quiet -J -r -V "ATLAS" -o "$VM_DIR/media/atlas.iso" "$A"
ls -lh "$VM_DIR/media/atlas.iso"
