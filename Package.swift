// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShelfCore", targets: ["ShelfCore"]),
        .library(name: "SourceKit", targets: ["SourceKit"]),
        .library(name: "RepoKit", targets: ["RepoKit"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .library(name: "DownloadKit", targets: ["DownloadKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        // Only used on Linux, where CryptoKit doesn't exist, so the packages can be tested there.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(name: "ShelfCore"),
        .target(name: "SourceKit", dependencies: ["ShelfCore", "SwiftSoup"]),
        .target(name: "RepoKit", dependencies: [
            "ShelfCore",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        .target(name: "LibraryKit", dependencies: ["ShelfCore"]),
        .target(name: "DownloadKit", dependencies: ["ShelfCore"]),
        .testTarget(name: "ShelfCoreTests", dependencies: ["ShelfCore"]),
        .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit"]),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
        .testTarget(name: "SourceKitTests", dependencies: ["SourceKit"]),
        .testTarget(name: "RepoKitTests", dependencies: ["RepoKit"]),
    ]
)
