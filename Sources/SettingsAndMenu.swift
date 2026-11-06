import SwiftUI
import AVKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DesktopEngine
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginBusy = false
    @State private var clearing = false
    private func preference<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { library.preferences[keyPath: key] }, set: { value in library.setPreferences { $0[keyPath: key] = value } })
    }
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    GroupBox("General") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Launch at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: updateLogin))
                                .disabled(loginBusy)
                            if loginStatus == .requiresApproval {
                                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            }
                            Toggle("Start with window closed", isOn: preference(\.startMinimized))
                            Toggle("Restore wallpapers on launch", isOn: preference(\.restoreOnLaunch))
                            Toggle("Resume after interruptions", isOn: preference(\.autoResume))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    GroupBox("Energy") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Optimize on battery", isOn: preference(\.batteryOptimization))
                            Toggle("Pause on battery", isOn: preference(\.pauseOnBattery)).disabled(!library.preferences.batteryOptimization)
                            Toggle("Pause when displays sleep", isOn: preference(\.pauseOnDisplaySleep))
                            Text(engine.onBattery ? "Battery · \(engine.batteryPercent)%" : "Power adapter")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    GroupBox("Playback") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Profile", selection: preference(\.profile)) {
                                ForEach(PerformanceProfile.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Quality", selection: preference(\.quality)) {
                                ForEach(PlaybackQuality.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Frame rate", selection: preference(\.frameRate)) {
                                ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    GroupBox("Storage") {
                        VStack(alignment: .leading, spacing: 9) {
                            Button(clearing ? "Clearing…" : "Clear Playback Cache") {
                                clearing = true
                                Task { await library.proxyCache.clear(); clearing = false }
                            }.disabled(clearing)
                            Button("Show Library Files") { NSWorkspace.shared.open(library.root) }
                            Button("Restore System Wallpapers") { engine.restoreOriginal() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    Text("Moving \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0")")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }.frame(maxWidth: .infinity)
            }.padding(16)
        }.frame(maxHeight: .infinity)
            .onAppear { loginStatus = SMAppService.mainApp.status }
    }
    private func updateLogin(_ enabled: Bool) {
        loginBusy = true
        Task { @MainActor in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                loginStatus = SMAppService.mainApp.status
            } catch { loginStatus = SMAppService.mainApp.status; library.message = "Login startup could not be changed. Install Moving in Applications first. \(error.localizedDescription)" }
            loginBusy = false
        }
    }
}

@MainActor
final class PreviewController: ObservableObject {
    @Published var player: AVQueuePlayer?
    @Published var error: String?
    @Published var still: NSImage?
    private var looper: AVPlayerLooper?
    private var access: ScopedMediaAccess?
    func start(_ item: Wallpaper) async {
        do {
            access = try ScopedMediaAccess(item)
            guard let access else { return }
            if !item.metadata.isVideo {
                still = WallpaperImages.preview(at: access.url)
                if still == nil { error = "Could not open the image." }
                return
            }
            let asset = AVURLAsset(url: access.url)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else { throw MotionError.invalidMedia(item.name) }
            try Task.checkCancellation()
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: asset))
            player = queue
            queue.play()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
    func stop() {
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        player = nil
        looper = nil
        access = nil
        still = nil
    }
}

struct PreviewSheet: View {
    let item: Wallpaper
    @StateObject private var controller = PreviewController()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Group {
                if let error = controller.error {
                    Text(error).foregroundStyle(.secondary)
                } else if item.metadata.isVideo {
                    VideoPlayer(player: controller.player)
                } else if let image = controller.still {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            }.frame(width: 610, height: 342).background(.black)
            Text(item.metadata.summary).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.frame(width: 610).preferredColorScheme(.dark)
            .task { await controller.start(item) }.onDisappear { controller.stop() }
    }
}

struct MenuPopover: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DesktopEngine
    var openWindow: (LibrarySection) -> Void
    var quit: () -> Void
    @State private var selectedDisplay = ""
    private var displayID: String { engine.displays.contains(where: { $0.id == selectedDisplay }) ? selectedDisplay : (engine.displays.first?.id ?? "") }
    private var current: Wallpaper? { library.wallpapers.first { $0.id == library.state.assignments[displayID] } }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                MovingMark(size: 19)
                Text("Moving").font(.headline)
                Spacer()
                Button { openWindow(.settings) } label: {
                    Image(systemName: "gearshape").frame(width: 22, height: 21).contentShape(Rectangle())
                }.buttonStyle(.borderless).accessibilityLabel("Settings").help("Settings")
            }
            if let current {
                HStack(spacing: 9) {
                    WallpaperThumbnail(item: current, url: library.thumbnailURL(current))
                        .frame(width: 73, height: 46).clipShape(RoundedRectangle(cornerRadius: 5))
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(engine.suspension ?? engine.statuses[displayID] ?? "Ready")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button { library.setFavorite(current.id) } label: {
                        Image(systemName: current.favorite ? "heart.fill" : "heart")
                            .frame(width: 21, height: 21).contentShape(Rectangle())
                    }.buttonStyle(.borderless).accessibilityLabel(current.favorite ? "Remove favorite" : "Favorite")
                }
            } else {
                Text("System wallpaper").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Button { engine.step(-1, displayID: displayID) } label: {
                    Label("Previous wallpaper", systemImage: "backward.end.fill")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, minHeight: 20).contentShape(Rectangle())
                }
                .help("Previous wallpaper")
                let paused = library.preferences.userPaused || engine.suspension != nil
                Button { engine.togglePlayback() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .frame(width: 24, height: 20).contentShape(Rectangle())
                }
                .accessibilityLabel(paused ? "Play" : "Pause")
                .disabled(current?.metadata.isVideo != true)
                Button { engine.step(1, displayID: displayID) } label: {
                    Label("Next wallpaper", systemImage: "forward.end.fill")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity, minHeight: 20).contentShape(Rectangle())
                }
                .help("Next wallpaper")
            }.buttonStyle(.bordered).disabled(displayID.isEmpty || library.wallpapers.isEmpty)
            Divider()
            if engine.displays.count > 1 {
                Picker("Display", selection: Binding(get: { displayID }, set: { selectedDisplay = $0 })) {
                    ForEach(engine.displays) { Text($0.name).tag($0.id) }
                }
            }
            Picker("Wallpaper", selection: Binding(get: { current?.id.uuidString ?? "system" }, set: { value in
                if let item = library.wallpapers.first(where: { $0.id.uuidString == value }) { engine.apply(item, to: [displayID]) }
                else { engine.restoreOriginal([displayID]) }
            })) {
                Text("System wallpaper").tag("system")
                ForEach(library.wallpapers) { Text($0.name).tag($0.id.uuidString) }
            }.disabled(displayID.isEmpty)
            Picker("Profile", selection: Binding(get: { library.preferences.profile }, set: { value in library.setPreferences { $0.profile = value } })) {
                ForEach(PerformanceProfile.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            HStack {
                Button("Library") { openWindow(.library) }
                Spacer()
                Button("Quit") { quit() }.keyboardShortcut("q")
            }.controlSize(.small)
        }
        .padding(13)
        .frame(width: 302)
        .preferredColorScheme(.dark)
        .tint(movingAccent)
    }
}
