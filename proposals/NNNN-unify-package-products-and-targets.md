# Unifying Package Products and Targets

* Proposal: [SE-NNNN](NNNN-unify-package-products-and-targets.md)
* Authors: [Owen Voorhees](https://github.com/owenv)
* Implementation: [PR-10500](https://github.com/swiftlang/swift-package-manager/pull/10500)
* Review: ([First Pitch](https://forums.swift.org/t/pitch-unifying-package-products-and-targets/89427), [Second Pitch](https://forums.swift.org/t/pitch-2-unifying-package-products-and-targets/90803))

## Introduction

Today, packages distinguish between the concept of targets, which represent a single module, and products, which group one or more targets into a binary other packages can consume. This distinction is often confusing in practice, and makes it difficult to express more complex builds. This proposal deprecates the concept of package products and extends the capabilities of package targets to support existing use cases and enable new ones.

## Motivation

Today, packages are divided into targets and products. Generally speaking, targets:
- organize source code into a single module
- cannot be directly depended upon by other packages
- do not control the type of image they're linked into
- can specify linker settings

Products, on the other hand:
- organize one or more targets into a library or executable
- can be directly depended upon by other packages
- may express an opinion about how they are linked
- cannot specify linker settings

In practice, this model has been confusing to many users, and the distinction between targets and products has become blurry. For example, an `executableTarget` is used to compile sources for linking into an `executable` product, which is redundant and easy to forget. A `testTarget` describes how its sources should be built and linked, but can't be included in a product. The lack of consistent rules makes it difficult to build a mental model of how packages are organized from first principles.

The split between products and targets also limits the expressivity of packages. A longstanding limitation of SwiftPM is that it's not possible for one of a package’s targets to depend on one of its own products. This makes organizing larger packages difficult, and limits users' control over how code within a package is linked. Users must resort to awkward workarounds like breaking their code into multiple packages or integrating with external build systems to regain control. This problem will be exacerbated as SwiftPM continues evolving to support building increasingly complex software with new kinds of targets and build outputs.

Many of these issues are caused by the fact that products currently conflate two unrelated concepts: how code is linked, and whether it's available for dependent packages to consume. By deprecating products in favor of more flexible targets, we can separate these two concepts and allow users to configure them independently.

## Proposed solution

Deprecate the concept of package products and related manifest API. In its place, introduce new target types to represent static, dynamic, and automatic library targets. Also introduce a new `visibility` parameter allowing targets to control whether a target in a dependent package may consume them.

## Detailed design

### New Target Types

Today, there are 3 types of products a package can declare: libraries, executables, and plugins.

Library products will be replaced by a new target type, `libraryTarget`:

```swift
    @available(_PackageDescription, introduced: 999.0)
    public static func libraryTarget(
        name: String,
        type: LibraryType? = nil,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil,
        visibility: TargetVisibility = .package
    ) -> Target
```

`Product.Library.LibraryType` will become a `typealias` of the new top-level `LibraryType` enum.

A `libraryTarget` with `type: .dynamic` will produce a dynamic library, and a `libraryTarget` with `type: .static` will produce a static library. A `libraryTarget` with no `type` leaves how it's linked up to the build system just as a `library` product with no specified linkage does today.

A `libraryTarget` is permitted to omit the sources directory as long as it has at least one dependency on a regular `target`. This allows the new target type to either aggregate multiple targets into a single library, or include sources itself and represent the contents of a single module. As a result, it can serve as a replacement for all current uses of library products. A `libraryTarget` with no sources of its own does not define a module.

The existing `executableTarget` replaces an `executable` product and continues to produce an executable without requiring any specific changes to the manifest API. Similarly, the existing `plugin` target API replaces the corresponding product API. No other existing target types have corresponding product types today.

### Linker Settings

Currently, only targets may have linker settings, but only products link an image. As a result, SwiftPM imparts a target's linker settings on dependent products. This results in linker settings often being applied to more transitive dependents of a target than the user intended, limiting the usefulness of linker settings as a whole. In the upcoming tools version where targets can represent linked images, linker settings will no longer be imparted on dependents and will only be applied to the specified target. If a target does not produce a final linked image, specifying linker settings will have no effect and emit a warning.

### Target Visibility

Instead of exposing functionality to dependent packages through products, package authors will now do so by specifying a target's visibility. The new `libraryTarget` API, along with the existing `target`, `executableTarget`, `testTarget`, `binaryTarget`, `plugin`, `macro`, and `systemLibrary` API each gain a new parameter:

```swift
visibility: TargetVisibility = .package
```

```swift
 @available(_PackageDescription, introduced: 999.0)
 public enum TargetVisibility {
    case `public`
    case `package`
 }
```

If a target has `.public` visibility, a target in the same package or a dependent package may declare a dependency on it. If a target has `.package` visibility, only targets in the same package are allowed to declare a dependency on it. If visibility isn't specified explicitly, targets default to `.package` visibility to ensure package authors don't accidentally expose an interface they didn't intend to.

If a target specifies that it has `visibility: .public`, a target in another package can declare a dependency on it using new `Target.Dependency` API:
```swift
    @available(_PackageDescription, introduced: 999.0)
    public static func target(
      name: String,
      package: String,
      moduleAliases: [String: String]? = nil,
      condition: TargetDependencyCondition? = nil
    ) -> Target.Dependency
```

Like products, this new API allows specifying module aliases when depending on a target in another package. Specifying module aliases in a dependency on a target from the same package remains disallowed.

### Deprecating Products

The existing `Package` initializer which accepts a `products` array will be deprecated (but not obsoleted) in favor of a new one where it's removed:

```swift
    @available(_PackageDescription, introduced: 999.0)
    public init(
        name: String,
        defaultLocalization: LanguageTag? = nil,
        platforms: [SupportedPlatform]? = nil,
        pkgConfig: String? = nil,
        providers: [SystemPackageProvider]? = nil,
        traits: Set<Trait> = [],
        dependencies: [Dependency] = [],
        targets: [Target] = [],
        swiftLanguageModes: [SwiftLanguageMode]? = nil,
        cLanguageStandard: CLanguageStandard? = nil,
        cxxLanguageStandard: CXXLanguageStandard? = nil
    )
```

Although the `products` parameter is deprecated, SwiftPM will continue to respect it if present. This means an existing package may adopt the new tools version before fully migrating its products to public targets, to ease the migration process. Additionally, the `product` methods which construct a `Target.Dependency` are _not_ deprecated by this proposal. After adopting the new tools version, a package may continue to depend on products declared by other packages, including packages with older tools versions. Finally, if a `product` dependency finds no products with the given name in the specified package, it will fall back to searching for a target with the specified name and public visibility. This allows a package to migrate from products to public targets without breaking clients.

SwiftPM will report an error if a product attempts to include a `libraryTarget`, and the general expectation is that products will not be able to aggregate any new target types introduced in the future.

### Determining Linkage Dependencies

Today, when linking a package product SwiftPM treats both the targets which make up that product and certain transitive dependencies as linker inputs. Consider a package like the following:

```swift
// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MyPackage",
    products: [
        .library(name: "MyLibrary", type: .dynamic, targets: ["TargetA"]),
    ],
    targets: [
        .target(name: "TargetA", dependencies: ["TargetB"]),
        .target(name: "TargetB", dependencies: ["TargetC"]),
        .macro(name: "TargetC"),
    ]
)
```

When this package is built, the "MyLibrary" dynamic library will include the objects from both TargetA and TargetB, even though TargetB is only a transitive dependency. TargetC will be excluded because it's a macro, and any plugin dependencies would be similarly excluded. This transitivity of linkage dependencies extends to statically linked products in dependencies as well.

Beginning in the upcoming tools version, targets will be required to declare a direct dependency on any other targets they link. For example, the above manifest would need to be rewritten as:

```swift
// swift-tools-version: 999.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MyPackage",
    targets: [
        // MyLibrary explicitly depends upon both TargetA and TargetB
        .libraryTarget(name: "MyLibrary", type: .dynamic, dependencies: ["TargetA", "TargetB"], visibility: .public),
        .target(name: "TargetA", dependencies: ["TargetB"]),
        .target(name: "TargetB", dependencies: ["TargetC"]),
        .macro(name: "TargetC"),
    ]
)
```

This means that if a package exposes a target with public visibility, it's responsible for ensuring clients can successfully link it. Consider the following package:

```swift
// swift-tools-version: 999.0

import PackageDescription

let package = Package(
    name: "MyPackage",
    targets: [
        // TargetA calls a function in target B
        .target(name: "TargetA", dependencies: ["TargetB"], visibility: .public),
        .target(name: "TargetB", dependencies: []),
    ]
)
```

A dependent of this package is only allowed to directly depend on the public target, TargetA, and cannot declare a dependency on TargetB. However, clients of TargetA will fail to link if they don't also declare a linkage dependency on TargetB. In most cases, bare `target`s should be linked as a `libraryTarget` when exposed with public visibility to avoid these issues. For example, this package could be rewritten as:

```swift
// swift-tools-version: 999.0

import PackageDescription

let package = Package(
    name: "MyPackage",
    targets: [
        // MyLibrary has no sources and only exists to produce a library composed of TargetA and TargetB
        .libraryTarget(name: "MyLibrary", dependencies: ["TargetA", "TargetB"], visibility: .public),
        .target(name: "TargetA", dependencies: ["TargetB"]),
        .target(name: "TargetB", dependencies: []),
    ]
)
```

or TargetA itself could be exposed as a `libraryTarget`:

```swift
// swift-tools-version: 999.0

import PackageDescription

let package = Package(
    name: "MyPackage",
    targets: [
        .libraryTarget(name: "TargetA", dependencies: ["TargetB"], visibility: .public),
        .target(name: "TargetB", dependencies: []),
    ]
)
```

Whether a target dependency implies a linkage dependency is determined by the type of the dependent and dependency:

| Dependent ↓ / Dependency → | `target` | `libraryTarget` | `executableTarget` | `testTarget` | `binaryTarget` | `plugin` | `macro` | `systemLibrary`[^1] |
|---|---|---|---|---|---|---|---|---|
| `target`[^2] | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `libraryTarget` | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| `executableTarget` | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| `testTarget` | ✅ | ✅ | ✅[^3] | ✅[^4] | ✅ | ❌ | ✅[^3] | ✅ |
| `binaryTarget`[^5] | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `plugin` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `macro` | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| `systemLibrary`[^6] | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

[^1]: Not every `systemLibrary` dependency implies linked libraries.

[^2]: A bare `target` does not produce a final linked image. Depending on the platform, it produces only a relocatable object or a collection of objects, so none of its dependencies are linkage dependencies.

[^3]: When a `testTarget` depends on an `executableTarget` or `macro`, the test bundle or runner links a dedicated testable copy of the executable built with a renamed entrypoint function.

[^4]: Only a `testTarget` may depend on another `testTarget`. A `testTarget` that other test targets depend on is treated as a test helper library.

[^5]: A `binaryTarget` is not permitted to declare any target dependencies.

[^6]: A `systemLibrary` target is not permitted to declare any target dependencies.

In many cases, a package wants to expose some code to dependents without specifying exactly how it's linked. This is the use case covered by "automatic" library products today. When not part of a root package, a library product with unspecified type does not produce a final linked image. Instead, it groups a set of targets which clients of the product should individually link. In the new tools version, a `libraryTarget` with automatic or unspecified linkage fulfills this same use case. A dependency on that target implies a linkage dependency on the target itself. This behavior extends to an automatic library target A which directly depends on another automatic library target B.

Whether a package should specify explicit vs automatic linkage largely depends on how it will be used. In general:
- If a package contains library code intended to be shared by multiple dependents, automatic linkage is a good default. It gives the package manager more flexibility to choose between static and dynamic linkage as needed to avoid introducing duplicate symbols issues when a target has multiple consumers in the package graph.
- If a root package builds a product like an command line tool, web server, or distributed library, specifying explicit linkage is often desirable.

To maintain compatibility with existing packages, a dependency on a static or automatic library product from a package with an older tools version will continue to follow transitive dependencies when determining linkage, even if the consumer has adopted the new tools version. This is important to allow packages to update their tools version one at a time on independent schedules. 

The "Fine-grained dependency specifications" section of "Future Directions" contains more detail of how we could further improve how dependencies are specified in future proposals by better distinguising between compilation, linking, and other types of dependency.

### CLI Changes

In general, existing CLI options for working with products will continue to be supported to allow working with packages that have older tools versions. For example, both `--target` and `--product` will continue to be supported by `swift build`.

However, various assorted changes to the SwiftPM CLI will be made to accommodate the new capabilities of targets:
- `swift package --generate-sbom` will gain a `--target` flag. Similar to the existing `--product` flag, it will generate an SBOM for a specific target. Publicly visible targets will receive the same treatment in generated SBOMS that products do today.
- `swift package add-target` currently allows specifying `--type library` to add a regular `target`. When a manifest uses the new tools version, `--type library` will now insert a `libraryTarget` with no type, `--type dynamic-library` will insert one with `type: .dynamic`, and `--type static-library` will insert one with `type: .static`. No `--type` flag will insert a regular `target`. The subcommand will also now accept `--visibility public` or `--visibility package` as optional arguments. This is a minor compatibility break, but more closely aligns the manifest editor commands with the actual manifest API.
- `swift package add-product` will emit a deprecation warning when run on a package with the new tools version.
- `swift package describe` output will be updated with a new field for target visibility.
- Currently when a command plugin is invoked with `swift package my-command-plugin`, SwiftPM considers plugins in the root package, and plugin products in direct dependencies. It will be updated to also consider plugin targets with `visibility: .public` in direct dependencies.
- Currently, `swift run --repl` exposes all library products in the root package to the REPL. It will be updated to also include any `libraryTarget` with `visibility: .public`.
- Currently, `swift package diagnose-api-breaking-changes` defaults to comparing the API of all modules incorporated in library products. It will be updated to also include any `libraryTarget` with `visibility: .public`.

### PackagePlugin API Changes

For the most part, the PackagePlugin API adapts straightforwardly to the new model:
- `ModuleKind` will add a new `library` case.
- A `libraryTarget` with no sources will be represented using a new internal type which conforms to the existing `Target` protocol. No new public `Target` conformer will be introduced. This is similar to how support for mixed language targets was introduced.
- `Target` will add a new `visibility` field:
```swift
@available(_PackageDescription, introduced: 999.0)
var visibility: TargetVisibility { get }
```

### Example: swift-driver and swift-argument-parser

swift-driver is a package which implements Swift's compiler driver, a component of the Swift toolchain. It's a medium sized package which demonstrates some of the benefits of this proposal. Currently, its manifest looks like this (with some slight simplifications):
```swift
// swift-tools-version:5.10

import PackageDescription

let package = Package(
  name: "swift-driver",
  platforms: [
    .macOS(.v12),
    .iOS(.v15),
  ],
  products: [
    .executable(
      name: "swift-driver",
      targets: ["swift-driver"]),
    .executable(
      name: "swift-help",
      targets: ["swift-help"]),
    .executable(
      name: "swift-build-sdk-interfaces",
      targets: ["swift-build-sdk-interfaces"]),
    .library(
      name: "SwiftDriver",
      targets: ["SwiftDriver"]),
    .library(
      name: "SwiftDriverDynamic",
      type: .dynamic,
      targets: ["SwiftDriver"]),
    .library(
      name: "SwiftOptions",
      targets: ["SwiftOptions"]),
    .library(
      name: "SwiftDriverExecution",
      targets: ["SwiftDriverExecution"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-tools-support-core.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.1"),
    .package(url: "https://github.com/swiftlang/swift-llbuild.git", branch: "main"),
  ],
  targets: [
    /// C modules wrapper for _InternalLibSwiftScan.
    .target(name: "CSwiftScan",
            exclude: [ "CMakeLists.txt" ]),

    /// The driver library.
    .target(
      name: "SwiftDriver",
      dependencies: [
        "SwiftOptions",
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
        "CSwiftScan",
      ],
      exclude: ["CMakeLists.txt"]),

    /// The execution library.
    .target(
      name: "SwiftDriverExecution",
      dependencies: [
        "SwiftDriver",
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core")
      ],
      exclude: ["CMakeLists.txt"]),

    /// Driver tests.
    .testTarget(
      name: "SwiftDriverTests",
      dependencies: ["SwiftDriver", "SwiftDriverExecution", "TestUtilities", "ToolingTestShim"]),

    /// IncrementalImport tests
    .testTarget(
      name: "IncrementalImportTests",
      dependencies: [
        "IncrementalTestFramework",
        "TestUtilities",
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ]),

    .target(
      name: "IncrementalTestFramework",
      dependencies: [ "SwiftDriver", "SwiftOptions", "TestUtilities" ],
      path: "Tests/IncrementalTestFramework"),

    .target(
      name: "TestUtilities",
      dependencies: ["SwiftDriver", "SwiftDriverExecution"],
      path: "Tests/TestUtilities"),

    .target(
      name: "ToolingTestShim",
      dependencies: ["SwiftDriver"],
      path: "Tests/ToolingTestShim"),

    /// The options library.
    .target(
      name: "SwiftOptions",
      dependencies: [
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"]),
    .testTarget(
      name: "SwiftOptionsTests",
      dependencies: ["SwiftOptions"]),

    /// The primary driver executable.
    .executableTarget(
      name: "swift-driver",
      dependencies: ["SwiftDriverExecution", "SwiftDriver"],
      exclude: ["CMakeLists.txt"]),

    /// The help executable.
    .executableTarget(
      name: "swift-help",
      dependencies: [
        "SwiftOptions",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"]),

    /// Build SDK Interfaces tool executable.
    .executableTarget(
      name: "swift-build-sdk-interfaces",
      dependencies: ["SwiftDriver", "SwiftDriverExecution"],
      exclude: ["CMakeLists.txt"]),

    /// The `makeOptions` utility (for importing option definitions).
    .executableTarget(
      name: "makeOptions",
      dependencies: [],
      // Do not enforce checks for LLVM's ABI-breaking build settings.
      // makeOptions runtime uses some header-only code from LLVM's ADT classes,
      // but we do not want to link libSupport into the executable.
      cxxSettings: [.unsafeFlags(["-DLLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING=1"])],
      linkerSettings: [
        .linkedLibrary("swiftCore", .when(platforms: [.windows])), // for swift_addNewDSOImage
      ]),
  ],
  cxxLanguageStandard: .cxx17
)
```

Immediately you'll notice that the list of products is largely redundant. Aside from "SwiftDriverDynamic", which configures linkage, all the products simply expose a single target to dependents. With the changes in this proposal, the manifest can be simplified to the following:

```swift
// swift-tools-version:999.0

import PackageDescription

let package = Package(
  name: "swift-driver",
  platforms: [
    .macOS(.v12),
    .iOS(.v15),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-tools-support-core.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.1"),
    .package(url: "https://github.com/swiftlang/swift-llbuild.git", branch: "main"),
  ],
  targets: [
    /// C modules wrapper for _InternalLibSwiftScan.
    .target(name: "CSwiftScan",
            exclude: [ "CMakeLists.txt" ]),

    /// The driver library.
    .libraryTarget(
      name: "SwiftDriver",
      dependencies: [
        "SwiftOptions",
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
        "CSwiftScan",
      ],
      exclude: ["CMakeLists.txt"],
      visibility: .public),

    /// The execution library.
    .libraryTarget(
      name: "SwiftDriverExecution",
      dependencies: [
        "SwiftDriver",
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core")
      ],
      exclude: ["CMakeLists.txt"],
      visibility: .public),

    .libraryTarget(
      name: "SwiftDriverDynamic",
      type: .dynamic,
      dependencies: ["SwiftDriver", "SwiftDriverExecution"],
      visibility: .public),

    /// Driver tests.
    .testTarget(
      name: "SwiftDriverTests",
      dependencies: ["SwiftDriver", "SwiftDriverExecution", "TestUtilities", "ToolingTestShim"]),

    /// IncrementalImport tests
    .testTarget(
      name: "IncrementalImportTests",
      dependencies: [
        "IncrementalTestFramework",
        "TestUtilities",
        "SwiftDriver",
        "SwiftDriverExecution",
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ]),

    .target(
      name: "IncrementalTestFramework",
      dependencies: [ "SwiftDriver", "SwiftOptions", "TestUtilities" ],
      path: "Tests/IncrementalTestFramework"),

    .target(
      name: "TestUtilities",
      dependencies: ["SwiftDriver", "SwiftDriverExecution"],
      path: "Tests/TestUtilities"),

    .target(
      name: "ToolingTestShim",
      dependencies: ["SwiftDriver"],
      path: "Tests/ToolingTestShim"),

    /// The options library.
    .libraryTarget(
      name: "SwiftOptions",
      dependencies: [
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      visibility: .public),
    .testTarget(
      name: "SwiftOptionsTests",
      dependencies: ["SwiftOptions"]),

    /// The primary driver executable.
    .executableTarget(
      name: "swift-driver",
      dependencies: ["SwiftDriverDynamic"],
      exclude: ["CMakeLists.txt"],
      visibility: .public),

    /// The help executable.
    .executableTarget(
      name: "swift-help",
      dependencies: [
        "SwiftOptions",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      visibility: .public),

    /// Build SDK Interfaces tool executable.
    .executableTarget(
      name: "swift-build-sdk-interfaces",
      dependencies: ["SwiftDriverDynamic"],
      exclude: ["CMakeLists.txt"],
      visibility: .public),

    /// The `makeOptions` utility (for importing option definitions).
    .executableTarget(
      name: "makeOptions",
      dependencies: [],
      // Do not enforce checks for LLVM's ABI-breaking build settings.
      // makeOptions runtime uses some header-only code from LLVM's ADT classes,
      // but we do not want to link libSupport into the executable.
      cxxSettings: [.unsafeFlags(["-DLLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING=1"])],
      linkerSettings: [
        .linkedLibrary("swiftCore", .when(platforms: [.windows])), // for swift_addNewDSOImage
      ]),
  ],
  swiftLanguageModes: [.v5],
  cxxLanguageStandard: .cxx17
)
```

In addition to the ergonomic improvements, swift-driver can also take advantage of the increased expressivity of the manifest. When shipped as part of the toolchain, we want to distribute both the swift-driver executable and the libSwiftDriver shared library which implements much of its functionality. Previously, the swift-driver executable target wasn't able to depend on the SwiftDriverDynamic product which specified dynamic linkage. Now, SwiftDriverDynamic is a `libraryTarget` with dynamic linkage, and we're able to build an executable which links a shared library from the same package.

Note that the above manifest still uses product dependencies to include code from swift-llbuild, swift-argument-parser, and swift-tools-support-core. These packages haven't been updated to the new target based model yet, but swift-driver is able to continue using them unmodified, allowing the package graph to migrate to the new format one package at a time. Let's say I wanted to migrate swift-argument-parser next. Its manifest currently looks like this:

```swift
import PackageDescription

var package = Package(
  name: "swift-argument-parser",
  products: [
    .library(
      name: "ArgumentParser",
      targets: ["ArgumentParser"]),
    .plugin(
      name: "GenerateDoccReference",
      targets: ["GenerateDoccReference"]),
    .plugin(
      name: "GenerateManual",
      targets: ["GenerateManual"]),
  ],
  dependencies: [],
  targets: [
    // Core Library
    .target(
      name: "ArgumentParser",
      dependencies: ["ArgumentParserToolInfo"],
      exclude: ["CMakeLists.txt"]),
    .target(
      name: "ArgumentParserTestHelpers",
      dependencies: ["ArgumentParser", "ArgumentParserToolInfo"],
      exclude: ["CMakeLists.txt"]),
    .target(
      name: "ArgumentParserToolInfo",
      exclude: ["CMakeLists.txt"]),

    // Plugins
    .plugin(
      name: "GenerateDoccReference",
      capability: .command(
        intent: .custom(
          verb: "generate-docc-reference",
          description:
            "Generate a documentation reference for a specified target."),
        permissions: [
          .writeToPackageDirectory(
            reason: "This command generates documentation.")
        ]),
      dependencies: ["generate-docc-reference"]),
    .plugin(
      name: "GenerateManual",
      capability: .command(
        intent: .custom(
          verb: "generate-manual",
          description: "Generate a manual entry for a specified target.")),
      dependencies: ["generate-manual"]),

    // Examples
    .executableTarget(
      name: "roll",
      dependencies: ["ArgumentParser"],
      path: "Examples/roll"),
    .executableTarget(
      name: "math",
      dependencies: ["ArgumentParser"],
      path: "Examples/math"),
    .executableTarget(
      name: "repeat",
      dependencies: ["ArgumentParser"],
      path: "Examples/repeat"),
    .executableTarget(
      name: "color",
      dependencies: ["ArgumentParser"],
      path: "Examples/color"),
    .executableTarget(
      name: "default-as-flag",
      dependencies: ["ArgumentParser"],
      path: "Examples/default-as-flag"
    ),

    // Tools
    .executableTarget(
      name: "generate-docc-reference",
      dependencies: ["ArgumentParser", "ArgumentParserToolInfo"],
      path: "Tools/generate-docc-reference"),
    .executableTarget(
      name: "generate-manual",
      dependencies: ["ArgumentParser", "ArgumentParserToolInfo"],
      path: "Tools/generate-manual"),

    // Tests
    .testTarget(
      name: "ArgumentParserEndToEndTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["CMakeLists.txt"]),
    .testTarget(
      name: "ArgumentParserExampleTests",
      dependencies: ["ArgumentParserTestHelpers"],
      exclude: ["Snapshots"],
      resources: [.copy("CountLinesTest.txt")]),
    .testTarget(
      name: "ArgumentParserGenerateDoccReferenceTests",
      dependencies: ["ArgumentParserTestHelpers"],
      exclude: ["Snapshots"]),
    .testTarget(
      name: "ArgumentParserGenerateManualTests",
      dependencies: ["ArgumentParserTestHelpers"],
      exclude: ["Snapshots"]),
    .testTarget(
      name: "ArgumentParserPackageManagerTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["CMakeLists.txt"]),
    .testTarget(
      name: "ArgumentParserToolInfoTests",
      dependencies: ["ArgumentParserToolInfo"],
      exclude: ["Examples"]),
    .testTarget(
      name: "ArgumentParserUnitTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["CMakeLists.txt", "Snapshots"]),
  ]
)
```

To migrate it to the new format, we remove the products list and expose the relevant targets with public visibility. The public target names match the old product names, so this change doesn't break the build of swift-driver:

```swift
// swift-tools-version:999.0

import PackageDescription

var package = Package(
  name: "swift-argument-parser",
  dependencies: [],
  targets: [
    // Core Library
    .libraryTarget(
      name: "ArgumentParser",
      dependencies: ["ArgumentParserToolInfo"],
      exclude: ["CMakeLists.txt"],
      visibility: .public),
    .target(
      name: "ArgumentParserTestHelpers",
      dependencies: ["ArgumentParser", "ArgumentParserToolInfo"],
      exclude: ["CMakeLists.txt"]),
    .target(
      name: "ArgumentParserToolInfo",
      exclude: ["CMakeLists.txt"]),

    // Plugins
    .plugin(
      name: "GenerateDoccReference",
      capability: .command(
        intent: .custom(
          verb: "generate-docc-reference",
          description:
            "Generate a documentation reference for a specified target."),
        permissions: [
          .writeToPackageDirectory(
            reason: "This command generates documentation.")
        ]),
      dependencies: ["generate-docc-reference"],
      visibility: .public),
    .plugin(
      name: "GenerateManual",
      capability: .command(
        intent: .custom(
          verb: "generate-manual",
          description: "Generate a manual entry for a specified target.")),
      dependencies: ["generate-manual"],
      visibility: .public),

    // Examples
    .executableTarget(
      name: "roll",
      dependencies: ["ArgumentParser"],
      path: "Examples/roll"),
    .executableTarget(
      name: "math",
      dependencies: ["ArgumentParser"],
      path: "Examples/math"),
    .executableTarget(
      name: "repeat",
      dependencies: ["ArgumentParser"],
      path: "Examples/repeat"),
    .executableTarget(
      name: "color",
      dependencies: ["ArgumentParser"],
      path: "Examples/color"),
    .executableTarget(
      name: "default-as-flag",
      dependencies: ["ArgumentParser"],
      path: "Examples/default-as-flag"
    ),

    // Tools
    .executableTarget(
      name: "generate-docc-reference",
      dependencies: ["ArgumentParser", "ArgumentParserToolInfo"],
      path: "Tools/generate-docc-reference"),
    .executableTarget(
      name: "generate-manual",
      dependencies: ["ArgumentParser", "ArgumentParserToolInfo"],
      path: "Tools/generate-manual"),

    // Tests
    .testTarget(
      name: "ArgumentParserEndToEndTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["CMakeLists.txt"]),
    .testTarget(
      name: "ArgumentParserExampleTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["Snapshots"],
      resources: [.copy("CountLinesTest.txt")]),
    .testTarget(
      name: "ArgumentParserGenerateDoccReferenceTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["Snapshots"]),
    .testTarget(
      name: "ArgumentParserGenerateManualTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["Snapshots"]),
    .testTarget(
      name: "ArgumentParserPackageManagerTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["CMakeLists.txt"]),
    .testTarget(
      name: "ArgumentParserToolInfoTests",
      dependencies: ["ArgumentParserToolInfo"],
      exclude: ["Examples"]),
    .testTarget(
      name: "ArgumentParserUnitTests",
      dependencies: ["ArgumentParser", "ArgumentParserTestHelpers"],
      exclude: ["CMakeLists.txt", "Snapshots"]),
  ]
)
```

And finally, swift-driver can update its dependency declarations on its own schedule from:

```swift
.executableTarget(
      name: "swift-help",
      dependencies: [
        "SwiftOptions",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      visibility: .public),
```

to:

```swift
.executableTarget(
      name: "swift-help",
      dependencies: [
        "SwiftOptions",
        .target(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: swiftToolsSupportCoreLibName, package: "swift-tools-support-core"),
      ],
      exclude: ["CMakeLists.txt"],
      visibility: .public),
```

Now, swift-driver uses a mix of targets and products from other packages, and package authors can continue to incrementally modernize the remaining packages.

## Security

This proposal only impacts how packages organize and build their sources. It does not impact package manager security.

## Impact on existing packages

- Packages using existing tools versions will continue to build as they do today.
- When upgrading their tools-version, packages may require updates to correctly specify link dependencies and options. However, they can incrementally migrate any products they expose to targets with public visibility.

## Alternatives considered

### Continue to Evolve Targets and Products Independently

This proposal is a large and disruptive change to how package manifests are authored. While the change significantly simplifies the manifest API and solves important issues like the current inability to declare dependencies between products in the same package, it could be argued that we should instead pursue more targeted changes to the existing product/target split.

### Immediately Obsolete Product Related Manifest API

Instead of deprecating products, but continuing to support declaring them as a transitional aid, we could immediately obsolete the related API in the upcoming tools version. This alternative was rejected as being too disruptive to existing packages which might want to adopt new tools versions without immediately taking on a major migration.

### Rename Target API

We could also use this change as an opportunity to improve naming of API appearing in a manifest's `targets` list to reduce redundancy and improve clarity. The proposed name changes would include:

- Naming the new `libraryTarget` introduced in this proposal `library` instead.
- Renaming `executableTarget` to `executable`.
- Renaming `testTarget` to `tests`. `tests` is chosen over something more specific like `testBundle` because test packaging differs by platform. It's pluralized because subjectively it reads more clearly than `test`, which might be confused for a single test case as opposed to a target containing a collection of tests.
- Renaming `binaryTarget` to `binary`.
- Leaving the `systemLibrary`, `plugin`, and `macro` API names unchanged.
- Leaving the naming of the bare `target` API unchanged. The main alternative name suggested for this API is `module`. However, this proposed name has become increasingly inaccurate as SwiftPM has gained improved support for C/C++ interop involving multiple modules associated with a single target, a trend that's likely to continue as the capabilities of package plugins improve and allow generating new kinds of resources/linker inputs/etc.

If we were to pursue these API renames, the old versions would be preserved to avoid unnecessarily preventing a manifest from compiling when updating its tools version. This proposal argues they should be deprecated in the new tools version to avoid user confusion as to which naming users should prefer, although this might introduce a large number of warnings in existing packages when upgrading.

If this was new API being introduced for the first time, this proposal would recommend these alternate names over what we have today. The "target" in `libraryTarget`, `executableTarget`, `testTarget`, and `binaryTarget` is clearly redundant when they appear in a manifest's targets list, and dropping it more clearly distinguishes them from a bare `target` which doesn't produce a linked image. This proposal keeps these renamings as an alternative primarily to minimize disruption to existing users of packages. Adopting the new names is a mechanical process, but it's still an additional change for users to adjust to. We should only rename key manifest API when the accompanying benefits outweigh the downsides of users needing to update packages, change documentation, etc. We also shouldn't use the admittedly disruptive changes in this proposal to justify further, separable disruptive changes which increase the overall impact while delivering lesser benefits to users. This proposal argues that the primary changes being proposed deliver significant functional benefits, while the additional renames would deliver only a moderate clarity benefit.

That said, these renames remain a perfectly viable alternative that could be considered during the review process if the consensus is that they're desirable.

## Future Directions

### Fine-grained dependency specifications

Today, the meaning of a dependency declared in a package is driven by heuristics which take into account things like the target types involved and the direct and transitive dependencies of a target. As packages get more complex, these heuristics won’t always be correct. We should consider introducing new manifest API which allows a dependency to specify whether it’s a compilation, linkage, or runtime dependency (or usually, some combination of the above). Simple packages can continue to use the existing heuristics, but more complex packages will have a new tool to ensure their dependencies are correctly tracked. For now, this proposal defers the design of this feature to future work.

### New Target Types

As mentioned in the motivation section, eliminating the product/target split in manifests makes it easier to introduce new target types supporting new types of build outputs, either builtin to SwiftPM or vended via plugins, without awkwardly requiring them to introduce a new paired product type.

### Expanded Linker Options

Currently, the set of linker settings which can be specified in the manifest is extremely limited, in part due to how they are imparted on dependents of a target. With the changes to linker settings in this proposal, it becomes much easier to add linker settings manifest API for customizing things like rpaths and install name which can be directly applied to the target which produces a library.

## Acknowledgements

Thanks to Bri Peticca, Joannis Orlandos, Sam Khouri, Sven Schmidt, Robert Connell, Doug Schaefer, Tracy Miranda, Paulo Mattos, Rishi Benegal, and Evan Wilde for their early feedback and suggestions on this proposal.

