# Package Manager Conditional Plugin

* Proposal: SE-NNNN
* Authors: [Clive Liu](https://github.com/clive819)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal extends the `plugins` parameter of SwiftPM target declarations to support conditional plugin application. A new `PluginUsageCondition` type lets package authors gate a plugin on the **host platform** (where the plugin will run), the **target platform** (where the compiled product will run), and the **traits** enabled for the build. This follows the `.when(...)` pattern established by [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md) and [SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md), but is shaped to fit the distinct host/target story that plugins have.

This proposal applies only to build tool plugins ([SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md)) used via a target's `plugins:` parameter. Command plugins ([SE-0332](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md)) are invoked explicitly through `swift package <verb>` and are not affected.

## Motivation

[SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) introduced build tool plugins, and [SE-0332](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md) added command plugins. Plugins are widely used for linting (SwiftLint), formatting (SwiftFormat), code generation (SwiftGen, SwiftProtobuf), and documentation (DocC). However, the `plugins` parameter on target declarations does not support any form of conditional application.

This is an important gap because build tool plugins are part of the *build environment*, not the built product. A package may be portable across platforms while some of its plugins are only relevant, available, or desirable on certain build hosts. A plugin may also emit output that is only valid for certain target platforms. SwiftPM already lets package authors conditionalize target dependencies and build settings, but not plugin application.

This creates a few practical problems:

1. **Host-specific tooling cannot be expressed declaratively.** Build tool plugins run on the machine performing the build. A linter, formatter, code generator, or documentation tool may only be supported on a subset of host platforms, or may depend on host-specific toolchains and SDKs. Today there is no manifest-level way to say "apply this plugin only on macOS" or "only when building on a host that opts into linting".
2. **Target-specific tooling cannot be expressed either.** A plugin may generate code that only compiles on certain target platforms — for example, a code generator that emits iOS-only bridging shims. Even on a capable host, the plugin shouldn't run when building the package's Linux-server product. [SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) explicitly anticipated this gap (Future Directions → *Contextual Information About the Target Platform*).
3. **Development-only workflow tools are forced into every build.** Many plugins are valuable for maintainers but are not actually required to build the package's product. Linters are the clearest example: they enforce policy and improve developer ergonomics, but they do not change the package's runtime behavior. Without conditional plugin application, package authors must either run such tools everywhere or fall back to manifest workarounds.
4. **Plugins can impose substantial build cost even when they are not always desired.** Build tool plugins participate in build planning and execution. In some cases they also have noticeable impact on incremental builds. This makes traits a natural fit for plugin application: package authors should be able to attach tools like linting or optional generation to the manifest while letting users opt in only when they want them.
5. **There is no first-class manifest feature for this.** Package authors who need host-, target-, or trait-specific plugin application must fall back to manifest compilation conditionals and helper variables instead of expressing the condition inline where the plugin is declared.

Consider a package developed on macOS that uses SwiftLint as a build tool plugin:

```swift
.executableTarget(
    name: "MyTool",
    plugins: [
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
    ]
)
```

SwiftLint distributes a pre-built binary artifact bundle. That binary is compiled against a newer glibc than what ships on some Linux distributions (e.g., Amazon Linux 2). When building this package on such a system, the build fails immediately - not because of any issue with the package's own code, but because the plugin binary cannot execute:

```
swiftlint: /lib64/libc.so.6: version `GLIBC_2.34' not found
error: failed: PrebuildCommand(...)
```

The build never reaches compilation. The plugin is a development tool that is only meaningful on the developer's workstation - it has no effect on the compiled output. Yet there is no way to express "apply this plugin only on macOS" in the package manifest.

### Current workarounds

The only workaround today is to use `#if` conditions in `Package.swift` to conditionally define the plugins array:

```swift
#if os(Linux)
let lintPlugins: [Target.PluginUsage] = []
#else
let lintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]
#endif
```

This works, but it has several drawbacks:

1. **Inconsistency with the rest of the manifest API.** Target dependencies support `.when(platforms:)` ([SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md)) and `.when(traits:)` ([SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)). Plugin usage is the only target-level configuration that lacks conditional support.
2. **Verbose and error-prone.** Every target that uses the plugin must reference the computed variable instead of declaring the plugin inline. For packages with many targets, this scatters the conditional logic away from where it is used.
3. **Misleading under cross-compilation.** `Package.swift` is parsed once on the host, so `#if os(...)` checks are evaluated against the host platform and cannot express target-platform-specific gating.
4. **Scales poorly.** If a package needs different plugins on different hosts or behind different traits, the `#if` blocks multiply.
5. **Breaks the declarative model.** `Package.swift` is designed to be a declarative manifest. Manifest compilation conditionals are an escape hatch, not a first-class feature - they are evaluated when the manifest is compiled, not when SwiftPM plans the build.

### Traits are a particularly good fit for plugins

Traits are especially useful for plugin application because many plugins represent workflow policy rather than product semantics. A package may reasonably want to define a `Lint` trait and apply a linter plugin only when that trait is enabled, for example via `swift build --traits Lint`. The same applies to optional code generation or documentation workflows.

## Proposed solution

Extend `Target.PluginUsage` to accept an optional `condition` parameter using a new `PluginUsageCondition` type. The condition can independently constrain the host platform, the target platform, and the set of enabled traits:

```swift
.executableTarget(
    name: "MyTool",
    plugins: [
        .plugin(
            name: "SwiftLintBuildToolPlugin",
            package: "SwiftLintPlugins",
            condition: .when(hostPlatforms: [.macOS])
        ),
    ]
)
```

The host and target axes are expressed as separate parameters because plugins have a genuine two-sided story: a plugin runs on the host but produces output for the target. [SE-0387](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md) defines "host" as the machine where code is built and "target" as the machine where code runs. `hostPlatforms:` gates on the former (e.g., a plugin backed by a macOS-only binary artifact); `targetPlatforms:` gates on the latter (e.g., a Metal shader code generator whose output only compiles on Apple platforms):

```swift
.plugin(
    name: "MetalShaderGenerator",
    package: "MetalShaderGenerator",
    condition: .when(targetPlatforms: [.macOS, .iOS, .tvOS, .visionOS])
)
```

With [SE-0450](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md) trait support, plugins can also be conditioned on traits:

```swift
.plugin(
    name: "SwiftLintBuildToolPlugin",
    package: "SwiftLintPlugins",
    condition: .when(traits: ["Lint"])
)
```

This would let users opt into linting via `swift build --traits Lint` without requiring the plugin to run on every build or on every platform.

Filters compose additively: a condition is satisfied only when every specified filter matches. A filter that is not specified imposes no constraint on that axis. When the condition is not met, the plugin is not applied to the target. The plugin's package dependency is still resolved, consistent with [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md), but the plugin is not invoked and its prebuild/build commands are not added to the build graph.

## Detailed design

### New `PackageDescription` API

The existing `PluginUsage` type gains a new factory function with a `condition` parameter:

```swift
extension Target.PluginUsage {
    /// Creates a reference to a plugin with an optional condition.
    ///
    /// When the condition is not met for the current build environment,
    /// the plugin is not applied to the target.
    ///
    /// - Parameters:
    ///   - name: The name of the plugin target.
    ///   - package: The name of the package that provides the plugin, or nil
    ///     if the plugin is defined in the same package.
    ///   - condition: The condition under which the plugin is applied.
    @available(_PackageDescription, introduced: 6.x)
    public static func plugin(
        name: String,
        package: String? = nil,
        condition: PluginUsageCondition? = nil
    ) -> PluginUsage
}
```

This proposal introduces a new `PluginUsageCondition` type. Following the precedent set by `BuildSettingCondition` ([SE-0238](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0238-package-manager-build-settings.md)), the condition exposes a single factory method with optional parameters so that additional filter axes can be added over time without combinatorial overload growth:

```swift
/// A condition that limits the application of a plugin to a target.
public struct PluginUsageCondition: Sendable {
    /// Creates a condition that limits when a plugin is applied.
    ///
    /// All filters are independent. The condition is satisfied only if
    /// every non-nil filter matches. A `nil` argument imposes no
    /// constraint on that axis. At least one argument must be non-nil.
    ///
    /// - Parameters:
    ///   - hostPlatforms: Platforms on which the plugin may run, matched
    ///     against the host platform (the machine performing the build).
    ///   - targetPlatforms: Platforms for which the plugin may produce
    ///     output, matched against the target platform (the machine where
    ///     the compiled product will run, per SE-0387).
    ///   - traits: Traits that must be enabled for the plugin to apply.
    public static func when(
        hostPlatforms: [Platform]? = nil,
        targetPlatforms: [Platform]? = nil,
        traits: Set<String>? = nil
    ) -> PluginUsageCondition
}
```

### Build planning behavior

When SwiftPM plans a build and encounters a plugin usage with a condition, it should do the following:

1. **Condition evaluation.** `hostPlatforms` is matched against the host platform; `targetPlatforms` is matched against the target platform (or, when not cross-compiling, the host platform); `traits` is matched against the set of enabled traits for the build. The triple-to-`Platform` mapping follows the same rules as `TargetDependencyCondition`.
2. **Plugin skipped.** If the condition is not met, the plugin is not invoked. No prebuild or build commands from that plugin are added to the build graph.
3. **Dependency resolution unchanged.** The plugin's package dependency is still resolved and fetched, consistent with [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md). This avoids adding host-specific logic to dependency resolution.
4. **Binary artifacts.** If the plugin uses a binary artifact that is unavailable for the current platform, and the condition excludes that platform, SwiftPM does not raise an error. Without this proposal, the unavailable binary can cause a build failure even though the plugin would not be used.

## Security

This proposal has no impact on security, safety, or privacy. It restricts when plugins are applied but does not change what plugins can do when they are applied.

## Impact on existing packages

This proposal is additive. Existing plugin usage declarations without a `condition` parameter continue to work as before. The new API is gated on a new tools version.

Packages that currently use `#if os(...)` workarounds in their manifests can migrate to the new API for cleaner, more declarative manifests.

## Alternatives considered

### Reuse `TargetDependencyCondition` directly

Instead of introducing `PluginUsageCondition`, we could reuse `TargetDependencyCondition`. This would reduce API surface, but it conflates two different concepts: a dependency that is linked into the build product, and a plugin that runs during the build process. More concretely, `TargetDependencyCondition.when(platforms:)` is already shipped and matches against the target platform — for target dependencies, "which platform will the product run on?" is the natural question. Plugins need both host and target filters, and adding a `hostPlatforms:` parameter to the existing condition type would force every reader of a manifest to remember that bare `platforms:` happens to mean target on that type. Keeping the condition types separate contains the label meanings to where they are unambiguous.

Separate types also leave room for the APIs to evolve independently — for example, a future `configuration` condition might make sense for plugins (skip linting in release builds) but not for dependencies.

### Conditional package-level dependencies

An alternative approach would be to make the *package-level* dependency on the plugin package conditional, so it is not even fetched on unsupported platforms. This was considered but rejected because:

1. It would require changes to dependency resolution, which is significantly more complex.
2. [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md) explicitly chose not to affect dependency resolution for conditional target dependencies, and this proposal follows that precedent.
3. Fetching a package that is not used has minimal cost compared to the build failure caused by invoking an incompatible plugin.

### Do nothing - rely on `#if os(...)` in Package.swift

This is the status quo. It works, but it is inconsistent with the rest of the manifest API, verbose, and misleading under cross-compilation because `Package.swift` is parsed on the host. As more packages adopt plugins and support more platforms, this workaround will become more common and less acceptable.

## Future directions

### Finer-grained platform filtering

The current `Platform` enum cannot distinguish among Linux distributions, libc flavors, or architectures. `.when(hostPlatforms: [.macOS])` cleanly excludes all Linux hosts, which resolves the SwiftLint-on-Amazon-Linux-2 pattern above, but it cannot express "any Linux host with glibc ≥ 2.34." That requires `Platform` itself to become more expressive, which is the subject of [SE-0387](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md)'s Future Directions and of the Platform Steering Group's ongoing work under [SP-0001](https://github.com/swiftlang/swift-evolution/blob/main/policies/0001-platform-support-tiers.md). Because `PluginUsageCondition` consumes `Platform` directly, it will pick up any such granularity without an additional proposal.

### Configuration conditionals for plugins

[SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md) proposed but has not yet implemented configuration conditionals (`.when(configuration: .debug)`). If configuration conditionals are added to `TargetDependencyCondition`, they should also be added to `PluginUsageCondition`. A common use case would be applying a linter plugin only in debug builds.

### Target-platform awareness inside a running plugin

This proposal lets the manifest decide *whether* a plugin runs based on the target platform. A complementary direction — exposing host and target triples to `PluginContext` at runtime — would let a running plugin adapt its emitted commands based on the target. The two directions compose naturally and are independent.
