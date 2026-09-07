// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "smartKey",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "smartKey", targets: ["smartKeyPopup"]),
        .library(name: "SmartKeyActions", targets: ["SmartKeyActions"]),
    ],
    targets: [
        .target(name: "SmartKeyActions"),
        .target(
            name: "SmartKey",
            path: "Sources/SmartKey"
        ),
        .executableTarget(
            name: "smartKeyPopup",
            dependencies: ["SmartKey", "SmartKeyActions"],
            path: "Sources/smartKeyPopup"
        ),
        .testTarget(name: "SmartKeySetupTests", dependencies: ["smartKeyPopup", "SmartKey", "SmartKeyActions"]),
        .testTarget(name: "SmartKeyActionsTests", dependencies: ["SmartKeyActions"]),
    ]
)
