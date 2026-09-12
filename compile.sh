#!/bin/bash
# Rebuild the shipped helpers in bin/. Needs clang. End users do not run this.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BACKEND_C="$SRC/backend/fichero-serial.c"
BACKEND_BIN="$SRC/bin/fichero-serial"
RFCOMM_M="$SRC/backend/fichero-rfcomm.m"
RFCOMM_BIN="$SRC/bin/fichero-rfcomm"

if [[ -x /usr/bin/clang ]]; then
  CC=/usr/bin/clang
elif command -v clang >/dev/null 2>&1; then
  CC="$(command -v clang)"
else
  echo "ERROR: clang not found. Install Xcode Command Line Tools." >&2
  exit 1
fi

mkdir -p "$SRC/bin"
echo "Compiling CUPS backend..."
"$CC" -Os -arch arm64 -arch x86_64 -o "$BACKEND_BIN" "$BACKEND_C"
codesign --force --sign - "$BACKEND_BIN" >/dev/null
echo "Compiling Bluetooth RFCOMM helper..."
"$CC" -fobjc-arc -Os -arch arm64 -arch x86_64 \
  -framework Foundation -framework IOBluetooth \
  -o "$RFCOMM_BIN" "$RFCOMM_M"
codesign --force --sign - "$RFCOMM_BIN" >/dev/null
chmod 755 "$BACKEND_BIN" "$RFCOMM_BIN"
echo "Wrote $BACKEND_BIN"
echo "Wrote $RFCOMM_BIN"
file "$BACKEND_BIN" "$RFCOMM_BIN"
