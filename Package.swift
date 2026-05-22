// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "AIToolKit",
    platforms: [
        .iOS("26.5"),
        .macOS("26.5"),
        .visionOS("26.5"),
    ],
    products: [
        .library(name: "AIToolKit", targets: ["AIToolKit"]),
    ],
    targets: [
        .target(
            name: "AIToolKit",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIToolKitTests",
            dependencies: ["AIToolKit"],
            swiftSettings: swiftSettings
        ),
    ]
)
