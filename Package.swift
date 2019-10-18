// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "Prototype_RangeSet",
    products: [
        .library(
            name: "Prototype_RangeSet",
            targets: ["Prototype_RangeSet"]),
        .executable(
            name: "demo",
            targets: ["Demo"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "Demo",
            dependencies: ["Prototype_RangeSet"]),
        .target(
            name: "Prototype_RangeSet",
            dependencies: []),
        .target(
            name: "TestHelpers",
            dependencies: ["Prototype_RangeSet"]),
        .testTarget(
            name: "RangeSetTests",
            dependencies: ["Prototype_RangeSet", "TestHelpers"]),
    ]
)
