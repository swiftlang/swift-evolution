# File level defaults

* Proposal: [SE-0478](0478-default-isolation-typealias.md)
* Authors: [Aviva Ruben](https://github.com/a-viv-a), [Holly Borla](https://github.com/hborla), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Returned for revision, partially implemented**
* Vision: [Improving the approachability of data-race safety](/visions/approachable-concurrency.md)
* Implementation: [swiftlang/swift#81863](https://github.com/swiftlang/swift/pull/81863), [swiftlang/swift-syntax#3087](https://github.com/swiftlang/swift-syntax/pull/3087)
* Experimental Feature Flag: `DefaultIsolationPerFile` (currently ships `using` syntax; this revision proposes `default`)
* Previous Proposal: [SE-0466: Control default actor isolation inference][SE-0466]
* Review: ([pitch](https://forums.swift.org/t/pitch-a-typealias-for-per-file-default-actor-isolation/79150))([review](https://forums.swift.org/t/se-0478-default-actor-isolation-typealias/79436))([return for revision](https://forums.swift.org/t/returned-for-revision-se-0478-default-actor-isolation-typealias/80253))([pitch 2](https://forums.swift.org/t/pitch-2-default-actor-isolation-per-file/80243))

## Summary of changes

Introduces `default` declaration syntax to specify default actor isolation, `@diagnose` behavior, or `@available` restrictions for every top-level declaration in the file.

## Motivation

Several language features, particularly some attributes and modifiers, are very commonly applied (or desirable to apply) to entire files. `@diagnose`, `@available`, and actor isolation are motivating features.

[SE-0522: Source-level control over compiler warnings][SE-0522] introduces `@diagnose`, a declaration attribute for controlling warnings within a lexical scope, instead of a blunt module-level control. However, applying the attribute to a collection of declarations below the granularity of a module is still repetitive. File-scope is [mentioned as a future direction for SE-0522](0522-source-warning-control.md#file-scope-warning-behavior-control).

Similarly, `@available` is used to control the lifecycle of APIs, but there is no mechanism to use it other than writing it on each declaration. Files containing platform-specific APIs, APIs incompatible with concurrency, deprecated APIs, or declarations using non-backported APIs end up repeating the same `@available` attribute on every declaration. It is very common to see files where every declaration has the same base availability.

[SE-0466: Control default actor isolation inference][SE-0466] introduced the ability to specify default actor isolation on a per-module basis, as part of approachable concurrency. It allows code to opt in to being “single-threaded” by default by isolating everything in the module to the main actor. When the programmer really wants concurrency, they can request it explicitly by marking a function or type as `nonisolated`, or they can define it in a module that does not default to main-actor isolation. However, it's very common to group multiple declarations used in concurrent code into one source file or a small set of source files. Instead of choosing between writing `nonisolated` on each individual declaration or splitting those files into a separate module, it's desirable to state that all declarations in those files default to `nonisolated`.

In each of these cases, it is repetitive and error-prone to repeat the same attributes and modifiers for each declaration in a file. Repetition risks masking cases where the attribute or modifier is *not* present or slightly differs, as readers learn to skim past it.

## Proposed solution

This proposal allows writing a new kind of declaration at the top of a file, to specify default file-level behaviors. The default behavior is specified with the `default` keyword, followed by the default attribute or isolation. For example, writing `default @available(*, deprecated, message: "this logging system uses global state")` specifies that all top level declarations in the file are deprecated:

```swift
// LegacyLogger.swift

default @available(*, deprecated, message: "this logging system uses global state")

// Implicitly @available(*, deprecated, message: "this logging system uses global state")
func log(message: String) { ... }

// Implicitly @available(*, deprecated, message: "this logging system uses global state")
func initLogging() { ... }
```

Writing `default @MainActor` specifies that all top level declarations in the file default to main actor isolated, even when the module uses `-default-isolation nonisolated`:

```swift
// Data.swift

default @MainActor

// Implicitly '@MainActor'
class Profile { ... }

// Implicitly '@MainActor'
class Settings { ... }
```

Writing `default nonisolated` specifies that all top level declarations in the file default to `nonisolated`, even when the module uses `-default-isolation MainActor`:

```swift
// Point.swift

default nonisolated

// Implicitly 'nonisolated'
struct Point {
  var x: Int
  var y: Int
}
```

## Detailed design

The following production rules describe the grammar of `default` declarations:

> declaration -> default-declaration \
> default-declaration -> `default` attribute \
> default-declaration -> `default` declaration-modifier

The `default` keyword can be followed by an attribute or a declaration modifier. This proposal only supports `default @MainActor`, `default nonisolated`, `default @available` and `default @diagnose`; any other attribute, modifier, or expression written after `default` is an error.

In general, the intention is that `default` behaves like writing the attribute or modifier on each appropriate top level declaration. This proposal inherits the existing propagation and inference rules for each default behavior; for example, [SE-0466]'s exception for `SendableMetatype`. The semantics of `default` are specified per attribute or modifier in the subsections below.

Writing a `default` declaration is only valid at the top-level scope; it is an error to write `default` in any other scope:

```swift
func f() {
  default @MainActor // error
}
```

Further, writing a `default` declaration is only valid before other declarations, with the exception of `import` statements:

```swift
default @available(swift, introduced: 5.9) // legal

import MyLibrary

default @diagnose(StrictMemorySafety, as: error) // legal

func foo() {}

default nonisolated // error
```

This choice aims to avoid the ambiguity of `default` written after a declaration; a reader should never need to search for per-file defaults.

The `default` keyword can be repeated at the top of the file to specify multiple defaults. For attribute defaults, multiple instances compose following the semantics of that attribute, as though the defaults were written before any per-decl attributes. For declaration-modifier defaults like isolation, repetition follows the underlying modifier's rules: since `@MainActor @MainActor struct ...` and `nonisolated @MainActor class ...` are errors, repeating those defaults with identical or conflicting values is likewise an error:

```swift
default @MainActor
default @MainActor // error
```

```swift
default nonisolated
default @available(swift, introduced: 5.1)
default @MainActor // error
```

In cases that are not errors (like for attributes), the compiler should emit warnings where a default attribute is identically repeated, and its repetition would have no effect.

### Actor isolation

A common use for default actor isolation is to override the module-level `-default-isolation` setting: file-level defaults supersede module-level defaults. Since a declaration can have at most one actor isolation, there can only be one file-level default actor isolation per file.

> [!NOTE]
> [SE-0343]'s rule that global variables and top-level code run on `@MainActor` in script mode is independent of default isolation, whether from file-level `default` or module-level `-default-isolation`.

Specifying `default nonisolated` at the top of the file will instruct the compiler to use `nonisolated` as the default isolation for unspecified top level declarations:

```swift
default nonisolated

// Implicitly 'nonisolated'
struct S {}

// Implicitly 'nonisolated'
extension S {
  // Implicitly the same as the extension, which is implicitly 'nonisolated'
  func foo() {}
}

// still '@MainActor'
@MainActor extension S {
  // Implicitly the same as the extension, which is explicitly '@MainActor'
  func bar() {}
}

// still '@MainActor'
@MainActor struct T {}
```

Specifying `default @MainActor` at the top of the file will instruct the compiler to use `@MainActor` as the default isolation for unspecified top level declarations:

```swift
default @MainActor

// Implicitly '@MainActor'
struct S {}

// Implicitly '@MainActor'
extension S {
  // Implicitly the same as the extension, which is implicitly '@MainActor'
  func foo() {}
}

// still 'nonisolated'
nonisolated extension S {
  // Implicitly the same as the extension, which is explicitly 'nonisolated'
  func bar() {}
}

// still 'nonisolated'
nonisolated struct T {}
```

`default` follows the same isolation inference rules as [SE-0466]. An isolation specified by `default` is only used as a default, meaning that all other isolation inference rules from an explicit annotation on a declaration are preferred. For example, inference from a protocol conformance is preferred over default actor isolation:

```swift
// In MyLibrary

@MainActor
protocol P {}

// In MyClient
import MyLibrary

default nonisolated

// '@MainActor' inferred from 'P'
struct S: P {}

// Implicitly 'nonisolated'
func f() {}
```

The naive approach is discussed in [alternatives considered](#dont-inherit-se-0466-carve-outs-for-default-actor-isolation).

> [!NOTE]
> **Divergence from [SE-0466]:** When compiled in Swift 5 language mode, SE-0466's `-default-isolation MainActor` marks the inferred isolation as preconcurrency, which is serialized into the public module interface as `@preconcurrency` and downgrades cross-actor diagnostics in downstream consumers to warnings. `default @MainActor` does not inherit this behavior. Inferred `@MainActor` based on `default` is treated like an explicit annotation, and the public interface contains no implicit `@preconcurrency`.

### Source warning control

Specifying `default @diagnose(...)` at the top of the file will instruct the compiler to apply `@diagnose(...)` to all top level declarations:

```swift
// Legacy.swift

default @diagnose(DeprecatedDeclaration, as: ignored, reason: "Maintaining backwards compatibility")

// Implicitly '@diagnose(DeprecatedDeclaration, as: ignored)'
func restoreLegacyAPI() {
  deprecatedHelper()
}

// Implicitly '@diagnose(DeprecatedDeclaration, as: ignored)'
extension Logger {
  func legacyFormat(_ s: String) -> String {
    oldStringFormatter(s)
  }
}

// explicit '@diagnose' takes precedence over the default
@diagnose(DeprecatedDeclaration, as: warning)
func migrationBridge() {
  anotherDeprecatedHelper()
}
```

`@diagnose` is lexically scoped, so its effect propagates to declarations nested inside a top-level declaration.

Repeated `default @diagnose(...)` declarations are permitted, and the order-sensitive rules from [SE-0522 multiple diagnose attributes on the same declaration](0522-source-warning-control.md#multiple-diagnose-attributes-on-the-same-declaration) apply to defaults as though the default attributes were written before any diagnose attributes on a given declaration:

```swift
default @diagnose(DiagGroupID, as: warning)
default @diagnose(DiagGroupID, as: error)

// implicit @diagnose(DiagGroupID, as: warning)
// implicit @diagnose(DiagGroupID, as: error)
public func foo() // DiagGroupID diagnoses as an error

// implicit @diagnose(DiagGroupID, as: warning)
// implicit @diagnose(DiagGroupID, as: error)
@diagnose(DiagGroupID, as: ignored)
public func bar() // DiagGroupID is ignored
```

### API availability

Specifying `default @available(...)` at the top of the file will instruct the compiler to apply `@available(...)` to all top level declarations:

```swift
// LockedCollections.swift

default @available(*, noasync, message: "holding a lock across suspension may deadlock")

// Implicitly '@available(*, noasync, message: "holding a lock across suspension may deadlock")'
public final class LockedEventLog {
  public func append(_ event: String) { ... }
  public func entries() -> [String] { ... }
}

// Implicitly '@available(*, noasync, message: "holding a lock across suspension may deadlock")'
public final class LockedCache<Key: Hashable, Value> {
  public func get(_ key: Key) -> Value? { ... }
  public func set(_ key: Key, to value: Value) { ... }
}
```

Repeated `default @available(...)` declarations are permitted, and follow the same merge rules as `@available` on an individual declaration.

> [!NOTE]
> `@available` has some special, and sometimes surprising, behavior for merging. For example, `@available(iOS, unavailable)` implies unavailability on Catalyst and visionOS unless explicitly specified. Default available attributes should be interpreted as though they were written on the top level declaration alongside any explicit attributes.

For example if you write an extension of a less-available type in the same file, the extension will still have the more constrained availability:

```swift
default @available(SwiftStdlib 5.1, *)

// Has default Swift 5.1 availability
public protocol Actor { ... }

// Has default Swift 5.1 availability
@globalActor
public actor MainActor { ... }

// Has explicit Swift 6.0 availability
@available(SwiftStdlib 6.0, *)
public protocol TaskExecutor { ... }

// Inherits Swift 6.0 availability from the extended protocol
extension TaskExecutor { ... }
```

## Source compatibility

This proposal is strictly additive. `default` is already a reserved keyword and top level `default` is not valid Swift today, so no existing code should be affected. Use of a new default such as `@available` or actor isolation carries the same source compatibility implications as writing it on top level declarations.

## ABI compatibility

This proposal has no effect on ABI compatibility, beyond the implications of changing the signature of public declarations by using this feature.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility. In cases where the default value was affecting public declarations, the default modifier or attribute could be written on the declaration when removing `default` to preserve ABI.

Adopting this feature without ABI changes for public APIs built in the Swift 5 language mode with `-default-isolation MainActor`, as an alternative to the module-level default isolation, would require adding `@preconcurrency` to all applicable public declarations.

## Future directions

`default` declarations in this proposal are designed so that they can be extended later if we need to. `default` is a general name that can work with any attribute or modifier.

This leaves us space to explore whether the `#SwiftSettings` feature described in the alternatives considered should be a separate feature from specifying defaults that impact language semantics, or whether it should be expressed via `default` declarations.

In a future where attributes supported by `default` emit diagnostics for repeated or overlapping uses, such diagnostics should not apply to pairs where one is a `default` and one is written on the declaration, since the declaration spelling is intended to supersede the file-level default. In such a future, diagnostics for repeated or overlapping attributes should also apply to repeated or overlapping `default` pairs.

### Custom actors

It may be desirable to group a collection of declarations which are isolated to a programmer defined actor. `default` could be extended to allow referencing programmer defined actors, creating a 'CustomActor by Default' mode, at a per-file level.

### Additional attributes and modifiers

There may be other attributes and modifiers that are discovered to be desirable to use with this feature. Attributes and modifiers added in the future may also want to consider being supported by `default`. Such attributes would need to have their utility weighed against their risk of increasing non-local behavior of code, and complicating the rules for `default`.

We are especially interested in feedback on attributes and modifiers that should be included in this proposal.

Some examples and their potential drawbacks include:

* `@concurrent`: only legal on top level async functions, not types, extensions etc. May require additional rules for `default` to apply to methods, or to be supported on all relevant top level declarations.
* `@preconcurrency`: there is no opposite attribute (a hypothetical `@concurrency`) to opt an individual declaration out of a `default @preconcurrency`. There is also potentially unique value in being locally explicit about `@preconcurrency`.
* `@unsafe`: may conceal unsafe behavior outside of the intended scope, and potentially disguises the unsafe nature of the file from a programmer reading a single function in isolation.
* access control: extreme non-local behavior, applying access control to a top level declaration does not affect its contents, and accidentally making something public in your API is hard to walk back.

> [!NOTE]
> Access control has special behavior with regard to `extension`. A `public extension` will make the methods and computed properties contained `public`, which is not the case for other nominal declarations; A `public class` does not make all of its members and methods public, for example. Edge case behavior like this in new and existing attributes and modifiers, which further contributes to non-local behavior, may increase the motivation not to support them for `default`.

### Macros

It may be desirable to support `default @CustomAttrMacro` in the future. A proposal that adds support for this would need to carefully consider the risks around "spooky action at a distance", especially for macros that define new methods and members.

### Inlay hints / LSP support

It may be desirable to indicate these default behaviors in the positions where they are applied, so that readers of code using `default` are immediately aware of the inferred qualities. Additionally, this may help prevent programmers from forgetting what modifiers and attributes are applied by default to the code they are writing.

## Alternatives considered

### Don't inherit [SE-0466] carve outs for default actor isolation

Instead of inheriting SE-0466's semantics regarding inference, we could treat default actor isolation as though it was written on *every* legal top level declaration. SE-0466 semantics are surprising; writing `default @MainActor`, conforming to something with a `SendableMetatype`, and then getting errors in your implementation about accessing `MainActor` isolated state elsewhere in the file from a `nonisolated` context is not intuitive. However, we think these carve outs are valuable here for the same reason SE-0466 added them; these special cases are exactly where the naive default would have failed, and required adding an explicit modifier to override it.

### Do inherit [SE-0466] `@preconcurrency` behavior in Swift 5

We could use the same `@preconcurrency` behavior as `-default-isolation MainActor` in Swift 5. This may be prudent for adoption and complexity purposes. However, we feel that proliferating `@preconcurrency` on new code being written is a greater cost than easing adoption of `default` for `-default-isolation MainActor` + Swift 5 + public API. The implicit `@preconcurrency` behavior in Swift 5 wasn't stated in the proposal, and `-default-isolation MainActor` was not intended for libraries.

We are especially curious to hear opinions on this and the previous alternative.

### `using` instead of `default` syntax

Instead of the `default` keyword, we could use the `using` keyword, as a previous iteration of this proposal did.

We did not choose this keyword for the following reasons:

1. `using` has associations with C++ aliasing and namespace management, so choosing it could confuse some programmers coming from C++.
2. In explanation and semantics, this feature is a *default*, and choosing syntax that states it as such makes that more clear.

However, compared to `default`, `using` may feel more open for future use to configure things that are not necessarily default behaviors.

### Using Swift package manifest-style APIs for specifying default attributes

Instead of supporting attributes and modifiers directly, we could instead use Swift package manifest-style APIs for specifying default attributes. For example (written with `using` syntax, since this was suggested in that context):

```swift
using defaultIsolation(MainActor.self)
```

We did not choose this direction for two reasons:
1. The attribute or modifier written after `using` makes it immediately clear what kind of default we're specifying. `@MainActor` and `nonisolated` are understood to be kinds of isolation, so having to write "isolation" in the syntax is not clarifying.
2. Having to write "default" in the syntax is equally not clarifying, and it will be repetitive if `using` is extended to other attributes.

Further, consider support for attributes:

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
2. The right hand side of the typealias is conceptually not a type, because it must be able to represent `nonisolated`, and the proposal added a typealias of `nonisolated` to `Never` to enable writing `nonisolated` as the underlying type.
3. The typealias name, `DefaultIsolation`, serves no purpose beyond affecting the compiler's inference. The name `DefaultIsolation` cannot be used explicitly on an individual declaration to impact its isolation.

Adding a typealias named `nonisolated` to `Never` to the Concurrency library to enable writing it as the underlying type of a typealias is pretty strange; this approach leverages the fact that `nonisolated` is a contextual keyword, so it's valid to use `nonisolated` as an identifier. Using an empty struct or enum type would introduce complications of having a new type be only available with the Swift 6.2 standard library. All of these solutions allow `nonisolated` to be written in contexts where it should never appear, such as parameter and result types of functions.

It's extremely valuable to have a consistent way to spell `nonisolated`. Introducing a type that follows standard naming conventions, such as `Nonisolated`, or using an existing type like `Never` is more consistent with recommended style, but overall complicates the concurrency model because it means you need to spell `nonisolated` differently when specifying it per file versus writing it on a declaration. And because the underlying type of this typealias is used to infer actor isolation, it's not used as a type in the same way that other typealiases are.

A bespoke syntax, as included in this proposal iteration, solves all of the above problems. The cost is adding new language syntax that deviates from other defaulting rules, but the benefits outweigh the costs:

1. `default` doesn't include extra ceremony like `private` or `fileprivate`.
2. It preserves a consistent way of spelling `nonisolated` without allowing `nonisolated` to be written in places where it shouldn't or repurposing features meant for types to apply to modifiers.
3. The name `default` is general enough that it can be extended in the future if we wish.

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

Additionally, `@diagnose` has already been accepted, so `default @diagnose` naturally reuses that accepted mechanism rather than reinventing file-level diagnostic control in a separate macro API.

[SE-0343]: 0343-top-level-concurrency.md
[SE-0466]: 0466-control-default-actor-isolation.md
[SE-0478]: 0478-default-isolation-typealias.md
[SE-0522]: 0522-source-warning-control.md
