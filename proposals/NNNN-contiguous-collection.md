# Introduce `{Mutable}ContiguousCollection` protocol

* Proposal: [SE-NNNN](NNNN-contiguous-collection.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Previous Proposal: [SE-0237](0237-contiguous-collection.md)

## Introduction

This proposal introduces two new protocols: `ContiguousCollection`, which
refines `Collection`, and `MutableContiguousCollection`, which refines
`MutableCollection`. Both provide guaranteed access to an underlying
unsafe buffer.

## Motivation

[SE-0237](https://github.com/apple/swift-evolution/blob/master/proposals/0237-contiguous-collection.md) 
introduced two new methods, `withContiguous{Mutable}StorageIfAvailable`, to
allow generic algorithms to test for and use an underlying unsafe buffer when
it is available. This has significant performance benefit for certain
algorithms, such as `sort`, which can achieve big speedups when they
have access to the unsafe buffer, but can still operate without that fast path
if needed.

There is another class of operation that _only_ wants to be available when
there is a fast path. A good example would be a Swift-friendly wrapper for
the `vDSP` suite of algorithms. 

For example, you might want to write a convenient wrapper for `vDSP_vadd`.

```swift 
// note this is **not** a proposal about vDSP wrappers, this is just a
// simplified example :)
func dspAdd<A: Collection, B: Collection>(
  _ a: A, _ b: B, _ result: inout [Float]
) where A.Element == Float, B.Element == Float {
  let n = a.count
  // try accessing contiguous underlying buffers:
  let wasContiguous: ()?? =
    a.withContiguousStorageIfAvailable { abuf in
      b.withContiguousStorageIfAvailable { bbuf in
        vDSP_vadd(abuf.baseAddress!, 1, bbuf.baseAddress!, 1, &result, 1, UInt(n))
      }
  }
  // if they weren't contiguous, create two arrays try again
  if wasContiguous == nil || wasContiguous! == nil {
    dspAdd(Array(a), Array(b), &result)
  }
}
```

This follows a similar pattern to `sort`: provide a fast path when available,
but fall back to a slower path when it isn't.

But in the case of functions like `vDSP_vsaddi` this is very much the wrong
thing to do. These functions often operate on a thin (but very material)
performance edge over their open-coded equivalent, and allocating and
initializing two arrays purely to be able to call it would probably vastly
outweigh the speed benefits gained by using the function instead of a regular
loop. This encourages misuse by the caller, who might not realize they are
getting worse performance than if they reorganized their code.

Trapping on non-contiguous inputs would flag the problem more clearly to the
user. In the case of the "return" buffer argument, if we wanted to make that
generic, trapping is the only option as we cannot just convert that type to an
array and rerun. But ideally we would use Swift's type system to enforce this
instead, guiding the user to a better solution.

## Proposed solution

Introduce two new protocols which guarantee access to a contiguous underlying
buffer.

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

Conforming to to `ContiguousCollection` should also provide types with a default
implementation of `Collection.withContiguousStorageIfAvailable`, via an extension 
that calls `withUnsafeBufferPointer`. Same for `MutableContiguousCollection` and
`Collection.withMutableContiguousStorageIfAvailable`.

## Detailed design

The introduction of these protocols allows an appropriate constraint that would
prevent a user passing a `Range` or `Repeating` collection into our `dspAdd`
function. It also allows an easy path to a generic result buffer instead of a
concrete array; this is important as often these functions are used in a tiled
mode where you would want to repeatedly pass in an array slice. As a nice
side-benefit, it also cleans up the function implementation:

```swift
func dspAdd<A: ContiguousCollection, B: ContiguousCollection, R: MutableContiguousCollection>(
  _ a: A, _ b: B, _ result: inout R
) where A.Element == Float, B.Element == Float, R.Element == Float {
  let n = a.count
  a.withUnsafeBufferPointer { abuf in
    b.withUnsafeBufferPointer { bbuf in
      result.withUnsafeMutableBufferPointer { rbuf in
        vDSP_vadd(abuf.baseAddress!, 1, bbuf.baseAddress!, 1, rbuf.baseAddress!, 1, UInt(n))
      }
    }
  }
}
```

## Source compatibility

These are additive changes and do not affect source compatibility.

## Effect on ABI stability

These are additive changes of new protocols and so can be introduced in an
ABI-stable way. On platforms that have declared ABI stability, they will need
to have availability annotations.

## Effect on API resilience

N/A

## Alternatives considered

This is a re-pitch of these protocols. They originally appeared in SE-0237, but were
deferred pending further use cases. This proposal is motivated by such cases.

