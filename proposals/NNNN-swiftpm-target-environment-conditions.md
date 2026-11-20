# Target environment conditions in package manifests

* Proposal: [SE-NNNN](NNNN-swiftpm-target-environment-conditions.md)
* Authors: [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Prototype only
* Related Proposals:
    - [SE-0273: Package Manager Conditional Target Dependencies][SE-0273]
    - [SE-0387: Swift SDKs for Cross-Compilation][SE-0387]

## Summary of changes

Adds an optional environment to the platforms of the `.when(platforms:)`
conditions of build settings and target dependencies. A platform with an
environment matches the OS and the environment component of the target triple,
for example `.iOS(environment: .simulator)` for `arm64-apple-ios17.0-simulator`.
The environment is the same value that the existing `#if targetEnvironment(...)`
evaluates in code.

## Motivation

A target triple has an architecture, a vendor, an OS and an optional
environment. The environment selects a variant of the OS that has a different
ABI or different libraries:

| Triple | Environment |
|---|---|
| `arm64-apple-ios17.0-simulator` | The iOS simulator |
| `arm64-apple-ios17.0-macabi` | Mac Catalyst |
| `x86_64-unknown-linux-gnu` | Linux with glibc |
| `x86_64-swift-linux-musl` | Linux with musl, for example the Static Linux SDK |
| `aarch64-unknown-linux-android` | Android |

Swift code can check some of these environments with `#if
targetEnvironment(simulator)` and `#if targetEnvironment(macCatalyst)`. Package
manifests can't check most of them. A `.when(platforms:)` condition matches only
the OS. Thus, a package can't do these things in its manifest:

- Link a different library for the simulator and for the device.
- Select a different implementation of a dependency for Linux with musl and for
  Linux with glibc.
- Select an implementation for an environment that a Swift SDK defines, if the
  rest of its triple is the same as the triple of an existing platform.

Today, packages work around this with `#if` checks in source code, or with
traits that the root package must enable, but this requires the traits to be
wired through to all transitive dependencies.

An environment is only meaningful together with a platform. For example,
`simulator` is a different environment for iOS than for a platform of another
vendor.

## Proposed solution

A package can add an environment to a platform in a condition:

```swift
import PackageDescription

let package = Package(
    name: "Example",
    targets: [
        // An implementation of `fts` for C libraries that don't have it, such as musl.
        .target(name: "CFTS"),
        .target(
            name: "FileWalker",
            dependencies: [
                .target(
                    name: "CFTS",
                    condition: .when(platforms: [.linux(environment: .musl)])
                ),
            ]
        ),
    ]
)
```

On Linux with glibc, `fts_open()` and the other `fts` functions are part of the
C library, and the `CFTS` target doesn't build. On Linux with musl, `FileWalker`
depends on `CFTS`, and Swift code in `FileWalker` checks `#if canImport(CFTS)`.

A platform without an environment matches the platform only, the same as today.
A condition with more than one platform is true if one of them matches.

## Detailed design

### PackageDescription API

```swift
/// The environment component of the target triple, such as the simulator.
public struct TargetEnvironment: Sendable, Equatable {
    /// The simulator environment.
    public static let simulator: TargetEnvironment

    /// The macabi environment.
    public static let macabi: TargetEnvironment

    /// The android environment.
    public static let android: TargetEnvironment

    /// The GNU C library environment.
    public static let gnu: TargetEnvironment

    /// The musl C library environment.
    public static let musl: TargetEnvironment

    /// The Microsoft Visual C++ environment.
    public static let msvc: TargetEnvironment

    /// A target environment with the given name in the target triple.
    public static func custom(_ name: String) -> TargetEnvironment
}

extension Platform {
    /// The platform, restricted to triples with the given environment.
    ///
    /// There is one function for each existing platform, for example
    /// `.iOS(environment:)` and `.linux(environment:)`.
    public static func iOS(environment: TargetEnvironment) -> Platform
    public static func linux(environment: TargetEnvironment) -> Platform

    /// A platform that is not known to SwiftPM, for example the OS of a custom
    /// Swift SDK, restricted to triples with the given environment.
    public static func custom(name: String, environment: TargetEnvironment) -> Platform
}
```

The static properties are the environments that the toolchains of swift.org and
the Swift SDKs of swift.org use today.

### Matching

A platform with an environment matches if both parts match:

- The platform matches the same way as a platform without an environment.
- The environment matches the environment component of the target triple of the
  build.

A condition without an environment doesn't evaluate the environment. Thus,
`.linux` matches `x86_64-unknown-linux-gnu` and `x86_64-swift-linux-musl`.

These existing platform static properties are short-hands for a platform with an
environment:

| Existing platform | With an environment |
|---|---|
| `.macCatalyst` | `.iOS(environment: .macabi)` |
| `.android` | `.linux(environment: .android)` |

The environment name matches by these rules:

- **A known environment** matches the name of the environment, and ignores its
  version. For example, `.android` matches `aarch64-unknown-linux-android28` for
  all API levels.
- **A custom environment** matches the complete environment component of the
  triple. The match is exact and case-sensitive.
- A triple without an environment matches no platform with an environment.

### Evaluation

SwiftPM gets the platform and the environment from the target triple of the
build. This is the triple that developers pass to `--triple`, or the triple of
the Swift SDK that's passed to `--swift-sdk`. For a build for the host, it is
the host triple.

### #targetEnvironment behavior

Today `#if targetEnvironment(...)` in Swift code only recognizes `simulator` and
`macCatalyst`. For other environments, the compiler shows a warning and the
condition is false. With this proposal, `targetEnvironment(name)` is true if
`name` is the environment of the target triple, following the same rules as in
[Matching](#matching). This aligns the behavior of a manifest condition and an
`#if` check in the code.

## Source compatibility

The proposal adds new API to PackageDescription. Existing manifests don't
change.

`#if targetEnvironment(name)` can become true for a name that was false before,
if the target triple has that environment. Code that checks for an environment
that it doesn't build for doesn't change.

## ABI compatibility

The proposal doesn't change the ABI of existing code.

## Implications on adoption

A package that uses the new API requires the tools version that ships the new
API. A package that must also support older tools can put the new conditions in
a manifest with a version-specific name, for example `Package@swift-6.5.swift`.

## Future directions

### Conditions on the architecture

A `.when(architectures:)` condition could match the architecture of the target
triple in the same way.

### Platforms for the WASI versions

`wasip1`, `wasip2` and `wasip3` are values of the OS component of the triple.
Today there is only a single `.wasi` platform today. New platforms for each
version could allow a more granular matching. The `threads` capabilities of
`wasm32-unknown-wasip1-threads` is an environment which can be matched with this
proposal using `.custom("threads")`.

### Matching a platform without an environment

`.iOS` matches the device and the simulator. A condition can't match the device
only. A new value for "no environment" would allow to express this.

### Versions of an environment

A condition could match a version of an environment, for example the API level
of Android.

## Alternatives considered

### A separate `targetEnvironments` parameter

An earlier version of this proposal had a `targetEnvironments` parameter next to
`platforms` but environments are inherently tied to platforms. For example,
`.when(platforms: [.linux, .iOS, .freeBSD], targetEnvironments: [.simulator])`
can match three different meanings of `simulator`. An environment as a part of
the platform doesn't allow this combination.

[SE-0273]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md
[SE-0387]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md
