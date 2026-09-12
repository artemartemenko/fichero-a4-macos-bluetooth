# Print from a Mac over Bluetooth

Fichero A4 printers work over USB with the official driver. Over Bluetooth
they usually never show up in **File → Print**.

This installer adds them there. After that you print from any app like
with a normal Mac printer.

Not made by, affiliated with, or endorsed by Fichero or the makers of the
official drivers.

Works with:

- FICHERO 6181 / A4Printer — tested on macOS 15
- Fichero 5622 / 6897 — set up the same way, not yet tested on that hardware

## Before you start

1. Download and install the official macOS driver for your printer from
   [fichero.eu](https://fichero.eu/).
2. Turn the printer on. Unplug USB so the Mac uses Bluetooth.
3. In **System Settings → Bluetooth**, pair the printer
   (`FICHERO_6181`, `FICHERO_5622`, `6897`, …).
   You do not need to add it in Printers & Scanners.

## Install

Double-click **Install.command**. A Terminal window opens and macOS asks
for an administrator password.

If it says the file cannot be opened, right-click **Install.command** and
choose Open.

Then print from any app: **File → Print**, pick the Fichero printer.
Paper size is A4.

To make it the default printer, run this in Terminal:

```bash
./install.sh --make-default
```

## If it does not print

The printer is probably off, too far, or still connected to a phone. Keep
it paired with the Mac and close the Fichero phone app.

## Uninstall

Double-click **Uninstall.command**. That removes this Bluetooth helper.
The official Fichero driver stays installed.

## Good to know

The two small helpers in `bin/` come prebuilt, so you do not need
developer tools. Their source is in `backend/`; run `./compile.sh` to
build them yourself.

Nothing is sent anywhere. The installer only adds a printer queue on this
Mac and passes your pages to the printer over Bluetooth.

## License

This project's own code is under the [PolyForm Noncommercial
License 1.0.0](LICENSE).

- **Non-commercial use** (home, hobby, school, charity): free, no
  permission needed.
- **Commercial use**: open an issue to ask for permission.

The official Fichero, ShippingPrinter, and Luckjingle drivers are not
covered by that license. They belong to their publishers. Download them
from [fichero.eu](https://fichero.eu/).
