# Supporting split collection in chunks of a given size parameter


* Proposal: [SE-NNNN](NNNN-collection-chunks-size.md)
* Authors: [Luciano Almeida](https://github.com/LucianoPAlmeida)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#19968](https://github.com/apple/swift/pull/19968)

## Introduction

This proposal suggests a method that provides the functionality of split a `Collection` in chunks of a given size.

Swift-evolution thread: [Supporting collection slice by slices of a given size parameter](https://forums.swift.org/t/supporting-collection-slice-by-slices-of-a-given-size-parameter/15186)

## Motivation

The Standard Library `Collection` API mostly provides methods that can split a collection by a given separator or that split it by a given closure that takes each value and decides if it is going to split in this element position. But, another use case is that sometimes we need the ability to split a `Collection` into slices of a given size.  

It is a functionality that many people usually implement it themselves as `Collection` or more usually `Array` extensions. It is also common to see that kind of method implemented in other languages such as [Ruby](https://apidock.com/ruby/Enumerable/each_slice) and  [Javascript](https://lodash.com/docs/4.17.10#chunk).

And since it has a general purpose and it is a common use functionally not so simple to implement by hand, this could be a good addition to the Standard Library.

## Proposed solution

Add a new method in `Collection` which takes a parameter `size` and returns a chunked view where the chunks are of the same count when the count of the collection divides evenly with the size, otherwise, the last chunk is filled with the rest of the elements.  

```swift
let s = (1...10).map({ $0 })
print(s.chunks(of: 3).map(Array.init)) 
// [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10]]
```

## Detailed design

As discussed on the  [Swift Forums Thread](https://forums.swift.org/t/supporting-collection-slice-by-slices-of-a-given-size-parameter/15186) if there isn't a major downside to a method being lazy, for example, taking a closure as a parameter, the implementation should be lazy. So adding the `chunks(of: )` method to `Collection` requires creating a `ChunkedColleciton<Base>` type as a lazy view to the `base` collection. 

```swift 
/// A collection that presents the elements of its base collection
/// in `SubSequence` chunks of any given size.
///
/// A ChunkedCollection is a lazy view on the base Collection, but it does not implicitly confer
/// laziness on algorithms applied to its result.  In other words, for ordinary collections `c`:
///
/// * `c.chunks(of: 3)` does not create new storage
/// * `c.chunks(of: 3).map(f)` maps eagerly and returns a new array
/// * `c.lazy.chunks(of: 3).map(f)` maps lazily and returns a `LazyMapCollection`
///
@frozen
public struct ChunkedCollection<Base: Collection> {
    @usableFromInline
    internal let _base: Base
    @usableFromInline
    internal let _size: Int
    
    ///  Creates a view instance that presents the `base`
    ///  elements in `SubSequence` chunks of the given size.
    ///
    /// - Complexity: O(1)
    @inlinable
    internal init(base: Base, size: Int) {
        self._base = base
        self._size = size
    }
}
```

**Conforming to Collection**

The `index(after:)` goes through the base collection by offset of size until it reaches the `base.endIndex`.

```swift 
extension ChunkedCollection: Collection {
    public typealias Element = Base.SubSequence

    public struct Index {
        @usableFromInline
        let _base: Base.Index
        
        @usableFromInline
        init(_base: Base.Index) {
            self._base = _base
        }
    }
    
    public var startIndex: Index { Index(_base: _base.startIndex) }
    public var endIndex: Index { Index(_base: _base.endIndex) }
    
    public subscript(i: Index) -> Element {
        let range = i..<index(after: i)
        return _base[range.lowerBound._base..<range.upperBound._base]
    }
    
    @inlinable
    public func index(after i: Index) -> Index {
        return Index(_base: _base.index(i._base, offsetBy: _size, limitedBy: _base.endIndex) ?? _base.endIndex)
    }

}
```


**Extending Collection**

The `chunks(of:)` will return a `ChunkedCollection` view created at constant time to chunk the base `Collection` in a lazy way. 
**Important** is that the `chunks(of:)` method is always lazy, but does not implicitly confer laziness on algorithms applied to its result. 

Meaning that: 

Calling a `collection.chunks(of: 2).map { $0 }` maps eagerly and returns a new array of `Collection.SubSequence` chunks.

```swift
extension Collection {
    /// Returns a `ChunkedCollection<Self>` view presenting the elements
    ///    in chunks with count of the given size parameter.
    ///
    /// - Parameter size: The size of the chunks. If the size parameter
    ///   is evenly divided by the count of the base `Collection` all the
    ///   chunks will have the count equals to size.
    ///   Otherwise, the last chunk will contain the remaining elements.
    ///
    ///     let c = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    ///     print(c.chunks(of: 5).map(Array.init))
    ///     // [[1, 2, 3, 4, 5], [6, 7, 8, 9, 10]]
    ///
    ///     print(c.chunks(of: 3).map(Array.init))
    ///     // [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10]]
    ///
    /// - Complexity: O(1)
    @inlinable
    public __consuming func chunks(of size: Int) -> ChunkedCollection<Self> {
        _precondition(size > 0, "Split size should be greater than 0.")
        return ChunkedCollection(_base: self, _size: size)
    }
}
```

**Conforming to BidirectionalCollection and RandomAccessCollection**

As pointed out on the [Swift Forums](https://forums.swift.org/t/supporting-collection-slice-by-slices-of-a-given-size-parameter/15186/8?u=lucianopalmeida) the [`BidirectionalCollection`](https://developer.apple.com/documentation/swift/bidirectionalcollection) and [`RandomAccessCollection`](https://developer.apple.com/documentation/swift/randomaccesscollection) conformance are conditionally constrained to `where Base: RandomAccessCollection` because the last chunk size needs to be calculated and it needs to be done in O(1). 

Also when adding those constraints we should make the `distance(from start: Index, to end: Index) -> Int`, `index(_ i: Index, offsetBy n: Int) -> Index` and `count` O(1).


```swift
extension ChunkedCollection:
    BidirectionalCollection, RandomAccessCollection
where Base: RandomAccessCollection {
    @inlinable
    public func index(before i: Index) -> Index {
        if i._base == _base.endIndex {
            let remainder = _base.count%_size
            if remainder != 0 {
                return Index(_base: _base.index(i._base, offsetBy: -remainder))
            }
        }
        return Index(_base: _base.index(i._base, offsetBy: -_size))
    }
    
    @inlinable
    public func distance(from start: Index, to end: Index) -> Int {
        let distance = _base.distance(from: start._base, to: end._base)/_size
        return _base.count.isMultiple(of: _size) ? distance : distance + 1
    }
    
    @inlinable
    public func index(_ i: Index, offsetBy n: Int) -> Index {
        guard n != 0 else { return i }
        return Index(_base: _base.index(i._base, offsetBy: n * _size))
    }
    
    @inlinable
    public var count: Int {
        let count = _base.count/_size
        return _base.count.isMultiple(of: _size) ? count : count + 1
    }
}

let s = (1...10).map({ $0 })
print(s.chunks(of: 3).map(Array.init)) // [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10]]

let r: ReversedCollection<ChunkedCollection<[Int]>> = s.chunks(of: 3).reversed()
print(r.map(Array.init)) // [[10], [7, 8, 9], [4, 5, 6], [1, 2, 3]]

```

## Source compatibility

This change is only additive to the standard library, so there is no effect on source compatibility.

## Effect on ABI stability

This change is additive only so it has no effect on ABI stability.

## Effect on API resilience

The additional APIs will be a permanent part of the standard library and will need to remain public API. 

## Alternatives considered

### Eager Implementation

* An alternative just to mention here is maybe a version of this that returns an `Array` of `SubSequence` of the `Collection` eagerly instead of a `ChunkedCollection` lazy view. But is just a mention and as pointed by [Ben Cohen](https://github.com/airspeedswift) if there isn't a major downside to them being lazy, like taking a closure as a parameter, it should be lazy.
Also is very simple to transform a `ChunkedCollection` into an `Array` of slices via `map({ $0 })` operation. 

### Chunks with overlaping elements

* Another alternative proposed on the forums discussion was a chuck implementation that also takes an overlapping size indicating how many base elements of the current chunk will overlap the elements of the previous one. 

**Example**
```swift
let array = (1...5).map({ $0 })
print("Overlaping: \(array.chunks(of: 2, overlapingBy: 1).map({ $0 }))")
// Overlaping: [ArraySlice([1, 2]), ArraySlice([2, 3]), ArraySlice([3, 4]), ArraySlice([4, 5])]
```
Also, as discussed on the thread maybe is overgeneralize this `chunks(of:)` method. But, could be something to consider as a separated method implementation and proposal.

### Chunked Collection with the same Index type as the Base.Index
The current implementation wraps the `Base.Index` into a custom `ChunckedCollection.Index`. But the first implementation consider was reuse the `Base.Index` type on `ChunkedCollection`.

### Chunks API with number of chunk instead of chunk size
Instead of a provide an API `chunks(of size: Int)` where the parameter is the chunk size. We could provide a different API `chunked(in slices: Int)` which mean that we pass how many chunks we want instead of the chunk size and collection will be chunked in `slices` + a possible extra slice with the remainder of `collection.count/slices`.
