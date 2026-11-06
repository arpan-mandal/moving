import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let artifacts = root.appendingPathComponent("Artifacts", isDirectory: true)
let iconSet = artifacts.appendingPathComponent("Moving.iconset", isDirectory: true)
let assetSet = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
for folder in [iconSet, assetSet] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

// The same folded ribbon is exported as a vector, a template mark and the app icon.
let ribbon = [[26, 71], [39, 30], [50, 30], [60, 46], [71, 30], [81, 30], [94, 71], [81, 71], [75, 51], [60, 69], [45, 51], [39, 71]]
let returnFold = [[60, 46], [71, 30], [81, 30], [94, 71], [81, 71], [75, 51], [60, 69]]
let leadingEdge = [[6, 71], [14, 52], [25, 52], [17, 71]]

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func bitmap(_ pixels: Int) -> CGContext {
    CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func paint(_ points: [[Int]], fill: CGColor, in context: CGContext) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: points[0][0], y: points[0][1]))
    for point in points.dropFirst() { path.addLine(to: CGPoint(x: point[0], y: point[1])) }
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(fill)
    context.fillPath()
}

func mark(in context: CGContext, monochrome: Bool) {
    paint(ribbon, fill: color(monochrome ? 0xFFFFFF : 0xD9F7A0), in: context)
    if !monochrome { paint(returnFold, fill: color(0xB7E16C), in: context) }
    paint(leadingEdge, fill: color(monochrome ? 0xFFFFFF : 0x96B76D), in: context)
}

func writePNG(_ image: CGImage, to file: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: file)
}

let template = bitmap(128)
template.translateBy(x: 0, y: 128)
template.scaleBy(x: 1.28, y: -1.28)
mark(in: template, monochrome: true)
try writePNG(template.makeImage()!, to: resources.appendingPathComponent("MovingMark.png"))

let svgShapes = [(ribbon, "#d9f7a0"), (returnFold, "#b7e16c"), (leadingEdge, "#96b76d")].map { points, fill in
    let path = points.map { "\($0[0]),\($0[1])" }.joined(separator: " ")
    return "  <polygon fill=\"\(fill)\" points=\"\(path)\"/>"
}.joined(separator: "\n")
let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 22 100 58\" role=\"img\" aria-label=\"Moving\">\n\(svgShapes)\n</svg>\n"
try svg.write(to: resources.appendingPathComponent("MovingMark.svg"), atomically: true, encoding: .utf8)

let icon = bitmap(1024)
let plaque = CGPath(roundedRect: CGRect(x: 57, y: 57, width: 910, height: 910), cornerWidth: 207, cornerHeight: 207, transform: nil)
icon.saveGState()
icon.addPath(plaque)
icon.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x141913), color(0x30392A)] as CFArray, locations: nil)!
icon.drawLinearGradient(gradient, start: CGPoint(x: 850, y: 65), end: CGPoint(x: 230, y: 950), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
icon.restoreGState()
icon.addPath(plaque)
icon.setStrokeColor(CGColor(red: 0.70, green: 0.77, blue: 0.63, alpha: 0.23))
icon.setLineWidth(3)
icon.strokePath()
icon.translateBy(x: 110, y: 915)
icon.scaleBy(x: 8.04, y: -8.04)
mark(in: icon, monochrome: false)
let master = icon.makeImage()!
try writePNG(master, to: artifacts.appendingPathComponent("Moving-icon.png"))

var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let context = bitmap(pixels)
        context.interpolationQuality = .high
        context.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let image = context.makeImage()!
        try writePNG(image, to: iconSet.appendingPathComponent(name))
        try writePNG(image, to: assetSet.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: assetSet.appendingPathComponent("Contents.json"))
