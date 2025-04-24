// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NextcloudFileProviderKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v11),
        .visionOS(.v1)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "NextcloudFileProviderKit",
            targets: ["NextcloudFileProviderKit"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/claucambra/NextcloudCapabilitiesKit.git",
                .upToNextMajor(from: "2.1.2")
        ),
        .package(url: "https://github.com/nextcloud/NextcloudKit", branch: "work/f-openclass"),
        .package(url: "https://github.com/realm/realm-swift.git", exact: "20.0.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NextcloudFileProviderKit",
            dependencies: [
                .product(name: "NextcloudCapabilitiesKit", package: "NextcloudCapabilitiesKit"),
                .product(name: "NextcloudKit", package: "NextcloudKit"),
                .product(name: "RealmSwift", package: "realm-swift")]),
        .target(
            name: "TestInterface",
            dependencies: [
                "NextcloudFileProviderKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio")
            ],
            path: "Tests/Interface"),
        .testTarget(
            name: "TestInterfaceTests",
            dependencies: ["NextcloudFileProviderKit", "TestInterface"],
            path: "Tests/InterfaceTests"
        ),
        .testTarget(
            name: "NextcloudFileProviderKitTests",
            dependencies: ["NextcloudFileProviderKit", "TestInterface"]),
    ]
)
