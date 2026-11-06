import AppKit
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum MediaBookmark {
    static func create(for url: URL) throws -> Data {
        // NSOpenPanel grants read-only access under our sandbox entitlement.
        // Omitting this flag requests write scope and fails for external files.
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

final class ScopedMediaAccess {
    let url: URL
    let refreshedBookmark: Data?
    private let scoped: Bool
    init(_ wallpaper: Wallpaper, bundle: Bundle = .main) throws {
        if let file = wallpaper.bundledFile {
            guard let url = bundle.url(forResource: file, withExtension: nil, subdirectory: "Wallpapers") else { throw MotionError.missingFile(wallpaper.name) }
            self.url = url; scoped = false; refreshedBookmark = nil
        } else {
            var stale = false
            if let bookmark = wallpaper.bookmark {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            } else { url = URL(fileURLWithPath: wallpaper.sourcePath) }
            scoped = url.startAccessingSecurityScopedResource()
            refreshedBookmark = stale ? try? MediaBookmark.create(for: url) : nil
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw MotionError.missingFile(wallpaper.name)
        }
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct InspectedMedia {
    let metadata: MediaMetadata
    let thumbnail: CGImage
}

enum WallpaperImages {
    private static let thumbnails: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.countLimit = 24
        return cache
    }()

    static func thumbnail(at url: URL) -> NSImage? {
        let key = url as NSURL
        if let image = thumbnails.object(forKey: key) { return image }
        guard let pixels = downsample(url, longestEdge: 600) else { return nil }
        let image = NSImage(cgImage: pixels, size: .zero)
        thumbnails.setObject(image, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return image
    }

    static func preview(at url: URL) -> NSImage? {
        downsample(url, longestEdge: 1600).map { NSImage(cgImage: $0, size: .zero) }
    }

    static func invalidate(_ url: URL) { thumbnails.removeObject(forKey: url as NSURL) }
    static func clearThumbnails() { thumbnails.removeAllObjects() }

    private static func downsample(_ url: URL, longestEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

enum MediaInspector {
    static func inspect(_ url: URL) async throws -> InspectedMedia {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw MotionError.invalidMedia(url.lastPathComponent) }
        let size = Int64(values.fileSize ?? 0)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 960, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let swapped = orientation >= 5 && orientation <= 8
            return InspectedMedia(metadata: MediaMetadata(width: swapped ? height : width, height: swapped ? width : height, duration: 0, frameRate: 0, fileSize: size, isVideo: false), thumbnail: thumbnail)
        }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), !(try await asset.load(.hasProtectedContent)),
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw MotionError.invalidMedia(url.lastPathComponent) }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let dimensions = CGRect(origin: .zero, size: natural).applying(transform).size
        let duration = try await asset.load(.duration).seconds
        let fps = try await track.load(.nominalFrameRate)
        guard duration.isFinite, duration > 0, abs(dimensions.width) > 0, abs(dimensions.height) > 0 else { throw MotionError.invalidMedia(url.lastPathComponent) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 600)
        let (thumbnail, _) = try await generator.image(at: .zero)
        return InspectedMedia(metadata: MediaMetadata(width: Int(abs(dimensions.width)), height: Int(abs(dimensions.height)), duration: duration, frameRate: Double(fps), fileSize: size, isVideo: true), thumbnail: thumbnail)
    }
    static func writeThumbnail(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        WallpaperImages.invalidate(url)
    }
}

// AVAssetExportSession.cancelExport is designed to interrupt an in-flight export.
// Only that cancellation operation crosses isolation; all configuration stays in ProxyCache.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

actor ProxyCache {
    let directory: URL
    private struct Job { let task: Task<URL, Error>; var clients: Set<UUID> }
    private var jobs: [String: Job] = [:]
    private var leases: [String: Int] = [:]
    private var lastExport: Task<URL, Error>?
    init(directory: URL) { self.directory = directory }
    func playbackURL(source: URL, metadata: MediaMetadata, policy: RenderPolicy) async throws -> URL {
        try Task.checkCancellation()
        guard policy.needsProxy(metadata) else { return source }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modified = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let signature = "\(source.path)|\(modified.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(modified.fileSize ?? 0)|\(policy.maxDimension)|\(policy.fps)"
        let key = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let output = directory.appendingPathComponent(key + ".mp4")
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
            leases[output.lastPathComponent, default: 0] += 1
            return output
        }
        let client = UUID()
        let task: Task<URL, Error>
        if var job = jobs[key] {
            job.clients.insert(client); jobs[key] = job; task = job.task
        } else {
            let previous = lastExport
            task = Task {
                if let previous { _ = try? await previous.value }
                try Task.checkCancellation()
                return try await self.createProxy(source: source, metadata: metadata, policy: policy, output: output)
            }
            lastExport = task
            jobs[key] = Job(task: task, clients: [client])
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                Task { await self.release(key: key, client: client) }
            })
            release(key: key, client: client)
            try Task.checkCancellation()
            leases[result.lastPathComponent, default: 0] += 1
            return result
        } catch { release(key: key, client: client); throw error }
    }
    private func release(key: String, client: UUID) {
        guard var job = jobs[key], job.clients.remove(client) != nil else { return }
        if job.clients.isEmpty { job.task.cancel(); jobs.removeValue(forKey: key) }
        else { jobs[key] = job }
    }
    private func createProxy(source: URL, metadata: MediaMetadata, policy: RenderPolicy, output: URL) async throws -> URL {
        let key = output.deletingPathExtension().lastPathComponent
        let temporary = directory.appendingPathComponent(key + "-" + UUID().uuidString + ".partial.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw MotionError.invalidMedia(source.lastPathComponent) }
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let original = rect.size
        let factor = policy.maxDimension == 0 ? 1 : min(1, CGFloat(policy.maxDimension) / max(original.width, original.height))
        let scaled = CGSize(width: max(2, floor(original.width * factor / 2) * 2), height: max(2, floor(original.height * factor / 2) * 2))
        let duration = try await asset.load(.duration)
        let composition = AVMutableVideoComposition()
        composition.renderSize = scaled
        composition.frameDuration = CMTime(value: 1, timescale: Int32(min(policy.fps, max(1, Int(metadata.frameRate.rounded())))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let normalized = transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        layer.setTransform(normalized.concatenating(CGAffineTransform(scaleX: scaled.width / original.width, y: scaled.height / original.height)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw MotionError.invalidMedia(source.lastPathComponent) }
        export.videoComposition = composition
        export.outputURL = temporary; export.outputFileType = .mp4
        try Task.checkCancellation()
        let cancellation = ExportCancellation(export)
        await withTaskCancellationHandler(operation: { await export.export() }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
        guard export.status == .completed else { throw export.error ?? MotionError.invalidMedia(source.lastPathComponent) }
        try FileManager.default.moveItem(at: temporary, to: output)
        prune(excluding: output)
        return output
    }
    private func prune(excluding active: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let entries = files.filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.contains("partial") }.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        for entry in entries where total > 1_073_741_824 && entry.0 != active && leases[entry.0.lastPathComponent] == nil && jobs[entry.0.deletingPathExtension().lastPathComponent] == nil {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { total -= entry.2 }
        }
    }
    func release(_ url: URL) {
        guard let count = leases[url.lastPathComponent] else { return }
        if count <= 1 { leases.removeValue(forKey: url.lastPathComponent) } else { leases[url.lastPathComponent] = count - 1 }
    }
    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where leases[file.lastPathComponent] == nil && jobs[file.deletingPathExtension().lastPathComponent] == nil && !file.lastPathComponent.contains("partial") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
