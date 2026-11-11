// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VPNChainCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VPNChainCore", targets: ["VPNChainCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh", .upToNextMinor(from: "0.15.0")),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "VPNChainCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/VPNChainCore"
        ),
        .executableTarget(
            name: "VPNChainSetup",
            dependencies: ["VPNChainCore"],
            path: "Sources/VPNChainSetup",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "VPNChainCoreTests",
            dependencies: ["VPNChainCore"],
            path: "Tests/VPNChainCoreTests"
        ),
    ]
)
