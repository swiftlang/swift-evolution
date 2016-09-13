# Apply API Guidelines to the Standard Library

* Proposal: [SE-0006](0006-apply-api-guidelines-to-the-standard-library.md)
* Authors: [Dave Abrahams](https://github.com/dabrahams), [Dmitri Gribenko](https://github.com/gribozavr), [Maxim Moiseev](https://github.com/moiseev)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000054.html)

## Reviewer notes

This review is part of a group of three related reviews, running
concurrently:

* [SE-0023 API Design Guidelines](0023-api-guidelines.md)
  ([Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/007353.html))
* [SE-0006 Apply API Guidelines to the Standard Library](0006-apply-api-guidelines-to-the-standard-library.md)
  ([Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/007354.html))
* [SE-0005 Better Translation of Objective-C APIs Into Swift](0005-objective-c-name-translation.md)
  ([Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/007355.html))

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

* The type `Bit`, which was only used as the index for `CollectionOfOne`, was
  removed.  We recommend using `Int` instead.

* The generic parameter name in unsafe pointer types was renamed from `Memory`
  to `Pointee`.

* No-argument initializers were removed from unsafe pointer types.  We
  recommend using the `nil` literal instead.

* `PermutationGenerator` was removed.

* `MutableSliceable` was removed.  Use `Collection where SubSequence :
  MutableCollection` instead.

* `sort()` => `sorted()`, `sortInPlace()` => `sort()`.

* `reverse()` => `reversed()`.

* `enumerate()` => `enumerated()`.

* `partition()` API was simplified.  It composes better with collection slicing
  now.

* `SequenceType.minElement()` => `.min()`, `.maxElement()` => `.max()`.

* Some initializers for sequence and collection adapters were removed.  We
  suggest calling the corresponding algorithm function or method instead.

* Some functions were changed into properties and vice versa.

* `String` factory methods dealing with nul-terminated UTF-8 data (a.k.a.
  C-strings) became initializers.

## API diffs

Differences between Swift 2.2 Standard library API and the proposed API are
added to this section as they are being implemented on the
[swift-3-api-guidelines branch][swift-3-api-guidelines-branch].

For repetitive changes that affect many types, only one representative instance
is shown in the diff.  For example, `generate()` was renamed to
`makeIterator()`.  We only show the diff for the protocol requirement, and all
other renames of this method are implied.  If a type was renamed, we show only
the diff for the type declaration, all other effects on the API where the name
is used are implied.

* Strip `Type` suffix from protocol names.

```diff
-public protocol BooleanType { ... }
+public protocol Boolean { ... }

-public protocol SequenceType { ... }
+public protocol Sequence { ... }

-public protocol CollectionType : ... { ... }
+public protocol Collection : ... { ... }

-public protocol MutableCollectionType : ... { ... }
+public protocol MutableCollection : ... { ... }

-public protocol RangeReplaceableCollectionType : ... { ... }
+public protocol RangeReplaceableCollection : ... { ... }

-public protocol AnyCollectionType : ... { ... }
+public protocol AnyCollectionProtocol : ... { ... }

-public protocol IntegerType : ... { ... }
+public protocol Integer : ... { ... }

-public protocol SignedIntegerType : ... { ... }
+public protocol SignedInteger : ... { ... }

-public protocol UnsignedIntegerType : ... { ... }
+public protocol UnsignedInteger : ... { ... }

-public protocol FloatingPointType : ... { ... }
+public protocol FloatingPoint : ... { ... }

-public protocol ForwardIndexType { ... }
+public protocol ForwardIndex { ... }

-public protocol BidirectionalIndexType : ... { ... }
+public protocol BidirectionalIndex : ... { ... }

-public protocol RandomAccessIndexType : ... { ... }
+public protocol RandomAccessIndex : ... { ... }

-public protocol IntegerArithmeticType : ... { ... }
+public protocol IntegerArithmetic : ... { ... }

-public protocol SignedNumberType : ... { ... }
+public protocol SignedNumber : ... { ... }

-public protocol IntervalType : ... { ... }
+public protocol Interval : ... { ... }

-public protocol LazyCollectionType : ... { ... }
+public protocol LazyCollectionProtocol : ... { ... }

-public protocol LazySequenceType : ... { ... }
+public protocol LazySequenceProtocol : ... { ... }

-public protocol OptionSetType : ... { ... }
+public protocol OptionSet : ... { ... }

-public protocol OutputStreamType : ... { ... }
+public protocol OutputStream : ... { ... }

-public protocol BitwiseOperationsType { ... }
+public protocol BitwiseOperations { ... }

-public protocol ReverseIndexType : ... { ... }
+public protocol ReverseIndexProtocol : ... { ... }

-public protocol SetAlgebraType : ... { ... }
+public protocol SetAlgebra : ... { ... }

-public protocol UnicodeCodecType { ... }
+public protocol UnicodeCodec { ... }

-public protocol CVarArgType { ... }
+public protocol CVarArg { ... }

-public protocol MirrorPathType { ... }
+public protocol MirrorPath { ... }

-public protocol ErrorType { ... }
+public protocol ErrorProtocol { ... }
```

* The concept of "generator" is renamed to "iterator" across all APIs.

```diff
-public protocol GeneratorType { ... }
+public protocol IteratorProtocol { ... }

 public protocol Collection : ... {
-  associatedtype Generator : GeneratorType = IndexingGenerator<Self>
+  associatedtype Iterator : IteratorProtocol = IndexingIterator<Self>

-  func generate() -> Generator
+  func makeIterator() -> Iterator
 }

-public struct IndexingGenerator<Elements : Indexable> : ... { ... }
+public struct IndexingIterator<Elements : Indexable> : ... { ... }

-public struct GeneratorOfOne<Element> : ... { ... }
+public struct IteratorOverOne<Element> : ... { ... }

-public struct EmptyGenerator<Element> : ... { ... }
+public struct EmptyIterator<Element> : ... { ... }

-public struct AnyGenerator<Element> : ... { ... }
+public struct AnyIterator<Element> : ... { ... }

-public struct LazyFilterGenerator<Base : GeneratorType> : ... { ... }
+public struct LazyFilterIterator<Base : IteratorProtocol> : ... { ... }

-public struct FlattenGenerator<Base : ...> : ... { ... }
+public struct FlattenIterator<Base : ...> : ... { ... }

-public struct JoinGenerator<Base : ...> : ... { ... }
+public struct JoinedIterator<Base : ...> : ... { ... }

-public struct LazyMapGenerator<Base : ...> ... { ... }
+public struct LazyMapIterator<Base : ...> ... { ... }

-public struct RangeGenerator<Element : ForwardIndexType> : ... { ... }
+public struct RangeIterator<Element : ForwardIndex> : ... { ... }

-public struct GeneratorSequence<Base : GeneratorType> : ... { ... }
+public struct IteratorSequence<Base : IteratorProtocol> : ... { ... }

-public struct StrideToGenerator<Element : Strideable> : ... { ... }
+public struct StrideToIterator<Element : Strideable> : ... { ... }

-public struct StrideThroughGenerator<Element : Strideable> : ... { ... }
+public struct StrideThroughIterator<Element : Strideable> : ... { ... }

-public struct UnsafeBufferPointerGenerator<Element> : ... { ... }
+public struct UnsafeBufferPointerIterator<Element> : ... { ... }
```

* The type `Bit`, which was only used as the index for `CollectionOfOne`, was
  removed.  We recommend using `Int` instead.

```diff
-public enum Bit : ... { ... }
```

* `PermutationGenerator` was removed.

```diff
-public struct PermutationGenerator<
-  C : CollectionType, Indices : SequenceType
-  where C.Index == Indices.Generator.Element
-> : ... { ... }
```

* `MutableSliceable` was removed.  Use `Collection where SubSequence :
  MutableCollection` instead.

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
 // The same changes applied to `UnsafePointer`, `UnsafeMutablePointer` and
 // `AutoreleasingUnsafeMutablePointer`.
 public struct UnsafePointer<
-  Memory
+  Pointee
 > ... : {
-  public var memory: Memory { get set }
+  public var pointee: Pointee { get set }

   // Use `nil` instead.
-  public init()
 }

public struct OpaquePointer : ... {
   // Use `nil` instead.
-  public init()
}
```

* `sort()` => `sorted()`, `sortInPlace()` => `sort()`.  We also added argument
  labels to closures.

```diff
 extension Sequence where Self.Iterator.Element : Comparable {
   @warn_unused_result
-  public func sort() -> [Generator.Element]
+  public func sorted() -> [Iterator.Element]
 }

 extension Sequence {
   @warn_unused_result
-  public func sort(
+  public func sorted(
-    @noescape                 isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
+    @noescape isOrderedBefore isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
   ) -> [Iterator.Element]
 }

 extension MutableCollection where Self.Iterator.Element : Comparable {
   @warn_unused_result(mutable_variant="sort")
-  public func sort() -> [Generator.Element]
+  public func sorted() -> [Iterator.Element]
 }

 extension MutableCollection {
   @warn_unused_result(mutable_variant="sort")
-  public func sort(
+  public func sorted(
-   @noescape                 isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
+   @noescape isOrderedBefore isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
   ) -> [Iterator.Element]
 }

 extension MutableCollection
   where
   Self.Index : RandomAccessIndex,
   Self.Iterator.Element : Comparable {

-  public mutating func sortInPlace()
+  public mutating func sort()

 }

 extension MutableCollection where Self.Index : RandomAccessIndex {
-  public mutating func sortInPlace(
+  public mutating func sort(
-    @noescape                 isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
+    @noescape isOrderedBefore isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
   )
 }
```

* `reverse()` => `reversed()`.

```diff
 extension SequenceType {
-  public func reverse() -> [Generator.Element]
+  public func reversed() -> [Iterator.Element]
 }

 extension CollectionType where Index : BidirectionalIndexType {
-  public func reverse() -> ReverseCollection<Self>
+  public func reversed() -> ReverseCollection<Self>
 }

 extension CollectionType where Index : RandomAccessIndexType {
-  public func reverse() -> ReverseRandomAccessCollection<Self>
+  public func reversed() -> ReverseRandomAccessCollection<Self>
 }

 extension LazyCollectionProtocol
   where Index : BidirectionalIndexType, Elements.Index : BidirectionalIndexType {

-  public func reverse()
+  public func reversed()
     -> LazyCollection<ReverseCollection<Elements>>
 }

 extension LazyCollectionProtocol
   where Index : RandomAccessIndexType, Elements.Index : RandomAccessIndexType {

-  public func reverse()
+  public func reversed()
     -> LazyCollection<ReverseRandomAccessCollection<Elements>>
 }
```

* `enumerate()` => `enumerated()`.

```diff
 extension Sequence {
-  public func enumerate() -> EnumerateSequence<Self>
+  public func enumerated() -> EnumeratedSequence<Self>
 }

-public struct EnumerateSequence<Base : SequenceType> : ... { ... }
+public struct EnumeratedSequence<Base : Sequence> : ... { ... }

-public struct EnumerateGenerator<Base : GeneratorType> : ... { ... }
+public struct EnumeratedIterator<Base : IteratorProtocol> : ... { ... }
```

* `partition()` API was simplified: the range argument was removed.  It
  composes better with collection slicing now, and is more uniform with other
  collection algorithms.  We also added `@noescape` and an argument label to
  the closure.

```diff
 extension MutableCollection where Index : RandomAccessIndex {
   public mutating func partition(
-    range: Range<Index>,
-                              isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
+    @noescape isOrderedBefore isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
   ) -> Index
 }

 extension MutableCollection
   where Index : RandomAccessIndex, Iterator.Element : Comparable {

-  public mutating func partition(range: Range<Index>) -> Index
+  public mutating func partition() -> Index
}
```

* `SequenceType.minElement()` => `.min()`, `.maxElement()` => `.max()`.  We
  also added argument labels to closures.

```diff
 extension Sequence {
-  public func minElement(
+  public func min(
-    @noescape                 isOrderedBefore: (Iterator.Element, Iterator.Element) throws -> Bool
+    @noescape isOrderedBefore isOrderedBefore: (Iterator.Element, Iterator.Element) throws -> Bool
   ) rethrows -> Iterator.Element?

-  public func maxElement(
+  public func max(
-    @noescape                 isOrderedBefore: (Iterator.Element, Iterator.Element) throws -> Bool
+    @noescape isOrderedBefore isOrderedBefore: (Iterator.Element, Iterator.Element) throws -> Bool
   ) rethrows -> Iterator.Element?
 }

 extension Sequence where Iterator.Element : Comparable {
-  public func minElement() -> Iterator.Element?
+  public func min() -> Iterator.Element?

-  public func maxElement() -> Iterator.Element?
+  public func max() -> Iterator.Element?
 }
```

* Some initializers for sequence, collection and iterator adapters were
  removed.  We suggest calling the corresponding algorithm function or
  method instead.

```diff
 extension Repeated {
-  public init(count: Int, repeatedValue: Element)
 }
+/// Return a collection containing `n` repetitions of `elementInstance`.
+public func repeatElement<T>(element: T, count n: Int) -> Repeated<T>

 public struct LazyMapSequence<Base : Sequence, Element> : ... {
   // Call `.lazy.map` on the sequence instead.
-  public init(_ base: Base, transform: (Base.Generator.Element) -> Element)
 }

 public struct LazyMapCollection<Base : Collection, Element> : ... {
   // Call `.lazy.map` on the collection instead.
-  public init(_ base: Base, transform: (Base.Generator.Element) -> Element)
 }

 public struct LazyFilterIterator<Base : IteratorProtocol> : ... {
   // Call `.lazy.filter` on the sequence instead.
-  public init(
-    _ base: Base,
-    whereElementsSatisfy predicate: (Base.Element) -> Bool
-  )
 }

 public struct RangeIterator<Element : ForwardIndex> : ... {
   // Use the 'generate()' method on the collection instead.
-  public init(_ bounds: Range<Element>)

   // Use the '..<' operator.
-  public init(start: Element, end: Element)
 }

 public struct ReverseCollection<Base : ...> : ... {
   // Use the 'reverse()' method on the collection.
-  public init(_ base: Base)
 }

 public struct ReverseRandomAccessCollection<Base : ...> : ... {
   // Use the 'reverse()' method on the collection.
-  public init(_ base: Base)
 }

 public struct Slice<Base : Indexable> : ... {
   // Use the slicing syntax.
-  public init(base: Base, bounds: Range<Index>)
 }

 public struct MutableSlice<Base : MutableIndexable> : ... {
   // Use the slicing syntax.
-  public init(base: Base, bounds: Range<Index>)
 }

 public struct EnumeratedIterator<Base : IteratorProtocol> : ... {
   // Use the 'enumerated()' method.
-  public init(_ base: Base)
 }

 public struct EnumeratedSequence<Base : IteratorProtocol> : ... {
   // Use the 'enumerated()' method.
-  public init(_ base: Base)
 }

 public struct IndexingIterator<Elements : Indexable> : ... {
   // Call 'iterator()' on the collection instead.
-  public init(_elements: Elements)
 }

 public struct HalfOpenInterval<Bound : Comparable> : ... {
   // Use the '..<' operator.
-  public init(_ start: Bound, _ end: Bound)
 }

 public struct ClosedInterval<Bound : Comparable> : ... {
   // Use the '...' operator.
-  public init(_ start: Bound, _ end: Bound)
 }
```

* Some functions were changed into properties and vice versa.

```diff
-public func unsafeUnwrap<T>(nonEmpty: T?) -> T
 extension Optional {
+  public var unsafelyUnwrapped: Wrapped { get }
 }

 public struct Mirror {
-  public func superclassMirror() -> Mirror?
+  public var superclassMirror: Mirror? { get }
 }

 public protocol CustomReflectable {
-  func customMirror() -> Mirror
+  var customMirror: Mirror { get }
 }

 public protocol Collection : ... {
-  public func underestimateCount() -> Int
+  public var underestimatedCount: Int { get }
 }

 public protocol CustomPlaygroundQuickLookable {
-  func customPlaygroundQuickLook() -> PlaygroundQuickLook
+  var customPlaygroundQuickLook: PlaygroundQuickLook { get }
 }

 extension String {
-  public var lowercaseString: String { get }
+  public func lowercased()

-  public var uppercaseString: String { get }
+  public func uppercased()
 }

 public enum UnicodeDecodingResult {
-  public func isEmptyInput() -> Bool {
+  public var isEmptyInput: Bool
 }

```

* Base names and argument labels were changed to follow guidelines about first
  argument labels.  (Some changes in this category are already specified
  elsewhere in the diff and are not repeated.)

```diff
 public protocol ForwardIndex {
-  func advancedBy(n: Distance) -> Self
+  func advanced(by n: Distance) -> Self

-  func advancedBy(n: Distance, limit: Self) -> Self
+  func advanced(by n: Distance, limit: Self) -> Self

-  func distanceTo(end: Self) -> Distance
+  func distance(to end: Self) -> Distance
 }

 public struct Set<Element : Hashable> : ... {
-  public mutating func removeAtIndex(index: Index) -> Element
+  public mutating func remove(at index: Index) -> Element
 }

 public struct Dictionary<Key : Hashable, Value> : ... {
-  public mutating func removeAtIndex(index: Index) -> Element
+  public mutating func remove(at index: Index) -> Element

-  public func indexForKey(key: Key) -> Index?
+  public func index(forKey key: Key) -> Index?

-  public mutating func removeValueForKey(key: Key) -> Value?
+  public mutating func removeValue(forKey key: Key) -> Value?
 }

 extension Sequence where Iterator.Element : Sequence {
   // joinWithSeparator(_:) => join(separator:)
-  public func joinWithSeparator<
+  public func joined<
     Separator : Sequence
     where
     Separator.Iterator.Element == Iterator.Element.Iterator.Element
-  >(separator: Separator) -> JoinSequence<Self>
+  >(separator separator: Separator) -> JoinedSequence<Self>
 }

 extension Sequence where Iterator.Element == String {
-  public func joinWithSeparator(separator: String) -> String
+  public func joined(separator separator: String) -> String
 }

 public class ManagedBuffer<Value, Element> : ... {
   public final class func create(
-    minimumCapacity: Int,
+    minimumCapacity minimumCapacity: Int,
     initialValue: (ManagedProtoBuffer<Value, Element>) -> Value
   ) -> ManagedBuffer<Value, Element>
 }

 public protocol Streamable {
-  func writeTo<Target : OutputStream>(inout target: Target)
+  func write<Target : OutputStream>(inout to target: Target)
 }

 public func dump<T, TargetStream : OutputStream>(
   value: T,
-  inout _ target: TargetStream,
+  inout to target: TargetStream,
   name: String? = nil,
   indent: Int = 0,
   maxDepth: Int = .max,
   maxItems: Int = .max
 ) -> T

 extension Sequence {
-  public func startsWith<
+  public func starts<
     PossiblePrefix : Sequence where PossiblePrefix.Iterator.Element == Iterator.Element
   >(
-    possiblePrefix: PossiblePrefix,
+    with possiblePrefix: PossiblePrefix,
     @noescape isEquivalent: (Iterator.Element, Iterator.Element) throws -> Bool
   ) rethrows -> Bool

-  public func startsWith<
+  public func starts<
     PossiblePrefix : Sequence where PossiblePrefix.Iterator.Element == Iterator.Element
   >(
-    possiblePrefix: PossiblePrefix
+    with possiblePrefix: PossiblePrefix
   ) -> Bool
 }

 extension CollectionType where Iterator.Element : Equatable {
-  public func indexOf(element: Iterator.Element) -> Index?
+  public func index(of element: Iterator.Element) -> Index?
 }

 extension CollectionType {
-  public func indexOf(predicate: (Iterator.Element) throws -> Bool) rethrows -> Index?
+  public func index(where predicate: (Iterator.Element) throws -> Bool) rethrows -> Index?
 }

 extension String.Index {
-  public func samePositionIn(utf8: String.UTF8View) -> String.UTF8View.Index
+  public func samePosition(in utf8: String.UTF8View) -> String.UTF8View.Index

-  public func samePositionIn(utf16: String.UTF16View) -> String.UTF16View.Index
+  public func samePosition(in utf16: String.UTF16View) -> String.UTF16View.Index

-  public func samePositionIn(unicodeScalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index
+  public func samePosition(in unicodeScalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index
 }

 extension String.UTF16View.Index {
-  public func samePositionIn(characters: String) -> String.Index
+  public func samePosition(in characters: String) -> String.Index

-  public func samePositionIn(utf8: String.UTF8View) -> String.UTF8View.Index
+  public func samePosition(in utf8: String.UTF8View) -> String.UTF8View.Index

-  public func samePositionIn(unicodeScalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index
+  public func samePosition(in unicodeScalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index
 }

 extension String.UTF8View.Index {
-  public func samePositionIn(characters: String) -> String.Index
+  public func samePosition(in characters: String) -> String.Index

-  public func samePositionIn(utf16: String.UTF16View) -> String.UTF16View.Index
+  public func samePosition(in utf16: String.UTF16View) -> String.UTF16View.Index

-  public func samePositionIn(unicodeScalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index
+  public func samePosition(in unicodeScalars: String.UnicodeScalarView) -> String.UnicodeScalarView.Index
 }

 extension String.UnicodeScalarView.Index {
-  public func samePositionIn(characters: String) -> String.Index
+  public func samePosition(in characters: String) -> String.Index

-  public func samePositionIn(utf16: String.UTF16View) -> String.UTF16View.Index
+  public func samePosition(in utf16: String.UTF16View) -> String.UTF16View.Index

-  public func samePositionIn(utf16: String.UTF16View) -> String.UTF16View.Index
+  public func samePosition(in utf16: String.UTF16View) -> String.UTF16View.Index
 }
```

* Lowercase enum cases and static properties.

```diff
 public struct Float {
-  public static var NaN: Float
+  public static var nan: Float
 }

 public struct Double {
-  public static var NaN: Double
+  public static var nan: Double

 public struct CGFloat {
-  public static var NaN: CGFloat
+  public static var nan: CGFloat
 }

 public protocol FloatingPoint : ... {
-  static var NaN: Self { get }
+  static var nan: Self { get }
 }

 public enum FloatingPointClassification {
-  case SignalingNaN
+  case signalingNaN

-  case QuietNaN
+  case quietNaN

-  case NegativeInfinity
+  case negativeInfinity

-  case NegativeNormal
+  case negativeNormal

-  case NegativeSubnormal
+  case negativeSubnormal

-  case NegativeZero
+  case negativeZero

-  case PositiveZero
+  case positiveZero

-  case PositiveSubnormal
+  case positiveSubnormal

-  case PositiveNormal
+  case positiveNormal

-  case PositiveInfinity
+  case positiveInfinity
 }

 public enum ImplicitlyUnwrappedOptional<Wrapped> : ... {
-  case None
+  case none

-  case Some(Wrapped)
+  case some(Wrapped)
 }

 public enum Optional<Wrapped> : ... {
-  case None
+  case none

-  case Some(Wrapped)
+  case some(Wrapped)
 }

 public struct Mirror {
   public enum AncestorRepresentation {
-    case Generated
+    case generated

-    case Customized(() -> Mirror)
+    case customized(() -> Mirror)

-    case Suppressed
+    case suppressed
   }

   public enum DisplayStyle {
-    case struct, class, enum, tuple, optional, collection
+    case `struct`, `class`, `enum`, tuple, optional, collection

-    case dictionary, `set`
+    case dictionary, `set`
   }
 }

 public enum PlaygroundQuickLook {
-  case Text(String)
+  case text(String)

-  case Int(Int64)
+  case int(Int64)

-  case UInt(UInt64)
+  case uInt(UInt64)

-  case Float(Float32)
+  case float(Float32)

-  case Double(Float64)
+  case double(Float64)

-  case Image(Any)
+  case image(Any)

-  case Sound(Any)
+  case sound(Any)

-  case Color(Any)
+  case color(Any)

-  case BezierPath(Any)
+  case bezierPath(Any)

-  case AttributedString(Any)
+  case attributedString(Any)

-  case Rectangle(Float64,Float64,Float64,Float64)
+  case rectangle(Float64,Float64,Float64,Float64)

-  case Point(Float64,Float64)
+  case point(Float64,Float64)

-  case Size(Float64,Float64)
+  case size(Float64,Float64)

-  case Logical(Bool)
+  case bool(Bool)

-  case Range(Int64, Int64)
+  case range(Int64, Int64)

-  case View(Any)
+  case view(Any)

-  case Sprite(Any)
+  case sprite(Any)

-  case URL(String)
+  case url(String)

-  case _Raw([UInt8], String)
+  case _raw([UInt8], String)
 }
```

* `String` factory methods dealing with nul-terminated UTF-8 data (a.k.a.
  C-strings) became initializers.

```diff
 extension String {
-  public static func fromCString(cs: UnsafePointer<CChar>) -> String?
+  public init?(validatingUTF8 cString: UnsafePointer<CChar>)

-  public static func fromCStringRepairingIllFormedUTF8(cs: UnsafePointer<CChar>) -> (String?, hadError: Bool)
+  public init(cString: UnsafePointer<CChar>)
+  public static func decodeCString<Encoding : UnicodeCodec>(
+    cString: UnsafePointer<Encoding.CodeUnit>,
+    as encoding: Encoding.Type,
+    repairingInvalidCodeUnits isReparing: Bool = true)
+      -> (result: String, repairsMade: Bool)?
 }
```

* `String` methods that mirror imported methods on NSString are renamed to reflect the new importing rules.

```diff
 extension String {
-  public static func localizedNameOfStringEncoding(
-    encoding: NSStringEncoding
-  ) -> String
+  public static func localizedName(
+    ofStringEncoding encoding: NSStringEncoding
+  ) -> String
 
-  public static func pathWithComponents(components: [String]) -> String
+  public static func path(withComponents components: [String]) -> String
 
-  public init?(UTF8String bytes: UnsafePointer<CChar>)
+  public init?(utf8String bytes: UnsafePointer<CChar>)

-  public func canBeConvertedToEncoding(encoding: NSStringEncoding) -> Bool
+  public func canBeConverted(toEncoding encoding: NSStringEncoding) -> Bool
 
-  public var capitalizedString: String
+  public var capitalized: String
 
-  public var localizedCapitalizedString: String
+  public var localizedCapitalized: String
 
-  public func capitalizedStringWithLocale(locale: NSLocale?) -> String
+  public func capitalized(with locale: NSLocale?) -> String
 
-  public func commonPrefixWithString(
-    aString: String, options: NSStringCompareOptions) -> String
+  public func commonPrefix(
+    with aString: String, options: NSStringCompareOptions = []) -> String
 
-  public func completePathIntoString(
-    outputName: UnsafeMutablePointer<String> = nil,
-    caseSensitive: Bool,
-    matchesIntoArray: UnsafeMutablePointer<[String]> = nil,
-    filterTypes: [String]? = nil
-  ) -> Int
+  public func completePath(
+    into outputName: UnsafeMutablePointer<String> = nil,
+    caseSensitive: Bool,
+    matchesInto matchesIntoArray: UnsafeMutablePointer<[String]> = nil,
+    filterTypes: [String]? = nil
+  ) -> Int

-  public func componentsSeparatedByCharactersInSet(
-    separator: NSCharacterSet
-  ) -> [String]
+  public func componentsSeparatedByCharacters(
+    in separator: NSCharacterSet
+  ) -> [String]
 
-  public func componentsSeparatedByString(separator: String) -> [String]
+  public func componentsSeparated(by separator: String) -> [String]

-  public func cStringUsingEncoding(encoding: NSStringEncoding) -> [CChar]?
+  public func cString(usingEncoding encoding: NSStringEncoding) -> [CChar]?
 
-  public func dataUsingEncoding(
-    encoding: NSStringEncoding,
-    allowLossyConversion: Bool = false
-  ) -> NSData?
+  public func data(
+    usingEncoding encoding: NSStringEncoding,
+    allowLossyConversion: Bool = false
+  ) -> NSData?
 
-  public func enumerateLinguisticTagsInRange(
-    range: Range<Index>,
-    scheme tagScheme: String,
-    options opts: NSLinguisticTaggerOptions,
-    orthography: NSOrthography?,
-    _ body:
-      (String, Range<Index>, Range<Index>, inout Bool) -> ()
-  )
+  public func enumerateLinguisticTags(
+    in range: Range<Index>,
+    scheme tagScheme: String,
+    options opts: NSLinguisticTaggerOptions = [],
+    orthography: NSOrthography? = nil,
+    _ body:
+      (String, Range<Index>, Range<Index>, inout Bool) -> ()
+  )

-  public func enumerateSubstringsInRange(
-    range: Range<Index>,
-    options opts:NSStringEnumerationOptions,
-    _ body: (
-      substring: String?, substringRange: Range<Index>,
-      enclosingRange: Range<Index>, inout Bool
-    ) -> ()
-  )
+  public func enumerateSubstrings(
+    in range: Range<Index>,
+    options opts:NSStringEnumerationOptions = [],
+    _ body: (
+      substring: String?, substringRange: Range<Index>,
+      enclosingRange: Range<Index>, inout Bool
+    ) -> ()
+  )

-  public func fileSystemRepresentation() -> [CChar]
+  public var fileSystemRepresentation: [CChar]
 
-  public func getBytes(
-    inout buffer: [UInt8],
-    maxLength maxBufferCount: Int,
-    usedLength usedBufferCount: UnsafeMutablePointer<Int>,
-    encoding: NSStringEncoding,
-    options: NSStringEncodingConversionOptions,
-    range: Range<Index>,
-    remainingRange leftover: UnsafeMutablePointer<Range<Index>>
-  ) -> Bool
+  public func getBytes(
+    inout buffer: [UInt8],
+    maxLength maxBufferCount: Int,
+    usedLength usedBufferCount: UnsafeMutablePointer<Int>,
+    encoding: NSStringEncoding,
+    options: NSStringEncodingConversionOptions = [],
+    range: Range<Index>,
+    remaining leftover: UnsafeMutablePointer<Range<Index>>
+  ) -> Bool
 
-  public func getLineStart(
-    start: UnsafeMutablePointer<Index>,
-    end: UnsafeMutablePointer<Index>,
-    contentsEnd: UnsafeMutablePointer<Index>,
-    forRange: Range<Index>
-  )
+  public func getLineStart(
+    start: UnsafeMutablePointer<Index>,
+    end: UnsafeMutablePointer<Index>,
+    contentsEnd: UnsafeMutablePointer<Index>,
+    for range: Range<Index>
+  )

-  public func getParagraphStart(
-    start: UnsafeMutablePointer<Index>,
-    end: UnsafeMutablePointer<Index>,
-    contentsEnd: UnsafeMutablePointer<Index>,
-    forRange: Range<Index>
-  )
+  public func getParagraphStart(
+    start: UnsafeMutablePointer<Index>,
+    end: UnsafeMutablePointer<Index>,
+    contentsEnd: UnsafeMutablePointer<Index>,
+    for range: Range<Index>
+  )

   public init(
-    contentsOfURL url: NSURL,
+    contentsOf url: NSURL,
     encoding enc: NSStringEncoding
   ) throws
 
   public init(
-    contentsOfURL url: NSURL,
+    contentsOf url: NSURL,
     usedEncoding enc: UnsafeMutablePointer<NSStringEncoding> = nil
   ) throws
 
   public init?(
-    CString: UnsafePointer<CChar>,
+    cString: UnsafePointer<CChar>,
     encoding enc: NSStringEncoding
   )

-  public init(format: String, _ arguments: CVarArgType...)
+  public init(format: String, _ arguments: CVarArg...)

-  public init(format: String, arguments: [CVarArgType])
+  public init(format: String, arguments: [CVarArg])
 
-  public init(format: String, locale: NSLocale?, _ args: CVarArgType...)
+  public init(format: String, locale: NSLocale?, _ args: CVarArg...)
 
-  public init(format: String, locale: NSLocale?, arguments: [CVarArgType])
+  public init(format: String, locale: NSLocale?, arguments: [CVarArg])

-  public func lengthOfBytesUsingEncoding(encoding: NSStringEncoding) -> Int
+  public func lengthOfBytes(usingEncoding encoding: NSStringEncoding) -> Int
 
-  public func lineRangeForRange(aRange: Range<Index>) -> Range<Index>
+  public func lineRange(for aRange: Range<Index>) -> Range<Index>
 
-  public func linguisticTagsInRange(
-    range: Range<Index>,
-    scheme tagScheme: String,
-    options opts: NSLinguisticTaggerOptions = [],
-    orthography: NSOrthography? = nil,
-    tokenRanges: UnsafeMutablePointer<[Range<Index>]> = nil // FIXME:Can this be nil?
-  ) -> [String]
+  public func linguisticTags(
+    in range: Range<Index>,
+    scheme tagScheme: String,
+    options opts: NSLinguisticTaggerOptions = [],
+    orthography: NSOrthography? = nil,
+    tokenRanges: UnsafeMutablePointer<[Range<Index>]> = nil // FIXME:Can this be nil?
+  ) -> [String]

-  public var localizedLowercaseString: String
+  public var localizedLowercase: String
 
-  public func lowercaseStringWithLocale(locale: NSLocale?) -> String
+  public func lowercaseString(with locale: NSLocale?) -> String
 
-  func maximumLengthOfBytesUsingEncoding(encoding: NSStringEncoding) -> Int
+  func maximumLengthOfBytes(usingEncoding encoding: NSStringEncoding) -> Int
 
-  public func paragraphRangeForRange(aRange: Range<Index>) -> Range<Index>
+  public func paragraphRange(for aRange: Range<Index>) -> Range<Index>
 
-  public func rangeOfCharacterFromSet(
-    aSet: NSCharacterSet,
-    options mask:NSStringCompareOptions = [],
-    range aRange: Range<Index>? = nil
-  ) -> Range<Index>?
+  public func rangeOfCharacter(
+    from aSet: NSCharacterSet,
+    options mask:NSStringCompareOptions = [],
+    range aRange: Range<Index>? = nil
+  ) -> Range<Index>?
 
-  func rangeOfComposedCharacterSequenceAtIndex(anIndex: Index) -> Range<Index>
+  func rangeOfComposedCharacterSequence(at anIndex: Index) -> Range<Index>
 
-  public func rangeOfComposedCharacterSequencesForRange(
-    range: Range<Index>
-  ) -> Range<Index>
+  public func rangeOfComposedCharacterSequences(
+    for range: Range<Index>
+  ) -> Range<Index>
 
-  public func rangeOfString(
-    aString: String,
-    options mask: NSStringCompareOptions = [],
-    range searchRange: Range<Index>? = nil,
-    locale: NSLocale? = nil
-  ) -> Range<Index>?
+  public func range(
+    of aString: String,
+    options mask: NSStringCompareOptions = [],
+    range searchRange: Range<Index>? = nil,
+    locale: NSLocale? = nil
+  ) -> Range<Index>?
 
-  public func localizedStandardContainsString(string: String) -> Bool
+  public func localizedStandardContains(string: String) -> Bool
 
-  public func localizedStandardRangeOfString(string: String) -> Range<Index>?
+  public func localizedStandardRange(of string: String) -> Range<Index>?
 
-  public var stringByAbbreviatingWithTildeInPath: String
+  public var abbreviatingWithTildeInPath: String
 
-  public func stringByAddingPercentEncodingWithAllowedCharacters(
-    allowedCharacters: NSCharacterSet
-  ) -> String?
+  public func addingPercentEncoding(
+    withAllowedCharaters allowedCharacters: NSCharacterSet
+  ) -> String?

-  public func stringByAddingPercentEscapesUsingEncoding(
-    encoding: NSStringEncoding
-  ) -> String?
+  public func addingPercentEscapes(
+    usingEncoding encoding: NSStringEncoding
+  ) -> String?
 
-  public func stringByAppendingFormat(
-    format: String, _ arguments: CVarArgType...
-  ) -> String
+  public func appendingFormat(
+    format: String, _ arguments: CVarArg...
+  ) -> String
 
-  public func stringByAppendingPathComponent(aString: String) -> String
+  public func appendingPathComponent(aString: String) -> String
 
-  public func stringByAppendingPathExtension(ext: String) -> String?
+  public func appendingPathExtension(ext: String) -> String?
 
-  public func stringByAppendingString(aString: String) -> String
+  public func appending(aString: String) -> String
 
-  public var stringByDeletingLastPathComponent: String
+  public var deletingLastPathComponent: String
 
-  public var stringByDeletingPathExtension: String
+  public var deletingPathExtension: String
 
-  public var stringByExpandingTildeInPath: String
+  public var expandingTildeInPath: String
 
-  public func stringByFoldingWithOptions(
-    options: NSStringCompareOptions, locale: NSLocale?
-  ) -> String
+  public func folding(
+    options: NSStringCompareOptions = [], locale: NSLocale?
+  ) -> String
 
-  public func stringByPaddingToLength(
-    newLength: Int, withString padString: String, startingAtIndex padIndex: Int
-  ) -> String
+  public func padding(
+    toLength newLength: Int,
+    with padString: String,
+    startingAt padIndex: Int
+  ) -> String
 
-  public var stringByRemovingPercentEncoding: String?
+  public var removingPercentEncoding: String?

-  public func stringByReplacingCharactersInRange(
-    range: Range<Index>, withString replacement: String
-  ) -> String
+  public func replacingCharacters(
+    in range: Range<Index>, with replacement: String
+  ) -> String
 
-  public func stringByReplacingOccurrencesOfString(
-    target: String,
-    withString replacement: String,
-    options: NSStringCompareOptions = [],
-    range searchRange: Range<Index>? = nil
-  ) -> String
+  public func replacingOccurrences(
+    of target: String,
+    with replacement: String,
+    options: NSStringCompareOptions = [],
+    range searchRange: Range<Index>? = nil
+  ) -> String
 
-  public func stringByReplacingPercentEscapesUsingEncoding(
-    encoding: NSStringEncoding
-  ) -> String?
+  public func replacingPercentEscapes(
+    usingEncoding encoding: NSStringEncoding
+  ) -> String?
 
-  public var stringByResolvingSymlinksInPath: String
+  public var resolvingSymlinksInPath: String
 
-  public var stringByStandardizingPath: String
+  public var standardizingPath: String
 
-  public func stringByTrimmingCharactersInSet(set: NSCharacterSet) -> String
+  public func trimmingCharacters(in set: NSCharacterSet) -> String
 
-  public func stringsByAppendingPaths(paths: [String]) -> [String]
+  public func strings(byAppendingPaths paths: [String]) -> [String]
 
-  public func substringFromIndex(index: Index) -> String
+  public func substring(from index: Index) -> String
 
-  public func substringToIndex(index: Index) -> String
+  public func substring(to index: Index) -> String
 
-  public func substringWithRange(aRange: Range<Index>) -> String
+  public func substring(with aRange: Range<Index>) -> String
 
-  public var localizedUppercaseString: String
+  public var localizedUppercase: String
 
-  public func uppercaseStringWithLocale(locale: NSLocale?) -> String
+  public func uppercaseString(with locale: NSLocale?) -> String
 
-  public func writeToFile(
-    path: String, atomically useAuxiliaryFile:Bool,
-    encoding enc: NSStringEncoding
-  ) throws
+  public func write(
+    toFile path: String, atomically useAuxiliaryFile:Bool,
+    encoding enc: NSStringEncoding
+  ) throws
 
-  public func writeToURL(
-    url: NSURL, atomically useAuxiliaryFile: Bool,
-    encoding enc: NSStringEncoding
-  ) throws
+  public func write(
+    to url: NSURL, atomically useAuxiliaryFile: Bool,
+    encoding enc: NSStringEncoding
+  ) throws
 
-  public func stringByApplyingTransform(
-    transform: String, reverse: Bool
-  ) -> String?
+  public func applyingTransform(
+    transform: String, reverse: Bool
+  ) -> String?
 
-  public func containsString(other: String) -> Bool
+  public func contains(other: String) -> Bool

-  public func localizedCaseInsensitiveContainsString(other: String) -> Bool
+  public func localizedCaseInsensitiveContains(other: String) -> Bool
 }
```

* Miscellaneous changes.

```diff
 public struct EnumeratedIterator<Base : IteratorProtocol> : ... {
-  public typealias Element = (index: Int, element: Base.Element)
+  public typealias Element = (offset: Int, element: Base.Element)
 }

 public struct Array<Element> : ... {
   // Same changes were also applied to `ArraySlice` and `ContiguousArray`.

-  public init(count: Int, repeatedValue: Element)
+  public init(repeating: Element, count: Int)
 }

 public protocol Sequence : ... {
   public func split(
-    maxSplit: Int = Int.max,
+    maxSplits maxSplits: Int = Int.max,
-    allowEmptySlices: Bool = false,
+    omittingEmptySubsequences: Bool = true,
     @noescape isSeparator: (Iterator.Element) throws -> Bool
   ) rethrows -> [SubSequence]
 }

 extension Sequence where Iterator.Element : Equatable {
   public func split(
-    separator: Iterator.Element,
+    separator separator: Iterator.Element,
-    maxSplit: Int = Int.max,
+    maxSplits maxSplits: Int = Int.max,
-    allowEmptySlices: Bool = false
+    omittingEmptySubsequences: Bool = true
   ) -> [AnySequence<Iterator.Element>] {
 }


 public protocol Sequence : ... {
-  public func lexicographicalCompare<
+  public func lexicographicallyPrecedes<
     OtherSequence : Sequence where OtherSequence.Iterator.Element == Iterator.Element
   >(
     other: OtherSequence,
     @noescape isOrderedBefore: (Iterator.Element, Iterator.Element) throws -> Bool
   ) rethrows -> Bool {
 }

 extension Sequence where Iterator.Element : Equatable {
-  public func lexicographicalCompare<
+  public func lexicographicallyPrecedes<
     OtherSequence : Sequence where OtherSequence.Iterator.Element == Iterator.Element
   >(
     other: OtherSequence
   ) -> Bool {
 }

 public protocol Collection : ... {
-  func prefixUpTo(end: Index) -> SubSequence
+  func prefix(upTo end: Index) -> SubSequence

-  func suffixFrom(start: Index) -> SubSequence
+  func suffix(from start: Index) -> SubSequence

-  func prefixThrough(position: Index) -> SubSequence
+  func prefix(through position: Index) -> SubSequence
 }

 // Changes to this protocol affect `Array`, `ArraySlice`, `ContiguousArray` and
 // other types.
 public protocol RangeReplaceableCollection : ... {
+  public init(repeating repeatedValue: Iterator.Element, count: Int)

-  mutating func replaceRange<
+  mutating func replaceSubrange<
     C : CollectionType where C.Iterator.Element == Iterator.Element
   >(
     subRange: Range<Int>, with newElements: C
   )

-  mutating func insert(newElement: Iterator.Element, atIndex i: Int)
+  mutating func insert(newElement: Iterator.Element, at i: Int)

-  mutating func insertContentsOf<
+  mutating func insert<
     S : Collection where S.Iterator.Element == Iterator.Element
-  >(newElements: S, at i: Index)
+  >(contentsOf newElements: S, at i: Index)

-  mutating func removeAtIndex(index: Int) -> Element
+  mutating func remove(at index: Int) -> Element

-  mutating func removeAll(keepCapacity keepCapacity: Bool = false)
+  mutating func removeAll(keepingCapacity keepingCapacity: Bool = false)

-  mutating func removeRange(subRange: Range<Index>)
+  mutating func removeSubrange(subRange: Range<Index>)

-  mutating func appendContentsOf<S : SequenceType>(newElements: S)
+  mutating func append<S : SequenceType>(contentsOf newElements: S)
 }

+extension Set : SetAlgebra {}

 public struct Dictionary<Key : Hashable, Value> : ... {
-  public typealias Element = (Key, Value)
+  public typealias Element = (key: Key, value: Value)
 }

 public struct DictionaryLiteral<Key, Value> : ... {
-  public typealias Element = (Key, Value)
+  public typealias Element = (key: Key, value: Value)
 }

 extension String {
-  public mutating func appendContentsOf(other: String) {
+  public mutating func append(other: String) {

-  public mutating appendContentsOf<S : SequenceType>(newElements: S)
+  public mutating append<S : SequenceType>(contentsOf newElements: S)

-  public mutating func replaceRange<
+  public mutating func replaceSubrange<
     C: CollectionType where C.Iterator.Element == Character
   >(
     subRange: Range<Index>, with newElements: C
   )

-  public mutating func replaceRange(
+  public mutating func replaceSubrange(
     subRange: Range<Index>, with newElements: String
   )

-  public mutating func insert(newElement: Character, atIndex i: Index)
+  public mutating func insert(newElement: Character, at i: Index)

-  public mutating func insertContentsOf<
+  public mutating func insert<
     S : Collection where S.Iterator.Element == Character
-  >(newElements: S, at i: Index)
+  >(contentsOf newElements: S, at i: Index)

-  public mutating func removeAtIndex(i: Index) -> Character
+  public mutating func remove(at i: Index) -> Character

-  public mutating func removeRange(subRange: Range<Index>)
+  public mutating func removeSubrange(subRange: Range<Index>)

-  mutating func removeAll(keepCapacity keepCapacity: Bool = false)
+  mutating func removeAll(keepingCapacity keepingCapacity: Bool = false)

-  public init(count: Int, repeatedValue c: Character)
+  public init(repeating repeatedValue: Character, count: Int)

-  public init(count: Int, repeatedValue c: UnicodeScalar)
+  public init(repeating repeatedValue: UnicodeScalar, count: Int)

-  public var utf8: UTF8View { get }
+  public var utf8: UTF8View { get set }

-  public var utf16: UTF16View { get }
+  public var utf16: UTF16View { get set }

-  public var characters: CharacterView { get }
+  public var characters: CharacterView { get set }
 }

 public enum UnicodeDecodingResult {
-  case Result(UnicodeScalar)
-  case EmptyInput
-  case Error
+  case scalarValue(UnicodeScalar)
+  case emptyInput
+  case error
 }

 public struct ManagedBufferPointer<Value, Element> : ... {
-  public var allocatedElementCount: Int { get }
+  public var capacity: Int { get }
 }

 public struct RangeIterator<Element : ForwardIndex> : ... {
-  public var startIndex: Element { get set }
-  public var endIndex: Element { get set }
 }

 public struct ObjectIdentifier : ... {
-  public var uintValue: UInt { get }
 }
 extension UInt {
+  /// Create a `UInt` that captures the full value of `objectID`.
+  public init(_ objectID: ObjectIdentifier)
 }
 extension Int {
+  /// Create an `Int` that captures the full value of `objectID`.
+  public init(_ objectID: ObjectIdentifier)
 }

-public struct Repeat<Element> : ... { ... }
+public struct Repeated<Element> : ... { ... }

 public struct StaticString : ... {
-  public var byteSize: Int { get }
+  public var utf8CodeUnitCount: Int { get }

   // Use the 'String(_:)' initializer.
-  public var stringValue: String { get }
 }

 extension Strideable {
-  public func stride(to end: Self, by stride: Stride) -> StrideTo<Self>
 }
+public func stride<T : Strideable>(from start: T, to end: T, by stride: T.Stride) -> StrideTo<T>

 extension Strideable {
-  public func stride(through end: Self, by stride: Stride) -> StrideThrough<Self>
 }
+public func stride<T : Strideable>(from start: T, through end: T, by stride: T.Stride) -> StrideThrough<T>

 public func transcode<
   Input : IteratorProtocol,
   InputEncoding : UnicodeCodec,
   OutputEncoding : UnicodeCodec
   where InputEncoding.CodeUnit == Input.Element>(
   inputEncoding: InputEncoding.Type, _ outputEncoding: OutputEncoding.Type,
   _ input: Input, _ output: (OutputEncoding.CodeUnit) -> Void,
-  stopOnError: Bool
+  stoppingOnError: Bool
 ) -> Bool

 extension UnsafeMutablePointer {
-  public static func alloc(num: Int) -> UnsafeMutablePointer<Pointee>
+  public init(allocatingCapacity count: Int)

-  public func dealloc(num: Int)
+  public func deallocateCapacity(count: Int)

-  public func initialize(newvalue: Memory)
+  public func initializePointee(newValue: Pointee, count: Int = 1)

-  public func move() -> Memory
+  public func take() -> Pointee

-  public func destroy()
-  public func destroy(count: Int)
+  public func deinitializePointee(count count: Int = 1)
 }

-public struct COpaquePointer : ... { ... }
+public struct OpaquePointer : ... { ... }

-public func unsafeAddressOf(object: AnyObject) -> UnsafePointer<Void>
+public func unsafeAddress(of object: AnyObject) -> UnsafePointer<Void>

-public func unsafeBitCast<T, U>(x: T, _: U.Type) -> U
+public func unsafeBitCast<T, U>(x: T, to: U.Type) -> U

-public func unsafeDowncast<T : AnyObject>(x: AnyObject) -> T
+public func unsafeDowncast<T : AnyObject>(x: AnyObject, to: T.Type) -> T

-public func print<Target: OutputStream>(
+public func print<Target : OutputStream>(
   items: Any...,
   separator: String = " ",
   terminator: String = "\n",
-  inout toStream output: Target
+  inout to output: Target
 )

-public func debugPrint<Target: OutputStream>(
+public func debugPrint<Target : OutputStream>(
   items: Any...,
   separator: String = " ",
   terminator: String = "\n",
-  inout toStream output: Target
+  inout to output: Target
 )

 public struct Unmanaged<Instance : AnyObject> {
-  public func toOpaque() -> COpaquePointer
 }
 extension OpaquePointer {
+  public init<T>(bitPattern bits: Unmanaged<T>)
 }

 public enum UnicodeDecodingResult
+  : Equatable {
-  public var isEmptyInput: Bool
}

-public func readLine(stripNewline stripNewline: Bool = true) -> String?
+public func readLine(strippingNewline strippingNewline: Bool = true) -> String?

 struct UnicodeScalar {
   // Use 'UnicodeScalar("\0")' instead.
-  init()

-  public func escape(asASCII forceASCII: Bool) -> String
+  public func escaped(asASCII forceASCII: Bool) -> String
 }

 public func transcode<
   Input : IteratorProtocol,
   InputEncoding : UnicodeCodec,
   OutputEncoding : UnicodeCodec
   where InputEncoding.CodeUnit == Input.Element
 >(
-  inputEncoding: InputEncoding.Type, _ outputEncoding: OutputEncoding.Type,
-  _ input: Input, _ output: (OutputEncoding.CodeUnit) -> Void,
-  stoppingOnError stopOnError: Bool
+  input: Input,
+  from inputEncoding: InputEncoding.Type,
+  to outputEncoding: OutputEncoding.Type,
+  stoppingOnError stopOnError: Bool,
+  sendingOutputTo processCodeUnit: (OutputEncoding.CodeUnit) -> Void
 ) -> Bool

 extension UTF16 {
-  public static func measure<
+  public static func transcodedLength<
     Encoding : UnicodeCodec, Input : IteratorProtocol
     where Encoding.CodeUnit == Input.Element
   >(
-    _: Encoding.Type, input: Input, repairIllFormedSequences: Bool
+    of input: Input,
+    decodedAs sourceEncoding: Encoding.Type,
+    repairingIllFormedSequences: Bool
-  ) -> (Int, Bool)?
+  ) -> (count: Int, isASCII: Bool)? {
 }

-public struct RawByte {}

-final public class VaListBuilder {}

-public func withVaList<R>(
-  builder: VaListBuilder,
-  @noescape _ f: CVaListPointer -> R)
--> R
```

## Impact on existing code

The proposed changes are massively source-breaking for Swift code, and will
require a migrator to translate Swift 2 code into Swift 3 code.  The API diffs
from this proposal will be the primary source of the information about the
required transformations.  In addition, to the extent the language allows, the
library will keep old names as unavailable symbols with a `renamed` annotation,
that allows the compiler to produce good error messages and emit Fix-Its.

[api-design-guidelines]: https://swift.org/documentation/api-design-guidelines  "API Design Guidelines"
[swift-repo]: https://github.com/apple/swift  "Swift repository"
[swift-3-api-guidelines-branch]: https://github.com/apple/swift/tree/swift-3-api-guidelines  "Swift 3 API Design Guidelines preview"

