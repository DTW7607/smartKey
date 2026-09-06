// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "smartKey",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "smartKey", targets: ["smartKeyPopup"]),
    ],
    targets: [
        .target(
            name: "SmartKey",
            path: "Sources/SmartKey"
        ),
        .executableTarget(
            name: "smartKeyPopup",
            dependencies: ["SmartKey"],
            path: "Sources/smartKeyPopup"
        ),
        .testTarget(name: "SmartKeySetupTests", dependencies: ["smartKeyPopup", "SmartKey"]),
    ]
)
