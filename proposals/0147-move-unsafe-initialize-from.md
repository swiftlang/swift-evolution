# Move UnsafeMutablePointer.initialize(from:) to UnsafeMutableBufferPointer

* Proposal: [SE-0147](0147-move-unsafe-initialize-from.md)
* Author: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3.1)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170102/029945.html)
* Implementation: [apple/swift#6601](https://github.com/apple/swift/pull/6601)

## Introduction

The version of `UnsafeMutablePointer.initialize(from:)` that takes a `Collection` should be deprecated in favor of a new method on `UnsafeMutableBufferPointer` that takes a `Sequence`, with a goal of improving memory safety and enabling faster initialization of memory from sequences. Similarly, `UnsafeMutableRawPointer.initializeMemory(as:from:)` should be deprecated in favor of a new `UnsafeMutableRawBufferPointer.initialize(as:from:)`.

## Motivation

`UnsafeMutablePointer.initialize(from:)` underpins implementations of collections, such as `Array`, which are backed by a buffer of contiguous memory. When operations like `Array.append` are implemented, they first ensure their backing store can accommodate the number of elements in a source collection, then pass that collection into the `initialize` method of their backing store.

Unfortunately there is a major flaw in this design: a collection's `count` might not accurately reflect the number of elements returned by its iterator. For example, some collections can be misused to return different results on each pass. Or a collection could just be implemented incorrectly.

If the collection's `count` ends up being lower than the actual number of elements yielded by its iterator, the caller may not allocate enough memory for them. Since `UnsafeMutablePointer.initialize(from:)` does not receive a limiting capacity, this method would then scribble past the end of the buffer, resulting in undefined behavior.

Normally when using `Unsafe...` constructs in Swift the burden of ensuring safety falls on the caller. When using this method with something known to have correct behavior, like an `Array`, you can do that. But when used in a generic context like `Array.append(contentsOf:)`, where the caller of `initialize` does not know exactly what kind of collection they are passing in, it is impossible to use this method safely. You can see the impact of this by running the following code. which exhibits memory-unsafe behavior despite only using “safe” constructs from the standard library, something that shouldn’t be possible:

```swift
var i = 0
let c = repeatElement(42, count: 10_000).lazy.filter { _ in 
	// capture i and use it to exhibit inconsistent
	// behavior across iteration of c
	i += 1; return i > 10_000 
}
var a: [Int] = []
// a will allocate insufficient memory before
// calling self._buffer.initialize(from: c)
a.append(contentsOf: c) // memory access violation
```

While a collection returning an inconsistent count is a programming error (in this case, use of the lazy filter in combination with an logically impure function, breaking value semantics), and it would be reasonable for the standard library to trap under these circumstances, undefined behavior like this is not OK.

In addition, the requirement to pre-allocate enough memory to accommodate `from.count` elements rules out using this method to initialize memory from a sequence, since sequences don't have a `count` property (they have an `underestimatedCount` but this isn't enough since underestimated counts are exactly the problem described above). The proposed solution would allow for this, enabling some internal performance optimizations for generic code.

## Proposed solution

The existing `initialize` method should be altered to receive a capacity, to avoid running beyond what the caller has allocated. Since `UnsafeMutableBufferPointer` already exists to encapsulate "pointer plus a count", the method should be moved to that type and the old method deprecated.

This new method should take a `Sequence` as its `from` argument, and handle possible element overflow, returning an `Iterator` of any elements not written due to a lack of space. It should also return an index into the buffer to indicate where the elements were written up to in cases of underflow.

Once this has been done, the version of `Array.append(contentsOf:)` that takes a collection can be eliminated, since the performance benefits of the collection version could be incorporated into the implementation of the one that takes a sequence.

The intention of this change is to add memory safety, not to allow the flexibility of collections giving inconsistent counts. Therefore the precondition should remain that the caller should ensure enough memory is allocated to accommodate `source.underestedCount` elements. The only difference is if they don’t, the behaviour should be well-defined (ideally by trapping, if this can be done efficiently). 

Therefore:

- Under-allocating the destination buffer relative to `underestimatedCount` may trap at runtime. _May_ rather than _will_ because this is an `O(n)` operation on some collections, so may only be enforced in debug builds.
- Over-allocating the destination buffer relative to `underestimatedCount` is valid and simply results in sequence underflow with potentially uninitialized buffer memory (a likely case with arrays that reserve more than they need).
- The source sequence's actual count may exceed both `underestimatedCount` and the destination buffer size, resulting in sequence overflow. This is also valid and handled by returning an iterator to the uncopied elements as an overflow sequence.

A matching change should also be made to `UnsafeRawBufferPointer.initializeMemory(from:)`. The one difference is that for convenience this should return an `UnsafeMutableBufferPointer` of the (typed) intialized elements instead of an index into the raw buffer.

## Detailed design

The following API changes would be made:

