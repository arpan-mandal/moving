import AppKit
import AVFoundation
import Combine
import IOKit.ps

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let screenNumber: UInt32
    var resolution: String { "\(pixelWidth) × \(pixelHeight)" }
    static func connected() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid)! as String
            let mode = CGDisplayCopyDisplayMode(number)
            return DisplayInfo(id: id, name: screen.localizedName, pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width), pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height), screenNumber: number)
        }
    }
    var screen: NSScreen? { NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == screenNumber } }
}

enum DesktopCoverage {
    static func coveredDisplays(_ displays: [DisplayInfo]) -> Set<String> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return coveredDisplays(displays, windows: windows)
    }

    static func coveredDisplays(_ displays: [DisplayInfo], windows: [[String: Any]]) -> Set<String> {
        let appLevel = Int(CGWindowLevelForKey(.normalWindow))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let windowBounds = windows.compactMap { window -> CGRect? in
            guard let level = window[kCGWindowLayer as String] as? Int,
                  (appLevel..<dockLevel).contains(level),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) >= 0.95,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        return Set(displays.compactMap { display -> String? in
            guard let screen = display.screen else { return nil }
            let bounds = CGDisplayBounds(display.screenNumber)
            let visible = screen.visibleFrame
            // Quartz uses a top-left origin. AppKit's visibleFrame has a bottom-left origin.
            let usable = CGRect(x: bounds.minX + visible.minX - screen.frame.minX,
                                y: bounds.minY + screen.frame.maxY - visible.maxY,
                                width: visible.width, height: visible.height).intersection(bounds)
            guard !usable.isEmpty else { return nil }
            // A maximized window may leave a few points around the usable display area.
            return windowBounds.contains { $0.insetBy(dx: -8, dy: -8).contains(usable) } ? display.id : nil
        })
    }
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true; acceptsMouseMovedEvents = false
        isOpaque = true; backgroundColor = .black; hasShadow = false
        isReleasedWhenClosed = false; hidesOnDeactivate = false; canHide = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }
}

final class WallpaperSurface: NSView {
    let playerLayer = AVPlayerLayer()
    let posterLayer = CALayer()
    let stillLayer = CALayer()
    var fit: WallpaperFit = .crop {
        didSet {
            guard fit != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.videoGravity = fit == .stretch ? .resize : .resizeAspectFill
            posterLayer.contentsGravity = fit == .stretch ? .resize : .resizeAspectFill
            stillLayer.contentsGravity = posterLayer.contentsGravity
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        posterLayer.contentsGravity = .resizeAspectFill; posterLayer.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        stillLayer.contentsGravity = .resizeAspectFill
        stillLayer.masksToBounds = true
        layer?.addSublayer(posterLayer)
        layer?.addSublayer(playerLayer)
        layer?.addSublayer(stillLayer)
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        posterLayer.frame = bounds; playerLayer.frame = bounds; stillLayer.frame = bounds
        CATransaction.commit()
    }
    func setPoster(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let maximum = min(7680, max(1920, Int(max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2))))
        posterLayer.contents = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum] as CFDictionary)
    }

    func showStill(_ frame: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.contents = frame
        CATransaction.commit()
    }
}

@MainActor
final class DesktopPlayback {
    let wallpaper: Wallpaper
    let policy: RenderPolicy
    let window: DesktopWindow
    let surface: WallpaperSurface
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var suspendedTime = CMTime.zero
    private(set) var status = "Preparing…"
    private(set) var hasFailed = false
    var onStatus: (() -> Void)?

    private var access: ScopedMediaAccess?
    private var cacheURL: URL?
    private var cache: ProxyCache?
    private var refreshBookmark: ((ScopedMediaAccess) -> Void)?
    private var prepareTask: Task<Void, Never>?
    private var freezeTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var errorToken: NSObjectProtocol?
    private var shouldPlay = true
    private var covered = false
    private var wantsPlayback: Bool { shouldPlay && !covered }
    private var pausedStatus: String { covered ? "Paused · display covered" : "Paused" }

