// swift-tools-version:5.9
// Builds this fork with the Command Line Tools alone, for Macs without Xcode.
// Scripts/build-local.sh wraps the result into an app bundle.
import PackageDescription

let package = Package(
    name: "Codenotch",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", from: "2.102.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/Vendor/zstd",
            exclude: ["README.md", "LICENSE"],
            sources: ["zstddeclib.c"],
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "Codenotch",
            dependencies: [
                "CZstd",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Sources",
            exclude: [
                "Vendor", "Assets.xcassets", "Resources", "Info.plist",
                "Localizable.xcstrings", "Codenotch-Bridging-Header.h",
            ],
            swiftSettings: [
                .unsafeFlags(["-import-objc-header", "Sources/Codenotch-Bridging-Header.h"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
