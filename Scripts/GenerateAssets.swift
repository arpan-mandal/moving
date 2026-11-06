import AppKit
import AVFoundation
import CoreVideo

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let wallpapers = root.appendingPathComponent("Resources/Wallpapers")
try FileManager.default.createDirectory(at: wallpapers, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func gradient(_ context: CGContext, colors: [CGColor], start: CGPoint, end: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func scene(_ c: CGContext, width: Int, height: Int, phase: Double, solar: Bool) {
    let w = CGFloat(width), h = CGFloat(height)
    gradient(c, colors: solar ? [color(0.015,0.035,0.10), color(0.32,0.19,0.30), color(0.91,0.53,0.35)] : [color(0.02,0.03,0.09), color(0.035,0.13,0.20), color(0.10,0.26,0.29)], start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h))
    if solar {
        c.setFillColor(color(1,0.75,0.48))
        c.fillEllipse(in: CGRect(x: w*0.64, y: h*0.47, width: h*0.19, height: h*0.19))
    }
    for band in (0..<9).reversed() {
        let b = CGFloat(band)
        let path = CGMutablePath(); path.move(to: CGPoint(x: -10, y: h+10)); path.addLine(to: CGPoint(x: -10, y: h * 0.5))
        for x in stride(from: CGFloat(-10), through: w+10, by: 6) {
            let fraction = x / w
            let wave = sin(fraction * 4.5 + CGFloat(phase) + b * 0.49) * h * 0.08 + cos(fraction * 8 - CGFloat(phase) + b * 0.4) * h * 0.035
            let y = h * (0.51 + b * 0.045) + wave
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: w+10, y: h+10)); path.closeSubpath()
        c.saveGState(); c.addPath(path); c.clip()
        let top = solar ? color(0.12+b*0.025,0.14+b*0.017,0.24+b*0.016) : color(0.04+b*0.008,0.20+b*0.035,0.28+b*0.038)
        gradient(c, colors: [top, color(0.015,0.025,0.065)], start: CGPoint(x: 0,y:h*0.4), end: CGPoint(x: w*0.5,y:h*1.2))
        c.restoreGState()
    }
    // Fine stars stay fixed while the ribbons complete an exact periodic loop.
    for index in 0..<55 {
        let x = CGFloat((index * 197 + 53) % width), y = CGFloat((index * 89 + 17) % max(1, height/3))
        c.setFillColor(color(0.8,0.91,1, CGFloat(index % 5 + 1) * 0.10))
        c.fillEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
    }
}
func bitmap(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let still = bitmap(width: 2560, height: 1440)
still.translateBy(x: 0, y: 1440); still.scaleBy(x: 1, y: -1)
scene(still, width: 2560, height: 1440, phase: 0, solar: true)
let rep = NSBitmapImageRep(cgImage: still.makeImage()!)
try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!.write(to: wallpapers.appendingPathComponent("Still Horizon.jpg"))

for solar in [false, true] {
    let output = wallpapers.appendingPathComponent(solar ? "Solar Tide.mp4" : "Aurora Drift.mp4")
    try? FileManager.default.removeItem(at: output)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let width = 1280, height = 720, fps = 24, frames = 144
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000, AVVideoMaxKeyFrameIntervalKey: fps*2]])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let c = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        scene(c, width: width, height: height, phase: Double(frame)/Double(frames)*2*Double.pi, solar: solar)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard adapter.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error ?? NSError(domain: "MovingAssets", code: 1) }
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0); writer.finishWriting { finished.signal() }; finished.wait()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "MovingAssets", code: 2) }
    print("Generated \(output.lastPathComponent)")
}
