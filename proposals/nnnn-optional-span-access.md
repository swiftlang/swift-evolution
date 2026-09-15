# Span-based access to `Optional`'s storage

* Proposal: [SE-NNNN](nnnn-optional-span-access.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#88153](https://github.com/swiftlang/swift/pull/88153)
* Review: ([pitch](https://forums.swift.org/t/89580))

[SE-0456]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md
[SE-0467]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md
[SE-0516]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md
[SE-0527]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md
[SE-0532]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0532-optional-noncopyable-improvements.md

## Summary of changes

Adds `span` and `mutableSpan` computed properties to `Optional`. They provide in-place access to the wrapped value as a one-element `Span` or `MutableSpan`, or as an empty span when there is no wrapped value. Also adds an `edit` function that provides access to the storage through the `OutputSpan` parameter of a closure, allowing a wrapped value to be added, replaced or removed.

## Motivation

We would like to extend `Optional` so that it can vend its storage to API that expects to receive a `Span` value, without requiring the programmer to explicitly deal with both cases of the `Optional`.

```swift
var array: UniqueArray<Person> = ...
let someone: Optional<Person> = ...
// currently required:
if let someone {
  array.append(someone)
}
// with the proposed API:
array.append(copying: someone.span)
```

## Proposed solution

An `Optional<Wrapped>` is, in storage terms, something that holds either zero or one instance of `Wrapped`. We have previously established the `span` and `mutableSpan` properties for containers to vend safe access to the storage they own ([SE-0456][SE-0456], [SE-0467][SE-0467]), and therefore we propose to add those same properties to `Optional`.

The `span` and `mutableSpan` properties will provide enhanced ergonomics when using noncopyable types, alongside the `ref` and `mutableRef` properties ([SE-0532][SE-0532]). The span properties will serve use cases where existing code is written in terms of contiguous storage, and the empty case doesn't require special handling.

The `span` property will allow the implementation of `BorrowingIteratorAdapter` ([SE-0516][SE-0516]) to be expressed entirely in terms of public API, rather than the internal helper it relies on today.

`Span` and `MutableSpan` can view an existing wrapped value, but neither can add or remove one. An operation that inspects the current wrapped value and dynamically decides whether to keep, remove or replace it, is complicated to write for noncopyable values. `UniqueArray` ([SE-0527][SE-0527]) calls that operation `edit`, and it vends an `OutputSpan` over its whole capacity. `edit`'s closure can inspect, add and remove elements during an exclusive access. We propose adding the `edit` function, vending `Optional`'s storage via an `OutputSpan` with a capacity of one.

## Detailed design

```swift
extension Optional where Wrapped: ~Copyable & Escapable {
  /// A span over the wrapped value of this instance.
  ///
  /// The span contains a single element when this instance has a wrapped
  /// value, and is empty when this instance is `nil`.
  ///
  /// - Complexity: O(1)
  var span: Span<Wrapped> {
    @_lifetime(borrow self) borrowing get
  }

  /// A mutable span over the wrapped value of this instance.
  ///
  /// The span contains a single element when this instance has a wrapped
  /// value, and is empty when this instance is `nil`.
  ///
  /// - Complexity: O(1)
  var mutableSpan: MutableSpan<Wrapped> {
    @_lifetime(&self) mutating get
  }

  /// Edit this instance through a closure with an output span over its storage.
  ///
  /// This method calls its function argument exactly once, allowing it to
  /// change or remove the wrapped value, or to supply one if this instance
  /// is `nil`. The span it is given has a capacity of one, and initially holds
  /// one element if this instance has a wrapped value, or none if it is `nil`.
  /// The argument is free to remove or add an item; however, it is not
  /// allowed to replace the span or change its capacity. Appending more than
  /// one item is a runtime error.
  ///
  /// When the function argument finishes (whether by returning or throwing an
  /// error) this instance is updated to match the final contents of the output
  /// span: it becomes `nil` if the span was left empty, and it wraps the item
  /// the span holds otherwise.
  ///
  ///     var number: Int? = nil
  ///
  ///     number.edit { n in
  ///       if n.isEmpty { n.append(6) }
  ///     }
  ///     print(number)
  ///     // Prints "Optional(6)"
  ///
  ///     number.edit { n in
  ///       n.removeAll()
  ///     }
  ///     print(number)
  ///     // Prints "nil"
  ///
  /// - Parameter body: A function that edits the wrapped value of this
  ///   instance through an `OutputSpan` argument. This method invokes this
  ///   function exactly once.
  /// - Returns: This method returns the result of its function argument.
  /// - Complexity: Adds O(1) overhead to the complexity of the function
  ///   argument.
  mutating func edit<E: Error, R: ~Copyable>(
    _ body: (inout OutputSpan<Wrapped>) throws(E) -> R
  ) throws(E) -> R
}
```

These additions are restricted to `Wrapped: Escapable` because `Span`, `MutableSpan` and `OutputSpan` cannot support nonescapable elements at this time.

## Source compatibility

This proposal is additive and source compatible.

## ABI compatibility

This proposal adds to the standard library, and can be implemented without adding to its ABI.

## Implications on adoption

The `span` and `mutableSpan` properties and the `edit` function are new standard library API. At compile time, the standard library used by the compiler must define them. On ABI-stable platforms, they have the same effective availability as the existing `Span`, `MutableSpan` and `OutputSpan` types.

## Future directions

#### A general one-element `Span` initializer

An initializer forming a one-element span over an arbitrary addressable value would generalize part of what the `span` and `mutableSpan` properties do, and would be complementary to this proposal.

## Alternatives considered

#### Returning `Span<Wrapped>?`

The properties could return an optional span, which would be `nil` when the `Optional` is `nil`. We believe that `Span.isEmpty` is enough to signify absence of a value, and that in this context optionality would add no information. The `ref` and `mutableRef` properties can be used when a returned `Optional` is needed or preferred.
