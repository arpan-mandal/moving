# Wallpaper rendering architecture

## Desktop integration

Moving uses public AppKit/Core Graphics window APIs. For every connected, assigned NSScreen, DesktopEngine creates a borderless DesktopWindow with:

- `CGWindowLevelForKey(.desktopWindow) + 1`, below `.desktopIconWindow`.
- `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle` collection behavior.
- `ignoresMouseEvents = true`, no shadow, no key/main-window eligibility, no app-activation behavior, and `hidesOnDeactivate = false`.
- A frame equal to the screen's full AppKit frame, including negative display origins. AppKit/layer backing scale handles Retina rendering.

This places animation in the desktop layer, not an ordinary fullscreen window. Finder icons and desktop widgets are higher in the window stack and keep receiving input. Dock, menu bar and normal application windows are above Moving. No Finder injection, private Space APIs, screen recording, accessibility access, or WindowServer modifications are used.

The running host reported Moving at level **−2147483622**, Finder at **−2147483603**, and desktop widgets at **−2147483601**. Playback smoke tests additionally verified click-through configuration, all-Spaces behavior flags, AVPlayerLayer readiness, and successful restoration. This confirms configured layering on this OS; actual Mission Control/Stage Manager transitions across older OS releases still need physical/manual qualification.

macOS does not expose a general supported API for installing arbitrary video as its system-managed wallpaper provider. AppKit desktop windows are the safest public-API alternative. They exist only while Moving runs and do not extend to the login screen. The same display assignment appears on ordinary desktop Spaces; separate wallpapers per Space are deliberately unsupported. Space and display-change notifications reassert geometry/order without changing application focus.

## Restoration by construction

Moving does **not call `NSWorkspace.setDesktopImageURL`**, write the wallpaper database, change Finder preferences, or replace the system wallpaper file. Videos and images both use a desktop overlay. Removing an assignment destroys that display's window and reveals the original OS background. Quitting, force quitting, or crashing lets WindowServer remove the process's windows. No recovery helper or saved wallpaper snapshot is required.

This also preserves Apple's dynamic wallpaper configuration, scaling and per-Space choices. If the user changes the system wallpaper while Moving runs, the new system choice appears when the overlay is removed; Moving does not overwrite it with a stale snapshot.

## Video and resource ownership

DesktopPlayback owns one AVQueuePlayer, AVPlayerLooper, AVPlayerLayer, file-access scope, task and observation set per active display. AVFoundation selects hardware decoding where the codec/hardware supports it. The player is muted, does not inhibit display sleep, and uses the original media timebase. AVPlayerLooper reuses queue items to avoid manual end-of-file seeks. Visible continuity still depends on source edit boundaries.

A separate decoder per display avoids relying on multiple AVPlayerLayers backed by a shared player behaving consistently across OS releases. Equal wallpapers share the optimized disk representation and in-flight export job. Decoders are only created for assigned, connected displays. Removing/reassigning a display cancels preparation, removes observations, disables looping, removes items, releases source access/cache leases and closes the desktop window. Preview playback has separate ownership and stops when its sheet closes. No polling render timer, CADisplayLink or unnecessary custom Metal pass is used.

AVPlayer, current player-item, and looper errors are observed. Failure releases the decoder and leaves the thumbnail visible with a descriptive playback status. Missing sources can be relinked without changing the wallpaper identity or display assignments.

## Effective performance profiles

AVPlayerItem.preferredMaximumResolution only affects HLS; setting it on local files would not reduce work. Moving instead produces actual AVFoundation playback copies, with orientation-aware transforms and a video composition imposing resolution and frame duration:

| Profile | Maximum long edge | Maximum fps | Additional default behavior |
|---|---:|---:|---|
| Battery Saver | 1280 | 24 | Pauses on battery with battery optimization enabled |
| Balanced | 1920 | 30 | Pauses for low battery, sleep, lock and resource pressure |
| Performance | Original | 60 | Prioritizes source quality; still respects safety suspensions |

User quality/fps preferences can lower these bounds. With battery optimization enabled, Balanced uses the 1280-pixel/24 fps limits on battery. Low Power Mode selects Battery Saver limits when optimization is enabled. Automatic proxy generation is serialized, duplicate requests share a job, canceled request ownership is tracked, and playback files use leases to prevent eviction underneath active loops. Files are keyed by source path, modification time, size, resolution and fps; originals are referenced without copying when already within limits.

The least-recently-used cache evicts unused entries above 1 GB and never deletes active playback files. Initial optimization can consume CPU/GPU and disk space once; the menu status reports Optimizing video. Original-quality playback in Performance mode avoids resolution conversion when the source fps fits the selected cap. Converted output does not promise HDR preservation.

## Environment events

Public NSWorkspace notifications cover system sleep, screen sleep/wake, active session changes, desktop Spaces and display changes. Public ProcessInfo and Dispatch memory-pressure notifications cover Low Power Mode, heat and memory pressure. IOKit power-source state is polled every 60 seconds with timer tolerance to detect power/charge changes; no per-frame monitoring is required.

Sleep, inactive sessions, lock notifications, critical heat, and memory pressure remove playback sessions and release decoders. Battery behavior follows settings. Auto Resume disabled holds playback after an interruption until the user presses Play. Manual pause and fullscreen coverage save the video time, capture a still up to 1920 pixels on its long edge, and release the player, looper, media access and cache lease. Resume seeks to the saved timestamp. If a still cannot be decoded, the paused player retains the visible frame. Window coverage checks run every two seconds while animation is enabled and also respond to app and Space changes. Manual pause disables those checks. Reconnection restores assignments using CGDisplay UUIDs, not transient screen array positions or display IDs.

The advisory `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications supplement supported session/display events. They are notification names, not private API calls, but Apple does not document a delivery contract. A launch into an already-locked session may not receive the original lock event. Playback never renders over the login window.

## Library and UI

LibraryStore is a main-actor observable store. Edits save an immutable copy atomically before publishing; failed writes leave the in-memory state unchanged. A versioned JSON repository maintains the previous valid save and preserves damaged input. Newer unknown formats are opened read-only rather than reset. Thumbnails are separate from original assets and cache entries.

Imported files use read-only security-scoped bookmarks. ScopedMediaAccess balances resource access; stale bookmarks are refreshed. Images are downsampled with ImageIO, and video metadata/thumbnails load asynchronously through AVFoundation. Only user-chosen local files are imported; there are no remote sources or network entitlements.

AppKit owns the accessory application lifecycle, NSStatusItem/NSPopover and library NSWindow. SwiftUI implements the library, display manager, previews and settings. Closing the NSWindow does not terminate the app. SMAppService.mainApp handles supported login-item registration and approval status.

## Apple API references

- [Desktop icon window level](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey/desktopiconwindow) and [CGWindowLevel](https://developer.apple.com/documentation/coregraphics/cgwindowlevel).
- [All-Spaces behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces).
- [AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper).
- [Local-file resolution hint limitation](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredmaximumresolution).
- [Session deactivation](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification).
- [SMAppService registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).
- [System desktop image API](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)), intentionally unused by this engine.
