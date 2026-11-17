// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiscoboxDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiscoboxDesktop", targets: ["DiscoboxDesktop"]),
        .executable(name: "DiscoboxSmoke", targets: ["DiscoboxSmoke"])
    ],
    targets: [
        .target(name: "DiscoboxCore"),
        .binaryTarget(name: "GhosttyKit", path: ".build/ghostty/sdk/6d2dd585a5d87fa745d48188dd096ca6e63014d0/GhosttyKit.xcframework"),
        .target(name: "DiscoboxUI", dependencies: ["DiscoboxCore", "GhosttyKit"], path: "Sources/DiscoboxDesktop", linkerSettings: [
            .linkedLibrary("c++"), .linkedFramework("Carbon"), .linkedFramework("CoreFoundation"),
            .linkedFramework("CoreGraphics"), .linkedFramework("CoreText"), .linkedFramework("CoreVideo"),
            .linkedFramework("QuartzCore"), .linkedFramework("IOSurface"), .linkedFramework("Metal")
        ]),
        .executableTarget(name: "DiscoboxDesktop", dependencies: ["DiscoboxUI"], path: "Sources/DiscoboxLauncher"),
        .executableTarget(name: "DiscoboxSmoke", dependencies: ["DiscoboxUI", "DiscoboxCore", "GhosttyKit"]),
        .testTarget(name: "DiscoboxCoreTests", dependencies: ["DiscoboxCore"])
    ]
)
