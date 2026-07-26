#!/usr/bin/env bash
# Print + summarise how to reach the VM. Runs after boot verification so the
# details land in the summary next to a proven-good machine.
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
PW=$(cat "$VM_DIR/vnc.pass")
URL=${TUNNEL_URL:-}
MIN=${SESSION_MINUTES:-330}
MODE=${ATLAS_MODE:-stage}
END=$(date -u -d "+${MIN} minutes" '+%Y-%m-%d %H:%M UTC')

cat <<BANNER

================================================================
  WINDOWS 11 LAB IS LIVE
================================================================
  Console : ${URL:-<tunnel unavailable>}/vnc.html
  VNC pw  : (masked in log - see the job summary)
  Windows : atlas / Atlas!2026   (local administrator)
  Open    : ${MIN} minutes, until ${END}
  Atlas   : mode=${MODE}
================================================================

BANNER

{
  echo "## Live session"
  echo ""
  if [ -n "$URL" ]; then
    echo "**noVNC console:** ${URL}/vnc.html?autoconnect=1&resize=scale"
    echo ""
    echo "> Tokenless Cloudflare quick tunnel - no account, no secret, no port forward."
  else
    echo "> The quick tunnel failed to establish; the VM is running but only reachable"
    echo "> from inside the runner. Re-run the workflow if you need remote access."
  fi
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| VNC password | \`${PW}\` |"
  echo "| Windows user | \`atlas\` |"
  echo "| Windows password | \`Atlas!2026\` |"
  echo "| Session ends | ${END} |"
  echo "| Atlas mode | \`${MODE}\` |"
  echo "| Atlas payload | \`C:\\Atlas\\payload\` |"
  echo "| Guest logs | \`C:\\Atlas\\logs\` |"
  echo ""
  echo "### To apply the Atlas Playbook"
  echo ""
  echo "1. Open the console link above."
  echo "2. Windows Security -> Virus & threat protection -> Manage settings:"
  echo "   turn **Real-time protection** and **Tamper protection** OFF."
  echo "   (Tamper Protection cannot be scripted - Microsoft blocks it by design.)"
  echo "3. Double-click **Launch-Atlas.cmd** on the desktop."
  echo "4. Drag the \`.apbx\` playbook onto the AME Wizard window and follow it."
  echo ""
  echo "A qcow2 snapshot named \`pre-atlas\` was taken before this point."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
