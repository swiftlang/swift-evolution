# Target environment platform condition

* Proposal: [SE-0190](0190-target-environment-platform-condition.md)
* Authors: [Erica Sadun](https://github.com/erica), [Graydon Hoare](https://github.com/graydon)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 4.1)**
* [Swift Evolution Review Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171127/041695.html)
* Implementation: [apple/swift#12964](https://github.com/apple/swift/pull/12964)

## Introduction

This proposal introduces a platform condition to differentiate device and simulator builds.
This condition subsumes a common pattern of conditional compilation for Metal, Keychain, and
AVFoundation Camera code.

Swift-evolution threads:

* [Expanding Build Configuration Tests for Simulator and Device targets](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160314/012557.html)
* [Target environment platform condition](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20171023/040652.html)

## Motivation

A common developer requirement is to conditionally compile code based on whether
the current compilation target is a simulator or a real device. The current technique
for accomplishing this involves testing for particular combinations of presumed mismatch
between architecture and operating system. This is fragile and non-obvious, and
requires reasoning about complex nested conditions that obscure the user's purpose.

For example, code often looks like this:


```swift
// Test for a simulator destination
#if (arch(i386) || arch(x86_64)) && (!os(macOS))
    print("Simulator")
#else
    print("Device")
#endif

// More restrictive test for iOS simulator
// Adjust the os test for watchOS, tvOS
#if (arch(i386) || arch(x86_64)) && os(iOS)
    // iOS simulator code
#endif
```

## Proposed Solution

This proposal adds a new platform condition `targetEnvironment` with a single valid 
argument: `simulator`.

In other words, the proposal is to enable conditional compilation of the form
`#if targetEnvironment(simulator)`.

## Detailed Design

When the compiler is targeting simulator environments, the `targetEnvironment(simulator)`
condition will evaluate to `true`. Otherwise it will evaluate as `false`.

In the future, other target environments may be indicated using different arguments to
the `targetEnvironment` condition. It is a general extension point for disambiguating
otherwise-similar target environments.

The name of the condition is motivated by the fact that an unambiguous indication of
target environment can be made using the 4th (seldom used, but valid) _environment_ field of
the _target triple_ provided to the compiler.

In other words, if the compiler's target triple is specified with an _environment_
field such as `arm64-apple-tvos-simulator`, the `targetEnvironment(simulator)` condition
will be set.

As a transitionary measure: until users have migrated to consistent use of _target triples_
with an explicit `simulator` value in the _environment_ field, the Swift compiler
will infer it from the remaining components of the target triple, without requiring the
user to approximate the condition through combinations of `os` and `arch` platform
conditions.

In other words, while a given _target triple_ may be missing the _environment_ field,
the `targetEnvironment(simulator)` condition may still be `true`, if it is inferred
that the current target triple denotes a simulator environment.

## Source compatibility

This is an additive proposal, existing code will continue to work.

A warning and fixit may be provided for migrating recognizable cases in existing code,
but this will necessarily be best-effort, as existing conditions may be arbitrarily
complex.

## Effect on ABI stability

None

## Effect on API resilience

None

## Current Art

Swift currently supports the following platform conditions:

* The `os()` function that tests for `macOS, iOS, watchOS, tvOS, Linux, Windows, FreeBSD,
  Android, PS4, Cygwin and Haiku`
* The `arch()` function that tests for `x86_64, arm, arm64, i386, powerpc64, powerpc64le and s390x`
* The `swift()` function that tests for specific Swift language releases, e.g. `swift(>=2.2)`

## Comparison with other languages

1. [Rust's conditional compilation system](https://doc.rust-lang.org/reference/attributes.html#conditional-compilation)
   includes the `target_env` configuration option, which similarly presents the _environment_
   field of the target triple.
2. In Clang, several _environment_-based preprocessor symbols can be used to achieve similar
   effects (`__CYGWIN__`, `__ANDROID__`, etc.) though the mapping is quite ad-hoc and the
   4th field of the _target triple_ is 
   [officially documented](https://clang.llvm.org/docs/CrossCompilation.html#target-triple)
   as representing the target _ABI_. In 
   [the implementation](https://github.com/apple/swift-llvm/blob/352a3d745c4ed4d24c1e5a86ec0e1b2af2f0dfa4/include/llvm/ADT/Triple.h#L219-L245),
   however, the 4th field is treated as _environment_ (subsuming _ABI_) and a 5th field
   for _object format_ is supported.
3. Clang also supports various flags such as `-mtvos-simulator-version-min` which define a
   simulator-specific preprocessor symbol `__APPLE_EMBEDDED_SIMULATOR__`.


## Alternatives Considered

Some possible alternatives were considered:

  1. As in the first round of this proposal, `target(simulator)`. This has the advantage
     of brevity, but the disadvantage of using a relatively overloaded term, and contradicts
     the existing design of using a separate condition per-component of the target triple
     (`os()` and `arch()`).
  2. A similarly brief `environment(simulator)` condition, which has the disadvantage that
     users may mistake it for a means of accessing environment variables of the compiler
     process.
  3. An additional state for the `os` or `arch` conditions, such as `os(simulator)`.
     This would complicate both the definition and implementation of platform conditions,
     while blurring the notion of an operating system.
  4. Avoidance of the target triple altogether, and use of a dedicated `simulator()`
     platform condition. This is the simplest option, but is less-similar to existing
     conditions and may introduce more meaningless combinations of flags as the set of
     target environments grows (rather than mutually exclusive arguments to
     `targetEnvironment`).
