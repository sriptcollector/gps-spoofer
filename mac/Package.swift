// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GPSSpooferMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GPSSpoofer", path: "Sources/GPSSpoofer"),
    ]
)
