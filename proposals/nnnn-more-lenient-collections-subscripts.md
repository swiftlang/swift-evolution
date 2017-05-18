# More lenient subscript methods over Collections

* Proposal: SE-NNNN
* Author(s): [Luis Henrique Borges](https://github.com/luish)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal seeks to provide more lenient [subscript](https://github.com/apple/swift/blob/7928140f798ae5b29af2053e774851f8012b555e/stdlib/public/core/Collection.swift#L147)
methods on collections, as regards bounds checks in order to avoid
`index out of range` errors in execution time.

Swift-evolution thread: [link to the discussion thread for that proposal](http://thread.gmane.org/gmane.comp.lang.swift.evolution/14252)

## Motivation

Doing that in Swift causes a runtime error:

```swift
let a = [1,2,3]
let b = a[0..<5]
```

```
> Error running code:
> fatal error: Array index out of range
```

In comparison with other languages (often referred to as
"modern languages"), we see the exact behavior I am
going after in this proposal.

Python:

```python
>>> a = [1,2,3]
>>> a[:5]
[1, 2, 3]
```

Ruby:

```ruby
> a = [1,2,3]
> a[0...5]
=> [1, 2, 3]
```

Considering that, the motivation is to have a
handy interface that allows more clean code in
cases where either validations on collections
bounds are not required or the expected subsequence
can have less elements than the size of the
range provided by the user.

## Proposed solution

The [mail list discussion](http://thread.gmane.org/gmane.comp.lang.swift.evolution/14252/focus=14382)
on the initial draft converged in a wider inclusion in the language that is worth considering.
The proposed solution is to provide a convenient interface to let the user slice
_collections_ implicit and explicitly through new labeled _subscript_ alternatives.
These new subscript methods, described in more details below, would either truncate
the range to the collection indices or return `nil` in cases where the range/index is
out of bounds.

#### - subscript(`clamping` range: Range&lt;Index&gt;) -> SubSequence

The proposed solution is to clamp the range to the collection's bounds
before applying the subscript on it.

In the following example,

```swift
let a = [1,2,3]
let b = a[clamping: -1 ..< 5]
```

the range would be equivalent to `max(-1, a.startIndex) ..< min(5, a.endIndex)`
which becomes `0 ..< 3` and `b` results in `[1,2,3]`.

#### - subscript(`checking` range: Range&lt;Index&gt;) -> SubSequence?

Returns `nil` whenever the range is out of bounds,
instead of throwing a _fatal error_ in execution time.

In the example below, `b` would be equal to `nil`.

```swift
let a = [1,2,3]
let b = a[checking: 0 ..< 5]
```

#### - subscript(`checking` index: Index) -> Element?

Similar behaviour as the previous method, but given an _Index_ instead.
Returns `nil` if the index is out of bounds.

```swift
let a = [1,2,3]
let b = a[checking: 5] // nil
```

This behaviour could be considered consistent with dictionaries, other
collection type in which the _subscript_ function returns `nil` if the
dictionary does not contain the key given by the user. Similarly, it
could be compared with `first` and `last`, which are very handy
optionals `T?` that are `nil` whenever the collection is empty.

In summary, considering `a = [1,2,3]`:

- `a[0 ..< 5]` results in _fatal error_, the current implementation (_fail fast_).
- `a[clamping: 0 ..< 5]` turns into `a[0 ..< 3]` and produces `[1,2,3]`.
- `a[checking: 0 ... 5]` returns `nil` indicating that the range is invalid, but not throwing any error.
- `a[checking: 3]` also returns `nil`, as the valid range is `0 ..< 3`.

## Detailed design

This is a simple implementation for the _subscript_ methods I am proposing:

(Swift 3)
```swift
extension Collection where Index: Comparable {
    
    subscript(clamping bounds: Range<Index>) -> SubSequence {
        let clamped = bounds.clamped(to: startIndex ..< endIndex)
        return self[clamped]
    }
    
    subscript(clamping bounds: ClosedRange<Index>) -> SubSequence {
        let range = bounds.lowerBound ..< index(bounds.upperBound, offsetBy: 1)
        let clamped = range.clamped(to: startIndex ..< endIndex)
        return self[clamped]
    }
    
    subscript(checking bounds: Range<Index>) -> SubSequence? {
        let range = startIndex ... endIndex
        return range.contains(bounds.lowerBound) && range.contains(bounds.upperBound) ? self[bounds] : nil
    }
    
    subscript(checking bounds: ClosedRange<Index>) -> SubSequence? {
        let range = bounds.lowerBound ..< index(bounds.upperBound, offsetBy: 1)
        return self[checking: range]
    }
    
    subscript(checking index: Index) -> Iterator.Element? {
        guard index >= startIndex && index < endIndex else { return nil }
        return self[index]
    }
    
}
```

Examples:

```swift
let a = [1, 2, 3]

a[clamping: 0 ..< 5] // [1, 2, 3]
a[clamping: -1 ..< 2] // [1, 2]
a[clamping: 1 ..< 2] // [2]
a[clamping: 4 ..< 3] // Fatal error: end < start

a[clamping: 2 ... 4] // [3]
a[clamping: -1 ... 5] // [1,2,3]
a[clamping: 3 ... 4] // []
a[clamping: -2 ... -1] // []

a[checking: -1 ... 4] // nil
a[checking: 0 ..< 5] // nil
a[checking: -2 ..< -1] // nil
a[checking: 1 ..< 3] // [2, 3]
a[checking: 0 ... 2] // [1,2,3]
a[checking: 4 ..< 3] // Fatal error: end < start

a[checking: 0] // 1
a[checking: -1] // nil
a[checking: 3] // nil
```

## Impact on existing code

It does not cause any impact on existing code, the current
behaviour will continue as the default implementation.

## Alternatives considered

An alternative would be to make the current subscript method `Throwable`
motivated by this blog post published by @erica:
[Swift: Why Try and Catch don’t work the way you expect](http://ericasadun.com/2015/06/09/swift-why-try-and-catch-dont-work-the-way-you-expect/)
