# `Equatable` and `Hashable` conformances for the span family

* Proposal: [SE-NNNN](NNNN-span-equatable-hashable.md)
* Author: [Clinton Nkwocha](https://github.com/clintonpi)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#NNNNN](#)
* Review: ([pitch](#))

## Summary of changes

Conforms `Span`, `MutableSpan` and `OutputSpan` to `Equatable` and `Hashable` when their `Element` does, and `RawSpan`, `MutableRawSpan` and `OutputRawSpan` unconditionally. Values of these types are considered equal when their elements/bytes are equal (not only when they view the same memory region).

## Motivation

These conformances render the span types more ergonomic and useful in more generic contexts.

## Proposed solution

Add said `Equatable` and `Hashable` conformances.

## Detailed design

```swift
extension Span where Element: Equatable & ~Copyable {
  /// Returns a Boolean value indicating whether two spans contain the same
  /// elements in the same order.
  ///
  /// `==` compares the elements the spans contain, not the memory regions they
  /// view. Two spans over different memory regions are equal when
  /// their elements are equal. To check whether two spans refer to the same
  /// memory region, use `isIdentical(to:)`. Empty spans are equal regardless
  /// of the memory region they refer to:
  ///
  ///     let numbers: [Int] = []
  ///     numbers.span == Span<Int>()                // true
  ///     numbers.span.isIdentical(to: Span<Int>())  // false
  ///
  /// - Complexity: O(*n*), where *n* is the number of elements in the spans.
  public static func ==(lhs: borrowing Self, rhs: borrowing Self) -> Bool
}
```

Identity is sufficient for equality but not vice versa. When two spans refer to the same memory region, `==` returns `true` without comparing their contents. A span is therefore equal to an identical span even when one of its elements isn't equal to itself, such as a floating-point NaN. However, spans of NaN over different memory regions are not equal. This behavior follows precedent in types like `Array`, `ContiguousArray`, etc.

```swift
extension Span where Element: Hashable & ~Copyable {
  /// Hashes the elements of this span by feeding them into the given hasher.
  ///
  /// - Parameter hasher: The hasher to use when combining the elements
  ///   of this span.
  public func hash(into hasher: inout Hasher)
}
```

```swift
extension RawSpan {
  /// Returns a Boolean value indicating whether two raw spans contain the
  /// same bytes in the same order.
  ///
  /// `==` compares the bytes the spans contain, not the memory regions they
  /// view. Two spans over different memory regions are equal when
  /// their bytes are equal. To check whether two spans refer to the same
  /// memory region, use `isIdentical(to:)`. Empty spans are equal regardless
  /// of the memory region they refer to:
  ///
  ///     let numbers: [Int] = []
  ///     numbers.span.bytes == RawSpan()                // true
  ///     numbers.span.bytes.isIdentical(to: RawSpan())  // false
  ///
  /// Comparing bytes is not the same as comparing the values those bytes
  /// represent. For example, the bytes of `0.0` and `-0.0` differ, though
  /// the two values compare as equal. And if the bytes belong to values of a
  /// type whose memory representation includes padding, any internal or
  /// trailing padding takes part in the comparison.
  ///
  /// - Complexity: O(*n*), where *n* is the number of bytes in the spans.
  public static func ==(lhs: borrowing Self, rhs: borrowing Self) -> Bool

  public func hash(into hasher: inout Hasher)
}
```

The other types implement the above conformances similarly. For `OutputSpan` and `OutputRawSpan`, `==` compares only the initialized content. Two `Output(Raw)Span`s with the same initialized content are equal even if their capacities differ. And only the initialized content and its count are hashed; capacity is not.

## Source compatibility

This proposal is additive. However, adding `Equatable` conformances enlarges the set of candidates for `==` and `!=`, which may require splitting up expressions that are already at the limit of type-checker performance.

Code that declares its own `==` or `hash(into:)` for a span type keeps calling its own implementation where it calls them directly. Generic code that reaches them through the standard library's conformances calls the standard library's implementations instead, so a client implementation with different semantics, such as identity, would give different results in the two cases.

Code that declares its own conformance keeps using it while its deployment target predates the standard library's conformances. Once its deployment target includes them, the compiler warns that the conformance was already declared in the standard library and uses the standard library's conformance. Its own `==` and `hash(into:)` then remain in use only for direct calls. Such code should remove its declarations.

## ABI compatibility

The conformances, including their synthesized `hashValue` implementations, are additive ABI in the standard library. `==` and `hash(into:)` are exported into clients and are not new ABI.

## Implications on adoption

The required methods for the conformances are back-deployed as far back as the availability of the span types they operate on, and can run on older Swift runtimes where those types are available. As these conformances would not be declared in the standard library on older runtimes, clients can call `==` and `hash(into:)` directly, or declare the conformances themselves with empty extensions that use these back-deployed implementations. However, adoption requires building with the Swift version in which the methods are introduced or later. `!=` and `hashValue` come from the conformances, so they have the conformances' availability.

## Alternatives considered

### Comparing identity rather than contents

Related types such as `Array`, `InlineArray` and `UniqueArray` compare contents in their `Equatable` conformances, so doing the same for the span types follows the existing pattern and is more intuitive. Comparing identity would also be an issue for empty spans, as which empty spans are equal would depend on how they were created. The spans of two empty arrays are identical because the arrays share storage, but neither is identical to `Span()` or to an empty slice of a non-empty array. `Span` and `RawSpan` provide `isIdentical(to:)` for comparing identity.

Content equality, however, has a cost. The `Equatable` documentation says that "equality implies substitutability", and that "exposing non-value aspects of `Equatable` types other than class identity is discouraged, and any that *are* exposed should be explicitly pointed out in documentation." Two spans that are equal by content can still be told apart by the memory region they view using `isIdentical(to:)`, and the documentation of `==` points this out. Equal spans may also have different lifetimes, but substituting a span with another of shorter lifetime is helpfully rejected at compile time.

## Acknowledgements

Thanks to Guillaume Lessard for working on some of the underlying implementation of these conformances' requirements, and to Steve Canon for insightful discussions on this topic.
