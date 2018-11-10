# Introduce Contiguous Collection Protocols

* Proposal: [SE-NNNN](NNNN-contiguous-collection.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#20484](https://github.com/apple/swift/pull/20484)

## Introduction

This proposal introduces two new protocols, `ContiguousCollection`, and a
mutable version `MutableContiguousCollection`. These protocols will allow
generic code to make use of the `withUnsafe{Mutable}BufferPointer` idiom,
as well as provide fast paths in the standard library for adopting types.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Almost every feature of `Array` is made available via one of the protocols
in the standard library, and so most code written against `Array` can be
rewritten generically as an extension of one or more protocols.

The exceptions to this are the operations `withUnsafeBufferPointer` and
`withUnsafeMutableBufferPointer`, which are only available on the concrete
types. Given the usefulness of these methods, they should also be made
available generically.

## Proposed solution

Introduce two new protocols, with requirements representing the with-unsafe capabilities of `Array` & co:

```swift
/// A collection that supports access to its underlying contiguous storage.
public protocol ContiguousCollection: Collection
where SubSequence: ContiguousCollection {
  /// Calls a closure with a pointer to the array's contiguous storage.
  func withUnsafeBufferPointer<R>(
    _ body: (UnsafeBufferPointer<Element>) throws -> R
  ) rethrows -> R
}

/// A collection that supports mutable access to its underlying contiguous
/// storage.
public protocol MutableContiguousCollection: ContiguousCollection, MutableCollection
where SubSequence: MutableContiguousCollection {
  /// Calls the given closure with a pointer to the array's mutable contiguous
  /// storage.
  mutating func withUnsafeMutableBufferPointer<R>(
    _ body: (inout UnsafeMutableBufferPointer<Element>) throws -> R
  ) rethrows -> R
}
```

Conformances will be added for the following types:
- `Array`, `ArraySlice` and `ContiguousArray` will conform to `MutableContiguousCollection`
- `UnsafeBufferPointer` will conform to `ContiguousCollection`
- `UnsafeMutableBufferPointer` will conform to `MutableContiguousCollection`
- `Slice` will conditionally conform:
    - to `ContiguousCollection where Base: ContiguousCollection`
    - to `MutableContiguousCollection where Base: MutableContiguousCollection`

In addition, the following customization point should be added to
`MutableCollection`, with a default implementation when the collection is
mutably contiguously stored:

```swift
protocol MutableCollection {
  /// Call `body(p)`, where `p` is a pointer to the collection's
  /// mutable contiguous storage.  If no such storage exists, it is
  /// first created.  If the collection does not support an internal
  /// representation in a form of mutable contiguous storage, `body` is not
  /// called and `nil` is returned.
  public mutating func withUnsafeMutableBufferPointerIfSupported<R>(
    _ body: (inout UnsafeMutableBufferPointer<Element>) throws -> R
  ) rethrows -> R?
}
```

This customization point already exists with an underscore in the standard
library (it just returns `nil` by default), and should be exposed to
general users, with a default implementation when the collection 
conforms to `MutableContiguousCollection`.

Use of this entry point can provide significant speedups in some
algorithms, e.g. our current
[`sort`](https://github.com/apple/swift/blob/6662ccc16dba27418eefd3cb7856bddda5a33386/stdlib/public/core/Sort.swift#L249)
which needs to move elements of a collection back and forth between
some storage.

## Source compatibility

These are additive changes and do not affect source compatibility.

## Effect on ABI stability

These are additive changes and do not affect ABI stability.

## Alternatives considered

Some collections are not fully contiguous, but instead consist of multiple contiguous 
regions (for example, a ring buffer is two separate contiguous regions). A protocol that
exposed a collection of contiguous regions could be implemented on top of this protocol.
