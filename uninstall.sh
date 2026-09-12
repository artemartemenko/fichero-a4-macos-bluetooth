#!/bin/bash
# Remove the CUPS queues and helpers. Leaves official vendor drivers in place.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DST="/usr/libexec/cups/backend/fichero-serial"
CUPS_FILTERS=(
  /usr/libexec/cups/filter/rastertofichero
  /usr/libexec/cups/filter/rastertofichero5622
)
RFCOMM_DST="/Library/Printers/FicheroMacOS/fichero-rfcomm"
PLIST_DST="/Library/LaunchDaemons/com.fichero.macos-cups.plist"
SPOOL="/var/spool/cups/tmp/fichero"
AS_ROOT=0
QUEUE=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --as-root) AS_ROOT=1 ;;
    --queue)
      QUEUE="${2:-}"
      [[ -n "$QUEUE" ]] || die "--queue needs a name"
      shift
      ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [--queue NAME]"
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

list_queues() {
  lpstat -v 2>/dev/null | awk -F'[ :]' '/fichero-serial:/ { print $3 }'
}

remove_all() {
  local q f
  if [[ -n "$QUEUE" ]]; then
    echo "Removing queue $QUEUE"
    lpadmin -x "$QUEUE" || true
  else
    while IFS= read -r q; do
      [[ -n "$q" ]] || continue
      echo "Removing queue $q"
      lpadmin -x "$q" || true
    done < <(list_queues)
  fi
  uid="$(stat -f %u /dev/console 2>/dev/null || true)"
  launchctl bootout system "$PLIST_DST" 2>/dev/null || true
  if [[ -n "$uid" ]]; then
    launchctl bootout "gui/$uid" /Library/LaunchAgents/com.fichero.macos-cups.plist 2>/dev/null || true
  fi
  rm -f "$PLIST_DST" /Library/LaunchAgents/com.fichero.macos-cups.plist "$RFCOMM_DST" /Library/Printers/FicheroMacOS/fichero-drain.sh
  rm -rf "$SPOOL"
  if [[ -e "$BACKEND_DST" ]]; then
    echo "Removing backend $BACKEND_DST"
    rm -f "$BACKEND_DST"
  fi
  for f in "${CUPS_FILTERS[@]}"; do
    if [[ -e "$f" ]]; then
      echo "Removing filter $f"
      rm -f "$f"
    fi
  done
  launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
  echo "Official ShippingPrinter / Luckjingle drivers were left in place."
}

if [[ "$AS_ROOT" -eq 0 && "$(id -u)" -ne 0 ]]; then
  echo "Requesting administrator privileges..."
  extra="--as-root"
  [[ -n "$QUEUE" ]] && extra="$extra --queue $(printf '%q' "$QUEUE")"
  osascript -e "do shell script \"bash \" & quoted form of \"$SRC/uninstall.sh\" & \" $extra\" with administrator privileges"
  exit 0
fi

remove_all
