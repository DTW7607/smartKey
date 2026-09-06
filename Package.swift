// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "smartKey",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SmartKey", targets: ["SmartKey"]),
        .executable(name: "smartKeyDemo", targets: ["smartKeyDemo"]),
        .executable(name: "smartKeyPopup", targets: ["smartKeyPopup"]),
    ],
    targets: [
        .target(
            name: "SmartKey",
            path: "Sources/SmartKey"
        ),
        .executableTarget(
            name: "smartKeyDemo",
            dependencies: ["SmartKey"],
            path: "Sources/smartKeyDemo"
        ),
        .executableTarget(
            name: "smartKeyPopup",
            path: "Sources/smartKeyPopup"
        ),
    ]
)
