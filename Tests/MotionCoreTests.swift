#if !MOTION_STANDALONE_TESTS
import XCTest
#endif
import AppKit
import AVFoundation
import CoreVideo
#if !MOTION_STANDALONE_TESTS
@testable import MotionCore
#endif

final class RepositoryTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testRoundTripAndBackupRecovery() throws {
        let repository = StateRepository(url: directory.appendingPathComponent("library.json"))
        var state = LibraryState(); let id = UUID()
        state.assignments = ["display-uuid": id]; state.preferences.profile = .batterySaver
        try repository.save(state)
        XCTAssertEqual(try repository.load().0, state)
        var second = state; second.preferences.frameRate = 60
        try repository.save(second)
        try Data("broken".utf8).write(to: repository.url)
        let recovered = try repository.load()
        XCTAssertTrue(recovered.recovered); XCTAssertEqual(recovered.0, state)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("library-damaged-") })
    }
    func testNewerVersionIsNeverSilentlyReplaced() throws {
        let repository = StateRepository(url: directory.appendingPathComponent("library.json"))
        try repository.save(LibraryState())
        var future = LibraryState(); future.version = 500
        let bytes = try JSONEncoder().encode(future); try bytes.write(to: repository.url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: repository.url), bytes)
    }
    func testFreshLibrary() throws {
        let result = try StateRepository(url: directory.appendingPathComponent("new.json")).load()
        XCTAssertTrue(result.0.wallpapers.isEmpty); XCTAssertFalse(result.recovered)
    }
    func testPoliciesHaveRealDistinctLimits() {
        var prefs = Preferences(); prefs.frameRate = 60
        prefs.profile = .performance
        XCTAssertEqual(RenderPolicy.make(prefs, lowPower: false), RenderPolicy(maxDimension: 0, fps: 60))
        prefs.profile = .balanced
        XCTAssertEqual(RenderPolicy.make(prefs, lowPower: false), RenderPolicy(maxDimension: 1920, fps: 30))
        XCTAssertEqual(RenderPolicy.make(prefs, lowPower: false, onBattery: true), RenderPolicy(maxDimension: 1280, fps: 24))
        prefs.profile = .batterySaver
        XCTAssertEqual(RenderPolicy.make(prefs, lowPower: false), RenderPolicy(maxDimension: 1280, fps: 24))
        prefs.profile = .performance
        XCTAssertEqual(RenderPolicy.make(prefs, lowPower: true).fps, 24)
        prefs.batteryOptimization = false
        XCTAssertEqual(RenderPolicy.make(prefs, lowPower: true).fps, 60)
        prefs.quality = .hd
        XCTAssertEqual(RenderPolicy.make(prefs, lowPower: false).maxDimension, 1280)
    }
}

@MainActor enum Fixture {
    static func image(at url: URL) throws {
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    }
    static func video(at url: URL, transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        input.transform = transform
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &buffer)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer)!, Int32(index*3), CVPixelBufferGetBytesPerRow(pixelBuffer)*90)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adapter.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 60)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}

