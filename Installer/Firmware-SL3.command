#!/bin/bash
# Firmware-SL3.command — update (or restore) the firmware of a Rane SL 3 over USB.
#
# The SL 3 keeps its firmware in an EEPROM on the box. Boxes in the field run different versions
# (2.31 on some); the newest, 2.50, is in Rane's last SL 3 driver for Mac, Sl3-2.0.1f2.zip. If the
# firmware is lost (an interrupted update), the box comes up with no strings and no audio, and the
# driver reports it as needing its firmware. (A box that does not enumerate at all can only be
# recovered by writing the EEPROM chip directly: see tools/firmware/README.md.)
# The firmware is Rane's and is not part of this driver. Rane no longer hosts the zip, but the
# Internet Archive keeps a copy. This script:
#   1. finds Sl3-2.0.1f2.zip in ~/Downloads, or downloads it from the Internet Archive; the zip is
#      checked against its SHA-256, so only Rane's original file is used; failing that, it says
#      where to download it and opens the link;
#   2. extracts the firmware from Rane's package (tools/firmware/extract-sl3-firmware.py),
#   3. installs it where sl3flash looks for it (/Library/Audio/Plug-Ins/HAL/SL3Device.firmware),
#   4. checks the attached box with sl3flash and, if its EEPROM does not already hold this
#      firmware, asks before writing it. sl3flash saves the EEPROM first, and never writes older
#      firmware than the box runs.
# Nothing else from the download is installed or kept, and a zip found in ~/Downloads is left
# untouched. Desinstalar-Rane-SL3.command removes the installed firmware with the driver.
#
# It needs the SL 3 audio driver installed (Instalar-Rane-SL3.command). It runs from the installer
# folder or a checkout of this repository (tools from tools/firmware), or from the control panel
# app, which carries it with those tools ("Update Firmware…"). It uses the sl3flash next to the
# repository (`make flash`) if there is one, else the one the driver package installs.
set -e
# Rane's zip as the Internet Archive captured it in 2017 ("id_": the file exactly as served).
RANE_URL="https://web.archive.org/web/20170721213635id_/http://dj.rane.com/files/product-downloads/Sl3-2.0.1f2.zip"
RANE_SHA="e6558b7d8c95148a9629a0c2a70dfb8e4dd0351fb03c43b158304a08f1617264"
DL="$HOME/Downloads"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# The tools: beside this script in the control panel app, else in the repository.
if [ -f "$HERE/extract-sl3-firmware.py" ]; then FW="$HERE"; else FW="$ROOT/tools/firmware"; fi
EXTRACT="$FW/extract-sl3-firmware.py"
INSTALL="$FW/sl3-firmware-install.sh"
FLASH="$ROOT/sl3flash"
[ -x "$FLASH" ] || FLASH=/usr/local/bin/sl3flash
DRIVER="/Library/Audio/Plug-Ins/HAL/SL3Device.driver"

command -v python3 >/dev/null || { echo "python3 is required (install the Xcode Command Line Tools)."; exit 1; }
[ -d "$DRIVER" ] || { echo "The SL 3 audio driver is not installed; run Instalar-Rane-SL3.command first."; exit 1; }

# Everything unpacked or extracted goes in WORK, which is deleted on exit; only the download
# itself is left in ~/Downloads.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl3fw.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Rane's 2.0.1f2 zip (firmware 2.50): a copy in ~/Downloads (a browser may have added "(1)" to its
# name), else a fresh download. Only a zip with the original's SHA-256 is used.
rane_ok() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$RANE_SHA" ]; }
ZIP=""
while IFS= read -r z; do
    if rane_ok "$z"; then ZIP="$z"; break; fi
    echo "Ignoring $(basename "$z"): it is not Rane's original file."
done < <(find "$DL" -maxdepth 1 -iname "Sl3-2.0.1f2*.zip" 2>/dev/null)
if [ -z "$ZIP" ]; then
    echo "Downloading Rane's SL 3 driver 2.0.1f2 (firmware 2.50) from the Internet Archive ..."
    if curl -fsSL --max-time 120 -o "$WORK/Sl3-2.0.1f2.zip" "$RANE_URL" && rane_ok "$WORK/Sl3-2.0.1f2.zip"; then
        ZIP="$WORK/Sl3-2.0.1f2.zip"
    else
        # The Internet Archive refuses some addresses (VPNs, rate limits): a browser usually gets it.
        echo "The download failed or was not Rane's original file."
        echo
        echo "Download Rane's Sl3-2.0.1f2.zip into your Downloads folder, then run this again:"
        echo "    $RANE_URL"
        open "$RANE_URL" 2>/dev/null || true
        exit 1
    fi
fi
echo "Using $(basename "$ZIP")"
unzip -q -o "$ZIP" -d "$WORK/rane"
PKG="$WORK/rane/Sl3.pkg"
[ -f "$PKG" ] || { echo "The zip has no Sl3.pkg."; exit 1; }

echo "Extracting firmware from $(basename "$PKG") ..."
python3 "$EXTRACT" "$PKG" "$WORK/out"
BOOT="$WORK/out/sl3_bootstrap_firmware.bin"
FINAL="$WORK/out/sl3_final_firmware.bin"
[ -f "$BOOT" ] && [ -f "$FINAL" ] || { echo "extraction did not produce the expected firmware images."; exit 1; }

echo
echo "Installing the firmware next to the driver (administrator password needed) ..."
sudo "$INSTALL" "$BOOT" "$FINAL"

echo
if [ ! -x "$FLASH" ]; then
    echo "sl3flash, which writes the firmware over USB, is missing: install the driver package, or"
    echo "build it with 'make flash', and run this again."
    exit 0
fi
echo "Checking the SL 3 ..."
rc=0; "$FLASH" --dry-run || rc=$?
case $rc in
    0)  ;;   # already holds this firmware, or runs newer
    3)  echo
        echo "Stop any audio on the SL 3 and quit Serato and sl3panel before continuing. The SL 3"
        echo "Control Panel can stay open; change nothing in it until this has finished."
        read -r -p "Write the firmware to the SL 3 now? [y/N] " answer
        if [[ "$answer" =~ ^[Yy] ]]; then "$FLASH"; else echo "Nothing written."; fi ;;
    *)  echo "sl3flash could not check the box (see above); connect it and run this again."; exit 1 ;;
esac
echo "Done."
