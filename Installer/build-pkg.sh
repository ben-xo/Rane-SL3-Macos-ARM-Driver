#!/bin/bash
# build-pkg.sh [version] — build the installer package and the download zip from this checkout:
#   build/RaneSL3-macOS-Universal.pkg            what Instalar-Rane-SL3.command installs
#   build/Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip  the Installer folder and tools/firmware, as published
# Nothing committed is touched: copy the results over Installer/RaneSL3-macOS-Universal.pkg and
# Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip to publish them. Run by `make package` (VERSION=x.y.z).
#
# The package installs, all ad-hoc signed:
#   /Library/Audio/Plug-Ins/HAL/SL3Device.driver   the CoreAudio driver (plugin/)
#   /Library/Frameworks/Sl3Api.framework           the Sl3Api replacement for Serato DJ Pro 2.5.5
#   /Library/Extensions/Sl3Driver.10.9.kext              Info.plist only: no code, nothing loads
#   /Applications/SL 3 Control Panel.app           tools/controlpanel/
#   /usr/local/bin/sl3panel, sl3dump, sl3flash
# with Installer/package/scripts as its pre- and post-install scripts.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEFAULT_VER=$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo "1.4.0")
VERSION=${1:-$DEFAULT_VER}
PKGSRC="$ROOT/Installer/package"
OUT="$ROOT/build"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/root"

# Build everything from source (release driver, no debug code).
cd "$ROOT"
make plugin api panel dump flash
tools/controlpanel/build-app.sh "$WORK"

# The driver bundle.
DRV="$STAGE/Library/Audio/Plug-Ins/HAL/SL3Device.driver"
mkdir -p "$DRV/Contents/MacOS"
cp -X plugin/Device-Info.plist "$DRV/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$DRV/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$DRV/Contents/Info.plist"
cp -X SL3Device "$DRV/Contents/MacOS/SL3Device"
codesign --force --sign - "$DRV"

# Sl3Api.framework, laid out as Rane's (Serato loads .../Sl3Api.framework/Sl3Api).
FW="$STAGE/Library/Frameworks/Sl3Api.framework"
mkdir -p "$FW/Versions/A/Resources"
cp -X Sl3Api "$FW/Versions/A/Sl3Api"
cp -X "$PKGSRC/metadata/Sl3Api-Info.plist" "$FW/Versions/A/Resources/Info.plist"
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/Sl3Api "$FW/Sl3Api"
ln -s Versions/Current/Resources "$FW/Resources"
codesign --force --sign - "$FW"

# The kext's Info.plist (clients look for an installed SL 3 kext; there is no code in it).
mkdir -p "$STAGE/Library/Extensions/Sl3Driver.10.9.kext/Contents"
cp -X "$PKGSRC/metadata/Sl3Driver-kext-Info.plist" "$STAGE/Library/Extensions/Sl3Driver.10.9.kext/Contents/Info.plist"

# The control panel app and the command-line tools.
mkdir -p "$STAGE/Applications" "$STAGE/usr/local/bin"
ditto --noextattr --noqtn "$WORK/SL 3 Control Panel.app" "$STAGE/Applications/SL 3 Control Panel.app"
cp -X sl3panel sl3dump sl3flash "$STAGE/usr/local/bin/"

# The component package. Bundles install where listed: not relocated to a copy found elsewhere.
pkgbuild --analyze --root "$STAGE" "$WORK/components.plist" >/dev/null
i=0
while plutil -replace "$i.BundleIsRelocatable" -bool NO "$WORK/components.plist" 2>/dev/null; do
    i=$((i + 1))
done
mkdir -p "$WORK/pkgs"
pkgbuild --root "$STAGE" --component-plist "$WORK/components.plist" --scripts "$PKGSRC/scripts" \
    --identifier com.pepelee.ranesl3.driver --version "$VERSION" --install-location / \
    "$WORK/pkgs/RaneSL3-Core.pkg"

# The product package, with the installer's pages (in English and Spanish, en.lproj and es.lproj: the
# Installer shows the Mac's language, with the version filled in) and its background drawn from the
# control panel's icon.
sed "s/@VERSION@/$VERSION/" "$PKGSRC/Distribution.xml" > "$WORK/Distribution.xml"
cp -R "$PKGSRC/resources" "$WORK/resources"
for f in "$WORK"/resources/*.lproj/*.html; do sed -i '' "s/@VERSION@/$VERSION/g" "$f"; done
swiftc -O tools/controlpanel/make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" --installer-background "$WORK/resources/background.png"
mkdir -p "$OUT"
productbuild --distribution "$WORK/Distribution.xml" --resources "$WORK/resources" \
    --package-path "$WORK/pkgs" "$OUT/RaneSL3-macOS-Universal.pkg"

# The download zip: the Installer folder's user-facing files with the new package, and tools/firmware.
Z="$WORK/zip"
mkdir -p "$Z/Installer" "$Z/tools"
cp Installer/*.command Installer/LEEME-INSTRUCCIONES.txt "$OUT/RaneSL3-macOS-Universal.pkg" "$Z/Installer/"
git ls-files -z tools/firmware | (cd "$ROOT" && xargs -0 tar cf -) | (cd "$Z" && tar xf -)
rm -f "$OUT/Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip"
(cd "$Z" && zip -qry "$OUT/Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip" Installer tools)

echo "built $OUT/RaneSL3-macOS-Universal.pkg ($VERSION) and $OUT/Rane-SL3-Installer-Mac-M1-M2-M3-M4.zip"
