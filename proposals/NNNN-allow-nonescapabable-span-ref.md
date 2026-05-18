# Allow Nonescapable Elements in `Span` and `Ref`

* Proposal: SE-NNNN
* Authors: [Nate Cook](https://github.com/natecook1000), [Andrew Trick](https://github.com/atrick), [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: [swiftlang/swift#89213](https://github.com/swiftlang/swift/pull/89213) and [swiftlang/swift#88990](https://github.com/swiftlang/swift/pull/88990)
* Related Proposals:
  * [SE-0446]: Nonescapable Types
  * [SE-0447]: `Span`: Safe Access to Contiguous Storage
  * [SE-0465]: Nonescapable Standard Library Primitives
  * [SE-0519]: `Ref` and `MutableRef` Types

## Introduction

This proposal generalizes the `Span` and `Ref` types to allow nonescapable elements, with the lifetime of an element copied from the lifetime of the containing type.

## Motivation

Swift's ownership work has introduced a set of composable primitives for writing APIs that express borrowing directly. `Span` provides a safe, non-owning view over contiguous storage, while `Ref` provides a read-only borrow of a single value. Both types are themselves nonescapable, with their lifetimes generally dependent on a borrow of their source value.

However, the current requirement that the instances referenced by a `Span` or `Ref` be `Escapable` limits what should be natural compositions and expressions of lifetimes. For example, the `Iterable` protocol proposed in [SE-0516] allows for `~Escapable` sequences, but the `Escapable` requirement for `Ref` makes it impossible to safely create a sequence of `~Escapable` sequences.

This limitation becomes more significant as the standard library and user libraries continue to adopt nonescapable APIs. `Optional` and `Result` have already been generalized to support nonescapable payloads. `Span` and `Ref` are likewise fundamental building blocks, and restricting them to escapable elements limits the flexibility of the available tools for managing ownership.

## Proposed solution

To allow this flexibility, we should update the `Span` and `Ref` types so that their `Element` and `Wrapped` types, respectively, may be nonescapable. When accessing a nonescapable element, the lifetime of the element will be copied from the `Span` or `Ref` instance.

The following example demonstrates the copied lifetime of a nonescapable value (a `Span`) retrieved from a `Ref`:

```swift
let array = [1, 2, 3, 4]

// This span has a borrowed lifetime from 'array'
let span = array.span

// This reference has borrowed lifetime from 'span'
let spanRef = Ref(borrowing: span)

// Getting the span back out of 'spanRef' copies the lifetime
let reborrowedSpan = spanRef.value

// 'reborrowedSpan's lifetime depends on 'span', not 'spanRef'
_ = consume spanRef

print(reborrowedSpan.count) // OK

// 'reborrowedSpan's lifetime ends with 'span'
_ = consume span

print(reborrowedSpan.count) // error: ...
```

## Detailed design

For both `Span` and `Ref`, the declaration sites add the `~Escapable` generalization to the primary associated types, and to all applicable extensions. Because the `UnsafePointer` types have not yet had their `Pointee` types generalized to allow nonescapable types, APIs that provide pointer access to a `Span`'s contents will continue to be limited to `Escapable` elements.

### Element lifetimes

The subscript and projection APIs on `Span` and `Ref` assign the same lifetime to the accessed element as the `Span` or `Ref` itself by using the `@_lifetime(copy: self)` attribute.

These extensions show the new lifetime annotations on the existing APIs for accessing elements:

```
extension Span where Element: ~Copyable & ~Escapable {
  public subscript(_ position: Index) -> Element {
    @_lifetime(copy self)
    borrow { ... }
  }
  
  @unsafe
  public subscript(unchecked position: Index) -> Element {
    @_lifetime(copy self)
    borrow { ... }
  }
}

extension Span where Element: BitwiseCopyable & ~Escapable {
  public subscript(_ position: Index) -> Element {
    @_lifetime(copy self)
    get { ... }
  }

  @unsafe
  public subscript(unchecked position: Index) -> Element {
    @_lifetime(copy self)
    get { ... }
  }
}

extension Ref where Value: ~Copyable & ~Escapable {
  public var value: Value {
    @_lifetime(copy self)
    borrow { ... }
  }
}
```

### `RawSpan` changes

In order to allow the `RawSpan`-providing `bytes` property on `Span`, the `RawSpan(unsafeElements:)` initializer, for converting a `Span` into a `RawSpan`, is generalized to allow spans of `~Escapable` elements.

## Source compatibility

The changes to both types are source compatible. Existing code that references `Span` will continue to implicitly require an `Escapable` element type until revised with an `Element: ~Escapable` constraint.

## ABI compatibility

The change to the `Span` type is ABI compatible, primarily because the entirety of `Span`'s API is declared with the `@_alwaysEmitIntoClient`. The only parts of the `Span` type that are present in the ABI are the getters for the `@usableFromInline` properties `_count` and `_pointer`. The ABI for these property getters is maintained through the use of a new version of the `@_preInverseGenerics` attribute, which allows the naming of specific inverse generics to keep in the ABI while omitting any new generalizations.

```swift
struct Span<Element: ~Copyable & ~Escapable>: ... {
   @_preInverseGenerics(except: ~Copyable)
   @usableFromInline
   internal var _count: Int
   
   // ...
}
```

The `Ref` type is a new addition in Swift 6.4, so ABI compatibility concerns do not apply.


## Future directions

### Nonescapable elements in a `MutableSpan`, `OutputSpan`, and other `Span` types, or in `MutableRef`

Support for `~Escapable` elements in mutable nonescapable containers is out of scope for this proposal.


[SE-0446]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[SE-0465]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0465-nonescapable-stdlib-primitives.md
[SE-0516]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md
[SE-0519]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md
