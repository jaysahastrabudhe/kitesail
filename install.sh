#!/bin/sh
# Kitesail one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/jaysahastrabudhe/kitesail/main/install.sh | sh
#
# Downloads the latest release DMG, copies Kitesail into /Applications (replacing an older copy) and opens it.
# Files fetched with curl aren't quarantined, so macOS doesn't show the "unidentified developer" prompt.
set -eu

URL="${KITESAIL_URL:-https://github.com/jaysahastrabudhe/kitesail/releases/latest/download/Kitesail.dmg}"
DEST="${KITESAIL_DEST:-/Applications/Kitesail.app}"
DRY="${KITESAIL_TEST:-}"   # set in tests: don't touch a running copy, don't launch

[ "$(uname -s)" = "Darwin" ] || { echo "Kitesail is a Mac app."; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Kitesail needs an Apple Silicon Mac."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || { echo "Kitesail needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."; exit 1; }

tmp=$(mktemp -d)
mnt="$tmp/mnt"
cleanup() { hdiutil detach "$mnt" -quiet 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

echo "Downloading Kitesail..."
curl -fL --progress-bar -o "$tmp/Kitesail.dmg" "$URL"

mkdir "$mnt"
hdiutil attach "$tmp/Kitesail.dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet

if [ -z "$DRY" ] && pgrep -x Kitesail >/dev/null 2>&1; then
  echo "Quitting the running copy..."
  osascript -e 'quit app "Kitesail"' >/dev/null 2>&1 || true
  sleep 2
fi

SUDO=""
[ -w "$(dirname "$DEST")" ] || { echo "Admin rights needed to write to /Applications."; SUDO="sudo"; }
$SUDO rm -rf "$DEST"
$SUDO ditto "$mnt/Kitesail.app" "$DEST"

echo "Installed to $DEST"
echo "Tip: after an update, macOS may ask you to re-allow Full Disk Access and Accessibility."
[ -n "$DRY" ] || open "$DEST"
