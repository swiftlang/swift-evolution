# Safe Access to Contiguous Storage

* Proposal: [SE-NNNN](nnnn-safe-shared-contiguous-storage.md)
* Authors: [Guillaume Lessard](https://github.com/glessard), [Andrew Trick](https://github.com/atrick), [Michael Ilseman](https://github.com/milseman)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Bug: rdar://48132971, rdar://96837923
* Implementation: (pending)
* Upcoming Feature Flag: (pending)
* Review: ([pitch](https://forums.swift.org/t/69888))

## Introduction

We introduce `Span<T>`, an abstraction for container-agnostic access to contiguous memory. It will expand the expressivity of performant Swift code without giving up on the memory safety properties we rely on: temporal safety, spatial safety, definite initialization and type safety.

In the C family of programming languages, memory can be shared with any function by using a pointer and (ideally) a length. This allows contiguous memory to be shared with a function that doesn't know the layout of a container being used by the caller. A heap-allocated array, contiguously-stored named fields or even a single stack-allocated instance can all be accessed through a C pointer. We aim to create a similar idiom in Swift, with no compromise to memory safety.

This proposal is related to two other features being proposed along with it: [Nonescapable types](https://github.com/apple/swift-evolution/pull/2304) (`~Escapable`) and [Compile-time Lifetime Dependency Annotations](https://github.com/apple/swift-evolution/pull/2305). This proposal also supersedes the rejected proposal [SE-0256](https://github.com/apple/swift-evolution/blob/main/proposals/0256-contiguous-collection.md). The overall feature of ownership and lifetime constraints has previously been discussed in the [BufferView roadmap](https://forums.swift.org/t/66211) forum thread. Additionally, we refer to the proposals for [`BitwiseCopyable`](https://github.com/apple/swift-evolution/blob/main/proposals/0426-bitwise-copyable.md) and [Non-copyable Generics](https://github.com/apple/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md).

## Motivation

Swift needs safe and performant types for local processing over values in contiguous memory. Consider for example a program using multiple libraries, including one for [base64](https://datatracker.ietf.org/doc/html/rfc4648) decoding. The program would obtain encoded data from one or more of its dependencies, which could supply the data in the form of `[UInt8]`, `Foundation.Data` or even `String`, among others. None of these types is necessarily more correct than another, but the base64 decoding library must pick an input format. It could declare its input parameter type to be `some Sequence<UInt8>`, but such a generic function significantly limits performance. This may force the library author to either declare its entry point as inlinable, or to implement an internal fast path using `withContiguousStorageIfAvailable()` and use an unsafe type. The ideal interface would have a combination of the properties of both `some Sequence<UInt8>` and `UnsafeBufferPointer<UInt8>`.

The `UnsafeBufferPointer` passed to a `withUnsafeXXX` closure-style API, while performant, is unsafe in multiple ways:

1. The pointer itself is unsafe and unmanaged
2. `subscript` is only bounds-checked in debug builds of client code
3. It might escape the duration of the closure

Even if the body of the `withUnsafeXXX` call does not escape the pointer, other functions called inside the closure have to be written in terms of unsafe pointers. This requires programmer vigilance across a project and pollutes code that otherwise could be written in terms of safe constructs.


## Proposed solution

`Span` will allow sharing the contiguous internal representation of a type, by providing access to a borrowed view of an interval of contiguous memory. A view does not copy the underlying data: it instead relies on a guarantee that the original container cannot be modified or destroyed during the lifetime of the view. `Span`'s lifetime is statically enforced as a lifetime dependency to a binding of the type vending it, preventing its escape from the scope where it is valid for use. This guarantee preserves temporal safety. `Span` also performs bounds-checking on every access to preserve spatial safety. Additionally `Span` always represents initialized memory, preserving the definite initialization guarantee.

By relying on borrowing, `Span` can provide simultaneous access to a non-copyable container, and can help avoid unwanted copies of copyable containers. Note that `Span` is not a replacement for a copyable container with owned storage; see the future directions for more details ([Resizable, contiguously-stored, untyped collection in the standard library](#Bytes))

`Span` is the currency type for local processing over values in contiguous memory. It is the replacement for any API currently using `Array`, `UnsafeBufferPointer`, `Foundation.Data`, etc., that does not need to escape the value.

### `ContiguousStorage`

A type can indicate that it can provide a `Span` by conforming to the `ContiguousStorage` protocol. `ContiguousStorage` forms a bridge between multi-type or generically-typed interfaces and a performant concrete implementation.

For example, for the hypothetical base64 decoding library mentioned above, a possible API could be:

```swift
extension HypotheticalBase64Decoder {
  public func decode(bytes: some ContiguousStorage<UInt8>) -> [UInt8]
}
```

**TODO**: But, we don't want to encourage this use. We want to encourage one concrete function taking a `Span<UInt8>`. Advanced libraries might add an inlinable/alwaysEmitIntoClient generic-dispatch interface in addition to this.

### `RawSpan`

`RawSpan` allows sharing the contiguous internal representation for values which may be heterogenously-typed, such as in decoders. Furthermore, it is a fully concrete type, without a generic parameter, which achieves better performance in debug builds of client code as well as a more straight-forwards unstanding of performance for library code.

All `Span<T>`s have a backing `RawSpan`.

**TODO**: Do we have a (parent) protocol for just raw span? Do we have API to get the raw span from a span?


## Detailed design

`Span<Element>` is a simple representation of a span of initialized memory.

```swift
public struct Span<Element: ~Copyable & ~Escapable>: Copyable, ~Escapable {
  internal var _start: Span<Element>.Index
  internal var _count: Int
}
```

It provides a collection-like interface to the elements stored in that span of memory:

```swift
extension Span {
  public typealias SubSequence: Self

  public struct Index: Copyable, Escapable, Strideable { /* ... */ }
  public var startIndex: Index { get }
  public var endIndex: Index { get }
  public var indices: Range<Index> { get }

  public var count: Int { get }
  public var isEmpty: Bool { get }

  // index-based subscripts
  subscript(_ position: Index) -> dependsOn(self) Element { get }
  subscript(_ bounds: Range<Index>) -> dependsOn(self) Span<Element> { get }

  // integer-offset subscripts
  subscript(offset: Int) -> dependsOn(self) Element { get }
  subscript(offsets: Range<Int>) -> dependsOn(self) Span<Element> { get }
}
```

Note that `Span` does _not_ conform to `Collection`. This is because `Collection`, as originally conceived and enshrined in existing source code, assumes pervasive copyability and escapability for itself as well as its elements. In particular a subsequence of a `Collection` is semantically a separate value from the instance it was derived from. In the case of `Span`, the slice _must_ have the same lifetime as the view from which it originates. Another proposal will consider collection-like protocols to accommodate different combinations of `~Copyable` and `~Escapable` for the collection and its elements.

As a side-effect of not conforming to `Collection` or `Sequence`, `Span` is not directly supported by `for` loops at this time. It is, however, easy to use in a `for` loop via indexing:

```swift
for i in mySpan.indices {
  calculation(mySpan[i])
}
```

### `ContiguousStorage`

A type can declare that it can provide access to contiguous storage by conforming to the `ContiguousStorage` protocol:

```swift
public protocol ContiguousStorage<Element>: ~Copyable, ~Escapable {
  associatedtype Element: ~Copyable & ~Escapable

  var storage: Span<Element> { get }
}
```

The key safety feature is that a `Span` cannot escape to a scope where the value it borrowed no longer exists.

A function that wishes to read from contiguous storage can declare a parameter type of `some ContiguousStorage`. The implementation will internally consist of a brief generic section, followed by business logic implemented in terms of a concrete `Span`. Frameworks that support library evolution (resilient frameworks) have an additional concern. Resilient frameworks have an ABI boundary that may differ from the API proper. Resilient frameworks may wish to adopt a pattern such as the following:

```swift
extension MyResilientType {
  // public API
  @inlinable public func essentialFunction(_ a: some ContiguousStorage<some Any>) -> Int {
    self.essentialFunction(a.storage)
  }

  // ABI boundary
  public func essentialFunction(_ a: Span<some Any>) -> Int { ... }
}
```

Here, the public function obtains the `Span` from the type that vends it in inlinable code, then calls a concrete, opaque function defined in terms of `Span`. Inlining the generic shim in the client is often a critical optimization. The need for such a pattern and related improvements are discussed in the future directions below (see [Syntactic Sugar for Automatic Conversions](#Conversions).)

#### Extensions to Standard Library and Foundation types

```swift
extension Array: ContiguousStorage<Self.Element> {
  // note: this could borrow a temporary copy of the `Array`'s storage
  var storage: Span<Element> { get }
}
extension ArraySlice: ContiguousStorage<Self.Element> {
  // note: this could borrow a temporary copy of the `ArraySlice`'s storage
  var storage: Span<Element> { get }
}
extension ContiguousArray: ContiguousStorage<Self.Element> {
  var storage: Span<Element> { get }
}

extension Foundation.Data: ContiguousStorage<UInt8> {
  var storage: Span<UInt8> { get }
}

extension String.UTF8View: ContiguousStorage<Unicode.UTF8.CodeUnit> {
  // note: this could borrow a temporary copy of the `String`'s storage
  var storage: Span<Unicode.UTF8.CodeUnit> { get }
}
extension Substring.UTF8View: ContiguousStorage<Unicode.UTF8.CodeUnit> {
  // note: this could borrow a temporary copy of the `Substring`'s storage
  var storage: Span<Unicode.UTF8.CodeUnit> { get }
}
extension Character.UTF8View: ContiguousStorage<Unicode.UTF8.CodeUnit> {
  // note: this could borrow a temporary copy of the `Character`'s storage
  var storage: Span<Unicode.UTF8.CodeUnit> { get }
}

extension SIMD: ContiguousStorage<Self.Scalar> {
  var storage: Span<Self.Scalar> { get }
}
extension KeyValuePairs: ContiguousStorage<(Self.Key, Self.Value)> {
  var storage: Span<(Self.Key, Self.Value)> { get }
}
extension CollectionOfOne: ContiguousStorage<Element> {
  var storage: Span<Element> { get }
}

extension Slice: ContiguousStorage where Base: ContiguousStorage {
  var storage: Span<Base.Element> { get }
}

extension UnsafeBufferPointer: ContiguousStorage<Self.Element> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<Element> { @_unsafeNonescapableResult get }
}
extension UnsafeMutableBufferPointer: ContiguousStorage<Self.Element> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<Element> { @_unsafeNonescapableResult get }
}
extension UnsafeRawBufferPointer: ContiguousStorage<UInt8> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<UInt8> { @_unsafeNonescapableResult get }
}
extension UnsafeMutableRawBufferPointer: ContiguousStorage<UInt8> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<UInt8> { @_unsafeNonescapableResult get }
}
```

**TODO**: What is the `@_unsafeNonescapableResult` annotation? Would `Slice<UnsafeBufferPointer<UInt8>>` need it?

**TODO**: Do we do a `Sequence.withSpanIfAvailable` API?

**TODO**: What all can we deprecate with this proposal?

**TODO**: Do these needs lifetime annotations on them?

#### Using `Span` with C functions or other unsafe code:

`Span` has an unsafe hatch for use with unsafe code.

```swift
extension Span {
  func withUnsafeBufferPointer<Result>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) -> Result
  ) -> Result
}

extension Span where Element: BitwiseCopyable {
  func withUnsafeBytes<Result>(
    _ body: (_ buffer: UnsafeRawBufferPointer) -> Result
  ) -> Result
}
```

#### Complete `Span` API:

```swift
public struct Span<Element: ~Copyable & ~Escapable>: Copyable, ~Escapable {
  internal var _start: Span<Element>.Index
  internal var _count: Int
}
```

##### Creating a `Span`:

The initialization of a `Span` instance is an unsafe operation. When it is initialized correctly, subsequent uses of the borrowed instance are safe. Typically these initializers will be used internally to a container's implementation of functions or computed properties that return a borrowed `Span`.

```swift
extension Span {

  /// Unsafely create a `Span` over initialized memory.
  ///
  /// The memory in `buffer` must be owned by the instance `owner`,
  /// meaning that as long as `owner` is alive the memory will remain valid.
  ///
  /// - Parameters:
  ///   - buffer: an `UnsafeBufferPointer` to initialized elements.
  ///   - owner: a binding whose lifetime must exceed that of
  ///            the returned `Span`.
  public init?<Owner>(
    unsafeBufferPointer buffer: UnsafeBufferPointer<Element>,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self?

  /// Unsafely create a `Span` over initialized memory.
  ///
  /// The memory representing `count` instances starting at
  /// `pointer` must be owned by the instance `owner`,
  /// meaning that as long as `owner` is alive the memory will remain valid.
  ///
  /// - Parameters:
  ///   - pointer: a pointer to the first initialized element.
  ///   - count: the number of initialized elements in the view.
  ///   - owner: a binding whose lifetime must exceed that of
  ///            the returned `Span`.
  public init<Owner>(
    unsafePointer pointer: UnsafePointer<Element>,
    count: Int,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self
}

extension Span where Element: BitwiseCopyable {

  /// Unsafely create a `Span` over initialized memory.
  ///
  /// The memory in `unsafeBytes` must be owned by the instance `owner`
  /// meaning that as long as `owner` is alive the memory will remain valid.
  ///
  /// `unsafeBytes` must be correctly aligned for accessing
  /// an element of type `Element`, and must contain a number of bytes
  /// that is an exact multiple of `Element`'s stride.
  ///
  /// - Parameters:
  ///   - unsafeBytes: a buffer to initialized elements.
  ///   - type: the type to use when interpreting the bytes in memory.
  ///   - owner: a binding whose lifetime must exceed that of
  ///            the returned `Span`.
  public init<Owner>(
    unsafeBytes buffer: UnsafeRawBufferPointer,
    as type: Element.Type,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self

  /// Unsafely create a `Span` over a span of initialized memory.
  ///
  /// The memory representing `count` instances starting at
  /// `unsafeRawPointer` must be owned by the instance `owner`,
  /// meaning that as long as `owner` is alive the memory will remain valid.
  ///
  /// `unsafeRawPointer` must be correctly aligned for accessing
  /// an element of type `Element`.
  ///
  /// - Parameters:
  ///   - unsafeRawPointer: a pointer to the first initialized element.
  ///   - type: the type to use when interpreting the bytes in memory.
  ///   - count: the number of initialized elements in the view.
  ///   - owner: a binding whose lifetime must exceed that of
  ///            the returned `Span`.
  public init<Owner>(
    unsafeRawPointer pointer: UnsafeRawPointer,
    as type: Element.Type,
    count: Int,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self
}
```

#####  `Collection`-like API:

The following typealiases, properties, functions and subscripts have direct counterparts in the `Collection` protocol hierarchy. Their semantics shall be as described where they counterpart is declared (in `Sequence`, `Collection`, `BidirectionalCollection` or `RandomAccessCollection`). The only difference with their counterpart should be a lifetime dependency annotation, allowing them to return borrowed nonescapable values or borrowed noncopyable values.

```swift
extension Span {
  public typealias Index = Span<Element>.Index
  public typealias SubSequence = Self

  public func makeIterator() -> dependsOn(self) Span<Element>.Iterator

  public var startIndex: Index { get }
  public var endIndex: Index { get }
  public var count: Int { get }
  public var isEmpty: Bool { get }

  public var indices: Range<Index> { get }

  // indexing operations
  public func index(after i: Index) -> Index
  public func index(before i: Index) -> Index
  public func index(_ i: Index, offsetBy distance: Int) -> Index
  public func index(
    _ i: Index, offsetBy distance: Int, limitedBy limit: Index
  ) -> Index?

  public func formIndex(after i: inout Index)
  public func formIndex(before i: inout Index)
  public func formIndex(_ i: inout Index, offsetBy distance: Int)
  public func formIndex(
    _ i: inout Index, offsetBy distance: Int, limitedBy limit: Index
  ) -> Bool

  public func distance(from start: Index, to end: Index) -> Int

  // subscripts
  public subscript(
    _ position: Index
  ) -> dependsOn(self) Element { get }
  public subscript(
    _ bounds: Range<Index>
  ) -> dependsOn(self) Span<Element> { get }
  public subscript(
    _ bounds: some RangeExpression<Index>
  ) -> dependsOn(self) Span<Element> { get }
  public subscript(
    x: UnboundedRange
  ) -> dependsOn(self) Span<Element> { get }

  // utility properties
  public var first Element? { get }
  public var last Element? { get }

  // one-sided slicing operations
  public func prefix(upTo: Index) -> dependsOn(self) Span<Element>
  public func prefix(through: Index) -> dependsOn(self) Span<Element>
  public func prefix(_ maxLength: Int) -> dependsOn(self) Span<Element>
  public func dropLast(_ k: Int = 1) -> dependsOn(self) Span<Element>
  public func suffix(from: Index) -> dependsOn(self) Span<Element>
  public func suffix(_ maxLength: Int) -> dependsOn(self) Span<Element>
  public func dropFirst(_ k: Int = 1) -> dependsOn(self) Span<Element>
}
```

##### Additions not in the `Collection` family API:

```swift
extension Span {
  // Integer-offset subscripts

  /// Accesses the element at the specified offset in the `Span`.
  ///
  /// - Parameter offset: The offset of the element to access. `offset`
  ///     must be greater or equal to zero, and less than the `count` property.
  ///
  /// - Complexity: O(1)
  public subscript(offset: Int) -> dependsOn(self) Element { get }

  /// Accesses the contiguous subrange of elements at the specified
  /// range of offsets in this `Span`.
  ///
  /// - Parameter offsets: A range of offsets. The bounds of the range
  ///     must be greater or equal to zero, and less than the `count` property.
  ///
  /// - Complexity: O(1)
  public subscript(offsets: Range<Int>) -> dependsOn(self) Span<Element> { get }

  /// Accesses the contiguous subrange of elements at the specified
  /// range of offsets in this `Span`.
  ///
  /// - Parameter offsets: A range of offsets. The bounds of the range
  ///     must be greater or equal to zero, and less than the `count` property.
  ///
  /// - Complexity: O(1)
  public subscript(
    offsets: some RangeExpression<Int>
  ) -> dependsOn(self) Span<Element> { get }

  // Unchecked subscripts

  /// Accesses the element at the specified `position`.
  ///
  /// This subscript does not validate `position`; this is an unsafe operation.
  ///
  /// - Parameter position: The position of the element to access. `position`
  ///     must be a valid index that is not equal to the `endIndex` property.
  ///
  /// - Complexity: O(1)
  public subscript(unchecked position: Index) -> dependsOn(self) Element { get }

  /// Accesses a contiguous subrange of the elements represented by this `Span`
  ///
  /// This subscript does not validate `bounds`; this is an unsafe operation.
  ///
  /// - Parameter bounds: A range of the collection's indices. The bounds of
  ///     the range must be valid indices of the collection.
  ///
  /// - Complexity: O(1)
  public subscript(
    uncheckedBounds bounds: Range<Index>
  ) -> dependsOn(self) Span<Element> { get }

  /// Accesses the contiguous subrange of the elements represented by
  /// this `Span`, specified by a range expression.
  ///
  /// This subscript does not validate `bounds`; this is an unsafe operation.
  ///
  /// - Parameter bounds: A range of the collection's indices. The bounds of
  ///     the range must be valid indices of the collection.
  ///
  /// - Complexity: O(1)
  public subscript(
    uncheckedBounds bounds: some RangeExpression<Index>
  ) -> dependsOn(self) Span<Element>

  // Unchecked integer-offset subscripts

  /// Accesses the element at the specified offset in the `Span`.
  ///
  /// This subscript does not validate `offset`; this is an unsafe operation.
  ///
  /// - Parameter offset: The offset of the element to access. `offset`
  ///     must be greater or equal to zero, and less than the `count` property.
  ///
  /// - Complexity: O(1)
  public subscript(
    uncheckedOffset offset: Int
  ) -> dependsOn(self) Element { get }

  /// Accesses the contiguous subrange of elements at the specified
  /// range of offsets in this `Span`.
  ///
  /// This subscript does not validate `offsets`; this is an unsafe operation.
  ///
  /// - Parameter offsets: A range of offsets. The bounds of the range
  ///     must be greater or equal to zero, and less than the `count` property.
  ///
  /// - Complexity: O(1)
  public subscript(
    uncheckedOffsets offsets: Range<Int>
  ) -> dependsOn(self) Span<Element> { get }
}
```

##### Index validation utilities:

Every time `Span` uses an index or an integer offset, it checks for their validity, unless the parameter is marked with the word "unchecked". The validation is performed with these functions:

```swift
extension Span {
  /// Traps if `position` is not a valid index for this `Span`
  ///
  /// - Parameters:
  ///   - position: an Index to validate
  public boundsCheckPrecondition(_ position: Index)

  /// Traps if `bounds` is not a valid range of indices for this `Span`
  ///
  /// - Parameters:
  ///   - position: a range of indices to validate
  public boundsCheckPrecondition(_ bounds: Range<Index>)

  /// Traps if `offset` is not a valid offset into this `Span`
  ///
  /// - Parameters:
  ///   - offset: an offset to validate
  public boundsCheckPrecondition(offset: Int)
  
  /// Traps if `offsets` is not a valid range of offsets into this `Span`
  ///
  /// - Parameters:
  ///   - offsets: a range of offsets to validate
  public boundsCheckPrecondition(offsets: Range<Int>)
}
```

##### Interoperability with unsafe code:

We provide two functions for interoperability with C or other legacy pointer-taking functions.

```swift
extension Span {
  /// Calls a closure with a pointer to the viewed contiguous storage.
  ///
  /// The buffer pointer passed as an argument to `body` is valid only
  /// during the execution of `withUnsafeBufferPointer(_:)`.
  /// Do not store or return the pointer for later use.
  ///
  /// - Parameter body: A closure with an `UnsafeBufferPointer` parameter
  ///   that points to the viewed contiguous storage. If `body` has
  ///   a return value, that value is also used as the return value
  ///   for the `withUnsafeBufferPointer(_:)` method. The closure's
  ///   parameter is valid only for the duration of its execution.
  /// - Returns: The return value of the `body` closure parameter.
  func withUnsafeBufferPointer<Result>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) -> Result
  ) -> Result
}

extension Span where Element: BitwiseCopyable {
  /// Calls the given closure with a pointer to the underlying bytes of
  /// the viewed contiguous storage.
  ///
  /// The buffer pointer passed as an argument to `body` is valid only
  /// during the execution of `withUnsafeBytes(_:)`.
  /// Do not store or return the pointer for later use.
  ///
  /// - Parameter body: A closure with an `UnsafeRawBufferPointer`
  ///   parameter that points to the viewed contiguous storage.
  ///   If `body` has a return value, that value is also
  ///   used as the return value for the `withUnsafeBytes(_:)` method.
  ///   The closure's parameter is valid only for the duration of
  ///   its execution.
  /// - Returns: The return value of the `body` closure parameter.
  func withUnsafeBytes<Result>(
    _ body: (_ buffer: UnsafeRawBufferPointer) -> Result
  ) -> Result
}
```

**TODO**: `public var rawSpan: RawSpan` API, as well a conformance to a raw span protocol if there is one.

### RawSpan

In addition to `Span<T>`, we propose the addition of `RawSpan` which can represent heterogenously-typed values in contiguous memory. `RawSpan` is similar to `Span<T>`, but represents initialized untyped bytes. Its API supports slicing, along with the operations `load(as:)` and `loadUnaligned(as:)`. 

`RawSpan` is a specialized type supporting parsing and decoding applications in particular, as well as applications where heavily-used code paths require concrete types as much as possible.

#### Complete `RawSpan` API:

```swift
public struct RawSpan: Copyable, ~Escapable {
  internal var _start: RawSpan.Index
  internal var _count: Int
}
```

##### Initializing a `RawSpan`:

```swift
extension RawSpan {
  /// Unsafely create a `RawSpan` over initialized memory.
  ///
  /// The memory in `buffer` must be owned by the instance `owner`,
  /// meaning that as long as `owner` is alive the memory will remain valid.
  ///
  /// - Parameters:
  ///   - buffer: an `UnsafeRawBufferPointer` to initialized memory.
  ///   - owner: a binding whose lifetime must exceed that of
  ///            the returned `RawSpan`.
  public init?<Owner: ~Copyable & ~Escapable>(
    unsafeBufferPointer buffer: UnsafeBufferPointer<Element>,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self?

  /// Unsafely create a `RawSpan` over initialized memory.
  ///
  /// The memory over `count` bytes starting at
  /// `pointer` must be owned by the instance `owner`,
  /// meaning that as long as `owner` is alive the memory will remain valid.
  ///
  /// - Parameters:
  ///   - pointer: a pointer to the first initialized element.
  ///   - count: the number of initialized elements in the view.
  ///   - owner: a binding whose lifetime must exceed that of
  ///            the returned `Span`.
  public init<Owner: ~Copyable & ~Escapable>(
    unsafeRawPointer pointer: UnsafeRawPointer,
    count: Int,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self

  /// Create a `RawSpan` over the memory represented by a `Span<T>`
  ///
  /// - Parameters:
  ///   - span: An existing `Span<T>`, which will define both this
  ///           `RawSpan`'s lifetime and the memory it represents.
  @inlinable @inline(__always)
  public init<T: _BitwiseCopyable>(
    _ span: borrowing Span<T>
  ) -> dependsOn(span) Self
}
```

##### Indexing Operations:

`RawSpan` has these `Collection`-like indexing operations:

```swift
extension RawSpan {
  public typealias Index = Span<Element>.Index
  public typealias SubSequence = Self

  public var startIndex: Index { get }
  public var endIndex: Index { get }
  public var count: Int { get }
  public var isEmpty: Bool { get }

  public var indices: Range<Index> { get }

  // indexing operations
  public func index(after i: Index) -> Index
  public func index(before i: Index) -> Index
  public func index(_ i: Index, offsetBy distance: Int) -> Index
  public func index(
    _ i: Index, offsetBy distance: Int, limitedBy limit: Index
  ) -> Index?

  public func formIndex(after i: inout Index)
  public func formIndex(before i: inout Index)
  public func formIndex(_ i: inout Index, offsetBy distance: Int)
  public func formIndex(
    _ i: inout Index, offsetBy distance: Int, limitedBy limit: Index
  ) -> Bool

  public func distance(from start: Index, to end: Index) -> Int
}
```

**TODO**: What does `typealias Index = Span<Element>.Index` mean? 

##### Index validation utiliities:

Every time `RawSpan` uses an index or an integer offset, it checks for their validity, unless the parameter is marked with the word "unchecked". The validation is performed with these functions:

```swift
extension RawSpan {
  /// Traps if `position` is not a valid index for this `RawSpan`
  ///
  /// - Parameters:
  ///   - position: an Index to validate
  public boundsCheckPrecondition(_ position: Index)

  /// Traps if `bounds` is not a valid range of indices for this `RawSpan`
  ///
  /// - Parameters:
  ///   - bounds: a range of indices to validate
  public boundsCheckPrecondition(_ bounds: Range<Index>)
  
  /// Traps if `offset` is not a valid offset into this `RawSpan`
  ///
  /// - Parameters:
  ///   - offset: an offset to validate
  public boundsCheckPrecondition(offset: Int)
  
  /// Traps if `offsets` is not a valid range of offsets into this `RawSpan`
  ///
  /// - Parameters:
  ///   - offsets: a range of offsets to validate
  public boundsCheckPrecondition(offsets: Range<Int>)
}
```

##### Slicing of `RawSpan` instances:

`RawSpan` has `Collection`-like slicing operations. Like `Span<T>`, it also has unchecked slicing operations and can be sliced using integer offsets:

```swift
extension RawSpan {
  public subscript(bounds: Range<Index>) -> dependsOn(self) Self { get }
  public subscript(unchecked bounds: Range<Index>) -> dependsOn(self) Self { get }

  public subscript(bounds: some RangeExpression<Index>) -> dependsOn(self) Self { get }
  public subscript(unchecked bounds: some RangeExpression<Index>) -> dependsOn(self) Self { get }
  public subscript(x: UnboundedRange) -> dependsOn(self) Self { get }
  
  public subscript(offsets: Range<Int>) -> dependsOn(self) Self { get }
  public subscript(uncheckedOffsets offsets: Range<Int>) -> dependsOn(self) Self { get }

  public subscript(offsets: some RangeExpression<Int>) -> dependsOn(self) Self { get }
  public subscript(uncheckedOffsets offsets: some RangeExpression<Int>) -> dependsOn(self) Self { get }
}
```

`RawSpan` has the following functions for loading arbitrary types from the memory it represents:

```swift
extension RawSpan {

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified byte offset.
  ///
  /// The memory at `offset` bytes from the start of this `Span`
  /// must be properly aligned for accessing `T` and initialized to `T`
  /// or another type that is layout compatible with `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from the start of this `Span`, in bytes.
  ///       `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///   `offset`. The returned instance is memory-managed and unassociated
  ///   with the value in the memory referenced by this `Span`.
  public func load<T: BitwiseCopyable>(
    fromByteOffset: Int = 0, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified index.
  ///
  /// The memory starting at `index` must be properly aligned for accessing `T`
  /// and initialized to `T` or another type that is layout compatible with `T`.
  ///
  /// - Parameters:
  ///   - index: The index into this `Span`
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes starting at
  ///   `index`. The returned instance is memory-managed and isn't associated
  ///   with the value in the memory referenced by this `Span`.
  public func load<T: BitwiseCopyable>(
    from index: Index, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified byte offset.
  ///
  /// The memory at `offset` bytes from the start of this `Span`
  /// must be laid out identically to the in-memory representation of `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from the start of this `Span`, in bytes.
  ///       `offset` must be nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///   `offset`. The returned instance isn't associated
  ///   with the value in the memory referenced by this `Span`.
  public func loadUnaligned<T: BitwiseCopyable>(
    fromByteOffset: Int = 0, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified index.
  ///
  /// The memory starting at `index` must be laid out identically
  /// to the in-memory representation of `T`.
  ///
  /// - Parameters:
  ///   - index: The index into this `Span`
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes starting at
  ///   `index`. The returned instance isn't associated
  ///   with the value in the memory referenced by this `Span`.
  public func loadUnaligned<T: BitwiseCopyable>(
    from index: Index, as: T.Type
  ) -> T
```

**TODO**: What about unchecked variants? Those would/could be the bottom API called by data parsers which have already checked the bounds earlier (e.g. for error-throwing purposes).

A `RawSpan` can be viewed as a `Span<T>`, provided the memory is laid out homogenously as instances of `T`.

```swift
  /// View the memory span represented by this view as a different type
  ///
  /// The memory must be laid out identically to the in-memory representation of `T`.
  ///
  /// - Parameters:
  ///   - type: The type you wish to view the memory as
  /// - Returns: A new `Span` over elements of type `T`
  public func view<T: BitwiseCopyable>(as: T.Type) -> dependsOn(self) Span<T>
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the standard library and runtime.

## Alternatives considered

##### Make `Span` a noncopyable type
Making `Span` non-copyable was in the early vision of this type. However, we found that would make `Span` a poor match to model borrowing semantics. This realization led to the initial design for non-escapable declarations.

##### A protocol in addition to `ContiguousStorage` for unsafe buffers
This document proposes adding the `ContiguousStorage` protocol to the standard library's `Unsafe{Mutable,Raw}BufferPointer` types. On the surface this seems like whitewashing the unsafety of these types. The lifetime constraint only applies to the binding used to obtain a `Span`, and the initialization precondition can only be enforced by documentation. Nothing will prevent unsafe code from deinitializing a portion of the storage while a `Span` is alive. There is no safe bridge from `UnsafeBufferPointer` to `ContiguousStorage`. We considered having the unsafe buffer types conforming to a different version of `ContiguousStorage`, which would vend a `Span` through a closure-taking API. Unfortunately such a closure would be perfectly capable of capturing the `UnsafeBufferPointer` binding and be as unsafe as can be. For this reason, the `UnsafeBufferPointer` family will conform to `ContiguousStorage`, with safety being enforced in documentation.

##### Use a non-escapable index type
Eventually we want a similar usage pattern for a `MutableSpan` as we are proposing for `Span`. If the index of a `MutableSpan` were to borrow the view, then it becomes impossible to implement a mutating subscript without also requiring an index to be consumed. This seems untenable.

##### Naming
The ideas in this proposal previously used the name `BufferView`. While the use of the word "buffer" would be consistent with the `UnsafeBufferPointer` type, it is nevertheless not a great name, since "buffer" is usually used in reference to transient storage. On the other hand we already have a nomenclature using the term "Storage" in the `withContiguousStorageIfAvailable()` function, and the term "View" in the API of `String`. A possible alternative name is `StorageSpan`, which mark it as a relative of C++'s `std::span`.

##### Adding `load` and `loadUnaligned` to `Span<UInt8>`on `Span<some BitwiseCopyable>` instead of adding `RawSpan

TKTKTK

## Future directions

##### Defining `BorrowingIterator` with support in `for` loops
This proposal defines a `Span.Iterator` that is borrowed and non-escapable. This is not compatible with `for` loops as currently defined. A `BorrowingIterator` protocol for non-escapable and non-copyable containers must be defined, providing a `for` loop syntax where the element is borrowed through each iteration. Ultimately we should arrive at a way to iterate through borrowed elements from a borrowed view:

```swift
borrowing view: Span<Element> = ...
for borrowing element in view {
  doSomething(element)
}
```

In the meantime, it is possible to loop through a `Span`'s elements by direct indexing:

```swift
func doSomething(_ e: borrowing Element) { ... }
let view: Span<Element> = ...
// either:
var i = view.startIndex
while i < view.endIndex {
  doSomething(view[i])
  view.index(after: &i)
}

// ...or:
for i in 0..<view.indices {
  doSomething(view[i])
}

// ...or
var iter = view.makeIterator()
while let elt = iter.next() {
  doSomething(elt)
}

```

**TODO**: Karoy mentioned that be might not want to even take the name `Iterator` until more of the borrowed iterator design is figured out

##### Collection-like protocols for non-copyable and non-escapable types

Non-copyable and non-escapable containers would benefit from a `Collection`-like protocol family to represent a set basic, common operations. This may be `Collection` if we find a way to make it work; it may be something else.

##### Sharing piecewise-contiguous memory

Some types store their internal representation in a piecewise-contiguous manner, such as trees and ropes. Some operations naturally return information in a piecewise-contiguous manner, such as network operations. These could supply results by iterating through a list of contiguous chunks of memory.

##### Safe mutations of memory with `MutableSpan<T>`

Some data structures can delegate mutations of their owned memory. In the standard library we have `withMutableBufferPointer()`, for example.

The `UnsafeMutableBufferPointer` passed to a `withUnsafeMutableXXX` closure-style API is unsafe in multiple ways:

1. The pointer itself is unsafe and unmanaged
2. `subscript` is only bounds-checked in debug builds of client code
3. It might escape the duration of the closure
4. Exclusivity of writes is not enforced
5. Initialization of any particular memory address is not ensured

I.e., it is unsafe in all the ways `UnsafeBufferPointer`-passing closure APIs are unsafe in addition to being unsafe in exclusivity and in initialization.

Loading an uninitialized non-`BitwiseCopyable` value leads to undefined behavior. Loading an uninitialized `BitwiseCopyable` value does not immediately lead to undefined behavior, but it produces a garbage value which may lead to misbehavior of the program.

A `MutableSpan<T>` should provide a better, safer alternative to mutable memory in the same way that `Span<T>` provides a better, safer read-only type. `MutableSpan<T>` would also automatically enforce exclusivity of writes.

However, it alone does not track initialization state of each address, and that will continue to be the responsibility of the developer.


##### Delegating initialization of memory with `OutputSpan<T>`

Some data structures can delegate initialization of their initial memory representation, and in some cases the initialization of additional memory. In the standard library we have `Array.init(unsafeUninitializedCapacity:initializingWith:)` and `String.init(unsafeUninitializedCapacity:initializingUTF8With:)`. A safer abstraction for initialization would make such initializers less dangerous, and would allow for a greater variety of them.

`OutputSpan<T>` would need run-time bookkeeping (e.g. a bitvector with a bit per-address) to track initialization state to safely support random access and random-order initialization.

Alternatively, a divide-and-conqueor style initialization order might be solvable via an API layer without run-time bookkeeping, but with more complex ergonomics.



##### <a name="Bytes"></a>Resizable, contiguously-stored, untyped collection in the standard library

The example in the [motivation](#motivation) section mentions the `Foundation.Data` type. There has been some discussion of either replacing `Data` or moving it to the standard library. This document proposes neither of those. A major issue is that in the "traditional" form of `Foundation.Data`, namely `NSData` from Objective-C, it was easier to control accidental copies because the semantics of the language did not lead to implicit copying. 

Even if `Span` were to replace all uses of a constant `Data` in API, something like `Data` would still be needed, just as `Array<T>` will: resizing mutations (e.g. `RangeReplaceableCollection` conformance.) We may still want to add an untyped-element equivalent of `Array` at a later time.

##### <a name="Conversions"></a>Syntactic Sugar for Automatic Conversions
In the context of a resilient library, a generic entry point in terms of `some ContiguousStorage` may add unwanted overhead. As detailed above, an entry point in an evolution-enabled library requires an inlinable  generic public entry point which forwards to a publicly-accessible function defined in terms of `Span`. If `Span` does become a widely-used type to interface between libraries, we could simplify these conversions with a bit of compiler help.

We could provide an automatic way to use a `ContiguousStorage`-conforming type with a function that takes a `Span` of the appropriate element type:

```swift
func myStrnlen(_ b: Span<UInt8>) -> Int {
  guard let i = b.firstIndex(of: 0) else { return b.count }
  return b.distance(from: b.startIndex, to: e)
}
let data = Data((0..<9).reversed()) // Data conforms to ContiguousStorage
let array = Array(data) // Array<UInt8> also conforms to ContiguousStorage
myStrnlen(data)  // 8
myStrnlen(array) // 8
```

This would probably consist of a new type of custom conversion in the language. A type author would provide a way to convert from their type to an owned `Span`, and the compiler would insert that conversion where needed. This would enhance readability and reduce boilerplate.

##### Interopability with C++'s `std::span` and with llvm's `-fbounds-safety`
The [`std::span`](https://en.cppreference.com/w/cpp/container/span) class template from the C++ standard library is a similar representation of a contiguous range of memory. LLVM may soon have a [bounds-checking mode](https://discourse.llvm.org/t/70854) for C. These are an opportunity for better, safer interoperation with a type such as `Span`.

## Acknowledgments

Joe Groff, John McCall, Tim Kientzle, Karoy Lorentey contributed to this proposal with their clarifying questions and discussions.
