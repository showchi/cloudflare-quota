// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cloudflare-quota",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "QuotaCore"),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
    ]
)
