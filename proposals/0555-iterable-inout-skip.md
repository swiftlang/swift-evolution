# `inout` overload of `BorrowingIteratorProtocol.skip(by:)`

* Proposal: [SE-0555](0555-iterable-inout-skip.md)
* Authors: [Nate Cook](https://github.com/natecook1000)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Active review (October 9–23, 2026)**
* Implementation: [swiftlang/swift#92109](https://github.com/swiftlang/swift/pull/92109)
* Review: [(pitch)](https://forums.swift.org/t/pitch-amend-iterable-proposal-with-additional-skip-by/89521)

## Summary of changes

Adds a new overload of the `BorrowingIteratorProtocol.skip(by:)` method that takes its argument as an `inout Int`. Unlike the existing method, which reports a count only when it returns normally, the new overload tells the caller how many elements are still to be skipped even when the iterator throws an error.

## Motivation

While iteration of types conforming to the new `Iterable` protocol is typically done using a `for`-`in` construct, manual iteration enables finer control over the chunks of elements to fetch or skip over. The existing [`BorrowingIteratorProtocol.skip(by:)`](https://docs.swift.org/latest/documentation/swift/borrowingiteratorprotocol/skip(by:)/) method advances through an iterator's elements and returns the number of elements that were actually skipped to the caller. However, if the iterator throws an error instead of returning normally, that number of skipped elements is lost.

```swift
var iterator = myIterable.makeBorrowingIterator()

// existing version
do {
    let skipCount = try iterator.skip(by: 5)
    if skipCount == 5 { 
        print("skipped 5 elements")
    } else {
        print("reached end of iterator")
    }
} catch {
    // no access to `skipCount`
}
```

## Proposed solution

In cases where the caller _needs_ information about how many elements were skipped, we'd like to add a `skip(by:)` overload that passes the offset parameter as an `inout Int`. The parameter is updated to the number of elements yet to be skipped after calling, whether the method returns normally or throws.

```swift
var iterator = myIterable.makeBorrowingIterator()

// new version
var toSkip = 5
do {
    try iterator.skip(by: &toSkip)
    if toSkip == 0 {
        print("skipped 5 elements")
    } else {
        print("reached end of iterator")
    }
} catch {
    print("threw an error, still to skip: \(toSkip)")
}
```

Not every borrowing iterator has behavior that makes this value useful, since `BorrowingIteratorProtocol` makes no requirements for post-throw iterator behavior. However, for iterators that *do* specify their post-throw behavior, this overload is an important building block for future algorithms.

For example, if `MyConcreteIterator` has been designed such that it is safe to resume work with an iterator immediately after an error has been produced, a `nextElement(afterSkipping:retryCount:)` method could be written like this:

```swift
extension MyConcreteIterator {
    func nextElement(afterSkipping n: Int, retryCount: Int = 0) throws -> Span<Element> {
        var retryCount = retryCount
        var toSkip = n
        while toSkip > 0 {
            do {
                try skip(by: &toSkip)
                guard toSkip == 0 else {
                    return Span()
                }
            } catch {
                if retryCount > 0 {
                    retryCount -= 1
                    continue
                }
                throw error
            }
        }
        return nextSpan(maxCount: 1)
    }
}
```

Each call to `skip(by:)` decrements `toSkip` by the number of elements actually skipped, allowing attempted continuation of the operation after an error is thrown.

## Detailed design

The `BorrowingIteratorProtocol` declaration will be modified to include the second `skip(by:)` overload:

```swift
@available(SwiftStdlib 6.4, *)
public protocol BorrowingIteratorProtocol<Element, Failure>: ~Copyable, ~Escapable {
  // Other existing declarations...
  
  /// Advances the position of this iterator by the specified offset, or until
  /// the end of the underlying type's elements.
  ///
  /// - Parameter maxOffset: The maximum number of elements
  ///   to offset the position of this iterator. `maxOffset` must be
  ///   nonnegative.
  /// - Returns: The number of items that were skipped. If the returned count
  ///   is less than `maxOffset`, then the underlying type did not have
  ///   enough elements left to skip the requested number of items.
  ///   In that case, the iterator's position is set to the end of the
  ///   underlying type.
  mutating func skip(by maxOffset: Int) throws(Failure) -> Int

  /// Advances the position of this iterator by the specified offset, or until
  /// the end of the underlying type's elements.
  ///
  /// Call this method when you need to know how many elements were actually
  /// skipped even after an error is thrown.
  ///
  /// - Parameter offset: The maximum number of elements
  ///   to offset the position of this iterator. `offset` must be
  ///   nonnegative. On return, `offset` is set to zero if the
  ///   operation succeeded without hitting the limit; otherwise,
  ///   `offset` reflects the number of elements that couldn't be skipped.
  @available(SwiftStdlib ZZZZ, *)
  mutating func skip(by offset: inout Int) throws(Failure)
}
```

The standard library will provide default implementations of both overloads, with the implementation of the existing `skip(by:)` forwarding to the new one when available. This implementation relies on the requirement that `BorrowingIteratorProtocol.nextSpan(maxCount:)` must return any elements it has produced before throwing an error, and allows conforming types to customize only this new method, instead of needing to supply both versions.

```swift
@available(SwiftStdlib 6.4, *)
extension BorrowingIteratorProtocol where Self: ~Copyable & ~Escapable, Element: ~Copyable {
  @export(implementation)
  internal mutating func _skip(by offset: inout Int) throws(Failure) {
    _precondition(offset >= 0, "Can't skip by a negative offset")
    while offset > 0 {
      let span = try nextSpan(maxCount: offset)
      if span.isEmpty { break }
      offset &-= span.count
    }
  }

  @export(implementation)
  public mutating func skip(by maximumOffset: Int) throws(Failure) -> Int {
    var remainder = maximumOffset
    if #available(SwiftStdlib ZZZZ, *) {
      try skip(by: &remainder)
    } else {
      try _skip(by: &remainder)
    }
    return maximumOffset &- remainder
  }
  
  @export(implementation)
  public mutating func skip(by offset: inout Int) throws(Failure) {
    try _skip(by: &offset)
  }
}
```

## Source compatibility

This is a new API that is source compatible with the existing members of `BorrowingIteratorProtocol`. Callers can select the desired overload by passing the `offset` parameter as a regular or `inout` value.

## ABI compatibility

This proposal adds a new member to `BorrowingIteratorProtocol`, with availability matching the Swift version that includes it for the first time (shown above using `ZZZZ` as a placeholder).

## Implications on adoption

If authors of custom borrowing iterators have implemented their own versions of the existing `skip(by:)`, they should switch over to the new `skip(by:)` method to take advantage of the implementation forwarding.

## Future directions

None.

## Alternatives considered

### Reversed polarity for the `offset` parameter

When the `skip(by:)` method either returns or throws an error, the `offset` parameter is updated to the number of items still to be skipped. That is, if you pass an offset of `5`, and only four elements are skipped, the value of `offset` after calling is `1`.

While this is the opposite of the `Int`-returning `skip(by:)`, which returns the number of elements that were skipped, it's the right value for continued processing. If we instead modify the `inout` parameter to the number of elements that were successfully skipped, it moves that bookkeeping work into the calling function. The following example shows the `nextElement(afterSkipping:retryCount:)` function from above, but with the alternative semantics. The author has to carefully track the number of elements remaining to skip without assistance from the `skip(by:)` method.

```swift
extension MyConcreteIterator {
    func nextElement(afterSkipping n: Int, retryCount: Int = 0) throws -> Span<Element> {
        var toSkip = n
        while toSkip > 0 {
            var offset = toSkip
            do {
                try skip(by: &offset)
                // Potential error #1: Comparing `offset == n` would be incorrect.
                guard offset == toSkip else {
                    return Span()
                }
            } catch {
                if retryCount > 0 {
                    retryCount -= 1
                    // Potential error #2: Must update `toSkip` in the right location.
                    toSkip -= offset
                    continue
                }
                throw error
            }
        }
        return nextSpan(maxCount: 1)
    }
}
```

The proposed behavior also matches the existing behavior of [`UniqueArray.formIndex(_:offsetBy:limitedBy:)`](https://developer.apple.com/documentation/swift/uniquearray/formindex(_:offsetby:limitedby:)), which similarly reports the distance that the index couldn't be moved, rather than the distance it did move.
