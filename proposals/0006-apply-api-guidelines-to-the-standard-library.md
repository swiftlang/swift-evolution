# Apply API Guidelines to the Standard Library

* Proposal: [SE-0006](https://github.com/apple/swift-evolution/blob/master/proposals/0006-apply-api-guidelines-to-the-standard-library.md)
* Author(s): [Dave Abrahams](https://github.com/dabrahams), [Dmitri Gribenko](https://github.com/gribozavr), [Maxim Moiseev](https://github.com/moiseev)
* Status: **Under Review** (January 22...February 5, 2016)
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

* `Unmanaged` was renamed to `UnsafeReference` and redesigned.

* `precondition` was renamed to `require`.

## API diffs

Differences between Swift 2.2 Standard library API and the proposed API are
added to this section as they are being implemented on the
[swift-3-api-guidelines branch][swift-3-api-guidelines-branch].

For repetitive changes that affect many types, only one representative instance
is shown in the diff.  For example, `generate()` was renamed to `iterator()`.
We only show the diff for the protocol requirement, and all other renames of
this method are implied.  If a type was renamed, we show only the diff for the
type declaration, all other effects on the API where the name is used are
implied.

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
```

* The concept of `generator` is renamed to `iterator` across all APIs.

```diff
-public protocol GeneratorType { ... }
+public protocol IteratorProtocol { ... }

 public protocol Collection : ... {
-  associatedtype Generator : GeneratorType = IndexingGenerator<Self>
+  associatedtype Iterator : IteratorProtocol = IndexingIterator<Self>

-  func generate() -> Generator
+  func iterator() -> Iterator
 }

-public struct IndexingGenerator<Elements : Indexable> : ... { ... }
+public struct IndexingIterator<Elements : Indexable> : ... { ... }

-public struct GeneratorOfOne<Element> : ... { ... }
+public struct IteratorOverOne<Element> : ... { ... }

-public struct EmptyGenerator<Element> : ... { ... }
+public struct EmptyIterator<Element> : ... { ... }

-public protocol ErrorType { ... }
+public protocol ErrorProtocol { ... }

-public struct AnyGenerator<Element> : ... { ... }
+public struct AnyIterator<Element> : ... { ... }

-public struct LazyFilterGenerator<Base : GeneratorType> : ... { ... }
+public struct LazyFilterIterator<Base : IteratorProtocol> : ... { ... }

-public struct FlattenGenerator<Base : ...> : ... { ... }
+public struct FlattenIterator<Base : ...> : ... { ... }

-public struct JoinGenerator<Base : ...> : ... { ... }
+public struct JoinIterator<Base : ...> : ... { ... }

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

* `sort()` => `sorted()`, `sortInPlace()` => `sort()`.

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
     @noescape isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
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
    @noescape isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
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
     @noescape isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
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

* `partition()` API was simplified.  It composes better with collection slicing
  now.

```diff
 extension MutableCollection where Index : RandomAccessIndex {
   public mutating func partition(
-    range: Range<Index>,
     isOrderedBefore: (Iterator.Element, Iterator.Element) -> Bool
   ) -> Index
 }

 extension MutableCollection
   where Index : RandomAccessIndex, Iterator.Element : Comparable {

-  public mutating func partition(range: Range<Index>) -> Index
+  public mutating func partition() -> Index
}
```

* `SequenceType.minElement()` => `.min()`, `.maxElement()` => `.max()`.

```diff
 extension Sequence {
-  public func minElement(
+  public func min(
     @noescape isOrderedBefore: (Iterator.Element, Iterator.Element) throws -> Bool
   ) rethrows -> Iterator.Element?

-  public func maxElement(
+  public func max(
     @noescape isOrderedBefore: (Iterator.Element, Iterator.Element) throws -> Bool
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

* `Unmanaged` was renamed to `UnsafeReference` and redesigned.

```diff
-public struct Unmanaged<Instance : AnyObject> {
   // New API: `UnsafeReference(bitPattern:)`.
-  public static func fromOpaque(value: COpaquePointer) -> Unmanaged

   // New API: `OpaquePointer(bitPattern:)`.
-  public func toOpaque() -> COpaquePointer

   // New API: `UnsafeReference(retaining:)`.
-  public static func passRetained(value: Instance) -> Unmanaged

   // New API: `UnsafeReference(withoutRetaining:)`.
-  public static func passUnretained(value: Instance) -> Unmanaged

   // New API: `UnsafeReference.object`.
-  public func takeUnretainedValue() -> Instance

   // New API: `UnsafeReference.release()`.
-  public func takeRetainedValue() -> Instance

   // New API: none.
-  public func retain() -> Unmanaged
-  public func release()
-  public func autorelease() -> Unmanaged
-}

+/// Holds an instance of `Object`, carrying ownership semantics that
+/// are not known to the type system and not represented in memory.
+///
+/// `UnsafeReference<T>` appears as a return type or "out" parameter
+/// in [Core
+/// Foundation](https://developer.apple.com/library/mac/documentation/CoreFoundation/Reference/CoreFoundation_Collection/)
+/// APIs that have not been
+/// [annotated](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/BuildingCocoaApps/WorkingWithCocoaDataTypes.html#//apple_ref/doc/uid/TP40014216-CH6-ID79)
+/// with information that allows clients to receive a safe `T`
+/// directly.
+///
+/// An `UnsafeReference` instance `u` can be in one of three
+/// "ownership states":
+///
+///  1. **Unretained**, where `u.object` yields a valid `T` and will
+///     do so through any number of accesses to the `.object`
+///     properties of `UnsafeReference` instances.  The behavior of
+///     `u.release()` is undefined, and any other operations may cause
+///     `u` to transition to the *released* state.
+///
+///  2. **Retained**, where `u.release()` yields a valid `T` and will
+///     do so exactly once.  Calling `.release()` transitions `u` and
+///     all its copies to the *released* state.
+///
+///  3. **Released**, where the behavior of both `u.object` and
+///     `u.release()` is undefined.  A released `UnsafeReference`
+///     can't be used for anything.
+///
+/// The ownership state of an `UnsafeReference` is not
+/// programmatically detectable, so careful documentation is
+/// essential.  When an `UnsafeReference` is returned in the
+/// *retained* state, it is usual to document that "the caller is
+/// responsible for releasing the object" or that the API "follows
+/// the [create
+/// rule](https://developer.apple.com/library/ios/documentation/CoreFoundation/Conceptual/CFMemoryMgmt/Concepts/Ownership.html#//apple_ref/doc/writerid/cfCreateRule)."
+/// Other `UnsafeReferences` are assumed to be in the *unretained*
+/// state.  No API should pass or return a *released*
+/// `UnsafeReference`
+///
+/// The safest way to deal with an instance of `UnsafeReference<T>` is
+/// to immediately extract a safe `T` from it exactly once (via
+/// `.object` or `.release()` according to its state), and let it go
+/// out of scope.
+///
+/// In the common case where the `UnsafeReference` is a return value,
+/// it's best to do the extraction as part of the call, e.g.:
+/// ~~~~
+/// let names: CFArray = CFHostGetNames(host).object
+/// let url: CFURL = CFHTTPMessageCopyRequestURL(message).release()
+/// ~~~
+///
+/// When the `UnsafeReference` is an "out" parameter, you can limit
+/// its scope by creating and unwrapping it in a closure:
+/// ~~~~
+/// var properties: CFPropertyList = try {
+///   var properties: UnsafeReference<CFPropertyList>?
+///   let error = MIDIObjectGetProperties(midiClient, &properties, true)
+///   if error != noErr {
+///     throw NSError(domain: "midi", code: Int(error), userInfo: nil)
+///   }
+///   return properties!.object
+/// }()
+/// ~~~~
+public struct UnsafeReference<Object : AnyObject> {
+
+  /// Relinquishes ownership of the `Object` and returns it as a safe
+  /// reference.
+  ///
+  /// - Requires: `self` is in the *retained* state.
+  ///
+  /// - Postcondition: `self` and all its copies are in the *released* state.
+  ///
+  /// - Warning: Calling `.release()` on an *unretained* or *released*
+  ///   `UnsafeReference` is a severe programming error yielding
+  ///   undefined behavior.
+  ///
+  /// - Warning: After this method is invoked once, invoking any
+  ///   methods on the same instance, or a copy thereof, is a severe
+  ///   programming error yielding undefined behavior.
+  public func release() -> Object
+
+  /// A safe reference to the `Object` instance.
+  ///
+  /// - Warning: if `self` is in the *retained* state, you must
+  ///   eventually call `.release()`, or the resulting object will be
+  ///   leaked.  It's better to just capture the result of invoking
+  ///   `.release()` in that case.
+  public var object: Object

+  /// Creates an unsafe holder of `safeObject` in the *unretained*
+  /// state; the held object can be accessed via the `.object` property.
+  public init(withoutRetaining safeObject: Object)
+
+  /// Creates an unsafe holder of `safeObject` in the *retained*
+  /// state; the held object can be accessed via the `release()`
+  /// method.
+  public init(retaining safeObject: Object)
+
+  /// Creates an unsafe holder of an object having the given
+  /// `bitPattern`.
+  public init(bitPattern: OpaquePointer)
+}
+
+extension OpaquePointer {
+  /// Unsafely convert an unmanaged class reference to an opaque
+  /// C pointer.
+  ///
+  /// This operation does not change reference counts.
+  ///
+  ///     let str0: CFString = "boxcar"
+  ///     let bits = OpaquePointer(bitPattern: UnsafeReference(withoutRetaining: str0))
+  ///     let str1 = UnsafeReference<CFString>(bitPattern: bits).object
+  public init<T>(bitPattern bits: UnsafeReference<T>)
+}
```

* `precondition` was renamed to `require`.

```diff
-public func precondition(
+public func require(
   @autoclosure condition: () -> Bool,
   @autoclosure _ message: () -> String = String(),
   file: StaticString = __FILE__, line: UInt = __LINE__
 )

@noreturn
-public func preconditionFailure(
+public func requirementFailure(
   @autoclosure message: () -> String = String(),
   file: StaticString = __FILE__, line: UInt = __LINE__
 )
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
+    maxSplits: Int = Int.max,
-    allowEmptySlices: Bool = false,
+    omitEmptySubsequences: Bool = true,
     @noescape isSeparator: (Iterator.Element) throws -> Bool
   ) rethrows -> [SubSequence]
 }

 extension Sequence where Iterator.Element : Equatable {
   public func split(
     separator: Iterator.Element,
-    maxSplit: Int = Int.max,
+    maxSplits: Int = Int.max,
-    allowEmptySlices: Bool = false
+    omitEmptySubsequences: Bool = true
   ) -> [AnySequence<Iterator.Element>] {
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

-  mutating func removeAtIndex(index: Int) -> Element
+  mutating func removeAt(index: Int) -> Element

-  mutating func removeAll(keepCapacity keepCapacity: Bool = false)
+  mutating func removeAll(keepingCapacity keepingCapacity: Bool = false)

-  mutating func removeRange(subRange: Range<Index>)
-  mutating func removeSubrange(subRange: Range<Index>)
 }

 public struct Set<Element : Hashable> : ... {
-  public mutating func removeAtIndex(index: Index) -> Element
+  public mutating func removeAt(index: Index) -> Element
 }

+extension Set : SetAlgebra {}

 public struct Dictionary<Key : Hashable, Value> : ... {
-  public typealias Element = (Key, Value)
+  public typealias Element = (key: Key, value: Value)

-  public mutating func removeAtIndex(index: Index) -> Element
+  public mutating func removeAt(index: Index) -> Element
 }

 extension String {
-  public mutating func appendContentsOf(other: String) {
+  public mutating func append(other: String) {

-  public mutating func replaceRange<
+  mutating func replaceSubrange<
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

-  public mutating func removeAtIndex(i: Index) -> Character
+  public mutating func removeAt(i: Index) -> Character

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
+  case ScalarValue(UnicodeScalar)
   case EmptyInput
   case Error
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
+  public func strideTo(end: Self, by stride: Stride) -> StrideTo<Self>
 }

 extension Strideable {
-  public func stride(through end: Self, by stride: Stride) -> StrideThrough<Self>
+  public func strideThrough(end: Self, by stride: Stride) -> StrideThrough<Self>
 }

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

[api-design-guidelines]: https://swift.org/documentation/api-design-guidelines.html  "API Design Guidelines"
[swift-repo]: https://github.com/apple/swift  "Swift repository"
[swift-3-api-guidelines-branch]: https://github.com/apple/swift/tree/swift-3-api-guidelines  "Swift 3 API Design Guidelines preview"

