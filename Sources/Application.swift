import AppKit
import SwiftUI

@MainActor
final class NavigationModel: ObservableObject { @Published var section = LibrarySection.library }

struct RootView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DesktopEngine
    @ObservedObject var navigation: NavigationModel
    var body: some View { MainView(library: library, engine: engine, section: $navigation.section) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private(set) var library: LibraryStore!
    private(set) var engine: DesktopEngine!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var popoverEventMonitors: [Any] = []
    private var mainWindow: NSWindow?
    private let navigation = NavigationModel()
    private let smoke = CommandLine.arguments.contains("--smoke-test")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let testRoot = smoke ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Moving-Smoke-\(ProcessInfo.processInfo.processIdentifier)") : nil
        library = LibraryStore(root: testRoot)
        engine = DesktopEngine(library: library, coveredDisplays: smoke ? { _ in [] } : DesktopCoverage.coveredDisplays)
        makeMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let icon = MovingMark.image?.copy() as? NSImage {
                icon.size = NSSize(width: 22, height: 22)
                icon.isTemplate = true
                icon.accessibilityDescription = "Moving"
                button.image = icon
            } else {
                button.title = "M"
            }
            button.toolTip = "Moving"
            button.target = self; button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuPopover(
            library: library,
            engine: engine,
            openWindow: { [weak self] section in self?.popover.performClose(nil); self?.showWindow(section) },
            quit: { NSApp.terminate(nil) }
        ))
        Task { @MainActor in
            await library.seedBundledWallpapers()
            if smoke { await runSmokeTest() }
            else if !library.preferences.startMinimized { showWindow(.library) }
        }
    }
    private func makeMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        appMenu.addItem(withTitle: "About Moving", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Open Library", action: #selector(openLibrary), keyEquivalent: "l")
        appMenu.addItem(withTitle: "Import Wallpaper…", action: #selector(importWallpaper), keyEquivalent: "i")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Moving", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit"); let editItem = NSMenuItem(); editItem.submenu = edit; menu.addItem(editItem)
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        NSApp.mainMenu = menu
    }
    @objc private func openLibrary() { showWindow(.library) }
    @objc private func importWallpaper() { library.chooseImport() }
    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            if let content = popover.contentViewController?.view {
                // Give AppKit the final SwiftUI size before it places the popover.
                content.layoutSubtreeIfNeeded()
                popover.contentSize = content.fittingSize
            }
            let bottomEdge: NSRectEdge = button.isFlipped ? .maxY : .minY
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: bottomEdge)
            popover.contentViewController?.view.window?.makeKey()
            monitorPopoverEvents()
        }
    }

    private func monitorPopoverEvents() {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseDown.union(.keyDown), handler: { [weak self] event in
            guard let self, let window = self.popover.contentViewController?.view.window else { return event }
            if event.type == .keyDown {
                guard window.isKeyWindow, event.charactersIgnoringModifiers == "\u{1b}" else { return event }
                self.popover.performClose(nil)
                return nil
            }
            // Let the status item handle its own toggle, and let outside clicks reach their target.
            if event.window !== window && event.window !== self.statusItem.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }) {
            popoverEventMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            self?.popover.performClose(nil)
        }) {
            popoverEventMonitors.append(global)
        }
    }

    func popoverWillClose(_ notification: Notification) {
        popoverEventMonitors.forEach(NSEvent.removeMonitor)
        popoverEventMonitors.removeAll()
    }

    func showWindow(_ section: LibrarySection) {
        navigation.section = section
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: RootView(library: library, engine: engine, navigation: navigation))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Moving"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.09, green: 0.10, blue: 0.09, alpha: 1)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 444))
            window.contentMinSize = NSSize(width: 690, height: 430)
            window.isReleasedWhenClosed = false
            window.delegate = self
            if smoke {
                window.center()
            } else {
                if !window.setFrameUsingName("MovingLibrary") { window.center() }
                window.setFrameAutosaveName("MovingLibrary")
            }
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(.library); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { engine?.stop() }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        mainWindow = nil
        if !popover.isShown { WallpaperImages.clearThumbnails() }
    }

    private func measureMenuPopover() async -> [String: Any] {
        guard let button = statusItem.button, let anchorWindow = button.window,
              let screen = anchorWindow.screen else { return ["shown": false] }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        try? await Task.sleep(for: .milliseconds(350))
        guard let content = popover.contentViewController?.view, let window = content.window else {
            return ["shown": false]
        }
        let contentFrame = window.convertToScreen(content.convert(content.bounds, to: nil))
        return [
            "shown": popover.isShown && window.isVisible,
            "focused": NSApp.isActive && window.isKeyWindow,
            "onScreen": screen.frame.insetBy(dx: -1, dy: -1).contains(window.frame),
            "belowIcon": contentFrame.maxY <= anchor.minY + 2,
            "anchorIsFlipped": button.isFlipped,
            "anchor": NSStringFromRect(anchor),
            "screen": NSStringFromRect(screen.frame),
            "window": NSStringFromRect(window.frame),
            "content": NSStringFromRect(contentFrame),
        ]
    }

    private func runSmokeTest() async {
        let reportURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Moving-smoke-report.json")
        var results: [String: Any] = ["displayCount": engine.displays.count, "bundledCount": library.wallpapers.count, "lsUIElement": Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false]
        togglePopover()
        results["emptyMenuPopover"] = await measureMenuPopover()
        let original = engine.displays.compactMap { $0.screen }.map { NSWorkspace.shared.desktopImageURL(for: $0)?.absoluteString ?? "" }
        if let demo = library.wallpapers.first(where: { $0.metadata.isVideo }),
           let source = try? ScopedMediaAccess(demo) {
            let imported = library.root.appendingPathComponent("Smoke Import.mp4")
            try? FileManager.default.copyItem(at: source.url, to: imported)
            await library.importURLs([imported])
            results["localMP4Imported"] = library.wallpapers.contains { !$0.isBundled && $0.metadata.isVideo }
        }
        if let item = library.wallpapers.first(where: { !$0.isBundled && $0.metadata.isVideo }), let display = engine.displays.first {
            engine.apply(item, to: [display.id])
            results["expandedMenuPopover"] = await measureMenuPopover()
            popover.close()
            try? await Task.sleep(for: .seconds(7))
            if let session = engine.sessions[display.id] {
                togglePopover()
                results["assignedMenuPopover"] = await measureMenuPopover()
                popover.close()
                results["windowLevel"] = session.window.level.rawValue
                results["belowIcons"] = session.window.level.rawValue < CGWindowLevelForKey(.desktopIconWindow)
                results["clickThrough"] = session.window.ignoresMouseEvents
                results["allSpaces"] = session.window.collectionBehavior.contains(.canJoinAllSpaces)
                results["playerRate"] = session.player?.rate ?? -1
                results["muted"] = session.player?.isMuted ?? false
                results["readyForDisplay"] = session.surface.playerLayer.isReadyForDisplay
                results["status"] = session.status
                results["timeAdvanced"] = (session.player?.currentTime().seconds ?? 0) > 0
                results["loopCount"] = session.looper?.loopCount ?? -1
                library.setPreferences { $0.userPaused = true }
                for _ in 0..<30 {
                    if session.player == nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                results["pauseWorks"] = session.player == nil && session.looper == nil && session.surface.stillLayer.contents != nil
                library.setPreferences { $0.userPaused = false }
                for _ in 0..<30 {
                    if session.player?.rate == 1 && session.surface.playerLayer.isReadyForDisplay { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                showWindow(.library)
                let windowSize = mainWindow?.contentView?.bounds.size ?? .zero
                results["compactWindow"] = windowSize.width > 0 && windowSize.width <= 760 && windowSize.height <= 444
                mainWindow?.close()
                results["continuesAfterWindowClose"] = session.player?.rate == 1 && mainWindow == nil
                showWindow(.library)
            }
            results["assignmentPersisted"] = LibraryStore(root: library.root).state.assignments[display.id] == item.id
            engine.restoreOriginal()
            results["restored"] = engine.sessions.isEmpty
        }
        popover.close()
        results["originalWallpaperUnchanged"] = original == engine.displays.compactMap { $0.screen }.map { NSWorkspace.shared.desktopImageURL(for: $0)?.absoluteString ?? "" }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL) }
        if let content = mainWindow?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let image = bitmap.representation(using: .png, properties: [:]) {
                try? image.write(to: reportURL.deletingLastPathComponent().appendingPathComponent("Moving-library.png"))
            }
        }
        // Leave the library open for inspection; the smoke test restores all desktop windows.
    }
}

@main
struct MovingMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) { }
    }
}
