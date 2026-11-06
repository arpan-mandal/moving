#if MOTION_SANDBOX_IMPORT_TEST
import AppKit

/// Runs as an ad-hoc signed, sandboxed test application with a read-only grant
/// to one generated fixture OUTSIDE its container. No user files are requested.
@main
struct SandboxImportProbe {
    @MainActor private static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<30 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let expectedFailure = CommandLine.arguments.contains("--expect-denied")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let library = LibraryStore(root: support.appendingPathComponent("Probe-" + UUID().uuidString))
        var report: [String: Any] = [:]
        do {
            // This is the original bug: requesting write scope from a read-only grant.
            _ = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            report["legacyWriteBookmarkRejected"] = false
        } catch {
            report["legacyWriteBookmarkRejected"] = true
            report["legacyError"] = error.localizedDescription
        }
        let originalSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        await library.importURLs([source])
        report["imported"] = library.wallpapers.count == 1
        report["importError"] = library.message ?? ""
        if let item = library.wallpapers.first {
            report["videoMetadata"] = item.metadata.isVideo && item.metadata.width == 1280 && item.metadata.height == 720
            report["bookmarkSaved"] = item.bookmark != nil
            report["thumbnailWritten"] = FileManager.default.fileExists(atPath: library.thumbnailURL(item).path)
            let reloaded = LibraryStore(root: library.root)
            do {
                let restored = reloaded.wallpapers.first!
                let access = try ScopedMediaAccess(restored)
                let inspected = try await MediaInspector.inspect(access.url)
                report["persistedBookmarkReadable"] = inspected.metadata.isVideo
            } catch { report["persistedBookmarkReadable"] = false; report["resolutionError"] = error.localizedDescription }
            await library.importURLs([source])
            report["deduplicated"] = library.wallpapers.count == 1
            await library.relink(item, url: source)
            report["relinkSucceeded"] = library.message == nil
            library.setPreferences { $0.batteryOptimization = false; $0.profile = .performance; $0.frameRate = 60 }
            var cover: NSWindow?
            let engine = DesktopEngine(library: library, coveredDisplays: { displays in
                guard let cover else { return [] }
                let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
                let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
                // Use a real WindowServer entry without depending on whatever apps the user has open.
                let testWindow = windows.filter { ($0[kCGWindowNumber as String] as? Int) == cover.windowNumber }
                return DesktopCoverage.coveredDisplays(displays, windows: testWindow)
            })
            if let display = engine.displays.first {
                engine.apply(library.wallpapers.first!, to: [display.id])
                try? await Task.sleep(for: .seconds(7.5))
                let playback = engine.sessions[display.id]
                report["externalVideoPlaying"] = playback?.player?.rate == 1
                report["readyForDisplay"] = playback?.surface.playerLayer.isReadyForDisplay == true
                report["looped"] = (playback?.looper?.loopCount ?? 0) >= 1
                if let screen = display.screen, let playback {
                    report["cropFillsAndPreservesAspectRatio"] = playback.surface.playerLayer.videoGravity == .resizeAspectFill
                    library.setFit(.stretch, for: display.id)
                    report["stretchFillsWithoutRestart"] = engine.sessions[display.id] === playback
                        && playback.surface.playerLayer.videoGravity == .resize
                        && playback.surface.posterLayer.contentsGravity == .resize

                    let window = NSWindow(contentRect: screen.visibleFrame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.ignoresMouseEvents = true
                    window.animationBehavior = .none
                    cover = window
                    window.setFrame(screen.visibleFrame, display: true)
                    window.orderBack(nil)
                    report["maximizedWindowFreezesPlayback"] = await waitFor {
                        playback.player == nil && playback.looper == nil && playback.surface.stillLayer.contents != nil
                    }
                    let pausedAt = playback.suspendedTime
                    try? await Task.sleep(for: .milliseconds(150))
                    report["frozenFrameStaysAtPlaybackPosition"] = pausedAt.seconds > 0
                        && pausedAt == playback.suspendedTime
                        && playback.surface.playerLayer.player == nil
                        && playback.surface.stillLayer.contentsGravity == .resize

                    window.setFrame(screen.visibleFrame.insetBy(dx: 120, dy: 120), display: true)
                    report["smallerWindowResumesPlayback"] = await waitFor {
                        playback.player?.rate == 1 && playback.surface.stillLayer.contents == nil
                    }
                    let resumedAt = playback.player?.currentTime().seconds ?? -1
                    report["pausedAtSeconds"] = pausedAt.seconds
                    report["resumedAtSeconds"] = resumedAt
                    report["resumePositionPreserved"] = abs(resumedAt - pausedAt.seconds) < 0.8

                    window.setFrame(screen.frame, display: true)
                    report["fullDisplayWindowFreezesPlayback"] = await waitFor {
                        playback.player == nil && playback.surface.stillLayer.contents != nil
                    }
                    library.setPreferences { $0.userPaused = true }
                    window.orderOut(nil)
                    try? await Task.sleep(for: .milliseconds(250))
                    report["revealingDesktopRespectsManualPause"] = playback.player == nil && playback.surface.stillLayer.contents != nil
                    cover = nil
                    window.close()
                }
                engine.restoreOriginal()
                report["restored"] = engine.sessions.isEmpty
            }
            engine.stop()
        }
        report["sourceUnchanged"] = originalSize == ((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("external-import-report.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print(String(data: (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? "")
        let passed: Bool
        if expectedFailure {
            passed = report["legacyWriteBookmarkRejected"] as? Bool == true && report["imported"] as? Bool == false
        } else {
            let checks = ["legacyWriteBookmarkRejected", "imported", "videoMetadata", "bookmarkSaved", "thumbnailWritten",
                          "persistedBookmarkReadable", "deduplicated", "relinkSucceeded", "externalVideoPlaying", "readyForDisplay",
                          "looped", "cropFillsAndPreservesAspectRatio", "stretchFillsWithoutRestart", "maximizedWindowFreezesPlayback",
                          "frozenFrameStaysAtPlaybackPosition", "smallerWindowResumesPlayback", "resumePositionPreserved", "fullDisplayWindowFreezesPlayback",
                          "revealingDesktopRespectsManualPause", "restored", "sourceUnchanged"]
            passed = checks.allSatisfy { report[$0] as? Bool == true }
        }
        exit(passed ? 0 : 1)
    }
}
#endif
