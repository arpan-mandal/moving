#!/bin/bash
set -euo pipefail
: "${SIGNING_IDENTITY:?Set your Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Set your notarytool keychain profile}"
MOTION_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOTION_DIST="$MOTION_ROOT/Artifacts/Release"
"$MOTION_ROOT/Scripts/build.sh"
ditto -c -k --keepParent "$MOTION_DIST/Moving.app" "$MOTION_DIST/Moving-notarization.zip"
xcrun notarytool submit "$MOTION_DIST/Moving-notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$MOTION_DIST/Moving.app"
"$MOTION_ROOT/Scripts/package-dmg.sh"
xcrun notarytool submit "$MOTION_DIST/Moving-1.2.0-universal.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$MOTION_DIST/Moving-1.2.0-universal.dmg"
xcrun stapler validate "$MOTION_DIST/Moving-1.2.0-universal.dmg"
spctl --assess --type execute --verbose=2 "$MOTION_DIST/Moving.app"
(cd "$MOTION_DIST" && shasum -a 256 Moving-1.2.0-universal.dmg > Moving-1.2.0-universal.dmg.sha256)
