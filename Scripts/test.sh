#!/bin/bash
set -euo pipefail
MOTION_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MOTION_ROOT"
mkdir -p Artifacts/Tests
if xcodebuild -version >/dev/null 2>&1; then
  swift test --no-parallel
else
  echo 'XCTest is not bundled with Command Line Tools; running the same cases with the standalone adapter.'
  xcrun swiftc -swift-version 5 -parse-as-library -D MOTION_STANDALONE_TESTS \
    -target "$(uname -m)-apple-macos14.0" \
    Sources/Models.swift Sources/Media.swift Sources/LibraryStore.swift Sources/DesktopEngine.swift \
    Tests/MotionCoreTests.swift Tests/StandaloneRunner.swift -o Artifacts/Tests/MotionTests
  Artifacts/Tests/MotionTests
fi

"$MOTION_ROOT/Scripts/test-external-import.sh"
