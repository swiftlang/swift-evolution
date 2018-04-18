# Compiler Version Directive

* Proposal: [SE-XXXX](XXXX-compiler-version-directive.md)
* Author: [David Hart](https://github.com/hartbit)
* Review Manager: TBD
* Implementation: [apple/swift#15977](https://github.com/apple/swift/pull/15977)
* Status: TBD

## Introduction

This proposal introduces a `compiler` directive that is syntactically equivalent to the `swift` version check but checks against the latest version of the language the compiler comes with, regardless of which mode it's currently compiling in.

## Motivation

Since Swift 4, the compiler can run in a compatibility mode for previous Swift versions. To make this explicit, a new Swift version 3.2 was introduced to represent the 4.0 compiler running in Swift 3 compatibility mode. This allowed developers to conditionally compile Swift 3 code which depends on Standard Library or compiler changes that appeared in the Swift 4 compiler.

```swift
#if swift(>=3.2)
// code depending on new stdlib/compiler
#endif
```

When Swift 4.1 was released, a new 3.3 version was introduced to represent the 4.1 compiler in Swift 3 compatibility mode. This is probablematic for two reasons:

1. Continually introducing new Swift versions for old language versions in new compilers will grow exponentially for every new major Swift release: Swift 4.2 will have to introduce a Swift 3.4 version but Swift 5 will have to introduce both a Swift 3.5 version (when in Swift 3 compatibility mode), as well as a Swift 4.3 version (when in Swift 4 compatibility mode).

2. Conditionally compiling for the Swift 4.1 compiler, whether we are in Swift 3 or 4 mode, as is necessary to support Standard Library changes, is untenable:

```swift
#if swift(>=4.1) || (swift(>=3.3) && !swift(>=4.0))
return array.compactMap({ $0 })
#else
return array.flatMap({ $0 })
#endif
```

## Proposed solution

This proposal suggests:

* introducing a new `compiler` directive that is synctactically equivalent to the `swift` directive but checks against the latest version of the language the compiler comes with,
* and stop bumping old Swift versions when new versions of the compiler are released.

While it is too late to use this for Swift 4.1, it will allow users to conditionally compile code which requires (or not) the Swift 5 compiler or Standard Library, regardless of the swift language version:

```swift
#if compiler(>=5.0)
// Use Swift 5 new and shiny Standard Library API
#else
// Use old Swift 4.2 Standard Library API
#endif
```

## Impact on existing code

This is a purely additive change and will have no impact on existing code.

## Alternatives considered

No other alternative naming was considered for this new directive.
