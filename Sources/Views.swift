import SwiftUI
import UniformTypeIdentifiers

let movingAccent = Color(red: 0.78, green: 0.94, blue: 0.51)

struct MovingMark: View {
    let size: CGFloat
    static let image = Bundle.main.url(forResource: "MovingMark", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Text("M").font(.system(size: size * 0.8, weight: .bold))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(movingAccent)
        .accessibilityHidden(true)
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case library = "Wallpapers", favorites = "Favorites", recent = "Recent", installed = "Imported", displays = "Displays", settings = "Settings"
    var id: String { rawValue }
    var isLibrary: Bool { self != .displays && self != .settings }
}

struct WallpaperThumbnail: View {
    let item: Wallpaper
    let url: URL

    var body: some View {
        GeometryReader { geometry in
            if let image = WallpaperImages.thumbnail(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Rectangle().fill(.quaternary).overlay {
                    Image(systemName: item.metadata.isVideo ? "film" : "photo").foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(item.name)
    }
}

struct MainView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var engine: DesktopEngine
    @Binding var section: LibrarySection
    @State private var search = ""
    @State private var collection: String?
    @State private var selectedID: UUID?
    @State private var displayID = "all"
    @State private var fitDraft: WallpaperFit?
    @State private var preview: Wallpaper?
    @State private var renameItem: Wallpaper?
    @State private var renameText = ""
    @State private var deleteItem: Wallpaper?
    @State private var addingCollection = false
    @State private var collectionName = ""
    @State private var targeted = false

    private var filtered: [Wallpaper] {
        var items = library.wallpapers.filter { item in
            (search.isEmpty || item.name.localizedCaseInsensitiveContains(search)) &&
            (collection == nil || item.collection == collection) &&
            (section != .favorites || item.favorite) &&
            (section != .installed || !item.isBundled) &&
            (section != .recent || item.lastUsed != nil)
        }
        if section == .recent { items.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) } }
        return items
    }

