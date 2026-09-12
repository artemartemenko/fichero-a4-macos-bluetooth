#!/bin/bash
# Install Fichero A4 as a macOS system printer (CUPS + RFCOMM helper).
# Supports ShippingPrinter (6181 / A4Printer) and Luckjingle (5622 / 6897).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BACKEND_NAME="fichero-serial"
BACKEND_C="$SRC/backend/$BACKEND_NAME.c"
BACKEND_BIN="$SRC/bin/$BACKEND_NAME"
BACKEND_DST="/usr/libexec/cups/backend/$BACKEND_NAME"
RFCOMM_M="$SRC/backend/fichero-rfcomm.m"
RFCOMM_BIN="$SRC/bin/fichero-rfcomm"
RFCOMM_DST="/Library/Printers/FicheroMacOS/fichero-rfcomm"
DRAIN_DST="/Library/Printers/FicheroMacOS/fichero-drain.sh"
SPOOL="/var/spool/cups/tmp/fichero"
PLIST_SRC="$SRC/launchd/com.fichero.macos-cups.plist"
PLIST_DST="/Library/LaunchDaemons/com.fichero.macos-cups.plist"
SHIP_FILTER="/Library/Printers/ShippingPrinter/Filter/rastertolabel"
SHIP_CUPS_FILTER="/usr/libexec/cups/filter/rastertofichero"
LUCK_FILTER="/Library/Printers/Luckjingle/Filter/rasterDitheringAndBinary"
LUCK_CUPS_FILTER="/usr/libexec/cups/filter/rastertofichero5622"
DRIVER_URL="https://fichero.eu/"

MAKE_DEFAULT=0
AS_ROOT=0
REBUILD=0
ONLY_QUEUE=""
BIN=""
HELPER=""
CONSOLE_UID=""
DEVICES=""
INSTALLED_QUEUES=()

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [--make-default] [--queue NAME] [--rebuild]

Installs CUPS queues for paired Fichero A4 Bluetooth printers.
Uses the prebuilt helpers in bin/. Pass --rebuild to compile them
again (needs clang).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --as-root) AS_ROOT=1 ;;
    --rebuild) REBUILD=1 ;;
    --make-default) MAKE_DEFAULT=1 ;;
    --queue)
      ONLY_QUEUE="${2:-}"
      [[ -n "$ONLY_QUEUE" ]] || die "--queue needs a name"
      shift
      ;;
    --bin)
      BIN="${2:-}"
      [[ -n "$BIN" ]] || die "--bin needs a path"
      shift
      ;;
    --helper)
      HELPER="${2:-}"
      [[ -n "$HELPER" ]] || die "--helper needs a path"
      shift
      ;;
    --uid)
      CONSOLE_UID="${2:-}"
      [[ -n "$CONSOLE_UID" ]] || die "--uid needs a value"
      shift
      ;;
    --devices)
      DEVICES="${2:-}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