    init(wallpaper: Wallpaper, policy: RenderPolicy, screen: NSScreen, thumbnail: URL) {
        self.wallpaper = wallpaper
        self.policy = policy
        window = DesktopWindow(screen: screen)
        surface = WallpaperSurface(frame: NSRect(origin: .zero, size: screen.frame.size))
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
        surface.setPoster(thumbnail)
    }

    func start(cache: ProxyCache, refreshed: @escaping (ScopedMediaAccess) -> Void) {
        self.cache = cache
        refreshBookmark = refreshed
        window.orderFrontRegardless()
        if wallpaper.metadata.isVideo {
            prepareVideo()
        } else {
            do {
                let scoped = try ScopedMediaAccess(wallpaper)
                surface.setPoster(scoped.url)
                refreshed(scoped)
                setStatus("Static wallpaper")
            } catch { fail(error.localizedDescription) }
        }
    }

    private func prepareVideo() {
        guard let cache, player == nil, prepareTask == nil, wantsPlayback else { return }
        setStatus(policy.needsProxy(wallpaper.metadata) ? "Optimizing video…" : "Preparing…")
        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { prepareTask = nil } }
            do {
                try Task.checkCancellation()
                let scoped = try ScopedMediaAccess(wallpaper)
                let url = try await cache.playbackURL(source: scoped.url, metadata: wallpaper.metadata, policy: policy)
                var adopted = false
                defer { if !adopted { Task { await cache.release(url) } } }
                try Task.checkCancellation()

                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                guard duration.isNumeric, duration.seconds > 0 else { throw MotionError.invalidMedia(wallpaper.name) }
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 1
                let queue = AVQueuePlayer()
                queue.isMuted = true
                queue.preventsDisplaySleepDuringVideoPlayback = false
                queue.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                queue.actionAtItemEnd = .advance
                let loop = AVPlayerLooper(player: queue, templateItem: item)
                if suspendedTime.seconds > 0 && suspendedTime < duration {
                    await queue.seek(to: suspendedTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                try Task.checkCancellation()

                adopted = true
                access = scoped
                cacheURL = url
                player = queue
                looper = loop
                surface.playerLayer.player = queue
                observe(queue: queue, loop: loop)
                queue.play()
                setStatus("Playing")
                refreshBookmark?(scoped)
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription) }
            }
        }
    }

    private func observe(queue: AVQueuePlayer, loop: AVPlayerLooper) {
        observations.append(loop.observe(\.status, options: [.initial, .new]) { [weak self, weak queue] loop, _ in
            guard loop.status == .failed else { return }
            let text = loop.error?.localizedDescription ?? "The video could not loop."
            Task { @MainActor in
                guard let self, let queue, self.player === queue else { return }
                self.fail(text)
            }
        })
        observations.append(queue.observe(\.status, options: [.initial, .new]) { [weak self] queue, _ in
            guard queue.status == .failed else { return }
            let text = queue.error?.localizedDescription ?? "The video decoder failed."
            Task { @MainActor in
                guard let self, self.player === queue else { return }
                self.fail(text)
            }
        })
        observations.append(queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] queue, _ in
            Task { @MainActor in
                guard let self, self.player === queue else { return }
                self.observeItem(queue.currentItem)
            }
        })
        observations.append(surface.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak queue] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in
                guard let self, let queue, self.player === queue, self.wantsPlayback else { return }
                self.surface.showStill(nil)
            }
        })
        errorToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self, weak queue] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            let error = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self, let queue, self.player === queue, queue.items().contains(item) else { return }
                self.fail(error ?? "Playback failed.")
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem?) {
        itemObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The video could not be decoded."
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                self.fail(message)
            }
        }
    }

    func updatePlayback(playing: Bool, covered: Bool) {
        guard wallpaper.metadata.isVideo, !hasFailed else { return }
        let wasPlaying = wantsPlayback
        shouldPlay = playing
        self.covered = covered
        guard wasPlaying != wantsPlayback else {
            if !wantsPlayback { setStatus(pausedStatus) }
            return
        }
        if wantsPlayback {
            freezeTask?.cancel()
            freezeTask = nil
            if let player {
                surface.showStill(nil)
                player.play()
                setStatus("Playing")
            } else {
                prepareVideo()
            }
        } else {
            prepareTask?.cancel()
            prepareTask = nil
            if let player { freezeAndRelease(player) }
            setStatus(pausedStatus)
        }
    }

    private func freezeAndRelease(_ player: AVQueuePlayer) {
        player.pause()
        let position = player.currentTime()
        if position.isNumeric { suspendedTime = position }
        guard surface.playerLayer.isReadyForDisplay, let item = player.currentItem else {
            releasePlayer()
            return
        }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        freezeTask = Task { [weak self, weak player] in
            // Keep the paused frame in the player if the asset cannot supply a still.
            guard let result = try? await generator.image(at: position), !Task.isCancelled,
                  let self, let player, self.player === player, !self.wantsPlayback else { return }
            self.surface.showStill(result.image)
            self.releasePlayer()
            self.freezeTask = nil
        }
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value
        onStatus?()
    }

    private func releasePlayer() {
        observations.removeAll()
        itemObservation = nil
        if let token = errorToken {
            NotificationCenter.default.removeObserver(token)
            errorToken = nil
        }
        surface.playerLayer.player = nil
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        player = nil
        looper = nil
        access = nil
        if let url = cacheURL, let cache { Task { await cache.release(url) } }
        cacheURL = nil
    }

    private func fail(_ text: String) {
        hasFailed = true
        freezeTask?.cancel()
        freezeTask = nil
        releasePlayer()
        setStatus(text)
    }

    func stop() {
        prepareTask?.cancel()
        prepareTask = nil
        freezeTask?.cancel()
        freezeTask = nil
        releasePlayer()
        surface.showStill(nil)
        window.close()
    }
}

