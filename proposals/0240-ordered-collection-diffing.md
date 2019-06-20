# Ordered Collection Diffing

* Proposal: [SE-0240](0240-ordered-collection-diffing.md)
* Authors: [Scott Perry](https://github.com/numist), [Kyle Macomber](https://github.com/kylemacomber)
* Review Manager: [Doug Gregor](https://github.com/DougGregor), [Ben Cohen](https://github.com/AirspeedSwift)
* Status: **Implemented (Swift 5.1)**
* Amendment status: **Active Review (June 19 - 25 2019)** 
* Implementation: [apple/swift#21845](https://github.com/apple/swift/pull/21845)
* Decision notes: [Rationale](https://forums.swift.org/t/accepted-with-modifications-se-0240-ordered-collection-diffing/20008)

## Introduction

This proposal describes additions to the standard library that provide an interchange format for diffs as well as diffing/patching functionality for appropriate collection types.

## Motivation

Representing, manufacturing, and applying transactions between states today requires writing a lot of error-prone code. This proposal is inspired by the convenience of the `diffutils` suite when interacting with text files, and the reluctance to solve similar problems in code by linking `libgit2`.

Many state management patterns would benefit from improvements in this area, including undo/redo stacks, generational stores, and syncing differential content to/from a service.

## Proposed solution

A new type representing the difference between collections is introduced along with methods that support its production and application.

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

Most diffing algorithms have collection access patterns that are not appropriate for basic collections, so difference production is dependant on conformance to `BidirectionalCollection`:

``` swift
@available(swift, introduced: 5.1)
extension BidirectionalCollection {
    /// Returns the difference needed to produce the receiver's state from the
    /// parameter's state, using the provided closure to establish equivalence
    /// between elements.
    ///
    /// This function does not infer moves.
    ///
    /// - Parameters:
    ///   - other: The base state.
    ///   - areEquivalent: A closure that returns whether the two
    ///     parameters are equivalent.
    ///
    /// - Returns: The difference needed to produce the reciever's state from
    ///   the parameter's state.
    ///
    /// - Complexity: For pathological inputs, worst case performance is
    ///   O(`self.count` * `other.count`). Faster execution can be expected
    ///   when the collections share many common elements.
    public func difference<C>(
        from other: C, by areEquivalent: (Element, C.Element) -> Bool
    ) -> CollectionDifference<Element>
        where C : BidirectionalCollection, C.Element == Self.Element
}

extension BidirectionalCollection where Element: Equatable {
    /// Returns the difference needed to produce the receiver's state from the
    /// parameter's state, using equality to establish equivalence between
    /// elements.
    ///
    /// This function does not infer element moves, but they can be computed
    /// using `CollectionDifference.inferringMoves()` if desired.
    ///
    /// - Parameters:
    ///   - other: The base state.
    ///
    /// - Returns: The difference needed to produce the reciever's state from
    ///   the parameter's state.
    ///
    /// - Complexity: For pathological inputs, worst case performance is
    ///   O(`self.count` * `other.count`). Faster execution can be expected
    ///   when the collections share many common elements, or if `Element`
    ///   also conforms to `Hashable`.
    public func difference<C>(from other: C) -> CollectionDifference<Element>
        where C: BidirectionalCollection, C.Element == Self.Element
```

The `difference(from:)` method produces an instance of a difference type, defined as:

``` swift
/// A type that represents the difference between two collection states.
@available(swift, introduced: 5.1)
public struct CollectionDifference<ChangeElement> {
    /// A type that represents a single change to a collection.
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
    /// For clients interested in the difference between two collections, see
    /// `BidirectionalCollection.difference(from:)`.
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

    /// Produces a difference that is the functional inverse of `self`
    public func inverse() -> CollectionDifference<ChangeElement>
}

/// A CollectionDifference is itself a Collection.
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
extension CollectionDifference : Collection {
    public typealias Element = CollectionDifference<ChangeElement>.Change
    public struct Index: Comparable, Hashable {}
}

extension CollectionDifference.Change: Equatable where ChangeElement: Equatable {}
extension CollectionDifference: Equatable where ChangeElement: Equatable {}

extension CollectionDifference.Change: Hashable where ChangeElement: Hashable {}
extension CollectionDifference: Hashable where ChangeElement: Hashable {
    /// Infers which `ChangeElement`s have been both inserted and removed only
    /// once and returns a new difference with those associations.
    ///
    /// - Returns: an instance with all possible moves inferred.
    ///
    /// - Complexity: O(*n*) where *n* is `self.count`
	public func inferringMoves() -> CollectionDifference<ChangeElement>
}

extension CollectionDifference: Codable where ChangeElement: Codable {}
```

A `Change` is a single mutating operation, a `CollectionDifference` is a plurality of such operations that represents a complete transition between two states. Given the interdependence of the changes, `CollectionDifference` has no mutating members, but it does allow index- and `Slice`-based access to its changes via `Collection` conformance as well as a validating initializer taking a `Collection`.

Fundamentally, there are only two operations that mutate collections, `insert(_:at:)` and `remove(_:at:)`, but there are benefits from being able to represent other operations such as moves and replacements, especially for UIs that may want to animate a move differently from an `insert`/`remove` pair. These operations are represented using `associatedWith:`. When non-`nil`, they refer to the offset of the counterpart as described in the headerdoc.

### Application of instances of `CollectionDifference`

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
    public func applying(_ difference: CollectionDifference<Element>) -> Self?
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

The following is an incomplete list based on common feedback received during the process of developing this API:

### Communicating changes via a series of callbacks

Breaking up a transaction into a sequence of imperative events is not very Swifty, and the pattern has proven to be fertile ground for defects.

### More cases in `CollectionDifference.Change`

While other cases such as `.move` are tempting, the proliferation of code in switch statements is unwanted overhead for clients that don't care about the "how" of a state transition so much as the "what".

The use of associated offsets allows for more information to be encoded into the diff without making it more difficult to use. You've already seen how associated offsets can be used to illustrate moves (as produced by `inferringMoves()`):

``` swift
CollectionDifference<String>([
    .remove(offset:0, element: "value", associatedWith: 4),
    .insert(offset:4, element: "value", associatedWith: 0)
])
```

But they can also be used to illustrate replacement when the offsets refer to the same position (and the element is different):

``` swift
CollectionDifference<String>([
    .remove(offset:0, element: "oldvalue", associatedWith: 0),
    .insert(offset:0, element: "newvalue", associatedWith: 0)
])
```

Differing offsets and elements can be combined when a value is both moved and replaced (or changed):

``` swift
CollectionDifference<String>([
    .remove(offset:4, element: "oldvalue", associatedWith: 0),
    .insert(offset:0, element: "newvalue", associatedWith: 4)
])
```

Neither of these two latter forms can be inferred from a diff by inferringMoves(), but they can be legally expressed by any API that vends a difference.

### `applying(_:) throws -> Self` instead of `applying(_:) -> Self?`

Applying a diff can only fail when the base state is incompatible. As such, the additional granularity provided by an error type does not add any value.

### Use `Index` instead of offset in `Change`

Because indexes cannot be navigated in the absence of the collection instance that generated them, a diff based on indexes instead of offsets would be much more limited in usefulness as a boundary type. If indexes are required, they can be rehydrated from the offsets in the presence of the collection(s) to which they belong.

### `Change` generic on both `BaseElement` and `OtherElement` instead of just `Element`

Application of differences would only be possible when both `Element` types were equal, and there would be additional cognitive overhead with comparators with the type `(Element, Other.Element) -> Bool`.

Since the comparator forces both types to be effectively isomorphic, a diff generic over only one type can satisfy the need by mapping one (or both) collections to force their `Element` types to match.

### `difference(from:using:)` with an enum parameter for choosing the diff algorithm instead of `difference(from:)`

This is an attractive API concept, but it can be very cumbersome to extend. This is especially the case for types like `OrderedSet` that—through member uniqueness and fast membership testing—have the capability to support very fast diff algorithms that aren't appropriate for other types.

### `CollectionDifference` or just `Difference` instead of `CollectionDifference`

The name `CollectionDifference` gives us the opportunity to build a family of related types in the future, as the difference type in this proposal is (intentionally) unsuitable for representing differences between keyed collections (which don't shift their elements' keys on insertion/removal) or structural differences between treelike collections (which are multidimensional).

## Intentional omissions:

### Further adoption

This API allows for more interesting functionality that is not included in this proposal.

### `mutating apply(_:)`

There is no mutating applicator because there is no algorithmic advantage to in-place application.

### `mutating inferringMoves()`

While there may be savings to be had from in-place move inferencing; we're holding this function for a future proposal.

### Formalizing the concept of an ordered collection

This problem warrants a proposal of its own.
