#!/bin/bash
set -euo pipefail
MOTION_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOTION_CONFIG="${CONFIGURATION:-Release}"
MOTION_ARCHS="${ARCHS:-arm64 x86_64}"
MOTION_SDK="$(xcrun --show-sdk-path)"
MOTION_OUTPUT="$MOTION_ROOT/Artifacts/$MOTION_CONFIG"
MOTION_APP="$MOTION_OUTPUT/Moving.app"
mkdir -p "$MOTION_OUTPUT/objects" "$MOTION_APP/Contents/MacOS" "$MOTION_APP/Contents/Resources"
if [[ ! -f "$MOTION_ROOT/Resources/Wallpapers/Aurora Drift.mp4" ]]; then
  xcrun swift "$MOTION_ROOT/Scripts/GenerateAssets.swift" "$MOTION_ROOT"
fi
if [[ ! -f "$MOTION_ROOT/Resources/Moving.icns" || ! -f "$MOTION_ROOT/Resources/MovingMark.png" ]]; then
  xcrun swift "$MOTION_ROOT/Scripts/GenerateBrand.swift" "$MOTION_ROOT"
  iconutil -c icns "$MOTION_ROOT/Artifacts/Moving.iconset" -o "$MOTION_ROOT/Resources/Moving.icns"
fi
MOTION_FLAGS=(-O -whole-module-optimization)
if [[ "$MOTION_CONFIG" == Debug ]]; then MOTION_FLAGS=(-Onone -g -D DEBUG); fi
MOTION_BINARIES=()
for MOTION_ARCH in $MOTION_ARCHS; do
  echo "Building $MOTION_CONFIG for $MOTION_ARCH"
  xcrun swiftc -swift-version 5 -parse-as-library "${MOTION_FLAGS[@]}" \
    -sdk "$MOTION_SDK" -target "$MOTION_ARCH-apple-macos14.0" \
    -module-name Moving "$MOTION_ROOT"/Sources/*.swift \
    -o "$MOTION_OUTPUT/objects/Moving-$MOTION_ARCH"
  MOTION_BINARIES+=("$MOTION_OUTPUT/objects/Moving-$MOTION_ARCH")
done
xcrun lipo -create "${MOTION_BINARIES[@]}" -output "$MOTION_APP/Contents/MacOS/Moving"
cp "$MOTION_ROOT/Resources/Info.plist" "$MOTION_APP/Contents/Info.plist"
cp "$MOTION_ROOT/Resources/Moving.icns" "$MOTION_ROOT/Resources/MovingMark.png" "$MOTION_APP/Contents/Resources/"
ditto "$MOTION_ROOT/Resources/Wallpapers" "$MOTION_APP/Contents/Resources/Wallpapers"
cp "$MOTION_ROOT/LICENSE" "$MOTION_APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$MOTION_APP/Contents/PkgInfo"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$MOTION_ROOT/Resources/Moving.entitlements" --sign "$SIGNING_IDENTITY" "$MOTION_APP"
else
  codesign --force --sign - --entitlements "$MOTION_ROOT/Resources/Moving.entitlements" "$MOTION_APP"
fi
codesign --verify --deep --strict "$MOTION_APP"
echo "$MOTION_APP"
