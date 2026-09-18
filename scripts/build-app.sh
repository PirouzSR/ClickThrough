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

# Signing identity. An ad-hoc signature bakes the binary's own hash into the
# app's designated requirement, so every rebuild looks like a different app to
# macOS and the Accessibility permission has to be granted all over again. A
# real signing identity produces a requirement based on the certificate, which
# survives rebuilds - see scripts/setup-signing.sh.
#
# Distribution builds stay ad-hoc on purpose: a certificate-based requirement
# embeds the signer's name in the app, which has no place in a published binary.
IDENTITY="-"
if [[ "${DISTRIBUTION:-0}" != "1" ]]; then
  if [[ -n "${CLICKTHROUGH_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CLICKTHROUGH_SIGN_IDENTITY"
  elif [[ -f .signing-identity ]]; then
    IDENTITY="$(head -1 .signing-identity)"
  fi
fi

codesign --force --sign "$IDENTITY" \
         --entitlements ClickThrough/ClickThrough.entitlements --options runtime "$APP"

if [[ "$IDENTITY" == "-" ]]; then
  echo "Signed ad-hoc: the Accessibility permission must be re-granted after each rebuild."
else
  echo "Signed with: $IDENTITY"
fi

echo "Built $APP"
