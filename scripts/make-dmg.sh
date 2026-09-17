#!/bin/zsh
# Packages build/ClickThrough.app into a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ClickThrough.app
DMG=build/ClickThrough.dmg
[[ -d "$APP" ]] || { echo "Build the app first: scripts/build-release.sh"; exit 1; }

STAGE=$(mktemp -d)/ClickThrough
mkdir -p "$STAGE"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
if diskutil image create from --help >/dev/null 2>&1; then
  # macOS 26+ replacement for `hdiutil create`.
  diskutil image create from --format UDZO --volumeName ClickThrough "$STAGE" "$DMG" >/dev/null
else
  hdiutil create -volname ClickThrough -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi
echo "Built $DMG"
