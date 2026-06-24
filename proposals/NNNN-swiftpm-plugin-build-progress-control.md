# Build Progress Display Control for SwiftPM Plugins

* Proposal: SE-NNNN
* Author: [Yuta Saito](https://github.com/kateinoigakukun)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-package-manager#8383](https://github.com/swiftlang/swift-package-manager/pull/8383)
* Review: TBD

## Introduction

This proposal introduces a new parameter `progressToConsole` to the `BuildParameters` in SwiftPM's plugin API to allow package plugins to control whether build progress messages should be displayed in the console in the animated way if possible or captured in the log buffer. This provides better control over the build output display and improves the user experience especially when building large-scale projects.

## Motivation

When a package plugin requests SwiftPM to build a target, SwiftPM captures all build output, including compiler diagnostics and progress messages, into the `logText` buffer. To provide visibility into the build process, the `BuildParameters` structure includes an `echoLogs` parameter, which, when enabled, duplicates all build output to both the console and `logText`. However, this approach introduces an issue with how progress messages are displayed.

Unlike a direct `swift build` invocation, which redraws a single line to create a smooth, animation-like effect using ANSI escape sequences, SwiftPM plugins must store logs in `logText` in a format that does not rely on such sequences. Consequently, progress messages are printed in a **"Multilines mode"**, where each progress update appears as a new line instead of replacing the previous one. This results in an excessively verbose console output, especially for large projects, making it harder for developers to monitor the build process efficiently.

For example, when running `swift build` normally, progress messages appear as:

```
[5/50] Compiling MyLibrary ModuleA.swift
```
with the same line being updated as the build progresses. However, when `echoLogs` is enabled in a plugin, the console output may instead look like:

```
[1/50] Compiling MyLibrary ModuleA.swift
[2/50] Compiling MyLibrary ModuleB.swift
[3/50] Compiling MyLibrary ModuleC.swift
...
```

which quickly floods the terminal with redundant information.

This proposal seeks to address this issue by providing finer control over how build progress is displayed in plugin builds, allowing for a more concise and readable output without compromising the ability to capture logs in `logText`.

## Proposed solution

We propose adding a new `progressToConsole` parameter to the `BuildParameters` struct in the plugin API. When set to `true`, build progress messages will be written directly to the console instead of being captured in the `BuildResult.logText`. This gives plugins the flexibility to choose how they want to handle build progress display.

## Detailed Design

We add a new `progressToConsole` parameter to the `BuildParameters` structure in the SwiftPM plugin API:

```swift
public struct PackageManager {
    public struct BuildParameters {
        // ... existing parameters ...

        /// Controls whether build progress messages are printed to the console.
        ///
        /// - If `true`, progress messages will be shown in real-time in the console.
        ///   They will be redrawn on a single line when running in a TTY environment.
        /// - If `false` (default), progress messages are captured in `BuildResult.logText`
        ///   and printed only when `echoLogs` is enabled.
        public var progressToConsole: Bool

        public init(
            configuration: BuildConfiguration = .debug,
            logging: BuildLogVerbosity = .concise,
            echoLogs: Bool = false,
            progressToConsole: Bool = false
        )
    }
}
```

When `progressToConsole` is set to `true`, build progress messages are printed directly to the console. If the standard error is attached to a terminal, progress updates are redrawn in place using ANSI escape sequences, creating a cleaner output experience. If not attached to a terminal, progress messages are displayed in separate lines.

When `progressToConsole` is set to `false` (the default behavior), build progress messages are captured in `BuildResult.logText` instead of being printed to the console. If `echoLogs` is also enabled, these messages will still be printed to the console but with each update on a new line.

A plugin can choose to enable this parameter when it wants to provide a better user experience for visualizing build progress:

```swift
let result = try packageManager.build(
    .product("MyProduct"),
    parameters: .init(
        progressToConsole: true
    )
)
```

## Security

This change has no impact on security, safety, or privacy. It only affects how build progress information is displayed.

## Impact on existing packages

This is a backward-compatible change that maintains the current behavior by default. Since `progressToConsole` defaults to `false`, existing plugins will continue to work as before.

The new functionality only affects packages that explicitly opt-in by setting the parameter to `true`. The change has no impact on the actual build process or results, only on how progress information is displayed to users.

## Alternatives considered

### Always output progress messages to console

We could modify SwiftPM to always output progress messages to the console in an animated way, removing them from `logText` entirely. While this would provide a better user experience by default, it would break backward compatibility for plugins that rely on parsing progress messages from `logText`. Although such use cases are rare, the benefit does not outweigh the cost of breaking compatibility.
