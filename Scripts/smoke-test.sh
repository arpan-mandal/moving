#!/bin/bash
set -euo pipefail
MOTION_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOTION_APP="$MOTION_ROOT/Artifacts/Release/Moving.app"
mkdir -p "$MOTION_ROOT/Artifacts/Tests"
MOTION_REPORT="$HOME/Library/Containers/com.motion.wallpaper/Data/tmp/Moving-smoke-report.json"
if pgrep -f "$MOTION_APP/Contents/MacOS/Moving" >/dev/null; then
  echo 'Quit the running Moving app before the isolated graphical smoke test.' >&2
  exit 1
fi
if [[ -f "$MOTION_REPORT" ]]; then mv "$MOTION_REPORT" "$MOTION_REPORT.previous"; fi
open -n "$MOTION_APP" --args --smoke-test
for MOTION_ATTEMPT in {1..30}; do
  if [[ -f "$MOTION_REPORT" ]]; then
    cp "$MOTION_REPORT" "$MOTION_ROOT/Artifacts/Tests/smoke-report.json"
    python3 - "$MOTION_REPORT" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
checks=['allSpaces','assignmentPersisted','belowIcons','clickThrough','compactWindow','continuesAfterWindowClose','localMP4Imported','lsUIElement','muted','originalWallpaperUnchanged','pauseWorks','readyForDisplay','restored','timeAdvanced']
failed=[key for key in checks if state.get(key) is not True]
for name in ('emptyMenuPopover', 'expandedMenuPopover', 'assignedMenuPopover'):
    popover = state.get(name, {})
    if any(popover.get(key) is not True for key in ('shown', 'focused', 'onScreen', 'belowIcon')):
        failed.append(name)
if state.get('loopCount',0)<1: failed.append('loopCount')
if state.get('playerRate')!=1: failed.append('playerRate')
print(json.dumps(state,indent=2))
if failed: sys.exit('Failed checks: '+', '.join(failed))
print('Graphical Release smoke test passed. Test data is isolated; system wallpapers were preserved.')
PY
    exit 0
  fi
  sleep 1
done
echo 'The app did not produce a smoke report within 30 seconds.' >&2
exit 1
