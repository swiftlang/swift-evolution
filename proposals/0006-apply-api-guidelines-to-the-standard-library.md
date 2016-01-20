# Apply API Guidelines to the Standard Library

* Proposal: [SE-0006](https://github.com/apple/swift-evolution/blob/master/proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* Author(s): [Dave Abrahams](https://github.com/dabrahams), [Dmitri Gribenko](https://github.com/gribozavr), [Maxim Moiseev](https://github.com/moiseev)
* Status: **Awaiting Review** (January 21...31, 2016)
* Review manager: [Doug Gregor](https://github.com/DougGregor)

## Reviewer notes

This review is part of a group of three related reviews, running
concurrently:

* [SE-0023 API Design Guidelines](https://github.com/apple/swift-evolution/blob/master/proposals/0023-api-guidelines.md)
* [SE-0006 Apply API Guidelines to the Standard Library](https://github.com/apple/swift-evolution/blob/master/proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* [SE-0005 Better Translation of Objective-C APIs Into Swift](https://github.com/apple/swift-evolution/blob/master/proposals/0005-objective-c-name-translation.md)

These reviews are running concurrently because they interact strongly
(e.g., an API change in the standard library will correspond to a
particular guideline, or an importer rule implements a particular
guideline, etc.). Because of these interactions, and to keep
discussion manageable, we ask that you:

* **Please get a basic understanding of all three documents** before
  posting review commentary
* **Please post your review of each individual document in response to
  its review announcement**. It's okay (and encouraged) to make
  cross-references between the documents in your review where it helps
  you make a point.

## Introduction

[Swift API Design Guidelines][api-design-guidelines] being developed as
part of Swift 3.  It is important that the Standard Library is an exemplar of
Swift API Design Guidelines: the APIs from the Standard Library are, probably,
the most frequently used Swift APIs in any application domain; the Standard
Library also sets precedent for other libraries.

In this project, we are reviewing the entire Standard Library and updating it
to follow the guidelines.

## Proposed solution

The actual work is being performed on the [swift-3-api-guidelines
branch][swift-3-api-guidelines-branch] of the [Swift repository][swift-repo].
On high level, the changes can be summarized as follows.

* Strip `Type` suffix from protocol names.  In a few special cases
  this means adding a `Protocol` suffix to get out of the way of type
  names that are primary (though most of these we expect to be
  obsoleted by Swift 3 language features).

* The concept of `generator` is renamed to `iterator` across all APIs.

* `IndexingGenerator` is renamed to `DefaultCollectionIterator`.

* The type `Bit`, which was only used as the index for `CollectionOfOne`, was
  removed.  We recommend using `Int` instead.

* The generic parameter name in unsafe pointer types was renamed from `Memory`
  to `Pointee`.

* No-argument initializers were removed from unsafe pointer types.  We
  recommend using the `nil` literal instead.

* `PermutationGenerator` was removed.

* `MutableSliceable` was removed.  Use `CollectionType where SubSequence :
  MutableCollectionType` instead.

* `sort()` => `sorted()`, `sortInPlace()` => `sort()`.

**More changes will be summarized here as they are implemented.**

## API diffs

Differences between Swift 2.2 Standard library API and the proposed API are
added to this section as they are being implemented on the
[swift-3-api-guidelines branch][swift-3-api-guidelines-branch].

For repetitive changes that affect many types, only one representative instance
is shown in the diff.  For example, `generate()` was renamed to `iterator()`.
We only show the diff for the protocol requirement, and all other renames of
this method are implied.

* Strip `Type` suffix from protocol names.

```diff
-public protocol CollectionType : ... { ... }
+public protocol Collection : ... { ... }

-public protocol MutableCollectionType : ... { ... }
+public protocol MutableCollection : ... { ... }

-protocol RangeReplaceableCollectionType : ... { ... }
+protocol RangeReplaceableCollection : ... { ... }
```

* The concept of `generator` is renamed to `iterator` across all APIs.

```diff
 public protocol Collection : ... {
-  typealias Generator : GeneratorType = IndexingGenerator<Self>
+  typealias Iterator : IteratorProtocol = DefaultCollectionIterator<Self>

-  func generate() -> Generator
+  func iterator() -> Iterator
 }

-public struct IndexingGenerator<Elements : Indexable> : ... { ... }
+public struct DefaultCollectionIterator<Elements : Indexable> : ... { ... }
```

* The type `Bit`, which was only used as the index for `CollectionOfOne`, was
  removed.  We recommend using `Int` instead.

```diff
-public enum Bit : ... { ... }
```

* `PermutationGenerator` was removed.

```diff
-public struct PermutationGenerator<
-  C : CollectionType, Indices: SequenceType
-  where C.Index == Indices.Generator.Element
-> : ... { ... }
```

* `MutableSliceable` was removed.  Use `CollectionType where SubSequence :
  MutableCollectionType` instead.

```diff
-public protocol MutableSliceable : CollectionType, MutableCollectionType {
-  subscript(_: Range<Index>) -> SubSequence { get set }
-}
```

* The generic parameter name in unsafe pointer types was renamed from `Memory`
  to `Pointee`.

* No-argument initializers were removed from unsafe pointer types.  We
  recommend using the `nil` literal instead.

```diff
 public struct AutoreleasingUnsafeMutablePointer<
-  Memory
+  Pointee
 > ... : {

-  public var memory: Memory
+  public var pointee: Pointee

   // Use `nil` instead.
-  public init()

 }

-public func unsafeUnwrap<T>(nonEmpty: T?) -> T
 extension Optional {
+  public var unsafelyUnwrapped: Wrapped { get }
 }

-public struct COpaquePointer : ... {
+public struct OpaquePointer : ... {

   // Use `nil` instead.
-  public init()

}

```

* `sort()` => `sorted()`, `sortInPlace()` => `sort()`.

```diff
extension Sequence where Self.Generator.Element : Comparable {
  @warn_unused_result
-  public func sort() -> [Generator.Element]
+  public func sorted() -> [Generator.Element]
}

extension Sequence {
  @warn_unused_result
-  public func sort(
+  public func sorted(
    @noescape isOrderedBefore: (Generator.Element, Generator.Element) -> Bool
  ) -> [Generator.Element]
}

extension MutableCollection where Self.Generator.Element : Comparable {
  @warn_unused_result(mutable_variant="sort")
-  public func sort() -> [Generator.Element]
+  public func sorted() -> [Generator.Element]
}

extension MutableCollection {
  @warn_unused_result(mutable_variant="sort")
-  public func sort(
+  public func sorted(
    @noescape isOrderedBefore: (Generator.Element, Generator.Element) -> Bool
  ) -> [Generator.Element]
}

 extension MutableCollection
   where
   Self.Index : RandomAccessIndex,
   Self.Generator.Element : Comparable {

-  public mutating func sortInPlace()
+  public mutating func sort()

 }

 extension MutableCollection where Self.Index : RandomAccessIndex {
-  public mutating func sortInPlace(
+  public mutating func sort(
     @noescape isOrderedBefore: (Generator.Element, Generator.Element) -> Bool
   )
 }
```

* Miscellaneous changes.

```diff
-public struct EnumerateGenerator<Base : GeneratorType> : ... {
+public struct EnumeratedIterator<Base : IteratorProtocol> : ... {

-  public typealias Element = (index: Int, element: Base.Element)
+  public typealias Element = (offset: Int, element: Base.Element)

 }

 public struct Array<Element> : ... {
   // Same changes were also applied to `ArraySlice` and `ContiguousArray`.

-  public init(count: Int, repeatedValue: Element)
+  public init(repeating: Element, count: Int)

 }

 public protocol Collection : ... {
-  public func underestimateCount() -> Int
+  public var underestimatedCount: Int

   @warn_unused_result
   public func split(
-    maxSplit: Int = Int.max,
+    maxSplits: Int = Int.max,
-    allowEmptySlices: Bool = false,
+    omitEmptySubsequences: Bool = true,
     @noescape isSeparator: (Generator.Element) throws -> Bool
   ) rethrows -> [SubSequence]
 }

 // Changes to this protocol affect `Array`, `ArraySlice`, `ContiguousArray` and
 // other types.
 protocol RangeReplaceableCollection : ... {

-  public mutating func insert(newElement: Element, atIndex i: Int)
+  public mutating func insert(newElement: Element, at i: Int)

-  public mutating func removeAtIndex(index: Int) -> Element
+  public mutating func removeAt(index: Int) -> Element

-  public mutating func removeAll(keepCapacity keepCapacity: Bool = false)
+  public mutating func removeAll(keepingCapacity keepingCapacity: Bool = false)

-  public mutating func replaceRange<
+  public mutating func replaceSubrange<
     C : CollectionType where C.Generator.Element == _Buffer.Element
   >(
     subRange: Range<Int>, with newElements: C
   )
 }
```

## Impact on existing code

The proposed changes are massively source-breaking for Swift code, and will
require a migrator to translate Swift 2 code into Swift 3 code.  The API diffs
from this proposal will be the primary source of the information about the
required transformations.  In addition, to the extent the language allows, the
library will keep old names as unavailable symbols with a `renamed` annotation,
that allows the compiler to produce good error messages and emit Fix-Its.

[api-design-guidelines]: https://swift.org/documentation/api-design-guidelines.html  "API Design Guidelines"
[swift-repo]: https://github.com/apple/swift  "Swift repository"
[swift-3-api-guidelines-branch]: https://github.com/apple/swift/tree/swift-3-api-guidelines  "Swift 3 API Design Guidelines preview"

