# Default actor isolation per-file

* Proposal: [SE-0478](0478-default-isolation-typealias.md)
* Authors: [Holly Borla](https://github.com/hborla), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Returned for revision**
* Vision: [Improving the approachability of data-race safety](/visions/approachable-concurrency.md)
* Implementation: [swiftlang/swift#81863](https://github.com/swiftlang/swift/pull/81863), [swiftlang/swift-syntax#3087](https://github.com/swiftlang/swift-syntax/pull/3087)
* Experimental Feature Flag: `DefaultIsolationPerFile`
* Previous Proposal: [SE-0466: Control default actor isolation inference][SE-0466]
* Review: ([pitch](https://forums.swift.org/t/pitch-a-typealias-for-per-file-default-actor-isolation/79150))([review](https://forums.swift.org/t/se-0478-default-actor-isolation-typealias/79436))([return for revision](https://forums.swift.org/t/returned-for-revision-se-0478-default-actor-isolation-typealias/80253))

## Introduction

[SE-0466: Control default actor isolation inference][SE-0466] introduced the ability to specify default actor isolation on a per-module basis. This proposal introduces a new declaration for specifying default actor isolation in individual source files within a module. This allows specific files to opt out of main actor isolation within a main-actor-by-default module, and opt into main actor isolation within a nonisolated-by-default module.

## Motivation

SE-0466 allows code to opt in to being “single-threaded” by default by isolating everything in the module to the main actor. When the programmer really wants concurrency, they can request it explicitly by marking a function or type as `nonisolated`, or they can define it in a module that does not default to main-actor isolation. However, it's very common to group multiple declarations used in concurrent code into one source file or a small set of source files. Instead of choosing between writing `nonisolated` on each individual declaration or splitting those files into a separate module, it's desirable to state that all declarations in those files default to `nonisolated`.

## Proposed solution

This proposal allows writing a new kind of declaration to specify the default actor isolation for a file. The isolation is specified with the `using` keyword, followed by the default isolation for the file. Writing `using @MainActor` specifies that all declarations in the file default to main actor isolated:

```swift
// main.swift

using @MainActor

// Implicitly '@MainActor'
var global = 0

// Implicitly '@MainActor'
func main() { ... }

main()
```

Writing `using nonisolated` specifies that all declarations in the file default to `nonisolated`:

```swift
// Point.swift

using nonisolated

// Implicitly 'nonisolated'
struct Point {
  var x: Int
  var y: Int
}
```

## Detailed design

The following production rules describe the grammar of `using` declarations:

> declaration -> using-declaration \
> using-declaration -> `using` attribute \
> using-declaration -> `using` declaration-modifier \
> using-declaration -> `using` call-expression

The `using` keyword can be followed by an attribute, a declaration modifier, or a call expression. This proposal only supports `using @MainActor` and `using nonisolated`; any other attribute, modifier, or expression written after `using` is an error. The general grammar rules allow `using` to be expanded in the future.

Writing a `using` declaration is only valid at the top-level scope; it is an error to write `using` in any other scope:

```swift
func f() {
  using @MainActor // error
}
```

Specifying `using @MainActor` anywhere in the file will instruct the compiler to use `@MainActor` as the default isolation for unspecified declarations:

```swift
using @MainActor

// Implicitly '@MainActor'
struct S {}

// still 'nonisolated'
nonisolated struct T {}
```


Specifying `using nonisolated` anywhere in the file will instruct the compiler to use `nonisolated` as the default isolation for unspecified declarations:

```swift
using nonisolated

// Implicitly 'nonisolated'
struct S {}

// still '@MainActor'
@MainActor struct T {}
```

`using` follows the same isolation inference rules as SE-0466. An isolation specified by `using` is only used as a default, meaning that all other isolation inference rules from an explicit annotation on a declaration are preferred. For example, inference from a protocol conformance is preferred over default actor isolation:

```swift
// In MyLibrary

@MainActor
protocol P {}

// In MyClient
import MyLibrary

using nonisolated

// '@MainActor' inferred from 'P'
struct S: P {}

// Implicitly 'nonisolated'
func f() {}
```

## Source compatibility

This is an additive feature with no impact on existing code.

## ABI compatibility

This proposal has no ABI impact on existing code.

## Implications on adoption

This proposal does not change the adoption implications of adding `@MainActor` to a declaration that was previously nonisolated and vice versa. The source and ABI compatibility implications of changing actor isolation are documented in the Swift migration guide's [Library Evolution](https://github.com/apple/swift-migration-guide/blob/29d6e889e3bd43c42fe38a5c3f612141c7cefdf7/Guide.docc/LibraryEvolution.md#main-actor-annotations) article.

## Alternatives considered

### Using Swift package manifest-style APIs for specifying default attributes

Instead of supporting attributes and modifiers directly, we could instead use Swift package manifest-style APIs for specifying default attributes. For example:

```swift
using defaultIsolation(MainActor.self)
```

We did not choose this direction for two reasons:
1. The attribute or modifier written after `using` makes it immediately clear what kind of default we're specifying. `@MainActor` and `nonisolated` are understood to be kinds of isolation, so having to write "isolation" in the syntax is not clarifying.
2. Having to write "default" in the syntax is equally not clarifying, and it will be repetitive if `using` is extended to other attributes.

To elaborate on these points, consider the future direction to extend `using` to `@available` attributes:

```swift
using @available(SwiftStdlib 5.1, *)

// Has default Swift 5.1 availability
public protocol Actor { ... }

// All concurrency-related APIs
```

It is immediately clear that what's being specified is availability, so having to include an additional "availability" in the syntax is repetitive:

```swift
using defaultAvailability("@available(SwiftStdlib 5.1, *)")
```

Not all attributes have a value representation in Swift code, so we'd likely end up having to write attributes and modifiers in string literals, which is not as nice as writing a plain attribute or modifier.

How the attribute or modifier is applied as a default depends on how inference for that attribute or modifier works throughout the language. For availability, if you write an extension of a less-available type in the same file, the extension will still have the more constrained availability:

```swift
using @available(SwiftStdlib 5.1, *)

// Has default Swift 5.1 availability
public protocol Actor { ... }

// Has default Swift 5.1 availability
@globalActor
public actor MainActor { ... }

// Has explicit Swift 6.0 availability
@available(SwiftStdlib 6.0, *)
public protocol TaskExecutor { ... }

// Has implicit Swift 6.0 availability
extension TaskExecutor { ... }
```

The fact that attributes and modifiers are only used as defaults will apply to every attribute or modifier that `using` is extended to. Programmers will learn this once when encountering `using` for the first time, and having to repeat the word `default` in the syntax with every use will not help reinforce how the default is applied.

### A typealias to specify default isolation per file

A previous iteration of this proposal used a typealias to specify default actor isolation instead of a new syntax:

```swift
// main.swift

private typealias DefaultIsolation = MainActor

// Implicitly '@MainActor'
var global = 0

// Implicitly '@MainActor'
func main() { ... }

main()
```

Though the typealias model is consistent with other language defaulting rules such as default literal types, there are a number of serious downsides:

1. The typealias must be `private` or `fileprivate` to limit its scope to the current file.
2. The right hand side of the typealias is conceptually not a type, because it must be able to represent `nonisolated`, and the proposal added a typelias of `nonisolated` to `Never` to enable writing `nonisolated` as the underlying type.
3. The typealias name, `DefaultIsolation`, serves no purpose beyond affecting the compiler's inference. The name `DefaultIsolation` cannot be used explicitly on an individual declaration to impact its isolation.

Adding a typealias named `nonisolated` to `Never` to the Concurrency library to enable writing it as the underlying type of a typealias is pretty strange; this approach leverages the fact that `nonisolated` is a contextual keyword, so it's valid to use `nonisolated` as an identifier. Using an empty struct or enum type would introduce complications of having a new type be only available with the Swift 6.2 standard library. All of these solutions allow `nonisolated` to be written in contexts where it should never appear, such as parameter and result types of functions.

It's extremely valuable to have a consistent way to spell `nonisolated`. Introducing a type that follows standard naming conventions, such as `Nonisolated`, or using an existing type like `Never` is more consistent with recommended style, but overall complicates the concurrency model because it means you need to spell `nonisolated` differently when specifying it per file versus writing it on a declaration. And because the underlying type of this typealias is used to infer actor isolation, it's not used as a type in the same way that other typealiases are.

A bespoke syntax, as included in this proposal iteration, solves all of the above problems. The cost is adding new language syntax that deviates from other defaulting rules, but the benefits outweigh the costs:

1. `using` doesn't include extra ceremony like `private` or `fileprivate`.
2. It preserves a consistent way of spelling `nonisolated` without allowing `nonisolated` to be written in places where it shouldn't or repurposing features meant for types to apply to modifiers.
3. The name `using` is general enough that it can be extended in the future if we wish.

### A general macro to specify compiler settings

There's a separate pitch on the forums that introduces a built-in macro which can enable compiler flags on a per-file basis, including enabling strict concurrency checking, strict memory safety, and warning control. This design discussion also explored using the macro for specifying actor isolation per file:

```swift
#SwiftSettings(
  .treatAllWarnings(as: .error),
  .treatWarning("DeprecatedDeclaration", as: .warning),
  .defaultIsolation(MainActor.self),
)
```

However, default actor isolation has a significant difference from the other compiler settings that the macro supported: it impacts language semantics. Default actor isolation is a language dialect, while the other compiler flags only configure diagnostics; the behavior of the code does not depend on which diagnostic control flags are set.

## Future directions

`using` declarations in this proposal are designed so that they can be extended later if we need to. `using` is a general name that can work with any attribute or modifier. One compelling use case is to support `@available` attributes, which already effectively have a module-wide default based on deployment target.

`using` can also be extended to work with other SwiftPM manifest-style APIs, e.g.

```swift
using strictMemorySafety()
```

This leaves us space to explore whether the `#SwiftSetings` feature described in the alternatives considered should be a separate feature from specifying defaults that impact language semantics, or whether it should be expressed via `using` declarations.

[SE-0466]: /proposals/0466-control-default-actor-isolation.md
