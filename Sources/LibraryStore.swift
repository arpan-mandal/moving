import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var state: LibraryState
    @Published var message: String?
    @Published private(set) var isImporting = false
    @Published private(set) var readOnly = false
    let root: URL
    let thumbnailDirectory: URL
    let proxyCache: ProxyCache
    private let repository: StateRepository
    var onChange: (() -> Void)?

    init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Keep the original data directory so the rename also works as an in-place upgrade.
        self.root = root ?? support.appendingPathComponent("Motion", isDirectory: true)
        thumbnailDirectory = self.root.appendingPathComponent("Thumbnails", isDirectory: true)
        proxyCache = ProxyCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("com.motion.wallpaper/Proxies"))
        repository = StateRepository(url: self.root.appendingPathComponent("library.json"))
        state = LibraryState()
        do {
            try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            let loaded = try repository.load(); state = loaded.0
            if loaded.recovered { message = "Recovered the library from its backup." }
        } catch {
            readOnly = true
            message = "Your saved library could not be opened. It has been preserved. \(error.localizedDescription)"
        }
    }
    var wallpapers: [Wallpaper] { state.wallpapers }
    var preferences: Preferences { state.preferences }
    func thumbnailURL(_ item: Wallpaper) -> URL { thumbnailDirectory.appendingPathComponent(item.thumbnailName) }

    @discardableResult
    func change(_ edit: (inout LibraryState) -> Void) -> Bool {
        guard !readOnly else { message = "The library is read-only."; return false }
        var updated = state; edit(&updated)
        do { try repository.save(updated); state = updated; onChange?(); return true }
        catch { message = MotionError.persistence(error.localizedDescription).localizedDescription; return false }
    }
    func setPreferences(_ edit: (inout Preferences) -> Void) { change { edit(&$0.preferences) } }
    func setFavorite(_ id: UUID) { change { state in if let i = state.wallpapers.firstIndex(where: { $0.id == id }) { state.wallpapers[i].favorite.toggle() } } }
    func rename(_ id: UUID, to value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        change { state in if let i = state.wallpapers.firstIndex(where: { $0.id == id }) { state.wallpapers[i].name = String(name.prefix(120)) } }
    }
    func setCollection(_ id: UUID, to collection: String) {
        change { state in if let i = state.wallpapers.firstIndex(where: { $0.id == id }) { state.wallpapers[i].collection = collection } }
    }
    func addCollection(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !state.collections.contains(trimmed) else { return }
        change { $0.collections.append(String(trimmed.prefix(60))) }
    }
    func remove(_ item: Wallpaper) {
        guard !item.isBundled else { return }
        if change({ state in state.wallpapers.removeAll { $0.id == item.id }; state.assignments = state.assignments.filter { $0.value != item.id } }) {
            WallpaperImages.invalidate(thumbnailURL(item))
            try? FileManager.default.removeItem(at: thumbnailURL(item))
        }
    }
    func assign(_ id: UUID, displays: [String], fit: WallpaperFit? = nil) {
        guard state.wallpapers.contains(where: { $0.id == id }) else { return }
        change { state in
            for display in displays {
                state.assignments[display] = id
                if let fit { state.setFit(fit, for: display) }
            }
            if let i = state.wallpapers.firstIndex(where: { $0.id == id }) { state.wallpapers[i].lastUsed = Date() }
        }
    }
    func setFit(_ fit: WallpaperFit, for display: String) {
        change { $0.setFit(fit, for: display) }
    }
    func restore(displays: [String]) { change { state in for display in displays { state.assignments.removeValue(forKey: display) } } }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .video, .image]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in await self?.importURLs(panel.urls) }
        }
    }
    func importURLs(_ urls: [URL]) async {
        guard !isImporting, !readOnly else { return }
        isImporting = true; defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL else { throw MotionError.invalidMedia(url.lastPathComponent) }
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                // Resolve bookmarks too: Finder moves may have changed the stored source path.
                let duplicate = wallpapers.contains { item in
                    if item.sourcePath == canonical { return true }
                    return (try? ScopedMediaAccess(item).url.resolvingSymlinksInPath().standardizedFileURL.path) == canonical
                }
                if duplicate { continue }
                let inspected = try await MediaInspector.inspect(url)
                let bookmark = try MediaBookmark.create(for: url)
                let item = Wallpaper(id: UUID(), name: url.deletingPathExtension().lastPathComponent, bookmark: bookmark, sourcePath: canonical, metadata: inspected.metadata)
                try MediaInspector.writeThumbnail(inspected.thumbnail, to: thumbnailURL(item))
                if !change({ $0.wallpapers.append(item) }) { try? FileManager.default.removeItem(at: thumbnailURL(item)) }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { message = failures.joined(separator: "\n\n") }
    }
    func seedBundledWallpapers() async {
        guard !readOnly else { return }
        let demos = [("36AD92B0-8BD0-43E2-BC37-015E77D2B001", "Aurora Drift.mp4", "Abstract"), ("36AD92B0-8BD0-43E2-BC37-015E77D2B002", "Solar Tide.mp4", "Nature"), ("36AD92B0-8BD0-43E2-BC37-015E77D2B003", "Still Horizon.jpg", "Nature")]
        for (uuid, file, category) in demos where !wallpapers.contains(where: { $0.bundledFile == file }) {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Wallpapers") else { message = "Bundled wallpaper \(file) is missing. Reinstall Moving."; continue }
            do {
                let inspected = try await MediaInspector.inspect(url)
                let item = Wallpaper(id: UUID(uuidString: uuid)!, name: url.deletingPathExtension().lastPathComponent, sourcePath: url.path, bundledFile: file, metadata: inspected.metadata, collection: category)
                try MediaInspector.writeThumbnail(inspected.thumbnail, to: thumbnailURL(item))
                change { $0.wallpapers.append(item) }
            } catch { message = error.localizedDescription }
        }
    }
    func locate(_ item: Wallpaper) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .video, .image]
        panel.message = "Locate the source for \(item.name)"; panel.prompt = "Locate"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.relink(item, url: url) }
        }
    }
    func relink(_ item: Wallpaper, url: URL) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let inspected = try await MediaInspector.inspect(url)
            let bookmark = try MediaBookmark.create(for: url)
            try MediaInspector.writeThumbnail(inspected.thumbnail, to: thumbnailURL(item))
            change { state in
                if let i = state.wallpapers.firstIndex(where: { $0.id == item.id }) {
                    state.wallpapers[i].bookmark = bookmark; state.wallpapers[i].sourcePath = url.path; state.wallpapers[i].metadata = inspected.metadata
                }
            }
        } catch { message = error.localizedDescription }
    }
    func refreshBookmark(_ item: Wallpaper, access: ScopedMediaAccess) {
        guard let bookmark = access.refreshedBookmark else { return }
        change { state in if let i = state.wallpapers.firstIndex(where: { $0.id == item.id }) { state.wallpapers[i].bookmark = bookmark; state.wallpapers[i].sourcePath = access.url.path } }
    }
}
