#!/bin/zsh
# Builds Kitesail.app without Xcode: SwiftPM release build + hand-made bundle + ad-hoc signature.
set -euo pipefail
cd "${0:A:h}"
swift build -c release
APP=build/Kitesail.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Kitesail "$APP/Contents/MacOS/Kitesail"
cp Info.plist "$APP/Contents/Info.plist"
# App icon: render once from tools/make-icon.swift, then pack every size into an .icns.
if [[ ! -f build/AppIcon.icns ]]; then
  [[ -f tools/icon-1024.png ]] || swift tools/make-icon.swift tools/icon-1024.png
  ICONSET=build/AppIcon.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s tools/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) tools/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
