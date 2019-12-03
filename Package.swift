// swift-tools-version:5.1
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
  name: "SwiftPreview",
  products: [
    .library(
      name: "SwiftPreview",
      targets: ["SwiftPreview"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/se-NNNN-package-name", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "SwiftPreview",
      dependencies: ["SE_NNNN_PackageName"]),
    
    .testTarget(
      name: "SwiftPreviewTests",
      dependencies: ["SwiftPreview"]),
  ]
)
