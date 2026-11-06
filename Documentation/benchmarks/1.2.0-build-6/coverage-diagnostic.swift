import AppKit

let applications = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.localizedName ?? "Unknown") })
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for screen in NSScreen.screens {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
    let bounds = CGDisplayBounds(number)
    let visible = screen.visibleFrame
    let usable = CGRect(x: bounds.minX + visible.minX - screen.frame.minX,
                        y: bounds.minY + screen.frame.maxY - visible.maxY,
                        width: visible.width, height: visible.height).intersection(bounds)
    for window in windows {
        guard let level = window[kCGWindowLayer as String] as? Int,
              (Int(CGWindowLevelForKey(.normalWindow))..<Int(CGWindowLevelForKey(.dockWindow))).contains(level),
              (window[kCGWindowAlpha as String] as? Double ?? 1) >= 0.95,
              let dict = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
              rect.insetBy(dx: -8, dy: -8).contains(usable),
              let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
        print("\(applications[pid] ?? "Unknown") (\(pid)) covers \(screen.localizedName)")
    }
}
