# Verification record

## Moving 1.2.0, build 7

Verified on November 5, 2026 on an Apple Silicon Mac with one built-in display. Both release architectures were compiled with the Apple Swift toolchain and macOS SDK. The deployment target is macOS 14.

- The universal executable contains arm64 and x86_64 slices. Strict code-signature verification passed for the local ad-hoc build.
- The compressed DMG passed disk-image verification and its SHA-256 check. A read-only mount contained the matching executable, a valid local signature and a shortcut to Applications.
- All 11 core tests passed with the standalone test runner. They cover persistence and recovery, import and relinking, playback policy, resolution and frame-rate conversion, window lifecycle, pause, looping and desktop restoration.
- The sandboxed external import probe verified read-only MP4 bookmarks, Crop and Stretch, pause for maximized and full-display windows, a retained still frame and resumption from the paused timestamp. It also verified that uncovering the desktop respects a manual pause.
- The Release smoke test exercised a real looping video and an isolated library. It checked the compact window, all three menu popover states, playback after closing the library, persistence and restoration of the original system wallpaper.
- The in-place upgrade preserved the installed library, display assignment and preferences. A native UI inspection confirmed the Wallpapers, Displays and Settings panels in the installed build.

The smoke test writes its report under `Artifacts/Tests/`. The [build 6 benchmark](benchmarks/1.2.0-build-6/Benchmark.md) records the measured process CPU and physical memory footprint on one Apple silicon Mac.

Runtime checks used Apple Silicon. Intel and older supported macOS versions still need runtime qualification. This release has no measured battery-life or peak-memory comparison. Direct public distribution requires a Developer ID-signed, notarized release. See [Signing](SIGNING.md) and [Limitations](LIMITATIONS.md).

## 1.0.1 external import regression

A user reported that choosing a custom MP4 produced “The file … couldn’t be opened.” Motion's process logs showed a scoped-file “Operation not permitted” error. The original import code requested `.withSecurityScope` alone, which asks for read/write scope despite the app only having read-only access to user-selected files.

`Scripts/test-external-import.sh --expect-denied` reproduced that exact failure in a signed sandboxed helper with a read-only grant to one generated MP4 outside its container. The original implementation failed import. After applying `.securityScopeAllowOnlyReadAccess` consistently to import, relinking and stale-bookmark renewal, `Scripts/test-external-import.sh` passed: import, metadata, thumbnail, persisted-bookmark resolution, duplicate handling, relinking, actual AVPlayerLayer playback, looping, and restoration. A control using the old bookmark flags still fails under the same grant, so this test distinguishes the regression from a permissive in-container test. The source file remains unchanged.

The helper's narrowly scoped test-only read grant is not part of Motion's entitlements. Motion retains read-only user-selected file access. This regression was tested with a narrowly scoped file grant outside the app container.

[Apple documents the read-only bookmark creation option](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/securityscopeallowonlyreadaccess).