    private func selection(in items: [Wallpaper]) -> Wallpaper? {
        let assigned = targetDisplays.first.flatMap { library.state.assignments[$0] }
        return items.first { $0.id == (selectedID ?? assigned) } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch section {
            case .displays: displayView
            case .settings: SettingsView(library: library, engine: engine)
            default: libraryView
            }
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.09))
        .tint(movingAccent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 690, minHeight: 430)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let data = try? await provider.loadFileURLData(), let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                await library.importURLs(urls)
            }
            return true
        }
        .overlay {
            if targeted { RoundedRectangle(cornerRadius: 10).strokeBorder(movingAccent, lineWidth: 2).padding(4).allowsHitTesting(false) }
        }
        .sheet(item: $preview) { item in PreviewSheet(item: item) }
        .alert("Moving", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK") { library.message = nil }
        } message: { Text(library.message ?? "") }
        .alert("Rename Wallpaper", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameItem = nil }
            Button("Save") {
                if let item = renameItem { library.rename(item.id, to: renameText) }
                renameItem = nil
            }
        }
        .alert("Remove Wallpaper?", isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } })) {
            Button("Cancel", role: .cancel) { deleteItem = nil }
            Button("Remove", role: .destructive) {
                if let item = deleteItem { library.remove(item) }
                deleteItem = nil
            }
        } message: { Text("The source file stays on disk.") }
        .alert("New Collection", isPresented: $addingCollection) {
            TextField("Name", text: $collectionName)
            Button("Cancel", role: .cancel) { }
            Button("Create") { library.addCollection(collectionName); collectionName = "" }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            MovingMark(size: 26)
            Text("Moving").font(.system(size: 21, weight: .semibold)).tracking(-0.7)
            Spacer()
            Picker("View", selection: Binding(get: { section.isLibrary ? .library : section }, set: { section = $0 })) {
                Text("Wallpapers").tag(LibrarySection.library)
                Text("Displays").tag(LibrarySection.displays)
                Text("Settings").tag(LibrarySection.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 254)
        }
        .padding(.horizontal, 17)
        .frame(height: 47)
    }

    private var libraryView: some View {
        let items = filtered
        let selected = selection(in: items)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Show", selection: $section) {
                    Text("All wallpapers").tag(LibrarySection.library)
                    Text("Favorites").tag(LibrarySection.favorites)
                    Text("Recent").tag(LibrarySection.recent)
                    Text("Imported").tag(LibrarySection.installed)
                }.labelsHidden().frame(width: 123)
                Picker("Collection", selection: $collection) {
                    Text("All collections").tag(nil as String?)
                    ForEach(library.state.collections, id: \.self) { name in Text(name).tag(name as String?) }
                }.labelsHidden().frame(width: 119)
                Button { addingCollection = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless).accessibilityLabel("New collection").help("New collection")
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 142)
                if library.isImporting {
                    ProgressView().controlSize(.small).frame(width: 66)
                } else {
                    Button { library.chooseImport() } label: { Label("Import", systemImage: "plus") }.keyboardShortcut("i")
                }
            }.controlSize(.small).padding(.horizontal, 14).frame(height: 39)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    if items.isEmpty {
                        Text("No wallpapers").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 265), spacing: 12)], spacing: 13) {
                            ForEach(items) { item in wallpaperTile(item, selected: selected?.id == item.id) }
                        }.padding(14)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected {
                    Divider()
                    ScrollView { inspector(selected).padding(13) }.frame(width: 237)
                }
            }.frame(maxHeight: .infinity)
        }
    }

    private func wallpaperTile(_ item: Wallpaper, selected: Bool) -> some View {
        Button { selectedID = item.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                WallpaperThumbnail(item: item, url: library.thumbnailURL(item))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        if item.metadata.isVideo {
                            Image(systemName: "play.fill").font(.system(size: 8)).padding(6)
                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                                .accessibilityLabel("Video")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? movingAccent : .white.opacity(0.12), lineWidth: selected ? 1.5 : 1)
                    }
                HStack(spacing: 5) {
                    Text(item.name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 1)
                    if item.favorite { Image(systemName: "heart.fill").foregroundStyle(movingAccent).font(.caption2) }
                }.padding(.horizontal, 1)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Preview") { preview = item }
            Button(item.favorite ? "Remove Favorite" : "Add to Favorites") { library.setFavorite(item.id) }
            Button("Rename…") { renameText = item.name; renameItem = item }
            Menu("Move to Collection") {
                ForEach(library.state.collections, id: \.self) { name in Button(name) { library.setCollection(item.id, to: name) } }
            }
            if !item.isBundled {
                Button("Locate File…") { library.locate(item) }
                Button("Show in Finder") { reveal(item) }
                Divider()
                Button("Remove…", role: .destructive) { deleteItem = item }
            }
        }
    }

    private func inspector(_ item: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { preview = item } label: {
                WallpaperThumbnail(item: item, url: library.thumbnailURL(item))
                    .frame(maxWidth: .infinity).frame(height: 112)
                    .overlay {
                        Image(systemName: item.metadata.isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold)).padding(10)
                            .background(.black.opacity(0.60), in: Circle())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Preview \(item.name)")
            HStack(alignment: .top, spacing: 5) {
                Text(item.name).font(.headline).lineLimit(2).help(item.name)
                Spacer(minLength: 0)
                Button { library.setFavorite(item.id) } label: {
                    Image(systemName: item.favorite ? "heart.fill" : "heart").frame(width: 20, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.favorite ? "Remove favorite" : "Favorite")
            }
            Text(item.metadata.summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Divider()
            if engine.displays.count > 1 {
                Picker("Display", selection: $displayID) {
                    Text("All displays").tag("all")
                    ForEach(engine.displays) { Text($0.name).tag($0.id) }
                }.labelsHidden().onChange(of: displayID) { fitDraft = nil }
            }
            Picker("Fit", selection: Binding(get: { wallpaperFit }, set: { fitDraft = $0 })) {
                ForEach(WallpaperFit.allCases) { fit in Text(fit.rawValue).tag(fit) }
            }.pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 7) {
                Button { engine.apply(item, to: targetDisplays, fit: wallpaperFit) } label: {
                    Text("Apply Wallpaper").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(targetDisplays.isEmpty)
                Button { engine.restoreOriginal(targetDisplays) } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("Restore system wallpaper").help("Restore system wallpaper")
            }
            if let reason = engine.suspension { Text(reason).font(.caption).foregroundStyle(.orange) }
            Divider()
            Picker("Collection", selection: Binding(get: { item.collection }, set: { library.setCollection(item.id, to: $0) })) {
                ForEach(library.state.collections, id: \.self) { Text($0).tag($0) }
            }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetDisplays: [String] {
        if engine.displays.contains(where: { $0.id == displayID }) { return [displayID] }
        return engine.displays.map(\.id)
    }

    private var wallpaperFit: WallpaperFit {
        fitDraft ?? targetDisplays.first.map { library.state.fit(for: $0) } ?? .crop
    }

    private func reveal(_ item: Wallpaper) {
        do {
            let scoped = try ScopedMediaAccess(item)
            NSWorkspace.shared.activateFileViewerSelecting([scoped.url])
        } catch { library.message = error.localizedDescription }
    }

    private var displayView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                ForEach(engine.displays) { display in displayRow(display) }
                if engine.displays.isEmpty { Text("No displays").foregroundStyle(.secondary) }
                if !library.state.assignments.isEmpty {
                    Button("Restore All Displays") { engine.restoreOriginal() }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity)
    }

    private func displayRow(_ display: DisplayInfo) -> some View {
        let item = library.wallpapers.first { $0.id == library.state.assignments[display.id] }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(display.name).font(.headline)
                Text(display.resolution).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(engine.statuses[display.id] ?? "System wallpaper").foregroundStyle(.secondary).lineLimit(1)
            }.font(.caption)
            HStack(spacing: 12) {
                if let item {
                    Button { preview = item } label: {
                        WallpaperThumbnail(item: item, url: library.thumbnailURL(item))
                            .frame(width: 105, height: 59).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityLabel("Preview \(display.name)")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Picker("Wallpaper", selection: Binding(get: { item?.id.uuidString ?? "system" }, set: { value in
                        if let selected = library.wallpapers.first(where: { $0.id.uuidString == value }) {
                            engine.apply(selected, to: [display.id])
                        } else { engine.restoreOriginal([display.id]) }
                    })) {
                        Text("System wallpaper").tag("system")
                        ForEach(library.wallpapers) { Text($0.name).tag($0.id.uuidString) }
                    }
                    if let item {
                        Picker("Fit", selection: Binding(get: { library.state.fit(for: display.id) }, set: { library.setFit($0, for: display.id) })) {
                            ForEach(WallpaperFit.allCases) { fit in Text(fit.rawValue).tag(fit) }
                        }
                        if engine.displays.count > 1 {
                            Button("Use on All Displays") {
                                engine.apply(item, to: engine.displays.map(\.id), fit: library.state.fit(for: display.id))
                            }
                        }
                    }
                }
            }
            Divider()
        }
    }
}

extension NSItemProvider {
    func loadFileURLData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
