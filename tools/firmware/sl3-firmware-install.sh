#!/bin/bash
# Install SL 3 firmware images into the default directory sl3flash reads them from, so the
# over-USB loader can be run later without pointing it at the images.
#
# The images go to /Library/Audio/Plug-Ins/HAL/SL3Device.firmware, next to the HAL driver:
# a plain folder that coreaudiod ignores and that survives reinstalling the driver. The
# driver itself never reads it — it only reports a box with no firmware; loading firmware
# is done by sl3flash (`sl3flash --firmware DIR` reads from elsewhere).
#
# The images are taken from your own copy of an official Rane / Serato driver (see
# tools/firmware/extract-sl3-firmware.py); they are not distributed with this project.
#
#   sudo tools/firmware/sl3-firmware-install.sh IMAGE.bin [IMAGE2.bin ...]
set -e
FW=/Library/Audio/Plug-Ins/HAL/SL3Device.firmware
[ $# -ge 1 ] || { echo "usage: sudo $0 IMAGE.bin [IMAGE2.bin ...]"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
mkdir -p "$FW"
for f in "$@"; do cp "$f" "$FW/"; done
chown -R root:wheel "$FW"
chmod 755 "$FW"; chmod 644 "$FW"/*
xattr -cr "$FW"
echo "installed in $FW: $(ls "$FW" | tr '\n' ' ')"
