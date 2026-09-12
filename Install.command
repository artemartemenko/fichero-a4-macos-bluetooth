#!/bin/bash
# Double-click in Finder to install Bluetooth printing.
cd "$(dirname "$0")" || exit 1

# Downloaded ZIPs can lose the executable bit.
chmod +x install.sh uninstall.sh check.sh compile.sh bin/* backend/fichero-drain.sh 2>/dev/null

echo "Fichero A4 Bluetooth for macOS"
echo "------------------------------"
echo "macOS will ask for an administrator password."
echo

./install.sh
status=$?

echo
if [[ "$status" -eq 0 ]]; then
  echo "Done. In any app use File → Print and pick the Fichero printer."
else
  echo "Install did not finish. Read the messages above."
fi
echo
read -r -p "Press Return to close this window."
exit "$status"
