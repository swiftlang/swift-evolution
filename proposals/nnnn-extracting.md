# Expand the `extracting()` slicing pattern to more types

* Proposal: [SE-0485](0485-outputspan.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Pitch**
* Implementation: underscored `_extracting()` members of `Span` and `RawSpan`, pending elsewhere.
* Review: Pending

[SE-0437]: proposals/0437-noncopyable-stdlib-primitives.md
[SE-0447]: proposals/0447-span-access-shared-contiguous-storage.md
[SE-0467]: proposals/0467-MutableSpan.md
[Forum-LifetimeAnnotations]: https://forums.swift.org/t/78638

## Introduction and Motivation

Slicing containers is an important operation, and non-copyable values have introduced a significant change in the spelling of that operation. When we [introduced][SE-0437] non-copyable primitives to the standard library, we allowed slicing `UnsafeBufferPointer` and related types via a family of `extracting()` methods. We expanded upon these when introducing [`MutableSpan`][SE-0467].

Now that we have a [stable spelling][Forum-LifetimeAnnotations] for lifetime dependencies, we propose adding the `extracting()` methods to `Span` and `RawSpan`, as well as members of the `UnsafeBufferPointer` family that were missed in [SE-0437][SE-0437].



## Proposed solution

The family of `extracting()` methods is as follows:
```swift
public func extracting(_ bounds: Range<Index>) -> Self
public func extracting(_ bounds: some RangeExpression<Index>) -> Self
public func extracting(_ UnboundedRange) -> Self
@unsafe public func extracting(unchecked bounds: Range<Index>) -> Self
@unsafe public func extracting(unchecked bounds: ClosedRange<Index>) -> Self

public func extracting(first maxLength: Int) -> Self
public func extracting(droppingLast k: Int) -> Self
public func extracting(last maxLength: Int) -> Self
public func extracting(droppingFirst k: Int) -> Self
```

These should be provided for the following standard library types:
```swift
Span<T>
RawSpan
UnsafeBufferPointer<T>
UnsafeMutableBufferPointer<T>
Slice<UnsafeBufferPointer<T>>
Slice<UnsafeMutableBufferPointer<T>>
UnsafeRawBufferPointer
UnsafeMutableRawBufferPointer
Slice<UnsafeRawBufferPointer>
Slice<UnsafeMutableRawBufferPointer>
```
Some of the types in the list above already have a subset of the `extracting()` functions; their support will be rounded out to the full set.

## Detailed design

The general declarations for these functions is as follows:
```swift
/// Returns an extracted slice over the items within
/// the supplied range of positions.
///
/// Traps if any position within the range is invalid.
@_lifetime(copy self)
public func extracting(_ byteOffsets: Range<Int>) -> Self

/// Returns an extracted slice over the items within
/// the supplied range of positions.
///
/// Traps if any position within the range is invalid.
@_lifetime(copy self)
public func extracting(_ byteOffsets: some RangeExpression<Int>) -> Self

/// Returns an extracted slice over all items of this container.
@_lifetime(copy self)
public func extracting(_ UnboundedRange) -> Self

/// Returns an extracted slice over the items within
/// the supplied range of positions.
///
/// This function does not validate `bounds`; this is an unsafe operation.
@unsafe @_lifetime(copy self)
public func extracting(unchecked bounds: Range<Index>) -> Self

/// Returns an extracted slice over the items within
/// the supplied range of positions.
///
/// This function does not validate `bounds`; this is an unsafe operation.
@unsafe @_lifetime(copy self)
public func extracting(unchecked bounds: ClosedRange<Index>) -> Self

/// Returns an extracted slice over the initial elements
/// of this container, up to the specified maximum length.
@_lifetime(copy self)
public func extracting(first maxLength: Int) -> Self

/// Returns an extracted slice excluding
/// the given number of trailing elements.
@_lifetime(copy self)
public func extracting(droppingLast k: Int) -> Self

/// Returns an extracted slice containing the final elements
/// of this container, up to the given maximum length.
@_lifetime(copy self)
public func extracting(last maxLength: Int) -> Self

/// Returns an extracted slice excluding
/// the given number of initial elements.
@_lifetime(copy self)
public func extracting(droppingFirst k: Int) -> Self
```
For non-escapable types, the `@_lifetime` attribute is ignored as being non-applicable.

## Source compatibility
This proposal is additive and source-copmatible with existing code.

## ABI compatibility
This proposal is additive and ABI-compatible with existing code.

## Implications on adoption
The additions described in this proposal require a new version of the Swift standard library.

## Alternatives considered
This is an extension of an existing pattern. We are not considering a different pattern at this time.

## Future directions
#### Disambiguation over ownership type
The `extracting()` functions proposed here are semantically consuming. `MutableSpan` has versions defined as mutations, but it could benefit from consuming ones as well. In order to do this, we could establish a pattern for disambiguation by name, or we could invent new syntax to disambiguate by ownership type. This is a complex topic left to future proposals.

## Acknowledgements
Thanks to Karoy Lorentey and Tony Parker.

