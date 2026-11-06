import AVFoundation
import Foundation

@main
struct ProxyBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { return }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let original = try await MediaInspector.inspect(source).metadata
        let clock = ContinuousClock()
        let configurations = [("Balanced on AC", false), ("Balanced with battery limits", true)]
        let settings = Preferences()
        var rows: [[String: Any]] = []
        for (name, onBattery) in configurations {
            for run in 1...3 {
                let cache = ProxyCache(directory: root.appendingPathComponent(UUID().uuidString))
                let policy = RenderPolicy.make(settings, lowPower: false, onBattery: onBattery)
                let coldStart = clock.now
                let output = try await cache.playbackURL(source: source, metadata: original, policy: policy)
                let cold = coldStart.duration(to: clock.now)
                await cache.release(output)
                let warmStart = clock.now
                let cached = try await cache.playbackURL(source: source, metadata: original, policy: policy)
                let warm = warmStart.duration(to: clock.now)
                guard cached == output && cached != source else { throw CocoaError(.fileReadUnknown) }
                let result = try await MediaInspector.inspect(cached).metadata
                await cache.release(cached)
                await cache.clear()
                rows.append([
                    "policy": name, "trial": run, "coldSeconds": seconds(cold), "warmLookupSeconds": seconds(warm),
                    "width": result.width, "height": result.height, "fps": result.frameRate, "sizeBytes": result.fileSize
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