@MainActor
final class MediaAndLibraryTests: XCTestCase {
    var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    func testImageImportDeduplicationMetadataAndPersistence() async throws {
        let file = directory.appendingPathComponent("Ocean.png"); try Fixture.image(at: file)
        let library = LibraryStore(root: directory.appendingPathComponent("Library"))
        await library.importURLs([file, file])
        XCTAssertEqual(library.wallpapers.count, 1, library.message ?? "")
        let item = try XCTUnwrap(library.wallpapers.first)
        XCTAssertEqual(item.metadata.width, 80); XCTAssertEqual(item.metadata.height, 40); XCTAssertFalse(item.metadata.isVideo)
        XCTAssertNotNil(item.bookmark); XCTAssertTrue(FileManager.default.fileExists(atPath: library.thumbnailURL(item).path))
        XCTAssertEqual(try ScopedMediaAccess(item).url.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        library.rename(item.id, to: "New Ocean"); library.setFavorite(item.id)
        library.addCollection("Personal"); library.setCollection(item.id, to: "Personal")
        library.assign(item.id, displays: ["screen-a", "screen-b"], fit: .stretch)
        library.setFit(.crop, for: "screen-b")
        let loaded = LibraryStore(root: library.root)
        XCTAssertEqual(loaded.wallpapers.first?.name, "New Ocean"); XCTAssertTrue(loaded.wallpapers.first?.favorite == true)
        XCTAssertEqual(loaded.wallpapers.first?.collection, "Personal"); XCTAssertEqual(loaded.state.assignments.count, 2)
        XCTAssertEqual(loaded.state, library.state)
        XCTAssertEqual(loaded.state.fit(for: "screen-a"), .stretch)
        XCTAssertEqual(loaded.state.fit(for: "screen-b"), .crop)
        XCTAssertEqual(loaded.state.fit(for: "unconfigured-display"), .crop)
        library.restore(displays: ["screen-a"])
        XCTAssertNil(library.state.assignments["screen-a"]); XCTAssertNotNil(library.state.assignments["screen-b"])
        library.remove(item)
        XCTAssertTrue(library.wallpapers.isEmpty); XCTAssertTrue(library.state.assignments.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testMissingFileRelinkAndInvalidMedia() async throws {
        let file = directory.appendingPathComponent("Original.png"); try Fixture.image(at: file)
        let library = LibraryStore(root: directory.appendingPathComponent("Library")); await library.importURLs([file])
        let item = try XCTUnwrap(library.wallpapers.first)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try ScopedMediaAccess(item))
        let replacement = directory.appendingPathComponent("Replacement.png"); try Fixture.image(at: replacement)
        await library.relink(item, url: replacement)
        let linked = try XCTUnwrap(library.wallpapers.first)
        XCTAssertEqual(linked.id, item.id); XCTAssertEqual(try ScopedMediaAccess(linked).url.resolvingSymlinksInPath().path, replacement.resolvingSymlinksInPath().path)
        let invalid = directory.appendingPathComponent("broken.mp4"); try Data("invalid media".utf8).write(to: invalid)
        await library.importURLs([invalid])
        XCTAssertNotNil(library.message); XCTAssertEqual(library.wallpapers.count, 1)
    }
    func testFailedSaveRollsBackState() async throws {
        let library = LibraryStore(root: directory.appendingPathComponent("Library"))
        let original = library.state
        try FileManager.default.createDirectory(at: library.root.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        library.setPreferences { $0.frameRate = 60 }
        XCTAssertEqual(library.state, original); XCTAssertNotNil(library.message)
    }
    func testVideoMetadataAndConcurrentProxyGeneration() async throws {
        let file = directory.appendingPathComponent("60fps.mp4"); try await Fixture.video(at: file)
        let inspected = try await MediaInspector.inspect(file)
        XCTAssertTrue(inspected.metadata.isVideo); XCTAssertEqual(inspected.metadata.width, 160)
        XCTAssertEqual(inspected.metadata.frameRate, 60, accuracy: 0.1); XCTAssertEqual(inspected.metadata.duration, 1, accuracy: 0.1)
        let cache = ProxyCache(directory: directory.appendingPathComponent("Proxies"))
        let policy = RenderPolicy(maxDimension: 80, fps: 24)
        async let first = cache.playbackURL(source: file, metadata: inspected.metadata, policy: policy)
        async let second = cache.playbackURL(source: file, metadata: inspected.metadata, policy: policy)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b); XCTAssertNotEqual(a, file)
        let proxy = try await MediaInspector.inspect(a)
        XCTAssertEqual(proxy.metadata.width, 80); XCTAssertEqual(proxy.metadata.height, 44)
        XCTAssertLessThanOrEqual(proxy.metadata.frameRate, 24.1)
        let cached = try await cache.playbackURL(source: file, metadata: inspected.metadata, policy: policy)
        XCTAssertEqual(cached, a)
        await cache.clear(); XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "Clearing cache must preserve active playback leases")
        await cache.release(a); await cache.release(b); await cache.release(cached)
        await cache.clear(); XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }
    func testRotatedVideoMetadataAndProxy() async throws {
        let file = directory.appendingPathComponent("Portrait.mp4")
        try await Fixture.video(at: file, transform: CGAffineTransform(rotationAngle: .pi / 2))
        let inspected = try await MediaInspector.inspect(file)
        XCTAssertEqual(inspected.metadata.width, 90); XCTAssertEqual(inspected.metadata.height, 160)
        let cache = ProxyCache(directory: directory.appendingPathComponent("PortraitCache"))
        let output = try await cache.playbackURL(source: file, metadata: inspected.metadata, policy: RenderPolicy(maxDimension: 80, fps: 24))
        let result = try await MediaInspector.inspect(output)
        XCTAssertEqual(result.metadata.width, 44); XCTAssertEqual(result.metadata.height, 80)
        await cache.release(output); await cache.clear()
    }
    func testColdLaunchAndManualResumeAfterInterruption() async throws {
        _ = NSApplication.shared
        guard let display = DisplayInfo.connected().first else { throw XCTSkip("Requires a graphical session") }
        let file = directory.appendingPathComponent("Static.png"); try Fixture.image(at: file)
        let library = LibraryStore(root: directory.appendingPathComponent("Library")); await library.importURLs([file])
        let item = try XCTUnwrap(library.wallpapers.first)
        library.assign(item.id, displays: [display.id])
        library.setPreferences { $0.restoreOnLaunch = false; $0.autoResume = false; $0.batteryOptimization = false }
        let engine = DesktopEngine(library: library, coveredDisplays: { _ in [] }); defer { engine.stop() }
        XCTAssertTrue(engine.sessions.isEmpty)
        engine.apply(item, to: [display.id]); XCTAssertNotNil(engine.sessions[display.id])
        let first = engine.sessions[display.id]
        engine.apply(item, to: [display.id])
        XCTAssertFalse(engine.sessions[display.id] === first, "Apply must retry the source even when its assignment is unchanged")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(100))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(engine.sessions.isEmpty); XCTAssertEqual(engine.suspension, "Press Play to resume")
        engine.togglePlayback(); XCTAssertNotNil(engine.sessions[display.id])
        library.setPreferences { $0.pauseOnDisplaySleep = false }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(engine.sessions[display.id]); XCTAssertNil(engine.suspension)
        engine.restoreOriginal()
        XCTAssertEqual(NSApp.windows.filter { $0 is DesktopWindow && $0.isVisible }.count, 0)
    }
    func testDisplayDetectionAndEngineLifecycle() async throws {
        _ = NSApplication.shared
        let displays = DisplayInfo.connected()
        guard !displays.isEmpty else { throw XCTSkip("Requires an active graphical macOS session") }
        XCTAssertEqual(Set(displays.map(\.id)).count, displays.count)
        XCTAssertTrue(displays.allSatisfy { $0.pixelWidth > 0 && $0.pixelHeight > 0 })
        let file = directory.appendingPathComponent("Loop.mp4"); try await Fixture.video(at: file)
        let library = LibraryStore(root: directory.appendingPathComponent("Library")); await library.importURLs([file])
        library.setPreferences { $0.profile = .performance; $0.frameRate = 60; $0.batteryOptimization = false }
        let engine = DesktopEngine(library: library, coveredDisplays: { _ in [] }); defer { engine.stop() }
        let item = try XCTUnwrap(library.wallpapers.first), display = displays[0]
        let original = display.screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        engine.apply(item, to: [display.id])
        try await Task.sleep(for: .seconds(2.5))
        let playback = try XCTUnwrap(engine.sessions[display.id])
        XCTAssertTrue(playback.window.ignoresMouseEvents); XCTAssertFalse(playback.window.canBecomeKey)
        XCTAssertLessThan(playback.window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)))
        XCTAssertTrue(playback.window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(playback.player?.rate, 1); XCTAssertTrue(playback.player?.isMuted == true)
        XCTAssertGreaterThanOrEqual(playback.looper?.loopCount ?? 0, 1)
        library.setFavorite(item.id)
        XCTAssertTrue(engine.sessions[display.id] === playback, "Metadata edits must not restart decoding")
        engine.togglePlayback()
        for _ in 0..<30 {
            if playback.player == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(playback.player == nil, "Manual pause should release the decoder")
        XCTAssertNil(playback.looper)
        XCTAssertNotNil(playback.surface.stillLayer.contents)
        engine.togglePlayback()
        for _ in 0..<30 {
            if playback.player?.rate == 1 && playback.surface.playerLayer.isReadyForDisplay { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(playback.player?.rate, 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(engine.sessions.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(engine.sessions[display.id])
        engine.restoreOriginal(); XCTAssertTrue(engine.sessions.isEmpty);
        XCTAssertEqual(NSApp.windows.filter { $0 is DesktopWindow && $0.isVisible }.count, 0); XCTAssertTrue(library.state.assignments.isEmpty)
        XCTAssertEqual(display.screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }, original)
        engine.stop(); XCTAssertTrue(engine.sessions.isEmpty)
    }
}
