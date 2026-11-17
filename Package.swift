// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShelfCore", targets: ["ShelfCore"]),
        .library(name: "SourceKit", targets: ["SourceKit"]),
        .library(name: "RepoKit", targets: ["RepoKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "ShelfCore"),
        .target(name: "SourceKit", dependencies: ["ShelfCore", "SwiftSoup"]),
        .target(name: "RepoKit", dependencies: ["ShelfCore"]),
        .testTarget(name: "ShelfCoreTests", dependencies: ["ShelfCore"]),
        .testTarget(name: "SourceKitTests", dependencies: ["SourceKit"]),
        .testTarget(name: "RepoKitTests", dependencies: ["RepoKit"]),
    ]
)
