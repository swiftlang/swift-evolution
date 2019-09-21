// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Prototype_CollectionConsumerSearcher",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "Prototype_CollectionConsumerSearcher",
            targets: ["Prototype_CollectionConsumerSearcher"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/ctxppc/PatternKit", .branch("development")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "CollectionConsumerSearcher",
            dependencies: []),
        .testTarget(
            name: "CollectionConsumerSearcherTests",
            dependencies: ["CollectionConsumerSearcher"]),
        .target(
            name: "Prototype_CollectionConsumerSearcher",
            dependencies: ["CollectionConsumerSearcher", "PatternKit"]),
        .testTarget(
            name: "PrototypeCollectionConsumerSearcherTests",
            dependencies: ["Prototype_CollectionConsumerSearcher"]),
        .target(
            name: "Prototype_CollectionConsumerSearcherExample",
            dependencies: ["Prototype_CollectionConsumerSearcher", "CollectionConsumerSearcher"]),
    ]
)
