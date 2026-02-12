# Swift runtime availability

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Allan Shortlidge](https://github.com/tshortli)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Bug: [swiftlang/swift#42630](https://github.com/swiftlang/swift/issues/42630)
* Experimental Feature Flag: `SwiftRuntimeAvailability`
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Since its 5.0 release, Swift has been ABI stable on Apple's operating systems. When targeting Apple platforms, library developers can opt-in to exposing ABI stable interfaces using the `-enable-library-evolution` compiler flag. With library evolution enabled it is possible for binary distributions of libraries and their clients to evolve separately from one another while remaining compatible at runtime. The `@available` attribute and `if #available(...)` runtime check are some of the tools that Swift offers to help developers maintain runtime compatibility as libraries gain new APIs. For example, in macOS 26 `Foundation` offers a new static property for accessing the user's preferred locales:

```swift
extension Locale {
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  public static var preferredLocales: [Locale] { get }
}
```

Applications can use `preferredLocales` and still be distributed to Macs running older operating systems as long as the app checks the version of the operating system at runtime before attempting to access the property:
```swift
if #available(macOS 26.0, *) {
  handlePreferredLocales(Locale.preferredLocales)
} else {
  // Fallback on earlier versions
}
```

As the Swift language progresses towards a long term goal of offering ABI stability on additional platforms, developers will need a way to check the availability of APIs in the standard library and core runtime libraries on those platforms. This proposal introduces the `Swift` availability domain to satisfy that need with a concise syntax that will work for this purpose no matter what platform the developer is targeting. 

## Motivation

In the future, Swift could become ABI stable on non-Apple platforms. For a given platform, the Swift runtime might either be distributed with the operating system, as it is on macOS, or it could be distributed separately using some mechanism like a package manager. In the former case, extending the Swift compiler to add platform-specific availability for that operating system would be sufficient to allow developers to back deploy Swift binaries. When the Swift runtime is distributed separately from the operating system, though, a platform independent notion of Swift runtime availability is needed instead. This proposal introduces the platform independent `Swift` availability domain to satisfy both use cases and make the task of writing cross platform code simpler.

## Proposed solution

A Swift runtime version should be accepted in `@available` attributes and `if #available` checks:

```swift
extension Locale {
  @available(Swift 6.2, *)
  public static var preferredLocales: [Locale] { get }
}

if #available(Swift 6.2, *) {
  handlePreferredLocales(Locale.preferredLocales)
}
```

On platforms such as macOS where the Swift runtime is built-in, platform availability can be inferred from `Swift` availability and vice-versa. This means that `@available(Swift 6.2, *)` is equivalent to `@available(macOS 26, *)` when targeting macOS, for example.

All new and existing APIs in the Swift standard libraries should be given `Swift` availability attributes instead of platform specific ones. The APIs in other libraries that are distributed with the Swift runtime, such as `Testing` or `Foundation`, should also be given `Swift` availability attributes.

To avoid confusion, the existing `swift` availability domain, which represents availability with respect to enabled Swift language mode, should be renamed to `SwiftLanguageMode`:

```swift
@available(swift 6) // warning: 'swift' has been renamed to 'SwiftLanguageMode'
func onlyAvailableInTheSwift6LanguageMode() { }
```

## Detailed design

### Availability attributes

In positions where platform names and versions are accepted in `@available` attributes today, the compiler should also accept `Swift` along with a version:
```swift
@available(Swift 6.2, *)
public func introducedInSwift6_2()

@available(Swift, introduced: 6.0, deprecated: 6.1, obsoleted: 6.2)
public func thisWasAMistake()
```

Unlike platform availability, though, declarations may not be `unavailable` or `deprecated` in `Swift` since this would be equivalent to being always unavailable or always deprecated, which already have existing spellings.
```swift
// Use @available(*, unavailable) instead
@available(Swift, unavailable) // error: 'unavailable' cannot be used in '@available' attribute for Swift
func unavailableInSwift() { }

// Use @available(*, deprecated) instead
@available(Swift, deprecated) // error: 'deprecated' cannot be used in '@available' attribute for Swift
func deprecatedInSwift() { }

```

### Availability queries

`Swift` should also be accepted where platform names and versions are accepted in `if #available` and `if #unavailable`:

```swift
if #available(Swift 6.2, *) {
  // Only executes when the Swift runtime version is at least 6.2
}
if #unavailable(Swift 6.2) {
  // Only executes when the Swift runtime version is less than 6.2
}
```

### Platform availability inference

On platforms like macOS where the Swift runtime ships built-in, platform availability can be inferred from `Swift` availability and vice-versa.

```swift
@available(Swift 6.2, *)
func introducedInSwift6_2()

@available(macOS 26, *)
func introducedInMacOS26()

if #available(macOS 26.0, *) {
  introducedInSwift6_2() // OK, macOS 26.0 implies Swift 6.2
}
if #available(Swift 6.2, *) {
  introducedInMacOS26() // OK, Swift 6.2 implies macOS 26
}
```

Platform availability may be specified and checked simultaneously with `Swift` availability so long as it is a platform that has `Swift` built-in:

```swift
// OK, macOS 26 takes precedence when compiling for macOS
if #available(Swift 6.0, macOS 26, *) { 
  // Executes on macOS 26, iOS 18, watchOS 11, tvOS 18, and visionOS 2
}

// This is illegal; 'Swift 6.0' and 'Windows 11' are independent conditions that
// would require separate checks at runtime.
if #available(Swift 6.0, Windows 11, *) { // error: Swift and Windows cannot be specified together in #available
  // ...
}
```

### Specifying a minimum Swift runtime

Code may be built with an implicit minimum Swift runtime version by specifying the `-min-swift-runtime-version` compiler flag. This effectively supplies the compiler with a "deployment target" in terms of the Swift runtime version:

```swift
@available(Swift 6.0, *)
func introducedInSwift6_0()

// Built with `-min-swift-runtime-version 6.0`.
introducedInSwift6_0() // OK, no `if #available` required 
```

To prevent ambiguity, this flag is only accepted when building for targets that do not have a built-in Swift runtime. For targets that do have a built-in runtime, the minimum Swift runtime version is inferred automatically from the target triple specified with `-target`.

### Swift language mode availability

The existing `swift` availability domain (with a lowercase `s`) should be renamed to `SwiftLanguageMode` in accordance with the terminology introduced by [SE-0441](https://forums.swift.org/t/se-0441-formalize-language-mode-terminology/73182).

## Source compatibility

Adding support for `Swift` versions in `@available` and `if #available` is an additive change that should not have any effect on source compatibility. The replacement of platform-specific availability attributes in the standard library will also be source compatible since the compiler will infer platform availability constraints from the new Swift runtime availability constraints and existing code must already satisfy platform availability constraints. When compiling for targets that do not offer an ABI stable Swift runtime, `Swift` availability constraints will be ignored by the compiler just as irrelevant platform availability constraints already are.

## ABI compatibility

An `@available` attribute does not directly affect the ABI of the declaration it is attached to. However, `@available` attributes are used by the compiler to determine whether or not to emit weak linkage for symbols associated with that declaration. Adding `Swift` availability annotations to existing declarations should not have any effect on the binaries of the libraries or their clients as long as the `Swift` availability attributes are equivalent to the platform availability attributes they replace.

## Implications on adoption

`@available` attributes and `if #available` checks that specify the `Swift` availability domain are not backward source compatible with older toolchains. This limitation is no different than any other new syntax added to the Swift language, but it does mean that cross-platform packages may not be able to easily adopt the new syntax to simplify cross-platform availability. Compiler version conditionals (e.g. `#if compiler(>=6.2)`) can be used to mitigate this problem where appropriate. 

## Future directions

### Extensible availability checking

On any platforms where Swift is ABI stable, it could make sense to allow libraries to extend availability checking with their own [availability domains](https://forums.swift.org/t/pitch-extensible-availability-checking/79308). These domains could be used to represent the versions of libraries that are always distributed separately from the underlying platform. This could help developers who want to distribute their own ABI stable Swift libraries via system package managers without requiring strict versioning compatibility for their clients, for example.

A sufficiently complex extensible availability checking feature might be able to subsume the compiler's built-in support for the `Swift` runtime availability domain someday. In order to do so, though, there would need to be a way to provide the compiler with a mapping of platform versions to the custom availability domain's versions.
