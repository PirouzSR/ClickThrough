#!/bin/zsh
# Fallback builder used when xcodebuild is unavailable. Produces the same
# ClickThrough.app from the same sources, for the host architecture.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
SDK=${SDKROOT:-$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)}
SWIFTC=$(xcrun --find swiftc 2>/dev/null || echo /Library/Developer/CommandLineTools/usr/bin/swiftc)
ARCH=$(uname -m)
APP=build/ClickThrough.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

if [[ "$CONFIG" == "debug" ]]; then
  FLAGS=(-Onone -g -D DEBUG)
else
  FLAGS=(-O -whole-module-optimization)
fi

"$SWIFTC" -sdk "$SDK" -target "$ARCH-apple-macos13.0" -swift-version 6 \
          -module-name ClickThrough -warnings-as-errors \
          "${FLAGS[@]}" ClickThrough/*.swift \
          -o "$APP/Contents/MacOS/ClickThrough"

cp ClickThrough/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: gives the app a stable identity for the Accessibility
# permission on this machine. See README for Gatekeeper notes.
codesign --force --sign - --entitlements ClickThrough/ClickThrough.entitlements --options runtime "$APP"

echo "Built $APP"
