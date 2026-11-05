// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cloudflare-quota",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"]),
    ],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaCore"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(name: "QuotaBarTests", dependencies: ["QuotaBar", "QuotaCore"]),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore"]
        ),
    ]
)
