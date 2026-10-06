// swift-tools-version:6.0
import PackageDescription

// DriveLoggerCore is deliberately platform-light: it declares macOS support so
// `swift test` runs the whole suite on a Mac with no simulator involved. Any
// dependency on UIKit/SwiftUI/CoreBluetooth/CoreMotion belongs in the app
// target, not here — see CLAUDE.md.
let package = Package(
    name: "DriveLoggerCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DriveLoggerCore", targets: ["DriveLoggerCore"]),
    ],
    targets: [
        .target(
            name: "DriveLoggerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DriveLoggerCoreTests",
            dependencies: ["DriveLoggerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
