// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "smartKeyDemo",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "smartKeyDemo",
            path: "Sources"
        ),
    ]
)
