# SwiftPM @testable build setting

* Proposal: [SE-0455](0455-swiftpm-testable-build-setting.md)
* Authors: [Jake Petroules](https://github.com/jakepetroules)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Accepted**
* Implementation: [swiftlang/swift-package-manager#8004](https://github.com/swiftlang/swift-package-manager/pull/8004)
* Review: ([pitch](https://forums.swift.org/t/pitch-swiftpm-testable-build-setting/75084)) ([review](https://forums.swift.org/t/se-0455-swiftpm-testable-build-setting/77100)) ([acceptance](https://forums.swift.org/t/accepted-se-0455-swiftpm-testable-build-setting/77510))

## Introduction

The current Swift Package Manager build system is currently hardcoded to pass the `-enable-testing` flag to the Swift compiler to enable `@testable import` when building in debug mode. 

Swift-evolution thread: [Pitch: [SwiftPM] @testable build setting](https://forums.swift.org/t/pitch-swiftpm-testable-build-setting/75084)

## Motivation

Not all targets in a given package make use of the `@testable import` feature (or wish to use it at all), but all targets are presently forced to build their code with this support enabled regardless of whether it's needed.

Developers should be able to disable `@testable import` when it's not needed or desired, just as they're able to do so in Xcode's build system.

On Windows in particular, where a shared library is limited to 65k exported symbols, disabling `@testable import` provides developers an option to significantly reduce the exported symbol count of a library by hiding all of the unnecessary internal APIs. It can also improve debug build performance as fewer symbols exported from a binary can result in faster linking.

## Proposed solution

Add a new Swift target setting API to specify whether testing should be enabled for the specified target, falling back to the current behavior by default.

## Detailed design

Add a new `enableTestableImport` API to `SwiftSetting` limited to manifests >= 6.1:

```swift
public struct SwiftSetting {
  // ... other settings
  
  @available(_PackageDescription, introduced: 6.1)
  public static func enableTestableImport(
      _ enable: Bool,
      _ condition: BuildSettingCondition? = nil
  ) -> SwiftSetting {
     ...
  }
}
```

The existing `--enable-testable-imports` / `--disable-testable-imports` command line flag to `swift-test` currently defaults to `--enable-testable-imports`. It will be changed to default to "unspecified" (respecting any target settings), and explicitly passing `--enable-testable-imports` or `--disable-testable-imports` will force all targets to enable or disable testing, respectively.

Attempting to enable `@testable import` in release builds will result in a build warning.

## Security

New language version setting has no implications on security, safety or privacy.

## Impact on existing packages

Since this is a new API, all existing packages will use the default behavior - `@testable import` will be enabled when building for the debug configuration, and disabled when building for the release configuration.

## Future directions

In a future manifest version, we may want to change `@testable import` to be disabled by default when building for the debug configuration.

## Alternatives considered

None.
