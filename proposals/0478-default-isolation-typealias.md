# Default actor isolation typealias

* Proposal: [SE-0478](0478-default-isolation-typealias.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active Review (April 21 ... May 5, 2025)**
* Vision: [Improving the approachability of data-race safety](/visions/approachable-concurrency.md)
* Implementation: [swiftlang/swift#80572](https://github.com/swiftlang/swift/pull/80572)
* Experimental Feature Flag: `DefaultIsolationTypealias`
* Previous Proposal: [SE-0466: Control default actor isolation inference][SE-0466]
* Review: ([pitch](https://forums.swift.org/t/pitch-a-typealias-for-per-file-default-actor-isolation/79150))([review](https://forums.swift.org/t/se-0478-default-actor-isolation-typealias/79436))

## Introduction

[SE-0466: Control default actor isolation inference][SE-0466] introduced the ability to specify default actor isolation on a per-module basis. This proposal introduces a new typealias for specifying default actor isolation in individual source files within a module. This allows specific files to opt out of main actor isolation within a main-actor-by-default module, and opt into main actor isolation within a nonisolated-by-default module.

## Motivation

SE-0466 allows code to opt in to being “single-threaded” by default by isolating everything in the module to the main actor. When the programmer really wants concurrency, they can request it explicitly by marking a function or type as `nonisolated`, or they can define it in a module that does not default to main-actor isolation. However, it's very common to group multiple declarations used in concurrent code into one source file or a small set of source files. Instead of choosing between writing `nonisolated` on each individual declaration or splitting those files into a separate module, it's desirable to state that all declarations in those files default to `nonisolated`.

## Proposed solution

This proposal allows writing a private typealias named `DefaultIsolation` to specify the default actor isolation for a file.

An underlying type of `MainActor` specifies that all declarations in the file default to main actor isolated:

```swift
// main.swift

private typealias DefaultIsolation = MainActor

// Implicitly '@MainActor'
var global = 0

// Implicitly '@MainActor'
func main() { ... }

main()
```

An underlying type of `nonisolated` specifies that all declarations in the file default to `nonisolated`:

```swift
// Point.swift

private typealias DefaultIsolation = nonisolated

// Implicitly 'nonisolated'
struct Point {
  var x: Int
  var y: Int
}
```

## Detailed design

 A typealias named `DefaultIsolation` can specify the actor isolation to use for the source file it's written in under the following conditions:

* The typealias is written at the top-level.
* The typealias is `private` or `fileprivate`; the `DefaultIsolation` typealias cannot be used to set the default isolation for the entire module, so its access level cannot be `internal` or above.
* The underlying type is either `MainActor` or `nonisolated`.

 It is not invalid to write a typealias called `DefaultIsolation` that does not meet the above conditions. Any typealias named `DefaultIsolation` that does not meet the above conditions will be skipped when looking up the default isolation for the source file. The compiler will emit a warning for any `DefaultIsolation` typealias that is not considered for default actor isolation along with the reason why:

```swift
@globalActor
actor CustomGlobalActor {
  static let shared = CustomGlobalActor()
}

private typealias DefaultIsolation = CustomGlobalActor // warning: not used for default actor isolation
```

To allow writing `nonisolated` as the underlying type of a typealias, this proposal adds a typealias named `nonisolated` to the Concurrency library:

```swift
public typealias nonisolated = Never
```

This typealias serves no purpose beyond specifying default actor isolation. To specify `nonisolated` using the `DefaultIsolation` typealias, the underlying type must be `nonisolated` exactly; it is invalid to write `private typealias DefaultIsolation = Never`.

## Source compatibility

Technically source breaking if someone happens to have written a private `DefaultIsolation` typealias with an underlying type of `MainActor`, which will start to infer every declaration in that file as `@MainActor`-isolated after this change. This seems extremely unlikely.

## ABI compatibility

This proposal has no ABI impact on existing code.

## Implications on adoption

This proposal does not change the adoption implications of adding `@MainActor` to a declaration that was previously nonisolated and vice versa. The source and ABI compatibility implications of changing actor isolation are documented in the Swift migration guide's [Library Evolution](https://github.com/apple/swift-migration-guide/blob/29d6e889e3bd43c42fe38a5c3f612141c7cefdf7/Guide.docc/LibraryEvolution.md#main-actor-annotations) article.

## Alternatives considered

Adding a typealias named `nonisolated` to `Never` to the Concurrency library to enable writing it as the underlying type of a typealias is pretty strange; this approach leverages the fact that `nonisolated` is a contextual keyword, so it's valid to use `nonisolated` as an identifier. This proposal uses a typealias instead of an empty struct or enum type to avoid the complications of having a new type be only available with the Swift 6.2 standard library.

It's extremely valuable to have a consistent way to spell `nonisolated`. Introducing a type that follows standard naming conventions, such as `Nonisolated`, or using an existing type like `Never` is more consistent with recommended style, but overall complicates the concurrency model because it means you need to spell `nonisolated` differently when specifying it per file versus writing it on a declaration. And because the underlying type of this typealias is used to infer actor isolation, it's not used as a type in the same way that other typealiases are.

Another alternative is to introduce a bespoke syntax such as `using MainActor` or `using nonisolated`. This approach preserves a consistent spelling for `nonisolated`, but at the cost of adding new language syntax that deviates from other defaulting rules such as the default literal types and the default actor system types.

Having a `nonisolated` typealias may also allow us to improve the package manifest APIs for specifying default isolation, allowing us to move away from using `nil` to specify `nonisolated`:

```swift
SwiftSetting.defaultIsolation(nonisolated.self)
```

We can also pursue allowing bare metatypes without `.self` to allow:

```swift
SwiftSetting.defaultIsolation(nonisolated)
SwiftSetting.defaultIsolation(MainActor)
```

[SE-0466]: /proposals/0466-control-default-actor-isolation.md
