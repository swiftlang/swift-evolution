# Build configuration conditionals for target dependencies

* Proposal: [SE-NNNN](NNNN-swiftpm-build-configuration-conditional-target-dependencies.md)
* Authors: [Dmytro Hutsuliak](https://github.com/dmhts)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Previous Proposal: [SE-0273](0273-swiftpm-conditional-target-dependencies.md)
* Implementation: [swiftlang/swift-build#1427](https://github.com/swiftlang/swift-build/pull/1427)
* Review: ([pitch](https://forums.swift.org/t/pitch-swiftpm-build-configuration-conditionals-for-target-dependencies/88981))

## Introduction

This proposal introduces the ability for Swift package authors to conditionalize target dependencies on build configuration. It completes the unimplemented part of [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md).

## Motivation

This proposal resolves a use case that the current version of the Package Manager doesn't support very well. Packages may need to link against a library only in certain build configurations. A debug menu, for example, should not be built or linked into release builds, while a crash reporter might only be wanted in release builds.

In addition, build settings can already be conditionalized on build configuration through `BuildSettingCondition`, so the same manifest supports `.when(configuration:)` for build settings but not for target dependencies.

This proposal addresses these gaps by allowing package authors to specify which build configurations a target dependency applies to.

This capability was already accepted as part of SE-0273, which proposed conditionalizing target dependencies on both platform and build configuration. However, configuration conditionals were left unimplemented because SwiftPM still had to generate Xcode projects through `swift package generate-xcodeproj`, and those projects could not express build configuration conditionals for target dependencies at the time. That command has since been removed, so the constraint no longer applies. Under the policy on addressing unimplemented evolution proposals, the unimplemented part of SE-0273 has expired, so it needs to go through evolution again.

## Proposed solution

This proposal adds `configuration` to `TargetDependencyCondition`:
```swift
// swift-tools-version: 6.5

import PackageDescription

let package = Package(
    name: "MyPackage",
    dependencies: [
        .package(url: "https://github.com/example/crash-reporter", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "MyTarget",
            dependencies: [
                .product(
                    name: "CrashReporter",
                    package: "crash-reporter",
                    condition: .when(configuration: .release)
                ),
                .target(
                    name: "DebugMenu",
                    condition: .when(configuration: .debug)
                )
            ]
        ),
        .target(name: "DebugMenu")
    ]
)
```
As in SE-0273, this has no effect on dependency resolution. It only affects which targets are built and linked for a given build configuration.

## Detailed design

`TargetDependencyCondition` gains a `configuration` property, mirroring `BuildSettingCondition`.

```swift
public struct TargetDependencyCondition: Sendable {
    let platforms: [Platform]?
    let configuration: BuildConfiguration?
    let traits: Set<String>?
}
```

A new factory method accepts all three conditions, matching the shape `BuildSettingCondition` adopted in `PackageDescription 6.1`:

```swift
@available(_PackageDescription, introduced: 999.0)
public static func when(
    platforms: [Platform]? = nil,
    configuration: BuildConfiguration? = nil,
    traits: Set<String>? = nil
) -> TargetDependencyCondition?
```

The method returns `nil` when no conditions are given, consistent with the existing overloads on this type.

The existing `when(platforms:)`, `when(platforms:traits:)` and `when(traits:)` overloads are unchanged, and the three `Target.Dependency` factory methods (`target`, `product`, `byName`) already accept a `condition` parameter, so they need no changes.

A dependency applies only when every condition it declares is satisfied. A dependency declared with `.when(platforms: [.macOS], configuration: .debug)` therefore applies only to debug builds for macOS.

As with platform conditionals, a target does not build or link a dependency whose condition is not satisfied. Source code referencing it needs to be guarded accordingly, for example with `#if DEBUG`.

## Security

This proposal has no impact on security, safety, or privacy.

## Impact on existing packages

Current packages will not be impacted by this change as all `PackageDescription` changes will be gated by a new tools version. As always, the Package Manager will support package hierarchies with heterogeneous tools versions, so authors will be able to adopt those new APIs with minimal impact to end-users.

## Alternatives considered

No alternatives were considered.
