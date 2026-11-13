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

Result builder attributes will be allowed to omit some or all of a generic result builder's generic arguments. The missing generic arguments will be inferred based on the return type of the declaration / parameter.

Inferred generic arguments will be supported in all result builder use cases, including function parameters, computed properties, function results, and struct properties. In all of the below examples, `@ArrayBuilder` is inferred to be `@ArrayBuilder<String>`:

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

### Type Inference Algorithm

Take this result builder call:

```swift
@ArrayBuilder
var arguments: [String] {
    "format"
    "--in-place"
}
```

The general type inference algorithm is that:
 1. We select the eligible `buildBlock` / `buildFinalResult` / `buildPartialBlock` path, following standard result builder priority: `buildFinalResult` if present / valid, `buildPartialBlock` if present / valid, and then `buildBlock`. In this example, the result builder uses `buildBlock`, which returns `[Element]`.
 2. We determine the expected result builder result type from the return type of the attached declaration / parameter. In this example, the result builder's result type is inferred as `[String]`.
 3. Finally, we type check the expression `ArrayBuilder.buildBlock` against the function type `(_) -> [String]`, using standard type checking / overload resolution. This gives us the result that `Element` is inferred to be `String`, and we resolve `@ArrayBuilder` to `@ArrayBuilder<String>`.

If the return type of the declaration / parameter is not an eligible result type of the result builder, it's diagnosted as an error:

```swift
struct SwiftFormatInvocation {
  @ArrayBuilder let arguments: Set<String> // error: unable to infer generic arguments for result builder '@ArrayBuilder'
}
```

If the generic argument is ambiguous (e.g. because there are multiple overloads of `buildFinalResult` that produce different, equally-ranked solutions for the generic arguments), then it's diagnosed as an error `generic arguments for result builder '@ArrayBuilder' are ambiguous`. (This is uncommon in practice.)

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

@CollectionBuilder // Inferred as `@CollectionBuilder<String>`
var array: [String] {
    "a"
    "b"
}

@CollectionBuilder // Inferred as `@CollectionBuilder<String>`
var set: Set<String> {
    "c"
    "d"
}

@CollectionBuilder // Inferred as `@CollectionBuilder<any StringProtocol>`
var array: [any StringProtocol] {
    "format"
    "--in-place".dropFirst(2)
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

@DictionaryBuilder // Inferred as `@DictionaryBuilder<String, [Int]>`
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

@Array.Builder // Inferred as `@Array<String>.Builder`
var array: [String] {
    "a"
    "b"
}
```

Placeholder types:

```swift
@DictionaryBuilder<String, _> // Inferred as `@DictionaryBuilder<String, (a: Int, b: Int, c: Int)>`
var dictionary: [String: (a: Int, b: Int, c: Int)] {
    (key: "a", value: (a: 1, b: 2, c: 3))
}
```

## Source compatibility

Inferring result builder generic arguments has no source compatibility impact, since this simply allows code that was previously rejected with an error.

## ABI compatibility

This proposal simply enables new callsite syntax for existing result builder declarations and has no ABI impacts.

## Implications on adoption

This proposal simply enables new callsite syntax for existing declarations and has no adoption implications.

## Alternatives considered

The primary alternative would be to do nothing and preserve the status-quo. However, these ergonomic improvements provide value for codebases using generic result builders, so seem to carry their weight.
