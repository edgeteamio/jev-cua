#!/bin/bash
# Assemble dist/JevCUA.app from a release build and ad-hoc sign it. Permissions (Microphone,
# Speech Recognition, Accessibility) attach to the bundle id io.edgeteam.jev-cua and survive
# rebuilds as long as the id and the ad-hoc signature stay the same.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

"$SWIFT" build -c release
APP=dist/JevCUA.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/jev-cua "$APP/Contents/MacOS/jev-cua"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Sign with a stable identity so TCC grants survive rebuilds (an ad-hoc signature changes with
# every build and resets Microphone, Speech, and Accessibility). Preference: the Developer ID
# Application certificate in the keychain, else the self-signed identity from
# scripts/signing-identity.sh, else ad-hoc. No hardened runtime: local builds are not notarized
# and the hardened runtime would need the audio-input entitlement for the microphone.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"JevCUA Dev Signing"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier io.edgeteam.jev-cua --timestamp=none "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --sign - --identifier io.edgeteam.jev-cua "$APP"
  echo "signed ad-hoc (no Developer ID; run scripts/signing-identity.sh once so permissions survive rebuilds)"
fi

echo "built $APP"
echo "  open $APP                                   # first launch: doctor with permission prompts"
echo "  $APP/Contents/MacOS/jev-cua speech-probe    # any subcommand, with the bundle's permissions"
