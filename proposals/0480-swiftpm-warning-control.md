# Warning Control Settings for SwiftPM

* Proposal: [SE-0480](0480-swiftpm-warning-control.md)
* Authors: [Dmitrii Galimzianov](https://github.com/DmT021)
* Review Manager: [John McCall](https://github.com/rjmccall), [Franz Busch](https://github.com/FranzBusch)
* Status: **Active review (April 23...May 5th, 2025)**
* Implementation: [swiftlang/swift-package-manager#8315](https://github.com/swiftlang/swift-package-manager/pull/8315)
* Review: ([pitch](https://forums.swift.org/t/pitch-warning-control-settings-for-swiftpm/78666)) ([review](https://forums.swift.org/t/se-0480-warning-control-settings-for-swiftpm/79475))
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

public static func treatAllWarnings(
    as level: WarningLevel,
    _ condition: BuildSettingCondition? = nil
) -> SwiftSetting // or CSetting or CXXSetting

public static func treatWarning(
    _ name: String,
    as level: WarningLevel,
    _ condition: BuildSettingCondition? = nil
) -> SwiftSetting // or CSetting or CXXSetting
```

#### C/C++-specific API

In C/C++ targets, we can also enable or disable specific warning groups, in addition to controlling their severity.

```swift
public static func enableWarning(
    _ name: String,
    _ condition: BuildSettingCondition? = nil
) -> CSetting // or CXXSetting

public static func disableWarning(
    _ name: String,
    _ condition: BuildSettingCondition? = nil
) -> CSetting // or CXXSetting
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

## Acknowledgments

Thank you to [Doug Gregor](https://github.com/douggregor) for the motivation, and to both [Doug Gregor](https://github.com/douggregor) and [Holly Borla](https://github.com/hborla) for their guidance during the implementation of this API.
