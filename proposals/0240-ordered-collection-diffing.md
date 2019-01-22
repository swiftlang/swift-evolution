# Ordered Collection Diffing

* Proposal: [SE-0240](0240-ordered-collection-diffing.md)
* Authors: [Scott Perry](https://github.com/numist), [Kyle Macomber](https://github.com/kylemacomber)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active review (January 14...22, 2019)**
* Prototype: [numist/Diffing](https://github.com/numist/Diffing)

## Introduction

This proposal describes additions to the standard library that provide an interchange format for diffs as well as diffing/patching functionality for ordered collection types.

## Motivation

Representing, manufacturing, and applying transactions between states today requires writing a lot of error-prone code. This proposal is inspired by the convenience of the `diffutils` suite when interacting with text files, and the reluctance to solve similar problems in code with `libgit2`.

Many state management patterns would benefit from improvements in this area, including undo/redo stacks, generational stores, and syncing differential content to/from a service.

## Proposed solution

A new type representing the difference between ordered collections is introduced along with methods that support its production and application.

Using this API, a line-by-line three-way merge can be performed in a few lines of code:

``` swift
// Split the contents of the sources into lines
let baseLines = base.components(separatedBy: "\n")
let theirLines = theirs.components(separatedBy: "\n")
let myLines = mine.components(separatedBy: "\n")
    
// Create a difference from base to theirs
let diff = theirLines.difference(from:baseLines)
    
// Apply it to mine, if possible
guard let patchedLines = myLines.applying(diff) else {
    print("Merge conflict applying patch, manual merge required")
    return
}
    
// Reassemble the result
let patched = patchedLines.joined(separator: "\n")
print(patched)
```

## Detailed design

### Producing diffs

Collections can only be efficiently diffed when they have a strong sense of order, so difference production is added to `BidirectionalCollection`:

``` swift
@available(swift, introduced: 5.1)
extension BidirectionalCollection {
    /// Returns the difference needed to produce the receiver's state from the
    /// parameter's state with the fewest possible changes, using the provided
    /// closure to establish equivalence between elements.
    ///
    /// This function does not infer element moves, but they can be computed
    /// using `OrderedCollectionDifference.inferringMoves()` if desired.
    ///
    /// Implementation is an optimized variation of the algorithm described by
    /// E. Myers (1986).
    ///
    /// - Parameters:
    ///   - other: The base state.
    ///   - areEquivalent: A closure that returns whether the two
    ///     parameters are equivalent.
    ///
    /// - Returns: The difference needed to produce the reciever's state from
    ///   the parameter's state.
    ///
    /// - Complexity: O(*n* * *d*), where *n* is `other.count + self.count` and
    ///   *d* is the number of changes between the two ordered collections.
    public func difference<C>(
        from other: C, by areEquivalent: (Element, C.Element) -> Bool
    ) -> OrderedCollectionDifference<Element>
        where C : BidirectionalCollection, C.Element == Self.Element
}

extension BidirectionalCollection where Element: Equatable {
    /// Returns the difference needed to produce the receiver's state from the
    /// parameter's state with the fewest possible changes, using equality to
    /// establish equivalence between elements.
    ///
    /// This function does not infer element moves, but they can be computed
    /// using `OrderedCollectionDifference.inferringMoves()` if desired.
    ///
    /// Implementation is an optimized variation of the algorithm described by
    /// E. Myers (1986).
    ///
    /// - Parameters:
    ///   - other: The base state.
    ///
    /// - Returns: The difference needed to produce the reciever's state from
    ///   the parameter's state.
    ///
    /// - Complexity: O(*n* * *d*), where *n* is `other.count + self.count` and
    ///   *d* is the number of changes between the two ordered collections.
    public func difference<C>(from other: C) -> OrderedCollectionDifference<Element>
        where C: BidirectionalCollection, C.Element == Self.Element
```

The `difference(from:)` method determines the fewest possible edits required to transition betewen the two states and stores them in a difference type, which is defined as:

``` swift
/// A type that represents the difference between two ordered collection states.
@available(swift, introduced: 5.1)
public struct OrderedCollectionDifference<ChangeElement> {
    /// A type that represents a single change to an ordered collection.
    ///
    /// The `offset` of each `insert` refers to the offset of its `element` in
    /// the final state after the difference is fully applied. The `offset` of
    /// each `remove` refers to the offset of its `element` in the original
    /// state. Non-`nil` values of `associatedWith` refer to the offset of the
    /// complementary change.
    public enum Change {
        case insert(offset: Int, element: ChangeElement, associatedWith: Int?)
        case remove(offset: Int, element: ChangeElement, associatedWith: Int?)
    }

    /// Creates an instance from a collection of changes.
    ///
    /// For clients interested in the difference between two ordered
    /// collections, see `OrderedCollection.difference(from:)`.
    ///
    /// To guarantee that instances are unambiguous and safe for compatible base
    /// states, this initializer will fail unless its parameter meets to the
    /// following requirements:
    ///
    /// 1) All insertion offsets are unique
    /// 2) All removal offsets are unique
    /// 3) All offset associations between insertions and removals are symmetric
    ///
    /// - Parameter changes: A collection of changes that represent a transition
    ///   between two states.
    ///
    /// - Complexity: O(*n* * log(*n*)), where *n* is the length of the
    ///   parameter.
    public init?<C: Collection>(_ c: C) where C.Element == Change

    /// The `.insert` changes contained by this difference, from lowest offset to highest
    public var insertions: [Change] { get }
    
    /// The `.remove` changes contained by this difference, from lowest offset to highest
    public var removals: [Change] { get }
}

/// An OrderedCollectionDifference is itself a Collection.
///
/// The enumeration order of `Change` elements is:
///
/// 1. `.remove`s, from highest `offset` to lowest
/// 2. `.insert`s, from lowest `offset` to highest
///
/// This guarantees that applicators on compatible base states are safe when
/// written in the form:
///
/// ```
/// for c in diff {
///     switch c {
///     case .remove(offset: let o, element: _, associatedWith: _):
///         arr.remove(at: o)
///     case .insert(offset: let o, element: let e, associatedWith: _):
///         arr.insert(e, at: o)
///     }
/// }
/// ```
extension OrderedCollectionDifference : Collection {
    public typealias Element = OrderedCollectionDifference<ChangeElement>.Change
    public struct Index: Comparable, Hashable {}
}

extension OrderedCollectionDifference.Change: Equatable where ChangeElement: Equatable {}
extension OrderedCollectionDifference: Equatable where ChangeElement: Equatable {}

extension OrderedCollectionDifference.Change: Hashable where ChangeElement: Hashable {}
extension OrderedCollectionDifference: Hashable where ChangeElement: Hashable {
    /// Infers which `ChangeElement`s have been both inserted and removed only
    /// once and returns a new difference with those associations.
    ///
    /// - Returns: an instance with all possible moves inferred.
    ///
    /// - Complexity: O(*n*) where *n* is `self.count`
	public func inferringMoves() -> OrderedCollectionDifference<ChangeElement>
}

extension OrderedCollectionDifference: Codable where ChangeElement: Codable {}
```

A `Change` is a single mutating operation, an `OrderedCollectionDifference` is a plurality of such operations that represents a complete transition between two states. Given the interdependence of the changes, `OrderedCollectionDifference` has no mutating members, but it does allow index- and `Slice`-based access to its changes via `Collection` conformance as well as a validating initializer taking a `Collection`.

Fundamentally, there are only two operations that mutate ordered collections, `insert(_:at:)` and `remove(at:)`, but there are benefits from being able to represent other operations such as moves and replacements, especially for UIs that may want to animate a move differently from an `insert`/`remove` pair. These operations are represented using `associatedWith:`. When non-`nil`, they refer to the offset of the counterpart as described in the headerdoc.

In a similar way, the name `difference(from:)` uses a term of art to admit the use of an algorithm that compromises between performance and a minimal output. It computes the [longest common subsequence](https://en.wikipedia.org/wiki/Longest_common_subsequence_problem) between the two collections, but not the [longest common substring](https://en.wikipedia.org/wiki/Longest_common_substring_problem) (which is a much slower operation). In the future other algorithms may be added as different methods to satisfy the need for different performance and output characteristics.

### Application of instances of `OrderedCollectionDifference`

``` swift
extension RangeReplaceableCollection {
    /// Applies a difference to a collection.
    ///
    /// - Parameter difference: The difference to be applied.
    ///
    /// - Returns: An instance representing the state of the receiver with the
    ///   difference applied, or `nil` if the difference is incompatible with
    ///   the receiver's state.
    ///
    /// - Complexity: O(*n* + *c*), where *n* is `self.count` and *c* is the
    ///   number of changes contained by the parameter.
    @available(swift, introduced: 5.1)
    public func applying(_ difference: OrderedCollectionDifference<Element>) -> Self?
}
```

Applying a diff to an incompatible base state is the only way application can fail. `applying(_:)` expresses this by returning nil.

## Source compatibility

This proposal is additive and the names of the types it proposes are not likely to already be in wide use, so it does not represent a significant risk to source compatibility.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This feature is additive and symbols marked with `@available(swift, introduced: 5.1)` as appropriate.

## Alternatives considered

### `difference(from:by:)` defined in protocol instead of extension

Different algorithms with different premises and/or semantics are free to be defined using different function names.

### Communicating changes via a series of callbacks

Breaking up a transaction into a sequence of imperative events is not very Swifty, and the pattern has proven to be fertile ground for defects.

### More cases in `OrderedCollectionDifference.Change`

While other cases such as `.move` are tempting, the proliferation of code in switch statements is unwanted overhead for clients that don't care about the "how" of a state transition so much as the "what".

The use of associated offsets allows for more information to be encoded into the diff without making it more difficult to use. You've already seen how associated offsets can be used to illustrate moves (as produced by `inferringMoves()`):

``` swift
OrderedCollectionDifference<String>([
    .remove(offset:0, element: "value", associatedWith: 4),
    .insert(offset:4, element: "value", associatedWith: 0)
])
```

But they can also be used to illustrate replacement when the offsets refer to the same position (and the element is different):

``` swift
OrderedCollectionDifference<String>([
    .remove(offset:0, element: "oldvalue", associatedWith: 0),
    .insert(offset:0, element: "newvalue", associatedWith: 0)
])
```

Differing offsets and elements can be combined when a value is both moved and replaced (or changed):

``` swift
OrderedCollectionDifference<String>([
    .remove(offset:4, element: "oldvalue", associatedWith: 0),
    .insert(offset:0, element: "newvalue", associatedWith: 4)
])
```

Neither of these two latter forms can be inferred from a diff by inferringMoves(), but they can be legally expressed by any API that vends a difference.

### `applying(_:) throws -> Self` instead of `applying(_:) -> Self?`

Applying a diff can only fail when the base state is incompatible. As such, the additional granularity provided by an error type does not add any value.

### Use `Index` instead of offset in `Change`

Because indexes cannot be navigated in the absence of the collection instance that generated them, a diff based on indexes instead of offsets would be much more limited in usefulness as a boundary type. If indexes are required, they can be rehydrated from the offsets in the presence of the collection(s) to which they belong.

### `OrderedCollection` conformance for `OrderedCollectionDifference`

Because the change offsets refer directly to the resting positions of elements in the base and modified states, the changes represent the same state transition regardless of their order. The purpose of ordering is to optimize for understanding, safety, and/or performance. In fact, this prototype already contains examples of two different equally valid sort orders: 

* The order provided by `for in` is optimized for safe diff application when modifying a compatible base state one element at a time.
* `applying(_:)` uses a different order where `insert` and `remove` instances are interleaved based on their adjusted offsets in the base state.

Both sort orders are "correct" in representing the same state transition.

### `Change` generic on both `BaseElement` and `OtherElement` instead of just `Element`

Application of differences would only be possible when both `Element` types were equal, and there would be additional cognitive overhead with comparators with the type `(Element, Other.Element) -> Bool`.

Since the comparator forces both types to be effectively isomorphic, a diff generic over only one type can satisfy the need by mapping one (or both) ordered collections to force their `Element` types to match.

### `difference(from:using:)` with an enum parameter for choosing the diff algorithm instead of `difference(from:)`

This is an attractive API concept, but it can be very cumbersome to extend. This is especially the case for types like `OrderedSet` that—through member uniqueness and fast membership testing—have the capability to support very fast diff algorithms that aren't appropriate for other types.

### `CollectionDifference` or just `Difference` instead of `OrderedCollectionDifference`

The name `OrderedCollectionDifference` gives us the opportunity to build a family of related types in the future, as the difference type in this proposal is (intentionally) unsuitable for representing differences between keyed collections (which don't shift their elements' keys on insertion/removal) or structural differences between treelike collections (which are multidimensional).

## Intentional omissions:

### Further adoption

This API allows for more interesting functionality that is not included in this proposal.

For example, this propsal could have included a `reversed()` function on the difference type that would return a new difference that would undo the application of the original.

The lack of additional conveniences and functionality is intentional; the goal of this proposal is to lay the groundwork that such extensions would be built upon.

In the case of `reversed()`, clients of the API in this proposal can use `Collection.map()` to invert the case of each `Change` and feed the result into `OrderedCollectionDifference.init(_:)`:

``` swift
let diff: OrderedCollectionDifference<Int> = /* ... */
let reversed = OrderedCollectionDifference<Int>(
    diff.map({(change) -> OrderedCollectionDifference<Int>.Change in
        switch change {
        case .insert(offset: let o, element: let e, associatedWith: let a):
            return .remove(offset: o, element: e, associatedWith: a)
        case .remove(offset: let o, element: let e, associatedWith: let a):
            return .insert(offset: o, element: e, associatedWith: a)
        }
    })
)!
```

### `mutating apply(_:)`

There is no mutating applicator because there is no algorithmic advantage to in-place application.

### `mutating inferringMoves()`

While there may be savings to be had from in-place move inferencing; we're holding this function for a future proposal.

### Formalizing the concept of an ordered collection

This problem warrants a proposal of its own.
