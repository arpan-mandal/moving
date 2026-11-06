import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let background = NSImage(size: NSSize(width: 660, height: 410))
let accent = NSColor(srgbRed: 0.78, green: 0.94, blue: 0.51, alpha: 1)
background.lockFocus()
NSColor(srgbRed: 0.08, green: 0.10, blue: 0.08, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 660, height: 410).fill()

if let mark = NSImage(contentsOfFile: CommandLine.arguments[2]) {
    let tinted = NSImage(size: NSSize(width: 47, height: 47), flipped: false) { rect in
        mark.draw(in: rect)
        accent.setFill()
        rect.fill(using: .sourceIn)
        return true
    }
    tinted.draw(in: NSRect(x: 241, y: 312, width: 47, height: 47))
}
("Moving" as NSString).draw(at: NSPoint(x: 291, y: 314), withAttributes: [
    .font: NSFont.systemFont(ofSize: 35, weight: .semibold), .foregroundColor: NSColor.white,
])

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 300, y: 205)); arrow.line(to: NSPoint(x: 360, y: 205))
arrow.move(to: NSPoint(x: 350, y: 215)); arrow.line(to: NSPoint(x: 360, y: 205)); arrow.line(to: NSPoint(x: 350, y: 195))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
accent.setStroke()
arrow.stroke()

let caption = NSMutableParagraphStyle()
caption.alignment = .center
("Drag Moving to Applications" as NSString).draw(in: NSRect(x: 30, y: 52, width: 600, height: 24), withAttributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 0.76, alpha: 1), .paragraphStyle: caption,
])
background.unlockFocus()
let rep = NSBitmapImageRep(data: background.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: output)
