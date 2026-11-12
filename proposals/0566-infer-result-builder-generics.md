# Infer generic arguments of result builder attributes

* Proposal: [SE-0566](0566-infer-result-builder-generics.md)
* Authors: [Cal Stephens](https://github.com/calda)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Active review (November 12–26, 2026)**
* Implementation: [#86209](https://github.com/swiftlang/swift/pull/86209)
* Review: ([pitch](https://forums.swift.org/t/pitch-infer-generic-arguments-of-result-builder-attributes/85272)) ([review](https://forums.swift.org/t/se-0566-infer-generic-arguments-of-result-builder-attributes/90702))

## Summary of changes

We should enable generic result builders to be used as attributes without needing to explicitly specify generic arguments, instead allowing them to be inferred.

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

We should improve the ergonomics of generic result builders by allowing generic arguments to be inferred.

This allows us to omit the generic arguments in all of these examples, simplifying the code:

```swift
struct SwiftFormatInvocation {
    @ArrayBuilder let arguments: [String]
}
```

```swift
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
extension Array {
    init(@ArrayBuilder _ build: () -> Self) {
        self = build()
    }
}
```

## Detailed design

Result builder attributes will be allowed to omit some or all of a generic result builder's generic arguments, either by leaving them out entirely (`@ArrayBuilder`) or by using placeholder types (e.g. `@DictionaryBuilder<String, _>`). The missing generic arguments are then inferred by the existing result builder transform, as part of type-checking the transformed body.

Take this result builder call:

```swift
@ArrayBuilder<String>
var arguments: [String] {
    "format"
    "--in-place"
}
```

Today, its result builder transform approximately expands to:

```swift
var arguments: [String] {
    let v0 = "format"
    let v1 = "--in-place"
    return ArrayBuilder<String>.buildBlock(v0, v1)
}
```

When omitting the generic type arguments:

```swift
@ArrayBuilder
var arguments: [String] {
    "format"
    "--in-place"
}
```

the result builder transform simply uses the type as written in the result builder attribute:

```swift
var arguments: [String] {
    let v0 = "format"
    let v1 = "--in-place"
    return ArrayBuilder.buildBlock(v0, v1)
}
```

The compiler will then type-check the resulting transformed code as usual, and will resolve the implicit generic arguments following standard type inference. This simple approach naturally scales to all result builder capabilities, including `buildBlock`, `buildPartialBlock`, and `buildFinalResult` use cases, as well as complex scenarios that require overload resolution.

Inferred generic arguments will be supported in all result builder use cases, including function parameters, computed properties, function results, and struct properties:

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

In cases with no attached body (function parameters, struct properties), the result builder type is specialized for each individual call site, each of which has its own separate result builder transform.

On potential impacts to type checking performance: Within the result builder transform output, all instances of the result builder type's unresolved generic arguments share the same type variables. Specifically, the result builder transform emits a single `$__builderSelf` variable whose type is solved once and then used in every call to the result builder. In addition to keeping the extra type checking work small and independent of the number of result builder calls, this prevents the result builder type from potentially resolving to different generic arguments within the same result builder transform.

### More Examples

Multiple potential result types:

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

// Valid use cases include:

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

More complex generic parameters:

```swift
@resultBuilder
enum DictionaryBuilder<Key: Hashable, Value> {
    static func buildBlock(_ component: (key: Key, value: Value)...) -> [Key: [Value]] {
        // ...
    }
}

// Valid use cases include:

@DictionaryBuilder
var dictionary: [String: [Int]] {
    (key: "a", value: 42)
    (key: "b", value: 100)
}
```

Non-generic result builders nested in generic types:

```swift
extension Array {
    @resultBuilder
    enum Builder {
        static func buildBlock(_ elements: Element...) -> [Element] {
            elements
        }
    }
}

// Valid use cases include:

@Array.Builder
var array: [String] {
    "a"
    "b"
}
```

Placeholder types:

```swift
@DictionaryBuilder<String, _>
var dictionary: [String: (a: Int, b: Int, c: Int)] {
    (key: "a", value: (a: 1, b: 2, c: 3))
}
```

## Source compatibility

Inferring result builder generic arguments has no source compatibility impact, since this simply allows code that was previously rejected with an error.

## ABI compatibility

This proposal simply enables new callsite syntax for existing result builder declarations and has no ABI impacts.

## Implications on adoption

Since the generic arguments of a result builder attribute are inferred when the result builder transform is applied, they aren't part of the declaration itself. `.swiftinterface` files for libraries using inferred generic result builders will contain the attribute as written, with its generic arguments omitted. Consumers of these libraries would need to be using a compiler version that supports this feature.

## Alternatives considered

The primary alternative would be to do nothing and preserve the status-quo. However, these ergonomic improvements provide value for codebases using generic result builders, so seem to carry their weight.
