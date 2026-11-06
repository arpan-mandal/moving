import Foundation

struct MediaMetadata: Codable, Equatable {
    var width: Int
    var height: Int
    var duration: Double
    var frameRate: Double
    var fileSize: Int64
    var isVideo: Bool
    var summary: String {
        let resolution = "\(width) × \(height)"
        return isVideo ? "\(resolution) · \(Int(frameRate.rounded())) fps · \(Int(duration.rounded()))s" : resolution
    }
}

struct Wallpaper: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var bookmark: Data?
    var sourcePath: String
    var bundledFile: String?
    var metadata: MediaMetadata
    var favorite = false
    var collection = "Unsorted"
    var addedAt = Date()
    var lastUsed: Date?
    var thumbnailName: String { id.uuidString + ".jpg" }
    var isBundled: Bool { bundledFile != nil }
}

enum PerformanceProfile: String, Codable, CaseIterable, Identifiable {
    case batterySaver = "Battery Saver", balanced = "Balanced", performance = "Performance"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .batterySaver: return "leaf"; case .balanced: return "circle.lefthalf.filled"; case .performance: return "bolt" }
    }
}

enum PlaybackQuality: String, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic", original = "Original", fullHD = "1080p", hd = "720p"
    var id: String { rawValue }
}

enum WallpaperFit: String, Codable, CaseIterable, Identifiable {
    case crop = "Crop"
    case stretch = "Stretch"
    var id: String { rawValue }
}

struct Preferences: Codable, Equatable {
    var startMinimized = false
    var autoResume = true
    var restoreOnLaunch = true
    var batteryOptimization = true
    var pauseOnBattery = false
    var pauseOnDisplaySleep = true
    var profile: PerformanceProfile = .balanced
    var quality: PlaybackQuality = .automatic
    var frameRate = 30
    var userPaused = false
}

struct LibraryState: Codable, Equatable {
    var version = 1
    var wallpapers: [Wallpaper] = []
    var assignments: [String: UUID] = [:]
    // Optional so libraries written before fit controls keep decoding unchanged.
    private var displayFits: [String: WallpaperFit]?
    var collections: [String] = ["Unsorted", "Nature", "Abstract"]
    var preferences = Preferences()

    func fit(for display: String) -> WallpaperFit { displayFits?[display] ?? .crop }

    mutating func setFit(_ fit: WallpaperFit, for display: String) {
        var fits = displayFits ?? [:]
        fits[display] = fit
        displayFits = fits
    }
}

struct RenderPolicy: Equatable, Hashable {
    var maxDimension: Int
    var fps: Int
    static func make(_ settings: Preferences, lowPower: Bool, onBattery: Bool = false) -> RenderPolicy {
        let reducePower = settings.batteryOptimization && (lowPower || (onBattery && settings.profile == .balanced))
        let profile: PerformanceProfile = reducePower ? .batterySaver : settings.profile
        var dimension = profile == .batterySaver ? 1280 : (profile == .balanced ? 1920 : 0)
        switch settings.quality {
        case .automatic: break
        case .original: if profile == .performance { dimension = 0 }
        case .fullHD: dimension = dimension == 0 ? 1920 : min(dimension, 1920)
        case .hd: dimension = 1280
        }
        let cap = profile == .batterySaver ? 24 : (profile == .balanced ? 30 : 60)
        return RenderPolicy(maxDimension: dimension, fps: min(max(settings.frameRate, 1), cap))
    }
    func needsProxy(_ metadata: MediaMetadata) -> Bool {
        metadata.isVideo && ((maxDimension > 0 && max(metadata.width, metadata.height) > maxDimension) || metadata.frameRate > Double(fps) + 0.1)
    }
}

enum MotionError: LocalizedError {
    case invalidMedia(String), missingFile(String), unsupportedVersion(Int), persistence(String)
    var errorDescription: String? {
        switch self {
        case .invalidMedia(let name): return "“\(name)” is not a playable video or supported image. Try an unprotected MP4, MOV, JPEG, PNG, or HEIC file."
        case .missingFile(let name): return "The source for “\(name)” is unavailable. Reconnect its drive or use Locate File."
        case .unsupportedVersion(let version): return "This library uses format \(version). Open it with a newer version of Moving."
        case .persistence(let message): return "The library could not be saved: \(message)"
        }
    }
}

struct StateRepository {
    let url: URL
    var backupURL: URL { url.appendingPathExtension("backup") }
    func load() throws -> (LibraryState, recovered: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (LibraryState(), false) }
        func decode(_ file: URL) throws -> LibraryState {
            let state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: file))
            guard state.version == 1 else { throw MotionError.unsupportedVersion(state.version) }
            return state
        }
        do { return (try decode(url), false) }
        catch MotionError.unsupportedVersion(let v) { throw MotionError.unsupportedVersion(v) }
        catch {
            // Preserve the damaged file for diagnosis rather than overwriting it.
            let damaged = url.deletingLastPathComponent().appendingPathComponent("library-damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: damaged)
            return (try decode(backupURL), true)
        }
    }
    func save(_ state: LibraryState) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? Data(contentsOf: url), (try? JSONDecoder().decode(LibraryState.self, from: previous)) != nil {
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        if !FileManager.default.fileExists(atPath: backupURL.path) { try data.write(to: backupURL, options: .atomic) }
    }
}
