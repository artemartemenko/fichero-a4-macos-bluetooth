#!/bin/bash
# Double-click in Finder to remove Bluetooth printing.
cd "$(dirname "$0")" || exit 1

# Downloaded ZIPs can lose the executable bit.
chmod +x uninstall.sh 2>/dev/null

echo "Fichero A4 Bluetooth for macOS"
echo "------------------------------"
echo "This removes the Bluetooth helper. The official driver stays installed."
echo "macOS will ask for an administrator password."
echo

./uninstall.sh
status=$?

echo
if [[ "$status" -eq 0 ]]; then
  echo "Done. The Bluetooth helper is removed."
else
  echo "Uninstall did not finish. Read the messages above."
fi
echo
read -r -p "Press Return to close this window."
exit "$status"
