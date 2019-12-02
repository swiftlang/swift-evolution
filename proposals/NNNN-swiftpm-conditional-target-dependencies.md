# Package Manager Conditional Target Dependencies

* Proposal: [SE-NNNN](NNNN-swiftpm-conditional-target-dependencies.md)
* Authors: [David Hart](https://github.com/hartbit)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: [apple/swift-package-manager#2428](https://github.com/apple/swift-package-manager/pull/2428)

## Introduction

This proposal introduces the ability for Swift package authors to conditionalize target dependencies on platform and configuration with a similar syntax to the one introduced in [SE-0248](0238-package-manager-build-settings.md) for build settings. This gives developers more flexibility to describe complex target dependencies to support multiple platforms or different configuration environments.

## Motivation

This proposal resolves two use cases that the current version of the Package Manager doesn't support very well. In the first scenario, packages that span multiple platforms may need to depend on different libraries depending on the platform, as can be the case for low-level, platform-specific code. In a second scenario, packages may want to link against libraries only in certain configurations, for example when importing debug libraries, which do not make sense to build and link in release builds, or when importing instrumentation logic, which only make sense in release builds when the developer can not benefit from debugging.

This proposal attempts to bring solutions to those use cases by allowing package authors to define under what build environments dependencies need to be built and linked against targets.

## Proposed solution

To allow package authors to append conditions to target dependencies, we introduce new APIs to the `Package.swift` manifest library. The `.target`, `.product`, and `.byName` will be optionally configurable with a `condition` argument of the same format as for build settings, to specify the platforms and configuration under which that dependency should be enabled. For example:

```swift
// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "BestPackage",
    dependencies: [
        .package(url: "https://github.com/pureswift/bluetooth", .branch("master")),
        .package(url: "https://github.com/pureswift/bluetoothlinux", .branch("master")),
    ],
    targets: [
        .target(
            name: "BestExecutable",
            dependencies: [
                .product(name: "Bluetooth", condition: .when(platforms: [.macOS])),
                .product(name: "BluetoothLinux", condition: .when(platforms: [.linux])),
                .target(name: "DebugHelpers", condition: .when(configuration: .debug)),
            ]
        ),
        .target(name: "DebugHelpers")
     ]
)
```

It is important to note that this proposal has no effect on dependency resolution, but only affects which targets are built and linked against each other during compilation. In the previous example, both the `Bluetooth` and `BluetoothLinux` packages will be resolved regardless of the platform, but when building, the Package Manager will avoid building the disabled dependency and will link the correct library depending on the platform. It will also build and link against the `DebugHelpers` target, but only in debug builds.

## Detailed design

### New `PackageDescription` API

All the cases of the `Target.Dependency` enum will gain a new optional `BuildSettingCondition` argument. The current static factory functions for initializing those enums will be obsoleted in the version of the tools this proposal will appear in, and new functions will take their place, introducing a new optional argument:

```swift
extension Target.Dependency {
    /// Creates a dependency on a target in the same package.
    ///
    /// - Parameters:
    ///   - name: The name of the target.
    ///   - condition: The condition under which the dependency is exercised.
    @available(_PackageDescription, introduced: 5.3)
    public static func target(name: String, condition: BuildSettingCondition? = nil) -> Target.Dependency {
        // ...
    }

    /// Creates a dependency on a product from a package dependency.
    ///
    /// - Parameters:
    ///   - name: The name of the product.
    ///   - package: The name of the package.
    ///   - condition: The condition under which the dependency is exercised.
    @available(_PackageDescription, introduced: 5.3)
    public static func product(
        name: String,
        package: String? = nil,
        condition: BuildSettingCondition? = nil
    ) -> Target.Dependency {
        // ...
    }

    /// Creates a by-name dependency that resolves to either a target or a product but
    /// after the package graph has been loaded.
    ///
    /// - Parameters:
    ///   - name: The name of the dependency, either a target or a product.
    ///   - condition: The condition under which the dependency is exercised.
    @available(_PackageDescription, introduced: 5.3)
    public static func byName(name: String, condition: BuildSettingCondition? = nil) -> Target.Dependency {
        // ...
    }
}
```

## Security

This proposal has no impact on security, safety, or privacy.

## Impact on existing packages

Current packages will not be impacted by this change as all `PackageDescription` changes will be gated by a new tools version. As always, the Package Manager will support package hierarchies with heterogeneous tools versions, so authors will be able to adopt those new APIs with minimal impact to end-users.

## Alternatives considered

No alternatives were considered for now.
