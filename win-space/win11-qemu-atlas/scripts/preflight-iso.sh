#!/usr/bin/env bash
# Validate the user-supplied ISO URL before committing a 6-hour runner to it.
# Emits: iso_bytes, iso_gib, iso_name, resumable  -> $GITHUB_OUTPUT
set -euo pipefail

: "${ISO_URL:?ISO_URL is required}"

out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT" || echo "$1=$2"; return 0; }
die() { echo "::error::$*"; exit 1; }

echo "==> Probing ISO URL"

case "$ISO_URL" in
  https://*) ;;
  http://*)  echo "::warning::Plain HTTP URL - transfer is unauthenticated and unencrypted." ;;
  *) die "iso_url must start with http:// or https:// (got: ${ISO_URL%%:*}...)" ;;
esac

# Some CDNs reject HEAD; fall back to a 1-byte ranged GET.
hdrs=$(curl -sSL --max-time 90 -A 'Mozilla/5.0' -I "$ISO_URL" 2>/dev/null || true)
if [ -z "$hdrs" ] || ! grep -qiE '^HTTP/.* (200|206)' <<<"$hdrs"; then
  echo "    HEAD unusable, retrying with Range: bytes=0-0"
  hdrs=$(curl -sSL --max-time 90 -A 'Mozilla/5.0' -r 0-0 -D - -o /dev/null "$ISO_URL" 2>/dev/null || true)
fi
[ -n "$hdrs" ] || die "No HTTP response from the URL. Is it reachable without authentication?"

status=$(grep -iE '^HTTP/' <<<"$hdrs" | tail -1 | awk '{print $2}' || true)
echo "    Final status: ${status:-unknown}"
case "$status" in
  200|206) ;;
  401|403) die "Server returned $status - the link needs auth/expired. Presigned URLs must be fresh." ;;
  404) die "Server returned 404 - the ISO link is dead." ;;
  "") die "Could not parse an HTTP status." ;;
  *) die "Server returned $status - not a usable direct download." ;;
esac

ctype=$(grep -i '^content-type:' <<<"$hdrs" | tail -1 | tr -d '\r' | cut -d' ' -f2- | tr 'A-Z' 'a-z' || true)
echo "    Content-Type: ${ctype:-<none>}"
case "$ctype" in
  *text/html*|*application/xhtml*)
    die "URL serves an HTML page, not a file. Copy the *direct* ISO link (right-click the download button -> Copy link address)." ;;
esac

# Size: Content-Length on 200, or the total from Content-Range on 206.
bytes=$(grep -i '^content-range:' <<<"$hdrs" | tail -1 | tr -d '\r' | sed -n 's#.*/\([0-9][0-9]*\)$#\1#p' || true)
[ -n "$bytes" ] || bytes=$(grep -i '^content-length:' <<<"$hdrs" | tail -1 | tr -d '\r' | awk '{print $2}' || true)
bytes=${bytes:-0}

if [ "$bytes" -eq 0 ]; then
  echo "::warning::Server did not advertise a size (chunked transfer). Continuing without a size gate."
  gib="unknown"
else
  gib=$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1073741824}')
  echo "    Size: $gib GiB ($bytes bytes)"
  # A Win11 25H2 x64 ISO is ~5.5-7.5 GiB. Anything far outside is the wrong file.
  if [ "$bytes" -lt 3221225472 ]; then
    die "File is only $gib GiB. A Windows 11 x64 ISO is ~5-8 GiB - this looks like an installer stub, a .exe, or an error page."
  fi
  if [ "$bytes" -gt 17179869184 ]; then
    die "File is $gib GiB - too large to stage on a GitHub runner (14 GB usable after cleanup)."
  fi
fi

# Resume support materially changes the download strategy for a 6 GB file.
if grep -qiE '^accept-ranges:[[:space:]]*bytes' <<<"$hdrs" || [ "$status" = "206" ]; then
  resumable=true
else
  resumable=false
fi
echo "    Resumable: $resumable"

name=$(grep -i '^content-disposition:' <<<"$hdrs" | tail -1 | tr -d '\r' \
       | sed -n 's/.*filename\*\?=\(UTF-8'"''"'\)\?"\?\([^";]*\)"\?.*/\2/p' | tail -1 || true)
[ -n "$name" ] || name=$(basename "${ISO_URL%%\?*}")
[ -n "$name" ] || name="windows11.iso"
echo "    Filename: $name"
case "${name,,}" in
  *.iso) ;;
  *) echo "::warning::Filename '$name' does not end in .iso - will still verify the contents after download." ;;
esac

out iso_bytes "$bytes"
out iso_gib   "$gib"
out iso_name  "$name"
out resumable "$resumable"
echo "==> Preflight OK"
