// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Moving",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MotionCore", targets: ["MotionCore"])],
    targets: [
        .target(name: "MotionCore", path: "Sources", exclude: ["Application.swift", "Views.swift", "SettingsAndMenu.swift"]),
        .testTarget(name: "MotionCoreTests", dependencies: ["MotionCore"], path: "Tests")
    ]
)
