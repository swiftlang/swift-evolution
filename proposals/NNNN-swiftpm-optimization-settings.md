# SwiftPM Optimization Settings

* Proposal: [SE-NNNN](NNNN-swiftpm-optimization-settings.md)
* Author: [Owen Voorhees](https://github.com/owenv)
* Status: **Pitch**
* Implementation: https://github.com/swiftlang/swift-package-manager/pull/10632
* Review: ([pitch](https://forums.swift.org/t/pitch-swiftpm-optimization-settings/90060))

## Motivation

Today SwiftPM defaults to optimizing code for speed in the release configuration, and disables most optimization in the debug configuration. These are sensible defaults, but they're not the best choice for every package. For example, a package may want to compile its sources with `-Osize` when compiling for a platform like watchOS. Another highly performance-sensitive package might want to enable full cross-module optimization in its release configuration to allow more of the implementation to be inlined into clients. SwiftPM should give package authors more flexibility in how these settings are configured.

## Proposed solution

Introduce three new settings in SwiftPM's manifest API:

- `.optimizationLevel(.none/.speed/.size)` can be used to set the compiler's optimization level when compiling Swift or C code. In addition to the builtin values, `.custom` can be used to specify a `-O` flag SwiftPM doesn't have builtin support for, like `-Ounchecked`.
- `.crossModuleOptimization(.disabled/.default/.full)` can be used to set the cross module optimization mode used when compiling Swift code.
- `.compilationMode(.incremental/.wholeModule)` can be used to set the compilation mode used to compile Swift code.

## Detailed Design

The full set of proposed manifest API is:

```swift
/// The compiler's optimization level.
@available(_PackageDescription, introduced: 999.0)
public struct OptimizationLevel: Sendable {
    /// Compile with no optimization. This is equivalent to passing `-Onone` to the Swift compiler or `-O0` to the C/C++ compiler.
    public static let none: OptimizationLevel = OptimizationLevel(["none"])

    /// Optimize for runtime performance. This is equivalent to passing `-O` to the Swift compiler or `-O2` to the C/C++ compiler.
    public static let speed: OptimizationLevel = OptimizationLevel(["speed"])

    /// Optimize for code size. This is equivalent to passing `-Osize` to the Swift compiler or `-Os` to the C/C++ compiler.
    public static let size: OptimizationLevel = OptimizationLevel(["size"])

    /// Manually specify an optimization level flag to use when compiling, which must begin with `-O`.
    public static func custom(_ flag: String) -> OptimizationLevel {
        OptimizationLevel(["custom", flag])
    }
}

/// Sets the optimization level used by the C compiler.
///
/// Use this setting to override the selected build configuration's default optimization level.
///
/// ```swift
/// cSettings: [
///     .optimizationLevel(.size, .when(configuration: .release)),
/// ]
/// ```
///
/// - Since: First available in PackageDescription 999.
///
/// - Parameters:
///   - level: The optimization level to use.
///   - condition: A condition that restricts the application of the build setting.
@available(_PackageDescription, introduced: 6.5)
public static func optimizationLevel(
    _ level: OptimizationLevel,
     _ condition: BuildSettingCondition? = nil
) -> CSetting

/// Sets the optimization level used by the C++ compiler.
///
/// Use this setting to override the selected build configuration's default optimization level.
///
/// ```swift
/// cxxSettings: [
///     .optimizationLevel(.size, .when(configuration: .release)),
/// ]
/// ```
///
/// - Since: First available in PackageDescription 999.
///
/// - Parameters:
///   - level: The optimization level to use.
///   - condition: A condition that restricts the application of the build setting.
@available(_PackageDescription, introduced: 6.5)
public static func optimizationLevel(
    _ level: OptimizationLevel,
    _ condition: BuildSettingCondition? = nil
) -> CXXSetting

/// Sets the optimization level used by the Swift compiler.
///
/// Use this setting to override the selected build configuration's default optimization level.
///
/// ```swift
/// swiftSettings: [
///     .optimizationLevel(.size, .when(configuration: .release)),
/// ]
/// ```
///
/// - Since: First available in PackageDescription 999.
///
/// - Parameters:
///   - level: The optimization level to use.
///   - condition: A condition that restricts the application of the build setting.
@available(_PackageDescription, introduced: 999.0)
public static func optimizationLevel(
    _ level: OptimizationLevel,
    _ condition: BuildSettingCondition? = nil
) -> SwiftSetting 
```

Notably, the `optimizationLevel` API doesn't try to represent every optimization level accepted by Swift/Clang. For example, it omits discouraged flags like Swift's `-Ounchecked` and lesser used flags like Clang's `-O1`. The `.custom` API allows specifying these options without permanently committing to them as manifest API. The specific mapping of manifest settings to compiler flags is implementation-defined and may change over time alongside the compilers.

```swift
/// The cross-module optimization mode used by the Swift compiler.
@available(_PackageDescription, introduced: 999.0)
public enum CrossModuleOptimization: Sendable {
    /// Use the compiler's default cross-module optimization behavior, which exposes some optimization opportunities to clients in release builds.
    case `default`

    /// Disable cross-module optimization. This is equivalent to passing `-disable-cmo` to Swift.
    case disabled

    /// Use the compiler's full cross-module optimization behavior, which exposes additional optimization opportunities to clients. This is equivalent to passing `-cross-module-optimization` to Swift.
    case full
}

/// Sets the cross-module optimization mode used by the Swift compiler.
///
/// Cross-module optimization allows the compiler to perform more cross-module inlining and optimization by exposing parts of this module's implementation to clients.
///
/// ```swift
/// swiftSettings: [
///     .crossModuleOptimization(.full, .when(configuration: .release)),
/// ]
/// ```
///
/// - Since: First available in PackageDescription 999.
///
/// - Parameters:
///   - mode: The cross-module optimization mode to use.
///   - condition: A condition that restricts the application of the build setting.
@available(_PackageDescription, introduced: 999.0)
public static func crossModuleOptimization(
    _ mode: CrossModuleOptimization,
    _ condition: BuildSettingCondition? = nil
) -> SwiftSetting
```

Consistent with other manifest settings, customizing a target's cross module optimization setting (and the other settings introduced in this proposal) does not impact how the target's dependencies are compiled. If a target wants to, for example, expose more of its implementation to clients in support of optimization, that target must explicitly enable full CMO.

```swift
/// The compilation mode used by the Swift compiler.
@available(_PackageDescription, introduced: 999.0)
public enum CompilationMode: Sendable {
    /// Compile the module's source files separately, in-parallel, enabling incremental builds.
    case incremental

    /// Compile all of the module's source files together, enabling whole-module optimization.
    case wholeModule
}

/// Sets the compilation mode used by the Swift compiler.
///
/// Use this setting to override the selected build configuration's default compilation mode.
///
/// ```swift
/// swiftSettings: [
///     .compilationMode(.incremental, .when(configuration: .release)),
/// ]
/// ```
///
/// - Since: First available in PackageDescription 999.
///
/// - Parameters:
///   - mode: The compilation mode to use.
///   - condition: A condition that restricts the application of the build setting.
@available(_PackageDescription, introduced: 999.0)
public static func compilationMode(
    _ mode: CompilationMode,
    _ condition: BuildSettingCondition? = nil
) -> SwiftSetting
```

Not all combinations of the new settings are valid:

| `optimizationLevel` | `compilationMode` | `crossModuleOptimization` | Reason |
|---|---|---|---|
| Any | `.incremental` | `.full` | CMO requires compiling in whole module mode, so this has no effect |
| `.none` | `.wholeModule` | `.full` | CMO requires compiling with optimizations enabled, so this has no effect |

SwiftPM will report an error in these situations.

## Security

## Impact on existing packages

None. There is no change to the build of packages which don't adopt the new manifest API.

## Future Directions

### Change Default CMO Level for Packages

In the past, enabling more aggressive CMO for the release configuration of packages has been discussed. However, this proposal is intended to be solely additive, and the new API doesn't prevent us from changing the default configurations in the future.
