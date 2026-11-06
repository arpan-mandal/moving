#!/bin/bash
set -euo pipefail
MOTION_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOTION_DIST="$MOTION_ROOT/Artifacts/Release"
MOTION_DMG="$MOTION_DIST/Moving-1.2.0-universal.dmg"
MOTION_RW="$MOTION_DIST/Moving-installer-rw.dmg"
MOTION_MOUNT="$(mktemp -d /tmp/moving-installer.XXXXXX)"
MOTION_PYTHON="$MOTION_ROOT/Artifacts/packaging-venv/bin/python"
if [[ ! -d "$MOTION_DIST/Moving.app" ]]; then "$MOTION_ROOT/Scripts/build.sh"; fi
if [[ ! -x "$MOTION_PYTHON" ]]; then
  python3 -m venv "$MOTION_ROOT/Artifacts/packaging-venv"
  "$MOTION_PYTHON" -m pip install 'ds-store==1.3.1' 'mac-alias==2.2.3'
fi
cleanup() { hdiutil detach "$MOTION_MOUNT" -quiet 2>/dev/null || true; rmdir "$MOTION_MOUNT" 2>/dev/null || true; rm -f "$MOTION_RW"; }
trap cleanup EXIT
rm -f "$MOTION_RW" "$MOTION_DMG"
hdiutil create -size 64m -fs HFS+ -volname Moving "$MOTION_RW" -quiet
hdiutil attach "$MOTION_RW" -mountpoint "$MOTION_MOUNT" -nobrowse -quiet
ditto "$MOTION_DIST/Moving.app" "$MOTION_MOUNT/Moving.app"
ln -s /Applications "$MOTION_MOUNT/Applications"
mkdir -p "$MOTION_MOUNT/.background"
xcrun swift "$MOTION_ROOT/Scripts/GenerateDMGBackground.swift" "$MOTION_MOUNT/.background/install.png" "$MOTION_ROOT/Resources/MovingMark.png"
"$MOTION_PYTHON" "$MOTION_ROOT/Scripts/dmg-layout.py" "$MOTION_MOUNT"
cp "$MOTION_ROOT/Resources/Moving.icns" "$MOTION_MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MOTION_MOUNT"; fi
hdiutil detach "$MOTION_MOUNT" -quiet
hdiutil convert "$MOTION_RW" -format UDZO -imagekey zlib-level=9 -o "$MOTION_DMG" -quiet
hdiutil verify "$MOTION_DMG"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then codesign --timestamp --sign "$SIGNING_IDENTITY" "$MOTION_DMG"; fi
(cd "$MOTION_DIST" && shasum -a 256 "${MOTION_DMG##*/}") > "$MOTION_DMG.sha256"
echo "$MOTION_DMG"
