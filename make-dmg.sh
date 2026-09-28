#!/bin/zsh
# Builds Kitesail.app, then a styled drag-to-Applications disk image:
#   build/Kitesail-<version>.dmg  (versioned, for the release)
#   build/Kitesail.dmg            (stable name, used by install.sh via releases/latest/download)
set -euo pipefail
cd "${0:A:h}"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

# One-time tooling: dmgbuild writes the Finder layout directly (no Finder scripting or permissions).
[[ -x tools/.venv/bin/dmgbuild ]] || { python3 -m venv tools/.venv && tools/.venv/bin/pip install -q dmgbuild; }
if [[ ! -f build/dmg-bg.tiff ]]; then
  swift tools/make-dmg-background.swift build/dmg-bg.png build/dmg-bg@2x.png
  tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out build/dmg-bg.tiff
fi

DMG="build/Kitesail-$VERSION.dmg"
rm -f "$DMG"
tools/.venv/bin/dmgbuild -s tools/dmg-settings.py -D app=build/Kitesail.app "Kitesail" "$DMG"
cp "$DMG" build/Kitesail.dmg
echo "Built $PWD/$DMG"
