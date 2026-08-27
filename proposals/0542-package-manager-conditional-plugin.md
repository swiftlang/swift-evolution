# Package Manager Build Tool Plugin Usage Conditionals

* Proposal: [SE-0542](0542-package-manager-conditional-plugin.md)
* Authors: [Clive Liu](https://github.com/clive819)
* Review Manager: [David Cummings](https://github.com/daveyc123)
* Status: **Active Review (August 6 - August 21, 2026)**
* Implementation: [swiftlang/swift-package-manager#10119](https://github.com/swiftlang/swift-package-manager/pull/10119) [swift-build#1439](https://github.com/swiftlang/swift-build/pull/1439/changes)
* Review: ([pitch](https://forums.swift.org/t/pitch-package-manager-conditional-plugin/86217)) ([review](https://forums.swift.org/t/se-0542-package-manager-condition-plugins/88820))

## Introduction

This proposal adds conditional use of build tool plugins ([SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md)) declared in a target's `plugins:` parameter. It reuses `TargetDependencyCondition` and adds an optional `hostPlatforms` filter. Plugin usages can combine this filter with target-platform and trait filters. All target dependencies can also use the host filter. Command plugins ([SE-0332](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md)) are invoked explicitly through `swift package <verb>` and are not affected.

Here, a **build tool plugin** is a sandboxed Swift script that returns `Command` values. A `Command` tells the build system how to invoke an executable before or during a build. The executable is the **build tool**. Platform constraints apply to build tools, including generators and other executables invoked during a build. A host condition prevents commands that invoke a build tool on an unsupported host. A target-platform condition is intended to filter the commands and their outputs.

## Motivation

[SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) introduced build tool plugins, and [SE-0332](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md) added command plugins. Plugins are widely used for linting (SwiftLint), formatting (SwiftFormat), code generation (SwiftGen, SwiftProtobuf), and documentation (DocC). However, the `plugins` parameter on target declarations does not support any form of conditional application.

This is an important gap because build tool plugins are part of the *build environment*, not the built product. A package may be portable across platforms while some of its build tools are only relevant, available, or desirable on certain build hosts. A plugin command may also produce output that is only valid for certain target platforms. SwiftPM already lets package authors conditionalize target dependencies and build settings, but not plugin application.

This creates a few practical problems:

1. **Host-specific tooling cannot be expressed declaratively.** Build tools run on the machine that performs the build. A linter, formatter, code generator, or documentation tool may only support a subset of host platforms. It can also depend on host-specific toolchains and SDKs. Today there is no manifest-level way to say "apply this plugin only on macOS" or "only when building on a host that opts into linting".
2. **Target-specific tooling cannot be expressed either.** A build tool may generate code that only compiles on certain target platforms — for example, a code generator that emits iOS-only bridging shims. Even on a capable host, commands that invoke this tool must not run when building the package's Linux-server product. [SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) explicitly anticipated this gap (Future Directions → *Contextual Information About the Target Platform*).
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

SwiftLint distributes a pre-built binary artifact bundle. That binary is compiled against a newer glibc than what ships on some Linux distributions (e.g., Amazon Linux 2). When building this package on such a system, the build fails immediately - not because of any issue with the package's own code, but because the build tool cannot execute:

```
swiftlint: /lib64/libc.so.6: version `GLIBC_2.34' not found
error: failed: PrebuildCommand(...)
```

The build never reaches compilation. The build tool is only a development tool in this example. It has no effect on the compiled output. Yet there is no way to express "apply this plugin only on macOS" in the package manifest.

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

Extend `Target.PluginUsage` with an optional `condition` parameter. The parameter uses the existing `TargetDependencyCondition` type. A package author can set a host platform, a target platform, enabled traits, or a combination of these values:

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

Plugins use both the host and target axes. [SE-0387](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md) defines the terms. The host is the machine that builds the code. The target is the machine that runs the product.

The new `hostPlatforms:` label selects the host platforms that can use the plugin. For example, a plugin can use a tool that only runs on macOS. The existing `platforms:` label continues to select target platforms. For example, a generator can produce files that only an Apple target uses:

```swift
.plugin(
    name: "MetalShaderGenerator",
    package: "MetalShaderGenerator",
    condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS])
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

All specified filters must match. An omitted filter does not limit that axis.

SwiftPM evaluates the host and trait filters before it invokes the build tool plugin. A target-platform filter works differently because the build tool plugin does not receive the target platform. SwiftPM applies the target-platform filter to commands and generated outputs from the plugin usage. The build system uses the filter for each configured target.

SwiftPM still resolves the package that contains the plugin. This behavior is consistent with [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md).

## Detailed design

### New `PackageDescription` API

The existing `PluginUsage` type gains a new factory function with a `condition` parameter:

```swift
extension Target.PluginUsage {
    /// Creates a reference to a plugin with an optional condition.
    ///
    /// - Parameters:
    ///   - name: The name of the plugin target.
    ///   - package: The name of the package that provides the plugin, or nil
    ///     if the plugin is defined in the same package.
    ///   - condition: The condition for this plugin usage.
    @available(_PackageDescription, introduced: 6.5)
    public static func plugin(
        name: String,
        package: String? = nil,
        condition: TargetDependencyCondition? = nil
    ) -> PluginUsage
}
```

This proposal adds an overload of `TargetDependencyCondition.when` that includes `hostPlatforms`. This parameter is required in the new overload. A host filter is still optional because the existing overloads stay available. The existing `platforms` parameter continues to identify target platforms. The following declaration shows the new API shape:

```swift
extension TargetDependencyCondition {
    /// Creates a condition for a target dependency or plugin usage.
    ///
    /// All specified filters must match. A nil value for platforms or traits
    /// does not add a constraint on that axis. The method returns nil if all
    /// arguments are nil or empty.
    ///
    /// - Parameters:
    ///   - platforms: The applicable target platforms.
    ///   - hostPlatforms: The applicable host platforms.
    ///   - traits: The applicable traits.
    @available(_PackageDescription, introduced: 6.5)
    public static func when(
        platforms: [Platform]? = nil,
        hostPlatforms: [Platform],
        traits: Set<String>? = nil
    ) -> TargetDependencyCondition?
}
```

### Target dependency behavior

The `target`, `product`, and `byName` dependency APIs can use this condition. SwiftPM evaluates `hostPlatforms` against the build host. It maps the host triple to `Platform` with the same rules that it uses for the target triple. SwiftPM continues to evaluate `platforms` against the target platform. It evaluates `traits` with the existing trait rules. All specified axes must match.

If `hostPlatforms` does not match, SwiftPM does not use that dependency edge. SwiftPM does not build or link the dependency through that edge. Package resolution does not change.

This filter is useful when a plugin target has a different build tool for each host:

```swift
.plugin(
    name: "CodeGeneratorPlugin",
    capability: .buildTool(),
    dependencies: [
        .target(
            name: "MacGenerator",
            condition: .when(hostPlatforms: [.macOS])
        ),
        .target(
            name: "LinuxGenerator",
            condition: .when(hostPlatforms: [.linux])
        ),
    ]
)
```

Each generator is a target dependency of the plugin target. SwiftPM builds only the generator for the current host. Host filtering is most useful for build-time dependencies, such as tools used by plugins. A source or library target can also use this filter. In that case, its dependency graph depends on the build host. The target must compile and link without a dependency that the host filter excludes.

### Plugin usage behavior

When SwiftPM finds a plugin usage with a condition, it does these actions:

1. **Evaluate the host and traits.** SwiftPM compares `hostPlatforms` with the host platform. It compares `traits` with the enabled traits. If a filter does not match, SwiftPM does not invoke the build tool plugin.
2. **Invoke the plugin without a target platform.** The build tool plugin returns its commands in a context that does not depend on a build request. SwiftPM does not give the target platform to the build tool plugin.
3. **Filter commands and outputs.** SwiftPM applies the `platforms` filter to each command and each generated source or resource. The build system selects the matching commands and generated files for each configured target.
4. **Keep dependency resolution unchanged.** SwiftPM still resolves and fetches the package dependency. This behavior is consistent with [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md).

On an excluded platform, SwiftPM does not run filtered commands or add generated files to the target. The target must compile without these files. To use a different generator, add a separate plugin usage with its own condition:

```swift
.target(
    name: "SharedModels",
    plugins: [
        .plugin(
            name: "AppleModelGeneratorPlugin",
            condition: .when(platforms: [.macOS, .iOS])
        ),
        .plugin(
            name: "LinuxModelGeneratorPlugin",
            condition: .when(platforms: [.linux])
        ),
    ]
)
```

Both build tools must generate the declarations that `SharedModels` requires. SwiftPM uses the Apple generator for macOS and iOS. It uses the Linux generator for Linux.

## Security

This proposal has no impact on security, safety, or privacy. It restricts dependency edges and plugin commands. It does not give code new capabilities or permissions.

## Impact on existing packages

This proposal is additive. Existing plugin usage declarations without a `condition` parameter continue to work as before. Existing target dependency conditions without `hostPlatforms` also keep their current behavior.

Packages that currently use `#if os(...)` workarounds in their manifests can migrate to the new API for cleaner, more declarative manifests.

## Alternatives considered

### Introduce `PluginUsageCondition`

A separate `PluginUsageCondition` type could use explicit labels for both platform axes. It could also evolve separately from `TargetDependencyCondition`.

However, target dependencies and plugin usages are both build-time dependencies. SwiftPM also stores them together in the package graph. Future conditions should apply to both types of dependency. Configuration conditionals are one example. One condition type lets SwiftPM add these conditions to both uses through the same API. Therefore, this proposal reuses `TargetDependencyCondition` and adds `hostPlatforms` to it. The existing `platforms` label continues to mean target platforms.

### Conditional package-level dependencies

An alternative approach would be to make the *package-level* dependency on the plugin package conditional, so it is not even fetched on unsupported platforms. This was considered but rejected because:

1. It would require changes to dependency resolution, which is significantly more complex.
2. [SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md) explicitly chose not to affect dependency resolution for conditional target dependencies, and this proposal follows that precedent.
3. Fetching a package that is not used has minimal cost compared to the build failure caused by invoking an incompatible plugin.

### Do nothing - rely on `#if os(...)` in Package.swift

This is the status quo. It works, but it is inconsistent with the rest of the manifest API, verbose, and misleading under cross-compilation because `Package.swift` is parsed on the host. As more packages adopt plugins and support more platforms, this workaround will become more common and less acceptable.

## Future directions

### Target-platform conditions for prebuild commands

Some build systems lack the information needed to execute prebuild commands conditionally. They report an error when a plugin usage with a target-platform condition returns a prebuild command. Other build systems apply the condition with the same execution behavior as build commands. Future work can extend this support to all build systems.

### Target-platform control for plugin authors

Today, a build tool plugin does not receive the target platform. This proposal applies the target-platform condition to commands and their generated outputs.

A future proposal can let a plugin add conditions to each `Command`. This lets the plugin author provide different commands for different target platforms. SwiftPM first invokes the plugin. It then applies each condition to the command and its declared outputs.

[SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md) also identifies target-platform information as a future direction. A future proposal can give a plugin this information so that it can provide commands for a specific target platform. This change is outside the scope of this proposal.

### Finer-grained platform filtering

The current `Platform` enum cannot distinguish among Linux distributions, libc flavors, or architectures. `.when(hostPlatforms: [.macOS])` cleanly excludes all Linux hosts, which resolves the SwiftLint-on-Amazon-Linux-2 pattern above, but it cannot express "any Linux host with glibc ≥ 2.34." That requires `Platform` itself to become more expressive, which is the subject of [SE-0387](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md)'s Future Directions and of the Platform Steering Group's ongoing work under [SP-0001](https://github.com/swiftlang/swift-evolution/blob/main/policies/0001-platform-support-tiers.md). Because `TargetDependencyCondition` consumes `Platform` directly, it will pick up any such granularity without an additional proposal.

### Configuration conditionals for plugins

[SE-0273](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md) proposed but has not yet implemented configuration conditionals (`.when(configuration: .debug)`). If configuration conditionals are added to `TargetDependencyCondition`, plugin usages will support them without a separate condition type. A common use case would be applying a linter plugin only in debug builds.
