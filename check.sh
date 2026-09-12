#!/bin/bash
# Diagnostics without sudo: drivers, PPDs, Bluetooth, CUPS queues.
set -u

ok=0
bad=0
say() { printf '%s\n' "$*"; }
pass() { say "OK   $*"; ok=$((ok + 1)); }
fail() { say "FAIL $*"; bad=$((bad + 1)); }
note() { say "INFO $*"; }

say "fichero-a4-macos-bluetooth check"
say "--------------------------------"

SRC="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname -s)" == Darwin ]]; then
  pass "macOS $(sw_vers -productVersion)"
else
  fail "not macOS ($(uname -s))"
fi

if [[ -x "$SRC/bin/fichero-serial" && -x "$SRC/bin/fichero-rfcomm" ]]; then
  pass "prebuilt helpers in bin/"
else
  fail "prebuilt helpers missing from bin/ — re-download this folder"
fi

ship=0
luck=0
if [[ -x /Library/Printers/ShippingPrinter/Filter/rastertolabel ]]; then
  pass "ShippingPrinter filter rastertolabel (6181 / A4Printer)"
  ship=1
else
  note "ShippingPrinter driver not installed (needed for 6181 / A4Printer)"
fi

if [[ -x /Library/Printers/Luckjingle/Filter/rasterDitheringAndBinary ]]; then
  pass "Luckjingle filter rasterDitheringAndBinary (5622 / 6897)"
  luck=1
else
  note "Luckjingle driver not installed (needed for 5622 / 6897)"
fi

if [[ "$ship" -eq 0 && "$luck" -eq 0 ]]; then
  fail "no official A4 driver found — download it from https://fichero.eu/, install it, then rerun"
fi

ppd6181=""
for candidate in \
  "/Library/Printers/PPDs/Contents/Resources/FICHERO 6181.ppd" \
  "/Library/Printers/ShippingPrinter/PPDs/FICHERO 6181.ppd" \
  "/Library/Printers/PPDs/Contents/Resources/FICHERO A4Printer.ppd" \
  "/Library/Printers/ShippingPrinter/PPDs/FICHERO A4Printer.ppd"
do
  if [[ -f "$candidate" ]]; then
    ppd6181="$candidate"
    break
  fi
done
if [[ -n "$ppd6181" ]]; then
  pass "PPD $ppd6181"
elif [[ "$ship" -eq 1 ]]; then
  fail "ShippingPrinter installed but Fichero 6181/A4Printer PPD missing"
fi

ppd5622=""
for candidate in \
  "/Library/Printers/PPDs/Contents/Resources/Fichero 5622.ppd" \
  "/Library/Printers/PPDs/Contents/Resources/FICHERO_5622.ppd"
do
  if [[ -f "$candidate" ]]; then
    ppd5622="$candidate"
    break
  fi
done
if [[ -n "$ppd5622" ]]; then
  pass "PPD $ppd5622"
elif [[ "$luck" -eq 1 ]]; then
  fail "Luckjingle installed but Fichero 5622 PPD missing"
fi

if system_profiler SPBluetoothDataType 2>/dev/null | grep -qiE 'FICHERO|5622|6897'; then
  pass "paired Bluetooth printer (FICHERO / 5622 / 6897)"
else
  fail "no matching printer in Bluetooth list — pair it in System Settings → Bluetooth and keep it on"
fi

if [[ -e /usr/libexec/cups/backend/fichero-serial ]]; then
  pass "CUPS backend installed (mode $(stat -f '%Lp' /usr/libexec/cups/backend/fichero-serial 2>/dev/null || echo '?'))"
else
  fail "CUPS backend not installed — run ./install.sh"
fi

copied=0
if [[ -x /usr/libexec/cups/filter/rastertofichero ]]; then
  pass "CUPS filter rastertofichero (6181)"
  copied=1
fi
if [[ -x /usr/libexec/cups/filter/rastertofichero5622 ]]; then
  pass "CUPS filter rastertofichero5622 (5622/6897)"
  copied=1
fi
if [[ "$copied" -eq 0 ]]; then
  fail "copied CUPS raster filter missing — rerun ./install.sh"
fi

if launchctl print system/com.fichero.macos-cups >/dev/null 2>&1; then
  pass "LaunchDaemon com.fichero.macos-cups loaded"
else
  fail "LaunchDaemon not loaded — rerun ./install.sh"
fi

if lpstat -v 2>/dev/null | grep -q fichero-serial; then
  while IFS= read -r line; do
    pass "queue $line"
  done < <(lpstat -v 2>/dev/null | grep fichero-serial)
else
  fail "no fichero-serial CUPS queue — rerun ./install.sh"
fi

say "--------------------------------"
say "$ok passed, $bad failed"
[[ "$bad" -eq 0 ]]
