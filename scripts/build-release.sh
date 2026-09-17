#!/bin/zsh
# Builds a release ClickThrough.app into ./build.
# Uses Xcode when it is available, and falls back to the Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

if xcodebuild -list -project ClickThrough.xcodeproj >/dev/null 2>&1; then
  echo "Building with xcodebuild…"
  xcodebuild -project ClickThrough.xcodeproj -scheme ClickThrough -configuration Release \
             -derivedDataPath build/DerivedData build
  rm -rf build/ClickThrough.app
  mkdir -p build
  cp -R build/DerivedData/Build/Products/Release/ClickThrough.app build/ClickThrough.app
  echo "Built build/ClickThrough.app"
else
  echo "xcodebuild unavailable (run: sudo xcodebuild -license accept). Using swiftc…"
  exec scripts/build-app.sh release
fi