first_file() {
  local path
  for path in "$@"; do
    if [[ -f "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

find_ship_ppd() {
  local hint="${1:-}"
  if echo "$hint" | grep -qi 'A4Printer\|A4 Printer'; then
    first_file \
      "/Library/Printers/PPDs/Contents/Resources/FICHERO A4Printer.ppd" \
      "/Library/Printers/ShippingPrinter/PPDs/FICHERO A4Printer.ppd" \
      && return 0
  fi
  first_file \
    "/Library/Printers/PPDs/Contents/Resources/FICHERO 6181.ppd" \
    "/Library/Printers/ShippingPrinter/PPDs/FICHERO 6181.ppd" \
    "/Library/Printers/PPDs/Contents/Resources/FICHERO A4Printer.ppd" \
    "/Library/Printers/ShippingPrinter/PPDs/FICHERO A4Printer.ppd"
}

find_luck_ppd() {
  local hint="${1:-}"
  if echo "$hint" | grep -q '_'; then
    first_file \
      "/Library/Printers/PPDs/Contents/Resources/FICHERO_5622.ppd" \
      "/Library/Printers/PPDs/Contents/Resources/Fichero 5622.ppd" \
      && return 0
  fi
  first_file \
    "/Library/Printers/PPDs/Contents/Resources/Fichero 5622.ppd" \
    "/Library/Printers/PPDs/Contents/Resources/FICHERO_5622.ppd"
}

paired_bt_names() {
  system_profiler SPBluetoothDataType 2>/dev/null \
    | sed -nE 's/^[[:space:]]+([^:]{2,80}):[[:space:]]*$/\1/p' \
    | grep -Ei 'fichero|5622|6897|6181' || true
}

queue_name_from_bt() {
  local q
  q="$(echo "$1" | tr ' ' '_' | tr -cd 'A-Za-z0-9_-')"
  if echo "$q" | grep -qi '^FICHERO'; then
    printf '%s\n' "$q"
  else
    printf 'FICHERO_%s\n' "$q"
  fi
}

is_ship_name() {
  echo "$1" | grep -Ei '6181|A4Printer|A4.?Printer' >/dev/null
}

is_luck_name() {
  echo "$1" | grep -Ei '5622|6897' >/dev/null
}

rewrite_ppd() {
  local src="$1" dest="$2" new_filter="$3"
  /usr/bin/sed -E \
    "s|(\\*cupsFilter:[[:space:]]*\"application/vnd.cups-raster 0 )[^\"]+\"|\\1${new_filter}\"|" \
    "$src" > "$dest"
  grep -q "$new_filter" "$dest" || die "Failed to rewrite PPD cupsFilter in $src"
}

copy_filter() {
  local src="$1" dest="$2"
  /bin/cp -f "$src" "$dest"
  /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  /bin/chmod 755 "$dest"
}

install_queue() {
  local queue="$1" bt_name="$2" ppd="$3" cups_filter="$4" title="$5"
  local ppd_work uri
  [[ -f "$ppd" ]] || die "PPD not found: $ppd"
  ppd_work="$(mktemp /tmp/fichero-XXXXXX.ppd)"
  rewrite_ppd "$ppd" "$ppd_work" "$cups_filter"
  uri="${BACKEND_NAME}:${bt_name}"
  echo "Creating queue $queue → $uri ($title)"
  cancel -a "$queue" 2>/dev/null || true
  lpadmin -p "$queue" -v "$uri" -P "$ppd_work" -E \
    -D "$title" -L "Bluetooth" \
    -o printer-is-shared=false \
    -o printer-error-policy=retry-job
  rm -f "$ppd_work"
  cupsenable "$queue" || true
  cupsaccept "$queue" || true
  INSTALLED_QUEUES+=("$queue")
}

preflight() {
  [[ "$(uname -s)" == Darwin ]] || die "This installer is macOS-only."
  [[ -f "$BACKEND_C" ]] || die "Backend source missing: $BACKEND_C"
  [[ -f "$RFCOMM_M" ]] || die "RFCOMM helper source missing: $RFCOMM_M"
  if [[ -z "$CONSOLE_UID" ]]; then
    CONSOLE_UID="$(stat -f %u /dev/console)"
  fi
  if [[ "$AS_ROOT" -eq 0 ]]; then
    if [[ -z "$DEVICES" ]]; then
      DEVICES="$(paired_bt_names | paste -sd, - || true)"
    fi
    if [[ ! -x "$SHIP_FILTER" && ! -x "$LUCK_FILTER" ]]; then
      die "No official Fichero A4 driver found. Download it from $DRIVER_URL, install it, then rerun."
    fi
    if [[ "$REBUILD" -eq 1 ]]; then
      bash "$SRC/compile.sh"
      BIN="$BACKEND_BIN"
      HELPER="$RFCOMM_BIN"
    fi
    if [[ -z "$BIN" || -z "$HELPER" ]]; then
      BIN="$BACKEND_BIN"
      HELPER="$RFCOMM_BIN"
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$BIN" "$HELPER" 2>/dev/null || true
  fi
  [[ -x "$BIN" ]] || die "Prebuilt backend missing: $BIN. Re-download this folder."
  [[ -x "$HELPER" ]] || die "Prebuilt helper missing: $HELPER. Re-download this folder."
}

elevate() {
  echo "Requesting administrator privileges..."
  local extra=""
  if [[ "$MAKE_DEFAULT" -eq 1 ]]; then
    extra+=' & " --make-default"'
  fi
  if [[ -n "$ONLY_QUEUE" ]]; then
    extra+=' & " --queue " & quoted form of "'"$ONLY_QUEUE"'"'
  fi
  if [[ -n "$DEVICES" ]]; then
    extra+=' & " --devices " & quoted form of "'"$DEVICES"'"'
  fi
  osascript <<APPLESCRIPT
do shell script "bash " & quoted form of "$SRC/install.sh" & " --as-root --bin " & quoted form of "$BIN" & " --helper " & quoted form of "$HELPER" & " --uid " & quoted form of "$CONSOLE_UID"$extra with administrator privileges
APPLESCRIPT
}

split_devices() {
  local IFS=','
  # shellcheck disable=SC2206
  DEV_LIST=(${DEVICES})
}

install_shared() {
  /bin/mkdir -p /Library/Printers/FicheroMacOS "$SPOOL"
  /bin/chmod 755 /Library/Printers/FicheroMacOS
  /bin/chmod 755 "$SPOOL"

  /usr/bin/install -m 700 "$BIN" "$BACKEND_DST"
  /usr/bin/install -m 755 "$HELPER" "$RFCOMM_DST"
  /usr/bin/xattr -dr com.apple.quarantine "$BACKEND_DST" "$RFCOMM_DST" 2>/dev/null || true
  /usr/bin/install -m 755 "$SRC/backend/fichero-drain.sh" "$DRAIN_DST"
  /bin/cp -f "$PLIST_SRC" "$PLIST_DST"
  /bin/chmod 644 "$PLIST_DST"

  if [[ -n "$CONSOLE_UID" ]]; then
    launchctl bootout system "$PLIST_DST" 2>/dev/null || true
    launchctl bootout "gui/$CONSOLE_UID" "$PLIST_DST" 2>/dev/null || true
    rm -f /Library/LaunchAgents/com.fichero.macos-cups.plist
    launchctl bootstrap system "$PLIST_DST"
    echo "LaunchDaemon loaded"
  fi

  launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
  sleep 1
}

install_shipping_queues() {
  local name q ppd created=0
  [[ -x "$SHIP_FILTER" ]] || return 0
  copy_filter "$SHIP_FILTER" "$SHIP_CUPS_FILTER"
  for name in "${DEV_LIST[@]+"${DEV_LIST[@]}"}"; do
    [[ -n "$name" ]] || continue
    is_ship_name "$name" || continue
    q="$(queue_name_from_bt "$name")"
    [[ -n "$ONLY_QUEUE" && "$q" != "$ONLY_QUEUE" ]] && continue
    ppd="$(find_ship_ppd "$name")" || die "ShippingPrinter PPD not found for $name"
    install_queue "$q" "$name" "$ppd" "rastertofichero" "$name"
    created=1
  done
  if [[ "$created" -eq 0 && -z "$ONLY_QUEUE" ]]; then
    ppd="$(find_ship_ppd "6181")" || die "FICHERO 6181 PPD not found. Download the official driver from $DRIVER_URL, install it, then rerun."
    install_queue "FICHERO_6181" "FICHERO_6181" "$ppd" "rastertofichero" "FICHERO 6181"
  fi
}

install_luck_queues() {
  local name q ppd created=0
  [[ -x "$LUCK_FILTER" ]] || return 0
  copy_filter "$LUCK_FILTER" "$LUCK_CUPS_FILTER"
  for name in "${DEV_LIST[@]+"${DEV_LIST[@]}"}"; do
    [[ -n "$name" ]] || continue
    is_luck_name "$name" || continue
    q="$(queue_name_from_bt "$name")"
    [[ -n "$ONLY_QUEUE" && "$q" != "$ONLY_QUEUE" ]] && continue
    ppd="$(find_luck_ppd "$name")" || die "Luckjingle PPD not found for $name"
    install_queue "$q" "$name" "$ppd" "rastertofichero5622" "$name"
    created=1
  done
  if [[ "$created" -eq 0 && -z "$ONLY_QUEUE" ]]; then
    ppd="$(find_luck_ppd "FICHERO_5622")" || die "Fichero 5622 PPD not found after installing the Luckjingle driver"
    install_queue "FICHERO_5622" "FICHERO_5622" "$ppd" "rastertofichero5622" "Fichero 5622"
  fi
}

install_backend_and_queue() {
  if [[ ! -x "$SHIP_FILTER" && ! -x "$LUCK_FILTER" ]]; then
    die "No official Fichero A4 driver found. Download it from $DRIVER_URL, install it, then rerun."
  fi
  split_devices
  install_shared
  install_shipping_queues
  install_luck_queues
  if [[ ${#INSTALLED_QUEUES[@]} -eq 0 ]]; then
    die "No printer queues were created"
  fi
  if [[ "$MAKE_DEFAULT" -eq 1 ]]; then
    lpadmin -d "${INSTALLED_QUEUES[0]}"
  fi
}

print_status() {
  local q
  echo
  echo "Printer queues:"
  lpstat -v 2>/dev/null | grep fichero-serial || true
  echo
  echo "Turn the printer on and pair it in System Settings → Bluetooth if needed."
  echo "Then print from any app:"
  lpstat -v 2>/dev/null | awk -F'[ :]' '/fichero-serial:/ { print "  File → Print → " $3 }'
}

main() {
  preflight
  if [[ "$AS_ROOT" -eq 1 ]]; then
    install_backend_and_queue
    return
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    elevate
  else
    install_backend_and_queue
  fi
  print_status
}

main
