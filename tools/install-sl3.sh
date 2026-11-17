#!/bin/bash
# Install a freshly built driver (SL3Device) into the installed HAL plug-in bundle and restart
# CoreAudio; with --api, also install a freshly built Sl3Api into the installed Sl3Api.framework
# (what Serato and Rane's control panel load); --restore-api puts back the framework binary that
# was there before the first --api install.
#
# Prerequisite: the driver and framework bundles must already be installed, by the release package
# (Installer/RaneSL3-macOS-Universal.pkg). This script only replaces the binaries inside them.
#
# usage: sudo tools/install-sl3.sh [--api] [driver-binary]
#        sudo tools/install-sl3.sh --restore-api
#   default driver: SL3Device built by `make plugin` in this checkout; --api: Sl3Api built by `make api`
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DRV=/Library/Audio/Plug-Ins/HAL/SL3Device.driver
FW=/Library/Frameworks/Sl3Api.framework
BACKUP=/Library/Frameworks/Sl3Api.before-install   # beside the framework, not inside it (that would break its signature)

# Write beside the old binary and rename over it: a process that has it loaded keeps its mapped
# (old) file, instead of having its code pages rewritten under it (which gets it killed: Code
# Signature Invalid). Then re-sign the bundle.
install_binary() {   # <source> <bundle> <path of the binary inside the bundle>
    cp "$1" "$2/$3.new"
    mv -f "$2/$3.new" "$2/$3"
    codesign --force --sign - "$2"
}

need_bundle() {   # <bundle>
    if [ ! -d "$1" ]; then
        echo "$1 is not installed. Install the release package first (Installer/RaneSL3-macOS-Universal.pkg);" >&2
        echo "this script only replaces the binaries inside the installed bundles." >&2
        exit 1
    fi
}

# --restore-api: the framework binary saved by the first --api install goes back.
if [ "${1:-}" = "--restore-api" ]; then
    need_bundle "$FW"
    [ -f "$BACKUP" ] || { echo "no saved framework binary at $BACKUP" >&2; exit 1; }
    install_binary "$BACKUP" "$FW" Versions/A/Sl3Api
    echo "restored Sl3Api from $BACKUP: restart Serato to load it"
    exit 0
fi

API=0
if [ "${1:-}" = "--api" ]; then API=1; shift; fi
SRC=${1:-$ROOT/SL3Device}

# --api: save the framework binary the first time (an older version of this script kept it in the
# checkout; move that one here), then install the built one.
if [ "$API" = 1 ]; then
    need_bundle "$FW"
    if [ ! -e "$BACKUP" ]; then
        if [ -f "$ROOT/Sl3Api.before-install" ]; then mv "$ROOT/Sl3Api.before-install" "$BACKUP"
        else cp "$FW/Versions/A/Sl3Api" "$BACKUP"; fi
        echo "saved the previous Sl3Api as $BACKUP (put it back with --restore-api)"
    fi
    echo "installing $ROOT/Sl3Api"
    install_binary "$ROOT/Sl3Api" "$FW" Versions/A/Sl3Api
    echo "installed Sl3Api $(shasum -a 256 "$FW/Versions/A/Sl3Api" | cut -c1-16): restart Serato to load it"
fi

# The driver, then restart CoreAudio and the processes that go stale when it restarts.
need_bundle "$DRV"
echo "installing $SRC"
install_binary "$SRC" "$DRV" Contents/MacOS/SL3Device
killall coreaudiod || true
killall -9 AirPlayXPCHelper 2>/dev/null || true   # can loop re-registering with the new coreaudiod; ignores SIGTERM
# Apps holding the old coreaudiod's device list drop the SL 3 and don't re-add it: refresh them.
sleep 2
killall ControlCenter 2>/dev/null || true
killall -9 QuickLookUIService 2>/dev/null || true   # ignores SIGTERM
echo "installed $(shasum -a 256 "$DRV/Contents/MacOS/SL3Device" | cut -c1-16) and restarted coreaudiod"
