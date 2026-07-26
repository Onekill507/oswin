#!/usr/bin/env bash
# Tokenless remote access:
#   QEMU VNC :5901  ->  websockify/noVNC :6080  ->  cloudflared quick tunnel
#
# A "quick tunnel" needs no Cloudflare account, no API token and no repo
# secret - cloudflared hands back a random https://<slug>.trycloudflare.com
# hostname. The VNC password (masked in the log, printed in the job summary)
# is what actually gates access.
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
VNC_DISPLAY=${VNC_DISPLAY:-1}
NOVNC_PORT=${NOVNC_PORT:-6080}
VNC_PORT=$((5900 + VNC_DISPLAY))
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT" || echo "$1=$2"; return 0; }

WEBROOT=/usr/share/novnc
[ -d "$WEBROOT" ] || WEBROOT=/usr/share/webapps/novnc
[ -d "$WEBROOT" ] || { echo "::error::noVNC web root not found."; exit 1; }

# Land people straight on the console instead of the launcher page.
if [ ! -e "$WEBROOT/index.html.orig" ] && [ -f "$WEBROOT/vnc.html" ]; then
  sudo cp -n "$WEBROOT/index.html" "$WEBROOT/index.html.orig" 2>/dev/null || true
  sudo cp "$WEBROOT/vnc.html" "$WEBROOT/index.html"
fi

echo "==> websockify $NOVNC_PORT -> 127.0.0.1:$VNC_PORT"
nohup websockify --web="$WEBROOT" "$NOVNC_PORT" "127.0.0.1:${VNC_PORT}" \
  > "$VM_DIR/logs/websockify.log" 2>&1 &
tcp_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0 || return 1; }
for _ in $(seq 1 30); do tcp_open "$NOVNC_PORT" && break; sleep 1; done
tcp_open "$NOVNC_PORT" || { echo "::error::websockify failed."; cat "$VM_DIR/logs/websockify.log"; exit 1; }
curl -fsS -o /dev/null -w "    local noVNC HTTP %{http_code}\n" "http://127.0.0.1:${NOVNC_PORT}/" || true

echo "==> cloudflared quick tunnel"
TLOG="$VM_DIR/logs/cloudflared.log"
: > "$TLOG"
nohup cloudflared tunnel \
  --no-autoupdate \
  --url "http://127.0.0.1:${NOVNC_PORT}" \
  --loglevel info \
  >> "$TLOG" 2>&1 &

URL=""
for i in $(seq 1 60); do
  URL=$(grep -Eoh 'https://[a-z0-9-]+\.trycloudflare\.com' "$TLOG" | head -1 || true)
  [ -n "$URL" ] && break
  sleep 2
done

if [ -z "$URL" ]; then
  echo "::warning::Quick tunnel did not come up. Falling back to a local-only session."
  tail -40 "$TLOG" || true
  out url ""
  out novnc ""
  exit 0
fi

echo "    tunnel: $URL"
for _ in $(seq 1 15); do
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "$URL/" || echo 000)
  [ "$code" = "200" ] && { echo "    edge reachable (HTTP 200)"; break; }
  sleep 4
done

PW=$(cat "$VM_DIR/vnc.pass" 2>/dev/null || true)
if [ -n "$PW" ]; then
  ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$PW")
  FULL="${URL}/vnc.html?autoconnect=1&resize=scale&reconnect=1&password=${ENC}"
else
  echo "::warning::No vnc.pass file - emitting the console URL without an embedded password."
  FULL="${URL}/vnc.html?autoconnect=1&resize=scale&reconnect=1"
fi

out url "$URL"
out novnc "$FULL"
printf '%s\n' "$URL" > "$VM_DIR/tunnel.url"
echo "==> noVNC published"
