#!/bin/zsh
# Records a code-signing identity for local builds, so that the Accessibility
# permission survives rebuilding the app.
#
# Why this is needed: an ad-hoc signature (`codesign --sign -`) puts the
# binary's own hash into the app's designated requirement. macOS therefore
# treats every rebuild as a different application and the Accessibility
# permission has to be granted again. Signing with a certificate produces a
# requirement based on that certificate instead, which does not change when the
# code does.
#
# The chosen identity is written to .signing-identity, which is not committed:
# a certificate-based requirement contains the signer's name, so published
# builds stay ad-hoc (scripts/build-release.sh forces that).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ge 1 ]]; then
  IDENTITY="$1"
else
  echo "Available code-signing identities:"
  security find-identity -v -p codesigning || true
  echo
  echo "Usage: scripts/setup-signing.sh '<identity name>'"
  echo
  echo "Any code-signing identity works, including a self-signed one created in"
  echo "Keychain Access (Certificate Assistant > Create a Certificate, type"
  echo "'Code Signing'). A self-signed certificate keeps your Apple Developer"
  echo "identity out of locally installed builds."
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "No code-signing identity matching: $IDENTITY" >&2
  exit 1
fi

print -r -- "$IDENTITY" > .signing-identity
echo "Recorded in .signing-identity: $IDENTITY"
echo
echo "Rebuild and reinstall once, then grant Accessibility permission one last"
echo "time. Later rebuilds will keep it:"
echo "  scripts/build-app.sh && rm -rf /Applications/ClickThrough.app \\"
echo "    && cp -R build/ClickThrough.app /Applications/"