```swift
extension UnsafeMutablePointer {
  @available(*, deprecated, message: "it will be removed in Swift 4.0.  Please use 'UnsafeMutableBufferPointer.initialize(from:)' instead")
  public func initialize<C : Collection>(from source: C)
      where C.Iterator.Element == Pointee 
}

extension UnsafeMutableBufferPointer {
  /// Initializes memory in the buffer with the elements of `source`.
  /// Returns an iterator to any elements of `source` that didn't fit in the 
  /// buffer, and an index to the point in the buffer one past the last element
  /// written (so `startIndex` if no elements written, `endIndex` if the buffer 
  /// was completely filled).
  ///
  /// - Precondition: The memory in `self` is uninitialized. The buffer must contain
  ///   sufficient uninitialized memory to accommodate `source.underestimatedCount`.
  ///
  /// - Postcondition: The returned iterator
  /// - Postcondition: The `Pointee`s at `self[startIndex..<initializedUpTo]` 
  ///   are initialized.
  @discardableResult
  public func initialize<S: Sequence>(
    from source: S
  ) -> (unwritten: S.Iterator, initializedUpTo: Index)
    where S.Iterator.Element == Iterator.Element
}
 
extension UnsafeMutableRawPointer {
  @available(*, deprecated, message: "it will be removed in Swift 4.0.  Please use 'UnsafeMutableRawBufferPointer.initialize(from:)' instead")
  @discardableResult
  public func initializeMemory<C : Collection>(
   as: C.Iterator.Element.Type, from source: C
  ) -> UnsafeMutablePointer<C.Iterator.Element>
}

extension UnsafeMutableRawBufferPointer {
  /// Initializes memory in the buffer with the elements of
  /// `source` and binds the initialized memory to type `T`.
  ///
  /// Returns an iterator to any elements of `source` that didn't fit in the 
  /// buffer, and an index into the buffer one past the last byte written.
  ///
  /// - Precondition: The memory in `self` is uninitialized or initialized to a
  ///   trivial type.
  ///
  /// - Precondition: The buffer must contain sufficient memory to
  ///   accommodate at least `source.underestimatedCount` elements.
  ///
  /// - Postcondition: The memory at `self[startIndex..<initialized.count *
  ///   MemoryLayout<S.Iterator.Element>.stride] is bound to type `S.Iterator`.
  ///
  /// - Postcondition: The memory at `self[startIndex..<initialized.count *
  ///   MemoryLayout<S.Iterator.Element>.stride] are initialized..
  @discardableResult
  public func initializeMemory<S: Sequence>(
     as: S.Iterator.Element.Type, from source: S
  ) -> (unwritten: S.Iterator, initialized: UnsafeMutableBufferPointer<S.Iterator.Element>)
}

```

The `+=` operators and `append<C : Collection>(contentsOf newElements: C)` methods on `Array`, `ArraySlice` and `ContiguousArray` will be removed as no-longer needed, since the implementation that takes a sequence can be made to be as efficient. The `+=` can be replaced by a generic one that calls `RangeReplaceableCollection.append(contenstsOf:)`:

(note, because it forwards on to a protocol requirement, it itself does not need to be a static operator protocol requirement)

```swift
/// Appends the elements of a sequence to a range-replaceable collection.
///
/// Use this operator to append the elements of a sequence to the end of
/// range-replaceable collection with same `Element` type. This example
/// appends the elements of a `Range<Int>` instance to an array of
/// integers.
///
///     var numbers = [1, 2, 3, 4, 5]
///     numbers += 10...15
///     print(numbers)
///     // Prints "[1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15]"
///
/// - Parameters:
///   - lhs: The array to append to.
///   - rhs: A collection or finite sequence.
///
/// - Complexity: O(*n*), where *n* is the length of the resulting array.
public func += <
  R : RangeReplaceableCollection, S : Sequence
>(lhs: inout R, rhs: S) 
 where R.Iterator.Element == S.Iterator.Element
```
 
## Source compatibility

The addition of the new method does not affect source compatibility. The deprecation of the old method does, but since this is a fundamentally unsound operation that cannot be fixed except via a source-breaking change, it should be aggressively deprecated and then removed.

The knock-on ability to remove the version of `Array.append(contentsOf:)` that takes a collection does not affect source compatibility since the version for sequences will be called for collections instead.

## Effect on ABI stability

This change must be made prior to declaring ABI stability, since it is currently called from the `Array.append` method, which is inlineable.

## Alternatives considered

Overflow (elements remain on the returned iterator) and underflow (`initializedUpTo != endIndex`) are almost but not quite mutually exclusive – if the buffer is exactly used, the caller must call `.next()` to check for any unwritten elements, which means the returned value must be declared `var`, and the check can't be chained. This is a little ugly, but is the unavoidable consequence of how iterators work: since iterating is consuming, the `initialize` method cannot easily test for this and indicate it back to the caller in some other way (such as returning an optional iterator).

