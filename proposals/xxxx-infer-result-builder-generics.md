# Infer generic arguments of result builder attributes

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Cal Stephens](https://github.com/calda)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [#86209](https://github.com/swiftlang/swift/pull/86209)
* Pitch: [1](https://forums.swift.org/t/add-arraybuilder-to-the-standard-library/83811/3)

## Introduction

We should enable generic result builders to be used as attributes without needing to explicitly specify generic arguments, instead allowing them to be inferred from the return type of the attached declaration.

## Motivation

Take this simple generic `ArrayBuilder` type that a project may choose to define:

```swift
@resultBuilder
enum ArrayBuilder<Element> {
    static func buildBlock(_ elements: Element...) -> [Element] {
        elements
    }

    // ...
}
```

At call sites, the result builder must be fully spelled out as `@ArrayBuilder<Element>`, explicitly specifying the generic argument for `Element`:

```swift
/// An invocation for the swift-format command line tool
struct SwiftFormatInvocation {
    @ArrayBuilder<String> let arguments: [String]
}
```

```swift
@ArrayBuilder<String>
var arguments: [String] {
    "format"
    "--in-place"

    if recursive {
        "--recursive"
    }
}
```

```swift
extension Array {
    init(@ArrayBuilder<Element> _ build: () -> Self) {
        self = build()
    }
}
```

In all of these cases, specifying the generic arguments of the `ArrayBuilder` adds additional boilerplate without adding much value, because the generic arguments are already obvious from context. This is also inconsistent with most other areas of the language, where generic arguments for types can typically be inferred.

## Proposed solution

We should improve the ergonomics of generic result builders by allowing generic arguments to be inferred from the return type of the attached declaration.

This allows us to omit the generic arguments in all of these examples, simplifying the code:

```swift
// Inferred to be `@ArrayBuilder<String>`
struct SwiftFormatInvocation {
    @ArrayBuilder let arguments: [String]
}
```

```swift
// Inferred to be `@ArrayBuilder<String>`
@ArrayBuilder
var arguments: [String] {
    "format"
    "--in-place"

    if recursive {
        "--recursive"
    }
}
```

```swift
// Inferred to be `@ArrayBuilder<Element>`
extension Array {
    init(@ArrayBuilder _ build: () -> Self) {
        self = build()
    }
}
```

## Detailed design

When not specified explicitly, the generic arguments for a generic result builder attribute will be inferred from the return type of the attached declaration.

We can infer that the return type of the attached declaration should be equal to one of the potential result types of the result builder. The potential result types of the result builder are defined by the types returned from the `buildFinalResult`, `buildPartialBlock`, and `buildBlock` methods.

For example, take this result builder:

```swift
@resultBuilder
enum CollectionBuilder<Element> {
    static func buildBlock(_ component: Element...) -> [Element] {
      component
    }

    static func buildFinalResult(_ component: [Element]) -> [Element] {
        component
    }

    static func buildFinalResult(_ component: [Element]) -> Set<Element> where Element: Hashable {
        Set(component)
    }
}
```

with these call sites:

```swift
@CollectionBuilder
var array: [String] {
    "a"
    "b"
}

@CollectionBuilder
var set: Set<String> {
    "c"
    "d"
}
```

The valid result types of `CollectionBuilder` are `[Element]` and `Set<Element>`. This gives us simple constraints (`[Element] == [String]`, `Set<Element> == Set<String>`) which are trivial to solve: `Element` is inferred to be `String`.

This design supports arbitrarily long lists of generic parameters and arbitrarily complex result types, as long as the generic arguments are unambiguously solvable. In this more complex example, the generic result builder is inferred to be `@DictionaryBuilder<String, Int>`, since that solves `[Key: [Value]] == [String: [Int]]`:

```swift
@resultBuilder
enum DictionaryBuilder<Key: Hashable, Value> {
    static func buildBlock(_ component: (key: Key, value: Value)...) -> [Key: [Value]] {
        // ...
    }
}

@DictionaryBuilder
var dictionary: [String: [Int]] {
    (key: "a", value: 42)
    (key: "b", value: 100)
}
```

Type inference is also supported for non-generic result builders namespaced within generic types. In this example, the result builder is inferred to be `@Array<String>.Builder`:

```swift
extension Array {
    @resultBuilder
    enum Builder {
        static func buildBlock(_ elements: Element...) -> [Element] {
            elements
        }
    }
}

@Array.Builder
var array: [String] {
    "a"
    "b"
}
```

This will be supported in all valid result builder use cases, including function parameters, computed properties, functions results, and struct properties:

```swift
init(@ArrayBuilder arguments: () -> [String]) { ... }

@ArrayBuilder
var arguments: [String] { ... }

@ArrayBuilder
func arguments() -> [String] { ... }

struct SwiftFormatInvocation {
    @ArrayBuilder let arguments: [String]
}
```

## Source compatibility

Inferring result builder generic parameters has no source compatibility impact, since this simply allows code that was previously rejected with an error.

## ABI compatibility

This proposal simply enables new callsite syntax for existing result builder declarations and has no ABI impacts.

## Implications on adoption

This proposal simply enables new callsite syntax for existing declarations and has no adoption implications.

## Future directions

### Add an `@ArrayBuilder` to the standard library

We could eventually add an `@ArrayBuilder` (or similar) to the standard library, or a core package like swift-collections. In the meantime, these ergonomic improvements will be valuable for community-defined generic result builders.

## Alternatives considered

The primary alternative would be to do nothing and preserve the status-quo. However, these ergonomic improvements provide value for codebases using generic result builders, so seem to carry their weight.
