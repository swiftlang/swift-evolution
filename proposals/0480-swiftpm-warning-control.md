# Warning Control Settings for SwiftPM

* Proposal: [SE-0480](0480-swiftpm-warning-control.md)
* Authors: [Dmitrii Galimzianov](https://github.com/DmT021)
* Review Manager: [John McCall](https://github.com/rjmccall), [Franz Busch](https://github.com/FranzBusch)
* Status: **Implemented (Swift 6.2)**
* Implementation: [swiftlang/swift-package-manager#8315](https://github.com/swiftlang/swift-package-manager/pull/8315)
* Review: ([pitch](https://forums.swift.org/t/pitch-warning-control-settings-for-swiftpm/78666)) ([review](https://forums.swift.org/t/se-0480-warning-control-settings-for-swiftpm/79475)) ([returned for revision](https://forums.swift.org/t/se-0480-warning-control-settings-for-swiftpm/79475/8)) ([acceptance](https://forums.swift.org/t/accepted-se-0480-warning-control-settings-for-swiftpm/80327))
* Previous Proposal: [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md)

## Introduction

This proposal adds new settings to SwiftPM to control how the Swift, C, and C++ compilers treat warnings during the build process. It builds on [SE-0443](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0443-warning-control-flags.md), which introduced warning control flags for the Swift compiler but left SwiftPM support as a future direction.

## Motivation

The Swift Package Manager currently lacks a unified way to control warnings across Swift, C, and C++ compilation. This limitation forces developers to either use `unsafeFlags` or accept the default warning settings.

## Proposed solution

This proposal introduces new methods to SwiftPM's build settings API, allowing fine-grained control over warnings.

### API

#### Cross-language API (Swift, C, and C++)

```swift
/// The level at which a compiler warning should be treated.
public enum WarningLevel: String {
    /// Treat as a warning.
    ///
    /// Warnings will be displayed during compilation but will not cause the build to fail.
    case warning

    /// Treat as an error.
    ///
    /// Warnings will be elevated to errors, causing the build to fail if any such warnings occur.
    case error
}

extension SwiftSetting { // Same for CSetting and CXXSetting
    public static func treatAllWarnings(
        as level: WarningLevel,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting // or CSetting or CXXSetting

    public static func treatWarning(
        _ name: String,
        as level: WarningLevel,
        _ condition: BuildSettingCondition? = nil
    ) -> SwiftSetting // or CSetting or CXXSetting
}
```

#### C/C++-specific API

In C/C++ targets, we can also enable or disable specific warning groups, in addition to controlling their severity.

```swift
extension CSetting { // Same for CXXSetting
    public static func enableWarning(
        _ name: String,
        _ condition: BuildSettingCondition? = nil
    ) -> CSetting // or CXXSetting

    public static func disableWarning(
        _ name: String,
        _ condition: BuildSettingCondition? = nil
    ) -> CSetting // or CXXSetting
}
```
_The necessity of these functions is also explained below in the Alternatives considered section._

### Example usage

```swift
.target(
    name: "MyLib",
    swiftSettings: [
        .treatAllWarnings(as: .error),
        .treatWarning("DeprecatedDeclaration", as: .warning),
    ],
    cSettings: [
        .enableWarning("all"),
        .disableWarning("unused-function"),

        .treatAllWarnings(as: .error),
        .treatWarning("unused-variable", as: .warning),
    ],
    cxxSettings: [
        .enableWarning("all"),
        .disableWarning("unused-function"),

        .treatAllWarnings(as: .error),
        .treatWarning("unused-variable", as: .warning),
    ]
)
```

## Detailed design

### Settings and their corresponding compiler flags

| Method | Swift | C/C++ |
|--------|-------|-------|
| `treatAllWarnings(as: .error)` | `-warnings-as-errors` | `-Werror` |
| `treatAllWarnings(as: .warning)` | `-no-warnings-as-errors` | `-Wno-error` |
| `treatWarning("XXXX", as: .error)` | `-Werror XXXX` | `-Werror=XXXX` |
| `treatWarning("XXXX", as: .warning)` | `-Wwarning XXXX` | `-Wno-error=XXXX` |
| `enableWarning("XXXX")` | N/A | `-WXXXX` |
| `disableWarning("XXXX")` | N/A | `-Wno-XXXX` |

### Order of settings evaluation

The order in which warning control settings are specified in a target's settings array directly affects the order of the resulting compiler flags. This is critical because when multiple flags affect the same warning group, compilers apply them sequentially with the last flag taking precedence.

For example, consider these two different orderings for C++ settings:

```swift
// Example 1: "unused-variable" in front of "unused"
cxxSettings: [
    .treatWarning("unused-variable", as: .error),
    .treatWarning("unused", as: .warning),
]

// Example 2: "unused" in front of "unused-variable"
cxxSettings: [
    .treatWarning("unused", as: .warning),
    .treatWarning("unused-variable", as: .error),
]
```

In Example 1, the compiler will receive flags in this order:
```
-Werror=unused-variable -Wno-error=unused
```
Since "unused-variable" is a specific subgroup of the broader "unused" group, and the "unused" flag is applied last, all unused warnings (including unused-variable) will be treated as warnings.

In Example 2, the compiler will receive flags in this order:
```
-Wno-error=unused -Werror=unused-variable
```
Due to the "last one wins" rule, unused-variable warnings will be treated as errors, while other unused warnings remain as warnings.

The same principle applies when combining any of the new build settings:

```swift
cxxSettings: [
    .enableWarning("all"),                 // Enable the "all" warning group
    .enableWarning("extra"),               // Enable the "extra" warning group
    .disableWarning("unused-parameter"),   // Disable the "unused-parameter" warning group
    .treatAllWarnings(as: .error),         // Treat all warnings as errors
    .treatWarning("unused", as: .warning), // Keep warnings of the "unused" group as warnings
]
```

This will result in compiler flags:
```
-Wall -Wextra -Wno-unused-parameter -Werror -Wno-error=unused
```

When configuring warnings, be mindful of the order to achieve the desired behavior.

### Remote targets behavior

When a target is remote (pulled from a package dependency rather than defined in the local package), the warning control settings specified in the manifest do not apply to it. SwiftPM will strip all of the warning control flags for remote targets and substitute them with options for suppressing warnings (`-w` for Clang and `-suppress-warnings` for Swift).

This behavior is already in place but takes into account only `-warnings-as-errors` (for Swift) and `-Werror` (for Clang) flags. We expand this list to include the following warning-related flags:

**For C/C++:**
* `-Wxxxx`
* `-Wno-xxxx`
* `-Werror`
* `-Werror=xxxx`
* `-Wno-error`
* `-Wno-error=xxxx`

**For Swift:**
* `-warnings-as-errors`
* `-no-warnings-as-errors`
* `-Wwarning xxxx`
* `-Werror xxxx`

This approach ensures that warning control settings are applied only to the targets you directly maintain in your package, while dependencies remain buildable without warnings regardless of their warning settings.

### Interaction with command-line flags

SwiftPM allows users to pass additional flags to the compilers using the `-Xcc`, `-Xswiftc`, and `-Xcxx` options with the `swift build` command. These flags are appended **after** the flags generated from the package manifest.

This ordering enables users to modify or override package-defined warning settings without modifying the package manifest.

#### Example

```swift
let package = Package(
    name: "MyExecutable",
    targets: [
        // C target with warning settings
        .target(
            name: "cfoo",
            cSettings: [
                .enableWarning("all"),
                .treatAllWarnings(as: .error),
                .treatWarning("unused-variable", as: .warning),
            ]
        ),
        // Swift target with warning settings
        .executableTarget(
            name: "swiftfoo",
            swiftSettings: [
                .treatAllWarnings(as: .error),
                .treatWarning("DeprecatedDeclaration", as: .warning),
            ]
        ),
    ]
)
```

When built with additional command-line flags:

```sh
swift build -Xcc -Wno-error -Xswiftc -no-warnings-as-errors
```

The resulting compiler invocations will include both sets of flags:

```
# C compiler invocation
clang ... -Wall -Werror -Wno-error=unused-variable ... -Wno-error ...

# Swift compiler invocation
swiftc ... -warnings-as-errors -Wwarning DeprecatedDeclaration ... -no-warnings-as-errors -Xcc -Wno-error ...
```

Flags are processed from left to right, and since `-no-warnings-as-errors` and `-Wno-error` apply globally to all warnings, they override the warning treating flags defined in the package manifest.

#### Limitations

This approach has a limitation when used with `-suppress-warnings`, which is mutually exclusive with other warning control flags:

```sh
swift build -Xswiftc -suppress-warnings
```

Results in compiler errors:

```
error: conflicting options '-warnings-as-errors' and '-suppress-warnings'
error: conflicting options '-Wwarning' and '-suppress-warnings'
```


## Security

This change has no impact on security, safety, or privacy.

## Impact on existing packages

The proposed API will only be available to packages that specify a tools version equal to or later than the SwiftPM version in which this functionality is implemented.

## Alternatives considered

### Disabling a warning via a treat level

Clang allows users to completely disable a specific warning, so for C/C++ settings we could implement that as a new case in the `WarningLevel` enum:

```swift
public enum WarningLevel {
    case warning
    case error
    case ignored
}
```

_(Since Swift doesn't allow selective warning suppression, we would actually have to split the enum into two: `SwiftWarningLevel` and `CFamilyWarningLevel`)_

But some warnings in Clang are disabled by default. If we simply pass `-Wno-error=unused-variable`, the compiler won't actually produce a warning for an unused variable. It only makes sense to use it if we have enabled the warning: `-Wunused-variable -Werror -Wno-error=unused-variable`.

This necessitates separate functions to enable and disable warnings. Therefore, instead of `case ignored`, we propose the functions `enableWarning` and `disableWarning`.

## Future directions

### Package-level settings

It has been noted that warning control settings are often similar across all targets. It makes sense to declare them at the package level while allowing target-level customizations. However, many other settings would also likely benefit from such inheritance, and SwiftPM doesn't currently provide such an option. Therefore, it was decided to factor this improvement out and look at all the settings holistically in the future.

### Support for other C/C++ Compilers

The C/C++ warning control settings introduced in this proposal are initially implemented with Clang's warning flag syntax as the primary target. However, the API itself is largely compiler-agnostic, and there's potential to extend support to other C/C++ compilers in the future.

For instance, many of the proposed functions could be mapped to flags for other compilers like MSVC:

| SwiftPM Setting                   | Clang             | MSVC (Potential Mapping) |
| :-------------------------------- | :---------------- | :----------------------- |
| `.treatAllWarnings(as: .error)`   | `-Werror`         | `/WX`                    |
| `.treatAllWarnings(as: .warning)` | `-Wno-error`      | `/WX-`                   |
| `.treatWarning("name", as: .error)`| `-Werror=name`    | `/we####` (where `####` is MSVC warning code) |
| `.treatWarning("name", as: .warning)`| `-Wno-error=name` | No direct equivalent     |
| `.enableWarning("name")`          | `-Wname`          | `/wL####` (e.g., `/w4####` to enable at level 4) |
| `.disableWarning("name")`         | `-Wno-name`       | `/wd####`                |

Where direct mappings are incomplete (like `.treatWarning(as: .warning)` for MSVC, which doesn't have a per-warning equivalent to Clang's `-Wno-error=XXXX`), SwiftPM could emit diagnostics indicating the setting is not fully supported by the current compiler. If more fine-grained control is needed for a specific compiler (e.g., MSVC's warning levels `0-4` for `enableWarning`), future enhancements could introduce compiler-specific settings or extend the existing API.

A key consideration is the handling of warning names or codes (the `"name"` parameter in the API). SwiftPM does not maintain a comprehensive list of all possible warning identifiers and their mapping across different compilers. Instead, package authors would be responsible for providing the correct warning name or code for the intended compiler.

To facilitate this, if support for other C/C++ compilers is added, the existing `BuildSettingCondition` API could be extended to allow settings to be applied conditionally based on the active C/C++ compiler. For example:

```swift
cxxSettings: [
    // Clang-specific warning
    .enableWarning("unused-variable", .when(cxxCompiler: .clang)),
    // MSVC-specific warning (using its numeric code)
    .enableWarning("4101", .when(cxxCompiler: .msvc)),
    // Common setting that maps well
    .treatAllWarnings(as: .error)
]
```

This approach, combined with the existing behavior where remote (dependency) packages have their warning control flags stripped and replaced with suppression flags, would allow projects to adopt new compilers. Even if a dependency uses Clang-specific warning flags, it would not cause build failures when the main project is built with a different compiler like MSVC, as those flags would be ignored.

### Formalizing "Development-Only" Build Settings

The warning control settings introduced by this proposal only apply when a package is built directly and are suppressed when the package is consumed as a remote dependency.

During the review of this proposal, it was suggested that this "development-only" characteristic could be made more explicit, perhaps by introducing a distinct category of settings (e.g., `devSwiftSettings`). This is an interesting avenue for future exploration. SwiftPM already has a few other settings that exhibit similar behavior. A dedicated future proposal for "development-only" settings could address all such use cases holistically, providing a clearer and more general mechanism for package authors to distinguish between "dev-only" settings and those that propagate to consumers.

## Acknowledgments

Thank you to [Doug Gregor](https://github.com/douggregor) for the motivation, and to both [Doug Gregor](https://github.com/douggregor) and [Holly Borla](https://github.com/hborla) for their guidance during the implementation of this API.