@MainActor
final class DesktopEngine: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var suspension: String?
    @Published private(set) var onBattery = false
    @Published private(set) var batteryPercent = 100
    @Published private(set) var lowPower = false
    private(set) var sessions: [String: DesktopPlayback] = [:]
    private let library: LibraryStore
    private let coveredDisplays: ([DisplayInfo]) -> Set<String>
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerTimer: Timer?
    private var coverageTimer: Timer?
    private var memorySource: DispatchSourceMemoryPressure?
    private var systemSleeping = false, displaySleeping = false, sessionInactive = false, screenLocked = false
    private var memoryCritical = false, holdAfterInterruption = false
    private var activationEnabled: Bool
    private var stopped = false
    private var restartRequested = Set<String>()

    init(library: LibraryStore, coveredDisplays: @escaping ([DisplayInfo]) -> Set<String> = DesktopCoverage.coveredDisplays) {
        self.library = library
        self.coveredDisplays = coveredDisplays
        activationEnabled = library.preferences.restoreOnLaunch
        displays = DisplayInfo.connected()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(.NSApplicationDidChangeScreenParameters, center: .default) { $0.refreshDisplays() }
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { engine in
            engine.refreshDisplays()
            for session in engine.sessions.values { session.window.orderFrontRegardless() }
        }
        observe(NSWorkspace.didActivateApplicationNotification, center: workspace) { $0.refreshCoverage() }
        observe(NSWorkspace.didMountNotification, center: workspace) { engine in
            for (id, session) in engine.sessions where session.hasFailed { engine.restartRequested.insert(id) }
            engine.synchronize()
        }
        observe(NSWorkspace.willSleepNotification, center: workspace) { $0.systemSleeping = true; $0.interrupted() }
        observe(NSWorkspace.didWakeNotification, center: workspace) { $0.systemSleeping = false; $0.refreshDisplays() }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.displaySleeping = true; $0.interrupted() }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.displaySleeping = false; $0.synchronize() }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { $0.sessionInactive = true; $0.interrupted() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { $0.sessionInactive = false; $0.synchronize() }
        // These advisory lock notifications are widely used but not a documented Apple contract.
        // Public sleep and session notifications remain the fallback; no private API is called.
        observe(Notification.Name("com.apple.screenIsLocked"), center: DistributedNotificationCenter.default()) { $0.screenLocked = true; $0.interrupted() }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: DistributedNotificationCenter.default()) { $0.screenLocked = false; $0.synchronize() }
        observe(Notification.Name.NSProcessInfoPowerStateDidChange, center: .default) { $0.pollPower() }
        observe(ProcessInfo.thermalStateDidChangeNotification, center: .default) { $0.synchronize() }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let data = self.memorySource?.data
                self.memoryCritical = data?.contains(.critical) == true || data?.contains(.warning) == true
                if self.memoryCritical { WallpaperImages.clearThumbnails() }
                self.interrupted()
            }
        }
        source.resume(); memorySource = source
        powerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollPower() } }
        powerTimer?.tolerance = 15
        library.onChange = { [weak self] in self?.synchronize() }
        pollPower(); synchronize()
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping (DesktopEngine) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in if let self { action(self) } } }
        tokens.append((center, token))
    }
    private func interrupted() { synchronize() }
    func refreshDisplays() {
        displays = DisplayInfo.connected(); synchronize()
    }
    func pollPower() {
        let wasLowPower = lowPower
        let wasOnBattery = onBattery
        let wasLowBattery = batteryPercent <= 15
        let lowPowerEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPowerEnabled != lowPower { lowPower = lowPowerEnabled }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            var usingBattery = false; var percent = 100
            for source in sources {
                guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
                if data[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue { usingBattery = true }
                if let current = data[kIOPSCurrentCapacityKey] as? Int, let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0 { percent = current * 100 / maximum }
            }
            if onBattery != usingBattery { onBattery = usingBattery }
            if batteryPercent != percent { batteryPercent = percent }
        }
        if lowPower != wasLowPower || onBattery != wasOnBattery || (batteryPercent <= 15) != wasLowBattery { synchronize() }
    }
    func synchronize() {
        guard !stopped else { return }
        for id in restartRequested { sessions.removeValue(forKey: id)?.stop() }
        restartRequested.removeAll()
        let settings = library.preferences
        var reason: String?
        if systemSleeping { reason = "Mac asleep" }
        else if screenLocked || sessionInactive { reason = "Mac locked" }
        else if displaySleeping && settings.pauseOnDisplaySleep { reason = "Display asleep" }
        else if memoryCritical { reason = "Memory pressure — playback suspended" }
        else if ProcessInfo.processInfo.thermalState == .critical || (settings.batteryOptimization && ProcessInfo.processInfo.thermalState == .serious) { reason = "Cooling down" }
        else if settings.batteryOptimization && onBattery && (batteryPercent <= 15 || settings.pauseOnBattery || settings.profile == .batterySaver) { reason = "Saving battery" }
        if reason != nil && !settings.autoResume { holdAfterInterruption = true }
        if reason == nil && holdAfterInterruption { reason = "Press Play to resume" }
        if suspension != reason { suspension = reason }
        let valid = Set(displays.map(\.id))
        for id in Array(sessions.keys) where !valid.contains(id) || library.state.assignments[id] == nil || reason != nil || !activationEnabled {
            sessions.removeValue(forKey: id)?.stop()
        }
        guard reason == nil, activationEnabled else {
            refreshCoverage()
            let updated = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, library.state.assignments[$0.id] == nil ? "System wallpaper" : (reason ?? "Press Apply to restore")) })
            if statuses != updated { statuses = updated }
            return
        }
        let policy = RenderPolicy.make(settings, lowPower: lowPower, onBattery: onBattery)
        for display in displays {
            guard let id = library.state.assignments[display.id], let wallpaper = library.wallpapers.first(where: { $0.id == id }), let screen = display.screen else {
                sessions.removeValue(forKey: display.id)?.stop(); continue
            }
            let existing = sessions[display.id]
            if existing?.wallpaper.id != wallpaper.id || existing?.wallpaper.sourcePath != wallpaper.sourcePath || existing?.wallpaper.metadata != wallpaper.metadata || existing?.policy != policy {
                sessions.removeValue(forKey: display.id)?.stop()
                let session = DesktopPlayback(wallpaper: wallpaper, policy: policy, screen: screen, thumbnail: library.thumbnailURL(wallpaper))
                session.onStatus = { [weak self] in self?.publishStatuses() }
                sessions[display.id] = session
                session.start(cache: library.proxyCache) { [weak library] access in
                    // Deferring bookmark persistence avoids re-entering synchronization during setup.
                    Task { @MainActor in library?.refreshBookmark(wallpaper, access: access) }
                }
            }
            if let session = sessions[display.id] {
                if session.window.frame != screen.frame { session.window.setFrame(screen.frame, display: true) }
                session.surface.fit = library.state.fit(for: display.id)
            }
        }
        refreshCoverage()
        publishStatuses()
    }

    private func refreshCoverage() {
        let animatedDisplays = displays.filter { display in
            guard let session = sessions[display.id] else { return false }
            return session.wallpaper.metadata.isVideo && !session.hasFailed
        }
        guard !library.preferences.userPaused, !animatedDisplays.isEmpty else {
            coverageTimer?.invalidate()
            coverageTimer = nil
            if library.preferences.userPaused {
                for display in animatedDisplays { sessions[display.id]?.updatePlayback(playing: false, covered: false) }
            }
            return
        }
        if coverageTimer == nil {
            // Polling also catches resizing the current app, which sends no activation notification.
            coverageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshCoverage() }
            }
            coverageTimer?.tolerance = 0.4
        }
        let covered = coveredDisplays(animatedDisplays)
        for display in animatedDisplays {
            sessions[display.id]?.updatePlayback(playing: true, covered: covered.contains(display.id))
        }
    }
    private func publishStatuses() {
        let updated = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, sessions[$0.id]?.status ?? "System wallpaper") })
        if statuses != updated { statuses = updated }
    }
    func apply(_ wallpaper: Wallpaper, to ids: [String], fit: WallpaperFit? = nil) {
        guard !ids.isEmpty else { library.message = "No connected display is available."; return }
        activationEnabled = true; holdAfterInterruption = false
        restartRequested.formUnion(ids)
        library.assign(wallpaper.id, displays: ids, fit: fit)
        restartRequested.removeAll()
    }
    func togglePlayback() {
        if suspension != nil { holdAfterInterruption = false; library.setPreferences { $0.userPaused = false }; synchronize() }
        else { library.setPreferences { $0.userPaused.toggle() } }
    }
    func restoreOriginal(_ ids: [String]? = nil) { library.restore(displays: ids ?? displays.map(\.id)) }
    func step(_ offset: Int, displayID: String) {
        let items = library.wallpapers
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == library.state.assignments[displayID] } ?? (offset > 0 ? -1 : 0)
        apply(items[(current + offset + items.count) % items.count], to: [displayID])
    }
    func stop() {
        stopped = true
        library.onChange = nil
        for session in sessions.values { session.stop() }; sessions.removeAll()
        powerTimer?.invalidate(); powerTimer = nil
        coverageTimer?.invalidate(); coverageTimer = nil
        memorySource?.cancel(); memorySource = nil
        for (center, token) in tokens { center.removeObserver(token) }; tokens.removeAll()
        statuses.removeAll()
    }
}

extension Notification.Name {
    static let NSApplicationDidChangeScreenParameters = NSApplication.didChangeScreenParametersNotification
}
