#!/bin/zsh
# Builds Kitesail.app, then packs it into a drag-to-Applications disk image: build/Kitesail-<version>.dmg
set -euo pipefail
cd "${0:A:h}"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R build/Kitesail.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/Kitesail-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Kitesail" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Built $PWD/$DMG"
