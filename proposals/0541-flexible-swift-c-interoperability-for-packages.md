# Flexible Swift/C Interoperability for Packages

* Proposal: [SE-0541](0541-flexible-swift-c-interoperability-for-packages.md)
* Authors: [Owen Voorhees](https://github.com/owenv)
* Review Manager: [Tim Condon](https://github.com/0xTim)
* Status: **Active review (August 5...August 19, 2026)**
* Implementation: [PR #10292](https://github.com/swiftlang/swift-package-manager/pull/10292), [PR #1537](https://github.com/swiftlang/swift-build/pull/1537), [PR #1546](https://github.com/swiftlang/swift-build/pull/1546), [PR #90774](https://github.com/swiftlang/swift/pull/90774)
* Review: ([pitch](https://forums.swift.org/t/pitch-flexible-swift-c-interoperability-in-packages/88354)) ([review](https://forums.swift.org/t/se-0541-flexible-swift-c-interoperability-for-packages/88796))

## Introduction

Swift has great support for bidirectional interoperability with C, C++, and Objective-C, but historically SwiftPM has restricted the set of interop features available to package authors. This proposal lifts most of those restrictions, giving packages a new set of tools to organize their code.

## Motivation

Swift provides a number of tools for interoperating with C/C++/Objective-C code:

- Swift code can directly import code which has been organized into a Clang module. This is the primary interop mechanism used by Swift packages today. For example, many existing packages contain a Swift `Library` target, and a C `LibraryCShims` target which defines a Clang module to import some C API. 
- A Swift module can expose a generated header which exposes `@c`/`@objc` annotated API to C code. This is partially supported by packages today, with some notable limitations.
- A Swift module can reexport an underlying Clang module with the same name, providing a unified Swift and C API surface through a single import. This is not supported by packages today, because a package target is not permitted to include both Swift and C-family sources.
- A Swift module can provide the implementation for a C header using `@implementation`. This is poorly supported in packages today, again because package targets do not allow mixing Swift and C sources.
- A Swift module can use a bridging header to import non-modular C code. This is not supported in packages today.

The goal of this proposal is to give package authors the flexibility to use whichever interop mechanism best fits their use case, while continuing to ensure they provide interfaces that can be soundly consumed by dependent packages.

## Proposed solution

This proposal includes three changes intended to allow packages to take full advantage of Swift's interop features:

1. Lift existing limitations and allow packages to freely mix Swift and C sources within a target
2. Add new manifest API which allows targets to specify a bridging header for a mixed source target
3. Fix soundness issues which can prevent use of a Swift-only target's generated header in a C target's interface

## Detailed design

### Mixed Source Targets

Today, SwiftPM reports an error if a target includes both Swift and C-family sources. This proposal lifts that limitation and allows the sources directory to contain any combination of Swift, C, C++, and Objective-C sources. Regular, executable, test, and macro targets are all supported as mixed source targets. This change is not applicable to binary and system library targets because they don't have associated sources. Plugin targets are interpreted as part of the build planning process and intended to be lightweight, so remain restricted to containing only Swift sources. However, any executable targets invoked as part of a task planned by a build tool plugin may be mixed source targets.

#### Headers and Module Maps

The rules for header organization in a mixed source target are largely the same as a C-only target. By default, the `include` subdirectory of the target sources directory is considered the target's public headers path. This path can be customized using the `publicHeadersPath` parameter when declaring a new target. As part of this proposal, the `testTarget` and `macro` Manifest API will each add new overloads which expose a `publicHeadersPath` parameter identical to the existing one on `target` and `executableTarget`.

SwiftPM will also generate a module map for a mixed source target in most cases, just as it would for a C-only target:

- If the public headers directory contains a `module.modulemap` file, it will be used and no modulemap will be generated.
- If the public headers directory contains a header whose basename matches the module name, a module map will be generated using that header as the umbrella header.
- If the public headers directory contains a directory whose name matches the module name, that directory contains a header whose basename also matches the module name, and the top-level public headers directory is otherwise empty, a module map will be generated using that header as the umbrella header.
- Otherwise, a module map will be generated using the public headers directory as an umbrella directory.

When SwiftPM generates a module map, it will include the Swift generated header in the Clang module of a mixed source target. This allows downstream C-family targets to consume API declared in Swift sources. When compiling the Swift sources of a mixed source target, the generated header is excluded from the underlying Clang module to avoid introducing a dependency cycle.

Historically, the Swift-generated header for a mixed source module has assumed the underlying Clang module has an umbrella header named after the module which is available via a Darwin-framework-style include. This assumption doesn't always hold for packages, which offer more flexibility when organizing code into a module. Under this proposal, the generated header for a mixed source package target will include headers from the underlying module (if needed) via quoted includes relative to the public headers directory, ensuring dependents are able to successfully consume it.

When the package provides a custom module map, the Swift generated header is not covered by the underlying Clang module. SwiftPM currently references headers and custom module maps directly in the sources directory. Extending these custom module maps would require either:

1. Introducing a mechanism to describe how headers/module maps can be copied to and referenced from an install location. This would allow the build system to process them as they are copied and inject the generated header. It's also desirable for other reasons beyond the scope of this proposal. For example, it would allow a package to describe how a library product should assemble its binary and interfaces for distribution.
2. Injecting a VFS into compilation of dependencies to redirect custom module map lookups to a copy which injects the generated header.

The first option is more future-proof compared to the second, but designing it is outside the scope of this proposal. This proposal defers the decision for now to reduce scope and avoid changes which might restrict future evolution.

#### C-Family Language Settings for Mixed Source Targets

The existing `publicHeadersPath`, `cSettings` and `cxxSettings` API can be used to configure how C-family sources in a mixed source target are compiled. This proposal introduces new `macro` and `testTarget` target API, as these target types don't currently expose the full set of configuration options:

```swift
    @available(_PackageDescription, introduced: 999)
    static func macro(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        publicHeadersPath: String? = nil, // New
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil, // New
        cxxSettings: [CXXSetting]? = nil, // New
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target

    @available(_PackageDescription, introduced: 999)
    public static func testTarget(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil, // New
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [PluginUsage]? = nil
    ) -> Target
```

The existing `.interoperabilityMode` API determines how a mixed source target's underlying Clang module is imported.

#### PackagePlugin Changes

The `PackagePlugin` module currently exposes distinct `SwiftSourceModuleTarget` and `ClangSourceModuleTarget` types to plugin authors, both of which conform to the `SourceModuleTarget` protocol. This proposal deprecates `SwiftSourceModuleTarget`/`ClangSourceModuleTarget` and adds the following new requirements to `SourceModuleTarget` which were previously exposed only on the concrete types:

```swift
    /// Any custom compilation conditions for the Swift sources of the module.
    @available(_PackageDescription, introduced: 999.0)
    var swiftCompilationConditions: [String] { get }

    /// Any preprocessor definitions for the C-family sources of the module.
    @available(_PackageDescription, introduced: 999.0)
    var clangPreprocessorDefinitions: [String] { get }

    /// Any custom header search paths.
    @available(_PackageDescription, introduced: 999.0)
    var headerSearchPaths: [String] { get }

    /// The directory containing public headers
    @available(_PackageDescription, introduced: 999.0)
    var publicHeadersDirectoryURL: URL? { get }
```

With these additions, `SourceModuleTarget` is now capable of exposing the full set of details for a mixed source target. Instead of conditionally casting a `SourceModuleTarget` to a concrete type, plugin implementations should use the new protocol requirements directly.

To maximize compatibility with existing plugins, SwiftPM will continue to use `SwiftSourceModuleTarget` as the concrete type for Swift-only targets and `ClangSourceModuleTarget` for C-family-only targets. Mixed source targets will be represented using an internal type which conforms to `SourceModuleTarget` but is not exposed as public API. A plugin which has not yet been updated to account for mixed source targets should continue to work without changes when applied to packages which have not adopted the feature. If an existing plugin is applied to a package that has adopted mixed source targets, it should continue to work unless it relies on being able to cast any target to an instance of one of the deprecated concrete types. This protocol-based approach also means that it is possible for plugins to support working with mixed source targets without raising their own tools version, so long as they are written to use `SourceModuleTarget` and don't rely on the new requirements added in this proposal.

### Bridging Header Configuration

Bridging headers provide an easy way for Swift code to interact with non-modular C. This proposal introduces new SwiftSetting API which allows any regular, executable, test, or macro target with Swift sources to configure a bridging header:
```swift
    /// The visibility of a bridging header's imported declarations.
    @available(_PackageDescription, introduced: 999.0)
    public enum BridgingHeaderVisibility: String {
        /// Declarations imported via the bridging header may appear in the target's public API.
        case `public`
        /// Declarations imported via the bridging header may only be used internally.
        case `internal`
    }

    /// Configures a bridging header for the target's Swift sources.
    ///
    /// A bridging header allows Swift code to import non-modular C/C++/Objective-C code.
    ///
    /// - Parameters:
    ///   - path: The path of the bridging header, relative to the target's sources directory.
    ///   - visibility: Whether declarations imported via the bridging header may appear in the
    /// target's public API. Library targets may only use `.internal` visibility.
    ///   - condition: A condition that restricts the application of the build setting.
    @available(_PackageDescription, introduced: 999.0)
    public static func bridgingHeader(
      _ path: String,
      visibility: BridgingHeaderVisibility,
      _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting
```

The bridging header path is specified relative to the target's `Sources` directory. It must not be inside the target's public headers directory. A target may not include more than one bridging header. Bridging header visibility may be `.public` or `.internal`, and determines whether API imported via a bridging header may appear in public declarations of the consumer. Regular (library) targets are only allowed to import a bridging header with `.internal` visibility to ensure they present a consistent interface to downstream targets. The existing `interoperabilityMode` setting determines how the bridging header is interpreted.

As a general guideline, package authors should prefer to modularize their C code where possible instead of using a bridging header. However, modularization can be resource intensive when first adopting Swift as part of a large existing C codebase. Bridging headers are a good fit when they're use to facilitate incremental adoption of Swift, and allow packages to quickly get up and running with interoperability as they fully modularize over a longer period of time.

### Modularizing the Swift Generated Header of Swift-only Targets

Currently, SwiftPM will generate a module map covering the Swift generated header for a Swift-only target. This allows downstream C-family targets to import API annotated with @c/@objc. However, this module map is currently only visible to downstream C targets. Consider a package with three targets:

- TargetA is Swift-only and exposes a public `@objc` class type `Foo`.
- TargetB is Objective-C-only, depends on TargetA, and exposes a function `bar` which returns a value of type `Foo`.
- TargetC is Swift-only, depends on TargetB, and contains a call to `bar`.

This package would fail to compile under tools-version 6.4, because when compiling TargetC's Swift sources, the declaration of `Foo` would not be visible when importing TargetB's Clang module.

Under this proposal the module map covering the generated module will be made visible to all downstream compiles in the upcoming tools-version, allowing this example to build successfully.

### Examples

Below are two examples of how the features in this proposal can be used to simplify the build of existing packages.

#### Adopting an Underlying Module in Swift Numerics

[swift-numerics](https://github.com/apple/swift-numerics) has a `_NumericsShims` target whose only purpose is to expose `static inline` wrappers around compiler builtins to the `RealModule` target:

```
swift-numerics/
  ...
  Sources/
    _NumericsShims/
      include/
        _NumericsShims.h // Vends wrappers
        module.modulemap
      _NumericsShims.c
    RealModule/
      ...
      Double+Real.swift // imports _NumericsShims and consumes wrappers
      ...
    ...
  ...
```

```swift
    // ...
    .target(
      name: "RealModule",
      dependencies: ["_NumericsShims"],
      exclude: excludedFilenames,
      linkerSettings: [
        .linkedLibrary("m", .when(platforms: [.linux, .android]))
      ]
    ),
    
    // MARK: - Implementation details
    .target(
      name: "_NumericsShims",
      exclude: excludedFilenames
    ),
    // ...
```

The `_NumericsShims` wrappers appear in inlinable function bodies in the `RealModule` library target, so a bridging header isn't a good fit. However, this is a good example of a case where the two targets could be combined into one mixed source target with an underlying Clang module. The updated package looks like this:

```
swift-numerics/
  ...
  Sources/
    RealModule/
      include/
        _NumericsShims.h
    Double+Real.swift
    ...
  ...
```

```swift
    // ...
    .target(
      name: "RealModule",
      exclude: excludedFilenames,
      linkerSettings: [
        .linkedLibrary("m", .when(platforms: [.linux, .android]))
      ]
    )
    // ...
```

In the updated package `RealModule` is a simpler, self-contained target with no dependencies, and the Swift sources can directly call the wrappers which are implicitly imported from the underlying Clang module. 

#### Adopting a Bridging Header in swift-format

Like Swift Numerics, [swift-format](https://github.com/swiftlang/swift-format) is also split into multiple targets to facilitate C interop. The `swift-format` executable depends on the `_SwiftFormatInstructionCounter` C target, which exposes a single function to the Swift code. This interface could be modularized, but here we use it to demonstrate a simplified case of bridging header adoption (Most real-world bridging header adoption is likely to occur in significantly larger, more complex codebases that can't be trivially modularized). Currently, Swift Format is organized like this:

```
swift-format/
  Sources/
    _SwiftFormatInstructionCounter/
      include/
        InstructionsExecuted.h
        module.modulemap
      src/
        InstructionsExecuted.c
    swift-format/
      Subcommands/
        PerformanceMeasurement.swift // import _SwiftFormatInstructionCounter
      ...
    ...
  ...
```

```swift
  // ...
  .target(
    name: "_SwiftFormatInstructionCounter",
    exclude: ["CMakeLists.txt"]),
  .executableTarget(
    name: "swift-format",
    dependencies: [
      "_SwiftFormatInstructionCounter",
      "SwiftFormat",
      // ...
    ],
    exclude: ["CMakeLists.txt"],
    linkerSettings: swiftformatLinkSettings),
  // ...
```

After adopting a bridging header, the updated package is organized like this:

```
swift-format/
  Sources/
    swift-format/
      InstructionsExecuted.c
      swift-format-bridging-header.h
      Subcommands/
        PerformanceMeasurement.swift
      ...
    ...
  ...
```

```swift
  // ...
  .executableTarget(
    name: "swift-format",
    dependencies: [
      "SwiftFormat",
      // ...
    ],
    exclude: ["CMakeLists.txt"],
    swiftSettings: [.bridgingHeader("swift-format-bridging-header.h", visibility: .internal)],
    linkerSettings: swiftformatLinkSettings),
  // ...
```

Again, the reorganization results in a simpler, easier to maintain package.

## Security

This proposal only impacts how packages organize and build their sources. It does not meaningfully impact package manager security.

## Impact on existing packages

- Packages using existing tools versions will continue to build as they do today.
- When upgrading to a new tools version, there is a small chance that the changes described under "Modularizing the Swift Generated Header" may introduce source compatibility edge cases by exposing the API in the generated header to new dependents.
- Existing package plugins may require updates to support being applied to packages which adopt the new features, as described in the "PackagePlugin Changes" section.
- Other behavioral changes in this proposal, like mixed source targets and bridging header support, require adopting a new tools version.

## Alternatives considered

### Expose a Concrete Type for Mixed Source Targets in PackagePlugin

The "PackagePlugin Changes" section proposes encouraging plugins to interact primarily with the `SourceModuleTarget` protocol as opposed to the concrete types which conform to it. Instead, we could introduce a new `GenericSourceModuleTarget` type to represent mixed source targets, or add C-related settings fields to the existing `SwiftSourceModuleTarget`. This would allow plugins to continue using the same type-casting patterns they're encouraged to use today.

This direction was not chosen primarily because it makes it more difficult to migrate towards a model where a single type is used to interact with Swift-only, Clang-only, and mixed source targets. With the proposed design, `SourceModuleTarget` becomes that type, but existing plugins continue to work when applied to packages that don't contain a mixed source target. If we introduced `GenericSourceModuleTarget`, using that type to represent Swift-only and Clang-only targets would be a larger breaking change for existing package plugins.

### Support Extending Custom Module Maps with the Swift Generated Header

Under the current proposal, mixed source targets with a custom module map are not extended to include the Swift generated header. This is a somewhat unintuitive limitation, and one which should be addressed in the long term. While it is technically possible to support, for the reasons described in the "Headers and Module Maps" section this proposal maintains this limitation for now to avoid constraining future evolution related to how SwiftPM manages header installation and library distribution.

## Acknowledgements

Mixed source target support was previously proposed in [SE-0403: Package Manager Mixed Language Target Support](0403-swiftpm-mixed-language-targets.md) by [Nick Cooke](https://github.com/ncooke3). That proposal and its review discussion helped inform the design of the "Mixed Source Targets" section.
