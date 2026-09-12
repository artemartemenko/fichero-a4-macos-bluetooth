#!/bin/bash
# Root LaunchDaemon: copy the CUPS spool job and send it over RFCOMM as the GUI user.
set -euo pipefail

SPOOL=/var/spool/cups/tmp/fichero
STAGE=/tmp/fichero-print
HELPER=/Library/Printers/FicheroMacOS/fichero-rfcomm

mkdir -p "$SPOOL" "$STAGE"
chmod 755 "$SPOOL" || true
chmod 1777 "$STAGE" || true

uid="$(stat -f %u /dev/console)"
shopt -s nullglob
for ready in "$SPOOL"/*.ready; do
  job="$(basename "$ready" .ready)"
  data="$SPOOL/$job.data"
  status="$SPOOL/$job.status"
  device="$SPOOL/$job.device"
  staged="$STAGE/$job.data"
  if [[ ! -f "$data" ]]; then
    echo "ERROR missing data" > "$status"
    rm -f "$ready"
    continue
  fi
  cp "$data" "$staged"
  chmod 644 "$staged"
  extra=()
  if [[ -f "$device" ]]; then
    name="$(tr -d '\n\r' < "$device")"
    if [[ -n "$name" ]]; then
      extra+=(--name "$name")
    fi
  fi
  if /bin/launchctl asuser "$uid" "$HELPER" --file "$staged" "${extra[@]+"${extra[@]}"}"; then
    printf 'OK\n' > "$status"
  else
    printf 'ERROR send failed\n' > "$status"
  fi
  rm -f "$ready" "$data" "$staged" "$device"
done
