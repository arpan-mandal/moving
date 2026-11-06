#!/bin/bash
set -euo pipefail
# The sandbox exception must name the fixture's physical path, including on macOS's /var alias.
MOTION_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MOTION_TEST_ROOT="$MOTION_ROOT/Artifacts/Tests/ExternalImport"
MOTION_PROBE="$MOTION_TEST_ROOT/MotionImportProbe.app"
MOTION_FIXTURE="$MOTION_TEST_ROOT/External-Read-Only.mp4"
mkdir -p "$MOTION_PROBE/Contents/MacOS" "$MOTION_PROBE/Contents/Resources"
cp "$MOTION_ROOT/Resources/Wallpapers/Aurora Drift.mp4" "$MOTION_FIXTURE"
python3 - "$MOTION_PROBE" "$MOTION_FIXTURE" <<'PY'
import plistlib, pathlib,sys
app,fixture=map(pathlib.Path,sys.argv[1:])
info={'CFBundleIdentifier':'com.motion.wallpaper.import-test','CFBundleExecutable':'MotionImportProbe','CFBundleName':'Motion Import Regression Test','CFBundlePackageType':'APPL','LSUIElement':True,'LSMinimumSystemVersion':'14.0'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
# A narrowly scoped READ-ONLY test grant reproduces the same sandbox constraint
# as a read-only NSOpenPanel grant. It is never added to Motion's entitlements.
entitlements={'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-only':True,'com.apple.security.files.bookmarks.app-scope':True,'com.apple.security.temporary-exception.files.absolute-path.read-only':[str(fixture)]}
(app.parent/'Probe.entitlements').write_bytes(plistlib.dumps(entitlements))
PY
xcrun swiftc -swift-version 5 -parse-as-library -D MOTION_SANDBOX_IMPORT_TEST \
  -target "$(uname -m)-apple-macos14.0" \
  "$MOTION_ROOT/Sources/Models.swift" "$MOTION_ROOT/Sources/Media.swift" \
  "$MOTION_ROOT/Sources/LibraryStore.swift" "$MOTION_ROOT/Sources/DesktopEngine.swift" \
  "$MOTION_ROOT/Tests/SandboxImportProbe.swift" -o "$MOTION_PROBE/Contents/MacOS/MotionImportProbe"
codesign --force --sign - --entitlements "$MOTION_TEST_ROOT/Probe.entitlements" "$MOTION_PROBE"
"$MOTION_PROBE/Contents/MacOS/MotionImportProbe" "$MOTION_FIXTURE" "${1:-}"
