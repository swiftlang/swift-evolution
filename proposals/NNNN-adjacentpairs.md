# Add an `adjacentPairs` algorithm to `Sequence`

* Proposal: [SE-NNNN](NNNN-adjacentpairs.md)
* Author: [Michael Pangburn](https://github.com/mpangburn)
* Review Manager: TBD
* Status: [Implemented](https://github.com/mpangburn/swift-sennnn-adjacent-pairs)

## Introduction

It is often desirable to access adjacent pairs of elements in a `Sequence` in performing an operation, such as verifying that a pattern holds between successive elements. This proposal introduces a new method on `Sequence` that returns a specialized sequence containing tuples of adjacent elements.

SE Discussion: https://forums.swift.org/t/add-an-adjacentpairs-algorithm-to-sequence/14817

## Motivation

This proposal addresses the need to perform an operation on adjacent pairs of elements in a sequence. The intention is to transform the common pattern demonstrated below into a concise, readable, generic, less error-prone operation.

For developers with backgrounds in the C-family, indexing may seem intuitive. Consider computing the distances between successive points in an array:

```swift 
let points: [Point] = /* ... */
var distancesBetweenPoints: [Double] = []
if points.count > 1 {
    for index in 0..<points.count - 1 {
        let pointDistance = distance(from: points[index], to: points[index + 1])
        distancesBetweenPoints.append(pointDistance)
    }
}
```

Observe that this operation, as written:

- Requires `Collection` conformance (and `RandomAccessCollection` conformance for reasonable performance).
- Is prone to off-by-one indexing errors.
- Requires verifying the length of the sequence prior to iteration.

An alternative approach may track the previous element in a separate variable:

```swift
var previousPoint: CGPoint?
for point in points {
    if let previousPoint = previousPoint {
        let pointDistance = distance(from: previousPoint, to: point)
        distancesBetweenPoints.append(pointDistance)
    }
    previousPoint = point
}
```

While certainly an improvement over the above, this approach misses out on optimizations with respect to the memory allocation of the resulting array.

In writing an algorithm generically on `Sequence` to return a sequence of adjacent pairs of elements, the following one-line implementation is tempting:

```swift
extension Sequence {
    func adjacentPairs() -> Zip2Sequence<Self, Self.SubSequence> {
        return zip(self, self.dropFirst())
    }
}
```

However, the behavior of this implementation is undefined for single-pass sequences.

## Proposed solution

Introduce an algorithm on `Sequence` called `adjacentPairs()` that returns a sequence containing two-tuples of adjacent elements.

The proposed algorithm deserves Standard Library support on the following grounds:

- **Commonality:** Supports a common algorithm pattern: accumulating adjacent pairs of elements in a sequence, which can then be processed.
- **Readability:** Improves call-site clarity; the concision of `seq.adjacentPairs()` reduces cognitive load when used in place of a for-loop.
- **Generality:** Supports all `Sequence` conformances, including single-pass sequences.
- **Performance:** Utilizes a specialized lazy sequence to avoid unnecessarily creating an intermediate array.
- **Correctness:** Avoids a tempting implementation that results in undefined behavior for single-pass sequences.

With the proposed algorithm, the point distances example above becomes a clean one-liner:

```swift
let distancesBetweenPoints = points.adjacentPairs().map(distance(from:to:))
```

As an additional example, consider the simplicity of the following extension designed to test whether a `Sequence` is sorted:

```swift
extension Sequence {
    func isSorted(by predicate: (Element, Element) -> Bool) -> Bool {
        // Swap the arguments to the predicate and negate the result
        // to ensure consecutive equal elements do not return `false`.
        return self.adjacentPairs().allSatisfy { !predicate($1, $0) }
    }
}
```

## Detailed design

Create a specialized wrapper, `AdjacentPairs`, whose iterator lazily produces two-tuples of adjacent elements from the underlying sequence. Expose the API through a new method on `Sequence` called `adjacentPairs`.

`AdjacentPairs` conforms to `Collection`, `BidirectionalCollection`, and `RandomAccessCollection` when its generic parameter `Base` conforms.

```swift
extension Sequence {
    /// Creates a sequence of adjacent pairs of elements from this sequence.
    ///
    /// In the `AdjacentPairs` instance returned by this method, the elements of
    /// the *i*th pair are the *i*th and *(i+1)*th elements of the underlying sequence.
    /// The following example uses the `adjacentPairs()` method to iterate over adjacent
    /// pairs of integers:
    ///
    ///    for pair in (1...5).adjacentPairs() {
    ///        print(pair)
    ///    }
    ///    // Prints "(1, 2)"
    ///    // Prints "(2, 3)"
    ///    // Prints "(3, 4)"
    ///    // Prints "(4, 5)"
    @inlinable
    public func adjacentPairs() -> AdjacentPairs<Self>
}

/// A sequence of adjacent pairs of elements built from an underlying sequence.
///
/// In an `AdjacentPairs` sequence, the elements of the *i*th pair are the *i*th 
/// and *(i+1)*th elements of the underlying sequence. The following example 
/// uses the `adjacentPairs()` method to iterate over adjacent pairs of integers:
///
///    for pair in (1...5).adjacentPairs() {
///        print(pair)
///    }
///    // Prints "(1, 2)"
///    // Prints "(2, 3)"
///    // Prints "(3, 4)"
///    // Prints "(4, 5)"
public struct AdjacentPairs<Base: Sequence>: Sequence {
    public struct Iterator: IteratorProtocol {
        public mutating func next() -> (Base.Element, Base.Element)?
    }

    public func makeIterator() -> Iterator
}

extension AdjacentPairs: Collection where Base: Collection {
    public struct Index: Comparable {
        public static func < (lhs: Index, rhs: Index) -> Bool
    }
    
    public var startIndex: Index { get }
    public var endIndex: Index { get }
    public func index(after i: Index) -> Index
    public subscript(position: Index) -> (Base.Element, Base.Element) { get }
}

extension AdjacentPairs: BidirectionalCollection where Base: BidirectionalCollection {
    public func index(before i: Index) -> Index
}

extension AdjacentPairs: RandomAccessCollection where Base: RandomAccessCollection {}
```

## Source compatibility

This change is purely additive and thus has no source compatibility consequences.

## Effect on ABI stability

This change is purely additive and thus has no ABI stability consequences.

## Effect on API resilience

This change is purely additive and thus has no API resilience consequences.

## Alternatives considered

Some methods on `Sequence`, such as `map` and `filter`, take two forms:

- An eager version returning an `Array`.
- A lazy version returning a specialized sequence.

However, adjacent pairs of elements are primarily useful as a transitory step in computing another value. For this reason, `adjacentPairs` follows in the footsteps of `joined` and `zip` in that it utilizes only a lazy wrapper type in its API.

In the pitch phase, a version of the API producing a pair containing the last and first elements of the underlying sequence was discussed, but use cases were not compelling.
