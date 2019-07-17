# Compiler Version Directive

* Proposal: [SE-0212](0212-compiler-version-directive.md)
* Author: [David Hart](https://github.com/hartbit)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Implementation: [apple/swift#15977](https://github.com/apple/swift/pull/15977)
* Status: **Implemented (Swift 4.2)**

## Introduction

This proposal introduces a `compiler` directive that is syntactically equivalent to the `#if swift` version check but checks against the version of the compiler, regardless of which compatibility mode it's currently running in.

## Motivation

The `#if swift` check allows conditionally compiling code depending on the version of the language. Prior to Swift 4, the version of the compiler and the language were one and the same. But since Swift 4, the compiler can run in a compatibility mode for previous Swift versions, introducing a new version dimension. To support code across multiple compiler versions and compatibility modes, extra language versions are regularly introduced to represent old language versions running under compatibility mode.

For example, the release of Swift 4 introduced a Swift 3.2 language version representing the Swift 4 compiler in version 3 compatibility mode. Here is the current language matrix, as well as guesses as to what those versions will be for Swift 5.0 and 5.1.

| Swift | --swift-version 3 | --swift-version 4 | --swift-version 4.2 | --swift-version 5 |
|:----- |:----------------- |:----------------- |:------------------- |:----------------- |
| 3.0   | N/A               | N/A               | N/A                 | N/A               |
| 3.1   | N/A               | N/A               | N/A                 | N/A               |
| 4.0   | 3.2               | 4.0               | N/A                 | N/A               |
| 4.1   | 3.3               | 4.1               | N/A                 | N/A               |
| 4.2   | 3.4               | 4.1.50            | 4.2                 | N/A               |
| 5.0   | 3.5               | 4.1.51            | 4.3                 | 5.0               |
| 5.1   | 3.6               | 4.1.52            | 4.4                 | 5.1               |

This solution is problematic for several reasons:

* It creates a quadratic growth in the number of Swift versions for each new compatibility version.
* Conditionally compiling for a version of the compiler, regardless of the compatibility mode, is difficult and error prone:

```swift
#if swift(>=4.1) || (swift(>=3.3) && !swift(>=4.0))
// Code targeting the Swift 4.1 compiler and above.
#endif

#if swift(>=4.1.50) || (swift(>=3.4) && !swift(>=4.0))
// Code targeting the Swift 4.2 compiler and above.
#endif

#if swift(>=5.0) || (swift(>=4.1.50) && !swift(>=4.2)) || (swift(>=3.5) && !swift(>=4.0))
// Code targeting the Swift 5.0 compiler and above.
#endif
```

## Proposed solution

This proposal suggests:

* introducing a new `compiler` directive that is syntactically equivalent to the `swift` directive but checks against the version of the compiler,
* stop bumping old Swift versions when new versions are introduced.

This will simplify future Swift versions by stopping the artificial growth of old language versions:

| Invocation                | Compiler Version | Language Version |
|:------------------------- |:---------------- |:---------------- |
| 3.0                       | N/A              | 3.0              |
| 3.1                       | N/A              | 3.1              |
| 4.0                       | N/A              | 4.0              |
| 4.0 (--swift-version 3)   | N/A              | 3.2              |
| 4.1                       | N/A              | 4.1              |
| 4.1 (--swift-version 3)   | N/A              | 3.3              |
| 4.2                       | 4.2              | 4.2              |
| 4.2 (--swift-version 3)   | 4.2              | 3.3              |
| 4.2 (--swift-version 4)   | 4.2              | 4.1              |
| 5.0                       | 5.0              | 5.0              |
| 5.0 (--swift-version 3)   | 5.0              | 3.3              |
| 5.0 (--swift-version 4)   | 5.0              | 4.1              |
| 5.0 (--swift-version 4.2) | 5.0              | 4.2              |
| 5.1                       | 5.1              | 5.1              |
| 5.1 (--swift-version 3)   | 5.1              | 3.3              |
| 5.1 (--swift-version 4)   | 5.1              | 4.1              |
| 5.1 (--swift-version 4.2) | 5.1              | 4.2              |

This change is possible because it retains the ability to conditionally compile code targeting a compiler in compatibility mode:

```swift
#if swift(>=4.1) && compiler(>=5.0)
// Code targeting the Swift 5.0 compiler and above in --swift-version 4 mode and above.
#endif
```

It will also greatly simplify conditional compilation based on compiler version alone:

```swift
#if swift(>=4.1) || (swift(>=3.3) && !swift(>=4.0))
// Code targeting the Swift 4.1 compiler and above.
// This can't change because it needs to continue working with older compilers.
#endif

#if compiler(>=4.2)
// Code targeting the Swift 4.2 compiler and above.
#endif

#if compiler(>=5.0)
// Code targeting the Swift 5.0 compiler and above.
#endif
```

## Impact on existing code

This is a purely additive change and will have no impact on existing code.

## Alternatives considered

No other alternative naming was considered for this new directive.
