# MutableSpan and MutableRawSpan: delegate mutations of contiguous memory

* Proposal: [SE-0467](0467-MutableSpan.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Implemented (Swift 6.2)**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: [PR #79650](https://github.com/swiftlang/swift/pull/79650), [PR #80517](https://github.com/swiftlang/swift/pull/80517)
* Review: ([Pitch](https://forums.swift.org/t/pitch-mutablespan/77790)) ([Review](https://forums.swift.org/t/se-0467-mutablespan/78454)) ([Acceptance](https://forums.swift.org/t/accepted-se-0467-mutablespan/78875))

[SE-0446]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[SE-0456]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md
[PR-2305]: https://github.com/swiftlang/swift-evolution/pull/2305
[SE-0437]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0437-noncopyable-stdlib-primitives.md
[SE-0453]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md
[SE-0223]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0223-array-uninitialized-initializer.md
[SE-0176]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0176-enforce-exclusive-access-to-memory.md

## Introduction

We recently [introduced][SE-0447] the `Span` and `RawSpan` types, providing shared read-only access to borrowed memory. This proposal adds helper types to delegate mutations of exclusively-borrowed memory: `MutableSpan` and `MutableRawSpan`.

## Motivation

Many standard library container types can provide direct access to modify their internal representation. Up to now, it has only been possible to do so in an unsafe way. The standard library provides this unsafe functionality with closure-taking functions such as `withUnsafeMutableBufferPointer()` and `withContiguousMutableStorageIfAvailable()`.

These functions have a few different drawbacks, most prominently their reliance on unsafe types, which makes them unpalatable in security-conscious environments. We continue addressing these issues with `MutableSpan` and `MutableRawSpan`, new non-copyable and non-escapable types that manage respectively mutations of typed and untyped memory.

In addition to the new types, we will propose adding new API some standard library types to take advantage of `MutableSpan` and `MutableRawSpan`.

## Proposed solution

We introduced `Span` to provide shared read-only access to containers. The natural next step is to provide a similar capability for mutable access. A library whose API provides access to its internal storage makes a decision regarding the type of access it provides; it may provide read-only access or provide the ability to mutate its storage. That decision is made by the API author. If mutations were enabled by simply binding a `Span` value to a mutable binding (`var` binding or `inout` parameter), that decision would rest with the user of the API instead of its author. This explains why mutations must be modeled by a type separate from `Span`.

Mutability requires exclusive access, per Swift's [law of exclusivity][SE-0176]. `Span` is copyable, and must be copyable in order to properly model read access under the law of exclusivity: a value can be simultaneously accessed through multiple read-only accesses. Exclusive access cannot be modeled with a copyable type, since a copy would represent an additional access, in violation of the law of exclusivity. This explains why the type which models mutations must be non-copyable.

#### MutableSpan

`MutableSpan` allows delegating mutations of a type's contiguous internal representation, by providing access to an exclusively-borrowed view of a range of contiguous, initialized memory. `MutableSpan`'s memory safety relies on guarantees that:
- it has exclusive access to the range of memory it represents, providing data race safety and enforced by `~Copyable`.
- the memory it represents will remain valid for the duration of the access, providing lifetime safety and enforced by `~Escapable`.
- each access is guarded by bounds checking, providing bounds safety.

A `MutableSpan` provided by a container represents a mutation of that container, as an extended mutation access. Mutations are implemented by mutating functions and subscripts, which let the compiler statically enforce exclusivity.

#### MutableRawSpan

`MutableRawSpan` allows delegating mutations to memory representing possibly heterogeneously-typed values, such as memory intended for encoding. It makes the same safety guarantees as `MutableSpan`. A `MutableRawSpan` can be obtained from a `MutableSpan` whose `Element` is `BitwiseCopyable`.

#### Extensions to standard library types

The standard library will provide `mutableSpan` computed properties. These return a new lifetime-dependent `MutableSpan` instance, and that `MutableSpan` represents a mutation of the instance that provided it. The `mutableSpan` computed properties are the safe and composable replacements for the existing `withUnsafeMutableBufferPointer` closure-taking functions. For example,

```swift
func(_ array: inout Array<Int>) {
  var ms = array.mutableSpan
  modify(&ms)        // call function that mutates a MutableSpan<Int>
  // array.append(2) // attempt to modify `array` would be an error here
  _ = consume ms     // access to `array` via `ms` ends here
  array.append(1)
}
```

The `mutableSpan` computed property represents a case of lifetime relationships not covered until now. The `mutableSpan` computed properties proposed here will represent mutations of their callee. This relationship will be illustrated with a hypothetical `@_lifetime` attribute, which ties the lifetime of a return value to an input parameter in a specific way.

Note: The `@_lifetime` attribute is not real; it is a placeholder. The eventual lifetime annotations proposal may or may not propose syntax along these lines. We expect that, as soon as Swift adopts a syntax do describe lifetime dependencies, the Standard Library will be modified to adopt that new syntax.

```swift
extension Array {
  public var mutableSpan: MutableSpan<Element> {
    @_lifetime(inout self)
    mutating get { ... }
  }
}
```

Here, the lifetime of the returned `MutableSpan` is tied to an `inout` access of `self` (the `Array`.) As long as the returned instance exists, the source `Array` is being mutated, and no other access to the `Array` can occur.

This lifetime relationship will apply to all the safe `var mutableSpan: MutableSpan<Element>` and `var mutableBytes: MutableRawSpan` properties described in this proposal.

#### Slicing `MutableSpan` or `MutableRawSpan` instances

An important category of use cases for `MutableSpan` and `MutableRawSpan` consists of bulk copying operations. Often times, such bulk operations do not necessarily start at the beginning of the span, thus having a method to select a sub-span is necessary. This means producing an instance derived from the callee instance. We adopt the nomenclature already introduced in [SE-0437][SE-0437], with a family of `extracting()` methods.

```swift
extension MutableSpan where Element: ~Copyable {
  @_lifetime(inout self)
  public mutating func extracting(_ range: Range<Index>) -> Self
}
```

This function returns an instance of `MutableSpan` that represents a mutation of the same memory as represented by the callee. The callee can therefore no longer be accessed (read or mutated) while the returned value exists:

```swift
var array = [1, 2, 3, 4, 5]
var span1 = array.mutableSpan
var span2 = span1.extracting(3..<5)
// neither array nor span1 can be accessed here
span2.swapAt(0, 1)
_ = consume span2 // explicitly end scope for `span2`
span1.swapAt(0, 1)
_ = consume span1 // explicitly end scope for `span1`
print(array) // [2, 1, 3, 5, 4]
```

As established in [SE-0437][SE-0437], the instance returned by the `extracting()` function does not share indices with the function's callee.

## Detailed Design

#### MutableSpan

`MutableSpan<Element>` is a simple representation of a region of initialized memory. It is non-copyable in order to enforce exclusive access for mutations of its memory, as required by the law of exclusivity:

````swift
@frozen
public struct MutableSpan<Element: ~Copyable>: ~Copyable, ~Escapable {
  internal var _start: UnsafeMutableRawPointer?
  internal var _count: Int
}

extension MutableSpan: @unchecked Sendable where Element: Sendable & ~Copyable {}
````

We store a `UnsafeMutableRawPointer` value internally in order to explicitly support reinterpreted views of memory as containing different types of `BitwiseCopyable` elements. Note that the the optionality of the pointer does not affect usage of `MutableSpan`, since accesses are bounds-checked and the pointer is only dereferenced when the `MutableSpan` isn't empty, when the pointer cannot be `nil`.

Initializers, required for library adoption, will be proposed alongside [lifetime annotations][PR-2305]; for details, see "[Initializers](#initializers)" in the [future directions](#Directions) section.

```swift
extension MutableSpan where Element: ~Copyable {
  /// The number of initialized elements in this `MutableSpan`.
  var count: Int { get }

  /// A Boolean value indicating whether the span is empty.
  var isEmpty: Bool { get }

  /// The type that represents a position in a `MutableSpan`.
  typealias Index = Int

  /// The range of indices valid for this `MutableSpan`.
  var indices: Range<Index> { get }

  /// Accesses the element at the specified position.
  subscript(_ index: Index) -> Element { borrow; mutate }
    // accessor syntax from accessors roadmap (https://forums.swift.org/t/76707)

  /// Exchange the elements at the two given offsets
  mutating func swapAt(_ i: Index, _ j: Index)

  /// Borrow the underlying memory for read-only access
  var span: Span<Element> { @_lifetime(borrow self) borrowing get }
}
```

Like `Span` before it, `MutableSpan` does not conform to `Collection` or `MutableCollection`. These two protocols assume their conformers and elements are copyable, and as such are not compatible with a non-copyable type such as `MutableSpan`. A later proposal will consider generalized containers.

The subscript uses a borrowing accessor for read-only element access, and a mutate accessor for element mutation. The read-only borrow is a read access to the entire `MutableSpan` for the duration of the access to the element. The `mutate` accessor is an exclusive access to the entire `MutableSpan` for the duration of the mutation of the element.

`MutableSpan` uses offset-based indexing. The first element of a given span is always at offset 0, and its last element is always at position `count-1`.

As a side-effect of not conforming to `Collection` or `Sequence`, `MutableSpan` is not directly supported by `for` loops at this time. It is, however, easy to use in a `for` loop via indexing:

```swift
for i in myMutableSpan.indices {
  mutatingFunction(&myMutableSpan[i])
}
```

##### Bulk updates of a `MutableSpan`'s elements:

We include functions to perform bulk copies of elements into the memory represented by a `MutableSpan`. Updating a `MutableSpan` from known-sized sources (such as `Collection` or `Span`) copies every element of a source. It is an error to do so when there is the span is too short to contain every element from the source. Updating a `MutableSpan` from `Sequence` or `IteratorProtocol` instances will copy as many items as possible, either until the input is empty or until the operation has updated the item at the last index. The bulk operations return the index following the last element updated.

```swift
extension MutableSpan where Element: Copyable {
  /// Updates every element of this span to the given value.
  mutating func update(
    repeating repeatedValue: Element
  )

  /// Updates the span's elements with the elements from the source
  mutating func update<S: Sequence>(
    from source: S
  ) -> (unwritten: S.Iterator, index: Index) where S.Element == Element

  /// Updates the span's elements with the elements from the source
  mutating func update(
    from source: inout some IteratorProtocol<Element>
  ) -> Index

  /// Updates the span's elements with every element of the source.
  mutating func update(
    fromContentsOf source: some Collection<Element>
  ) -> Index
}

extension MutableSpan where Element: ~Copyable
  /// Updates the span's elements with every element of the source.
  mutating func update(
    fromContentsOf source: Span<Element>
  ) -> Index

  /// Updates the span's elements with every element of the source.
  mutating func update(
    fromContentsOf source: borrowing MutableSpan<Element>
  ) -> Index

  /// Updates the span's elements with every element of the source,
  /// leaving the source uninitialized.
  mutating func moveUpdate(
    fromContentsOf source: UnsafeMutableBufferPointer<Element>
  ) -> Index
}

extension MutableSpan where Element: Copyable {
  /// Updates the span's elements with every element of the source,
  /// leaving the source uninitialized.
  mutating func moveUpdate(
    fromContentsOf source: Slice<UnsafeMutableBufferPointer<Element>>
  ) -> Index
}
```

##### Extracting sub-spans
These functions extract sub-spans of the callee. The first two perform strict bounds-checking. The last four return prefixes or suffixes, where the number of elements in the returned sub-span is bounded by the number of elements in the parent `MutableSpan`.

```swift
extension MutableSpan where Element: ~Copyable {
  /// Returns a span over the items within the supplied range of
  /// positions within this span.
  @_lifetime(inout self)
  mutating public func extracting(_ bounds: Range<Index>) -> Self
  
  /// Returns a span over the items within the supplied range of
  /// positions within this span.
  @_lifetime(inout self)
  mutating public func extracting(_ bounds: some RangeExpression<Index>) -> Self
  
  /// Returns a span containing the initial elements of this span,
  /// up to the specified maximum length.
  @_lifetime(inout self)
  mutating public func extracting(first maxLength: Int) -> Self
  
  /// Returns a span over all but the given number of trailing elements.
  @_lifetime(inout self)
  mutating public func extracting(droppingLast k: Int) -> Self
  
  /// Returns a span containing the final elements of the span,
  /// up to the given maximum length.
  @_lifetime(inout self)
  mutating public func extracting(last maxLength: Int) -> Self
  
  /// Returns a span over all but the given number of initial elements.
  @_lifetime(inout self)
  mutating public func extracting(droppingFirst k: Int) -> Self
}
```

##### Unchecked access to elements or sub-spans:

The `subscript` and index-taking functions mentioned above always check the bounds of the `MutableSpan` before allowing access to the memory, preventing out-of-bounds accesses. We also provide unchecked variants of the `subscript`, the `swapAt()` and `extracting()` functions as alternatives in situations where repeated bounds-checking is costly and has already been performed:

```swift
extension MutableSpan where Element: ~Copyable {
  /// Accesses the element at the specified `position`.
  ///
  /// This subscript does not validate `position`; this is an unsafe operation.
  ///
  /// - Parameter position: The offset of the element to access. `position`
  ///     must be greater or equal to zero, and less than `count`.
  @unsafe
  subscript(unchecked position: Index) -> Element { borrow; mutate }

  /// Exchange the elements at the two given offsets
  ///
  /// This function does not validate `i` or `j`; this is an unsafe operation.
  @unsafe
  mutating func swapAt(unchecked i: Index, unchecked j: Index)
  
  /// Constructs a new span over the items within the supplied range of
  /// positions within this span.
  ///
  /// This function does not validate `bounds`; this is an unsafe operation.
  @unsafe
  @_lifetime(inout self)
  mutating func extracting(unchecked bounds: Range<Index>) -> Self
  
  /// Constructs a new span over the items within the supplied range of
  /// positions within this span.
  ///
  /// This function does not validate `bounds`; this is an unsafe operation.
  @unsafe
  @_lifetime(inout self)
  mutating func extracting(unchecked bounds: ClosedRange<Index>) -> Self
}
```

##### Interoperability with unsafe code

```swift
extension MutableSpan where Element: ~Copyable {
  /// Calls a closure with a pointer to the viewed contiguous storage.
  func withUnsafeBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
  
  /// Calls a closure with a pointer to the viewed mutable contiguous
  /// storage.
  mutating func withUnsafeMutableBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
}

extension MutableSpan where Element: BitwiseCopyable {
  /// Calls a closure with a pointer to the underlying bytes of
  /// the viewed contiguous storage.
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result

  /// Calls a closure with a pointer to the underlying bytes of
  /// the viewed mutable contiguous storage.
  ///
  /// Note: mutating the bytes may result in the violation of
  ///       invariants in the internal representation of `Element`
  @unsafe
  mutating func withUnsafeMutableBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```
These functions use a closure to define the scope of validity of `buffer`, ensuring that the underlying `MutableSpan` and the binding it depends on both remain valid through the end of the closure. They have the same shape as the equivalents on `Array` because they fulfill the same function, namely to keep the underlying binding alive.

#### MutableRawSpan

`MutableRawSpan` is similar to `MutableSpan<T>`, but represents untyped initialized bytes. `MutableRawSpan` specifically supports encoding and decoding applications. Its API supports `unsafeLoad(as:)` and `storeBytes(of: as:)`, as well as a variety of bulk copying operations.

##### `MutableRawSpan` API:

```swift
@frozen
public struct MutableRawSpan: ~Copyable, ~Escapable {
  internal var _start: UnsafeMutableRawPointer?
  internal var _count: Int
}

extension MutableRawSpan: @unchecked Sendable
```

Initializers, required for library adoption, will be proposed alongside [lifetime annotations][PR-2305]; for details, see "[Initializers](#initializers)" in the [future directions](#Directions) section.

```swift
extension MutableRawSpan {
  /// The number of bytes in the span.
  var byteCount: Int { get }

  /// A Boolean value indicating whether the span is empty.
  var isEmpty: Bool { get }

  /// The range of valid byte offsets into this `RawSpan`
  var byteOffsets: Range<Int> { get }
}
```

##### Accessing and modifying  the memory of a `MutableRawSpan`:

`MutableRawSpan` supports storing the bytes of a `BitwiseCopyable` value to its underlying memory:

```swift
extension MutableRawSpan {
  /// Stores the given value's bytes into raw memory at the specified offset.
  mutating func storeBytes<T: BitwiseCopyable>(
    of value: T, toByteOffset offset: Int = 0, as type: T.Type
  )

  /// Stores the given value's bytes into raw memory at the specified offset.
  ///
  /// This function does not validate `offset`; this is an unsafe operation.
  @unsafe
  mutating func storeBytes<T: BitwiseCopyable>(
    of value: T, toUncheckedByteOffset offset: Int, as type: T.Type
  )
}
```

Additionally, the basic loading operations available on `RawSpan` are available for `MutableRawSpan`. These operations are not type-safe, in that the loaded value returned by the operation can be invalid, and violate type invariants. Some types have a property that makes the `unsafeLoad(as:)` function safe, but we don't have a way to [formally identify](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md#SurjectiveBitPattern) such types at this time.

```swift
extension MutableRawSpan {
  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  @unsafe
  func unsafeLoad<T>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  @unsafe
  func unsafeLoad<T>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T
}
```

We include functions to perform bulk copies into the memory represented by a `MutableRawSpan`. Updating a `MutableRawSpan` from a `Collection` or a `Span` copies every element of a source. It is an error to do so when there is are not enough bytes in the span to contain every element from the source. Updating `MutableRawSpan` from `Sequence` or `IteratorProtocol` instance copies as many items as possible, either until the input is empty or until there are not enough bytes in the span to store another element.

```swift
extension MutableRawSpan {
  /// Updates the span's bytes with the bytes of the elements from the source
  mutating func update<S: Sequence>(
    from source: S
  ) -> (unwritten: S.Iterator, byteOffset: Int) where S.Element: BitwiseCopyable
  
  /// Updates the span's bytes with the bytes of the elements from the source
  mutating func update<Element: BitwiseCopyable>(
    from source: inout some IteratorProtocol<Element>
  ) -> Int

  /// Updates the span's bytes with every byte of the source.
  mutating func update<C: Collection>(
    fromContentsOf source: C
  ) -> Int where C.Element: BitwiseCopyable
  
  /// Updates the span's bytes with every byte of the source.
  mutating func update<Element: BitwiseCopyable>(
    fromContentsOf source: Span<Element>
  ) -> Int
  
  /// Updates the span's bytes with every byte of the source.
  mutating func update<Element: BitwiseCopyable>(
    fromContentsOf source: borrowing MutableSpan<Element>
  ) -> Int
  
  /// Updates the span's bytes with every byte of the source.
  mutating func update(
    fromContentsOf source: RawSpan
  ) -> Int
  
  /// Updates the span's bytes with every byte of the source.
  mutating func update(
    fromContentsOf source: borrowing MutableRawSpan
  ) -> Int
}
```

##### Extracting sub-spans

These functions extract sub-spans of the callee. The first two perform strict bounds-checking. The last four return prefixes or suffixes, where the number of elements in the returned sub-span is bounded by the number of elements in the parent `MutableRawSpan`.

```swift
extension MutableRawSpan {
  /// Returns a span over the items within the supplied range of
  /// positions within this span.
  @_lifetime(inout self)
  mutating public func extracting(_ byteOffsets: Range<Int>) -> Self
  
  /// Returns a span over the items within the supplied range of
  /// positions within this span.
  @_lifetime(inout self)
  mutating public func extracting(_ byteOffsets: some RangeExpression<Int>) -> Self
  
  /// Returns a span containing the initial elements of this span,
  /// up to the specified maximum length.
  @_lifetime(inout self)
  mutating public func extracting(first maxLength: Int) -> Self
  
  /// Returns a span over all but the given number of trailing elements.
  @_lifetime(inout self)
  mutating public func extracting(droppingLast k: Int) -> Self
  
  /// Returns a span containing the final elements of the span,
  /// up to the given maximum length.
  @_lifetime(inout self)
  mutating public func extracting(last maxLegnth: Int) -> Self
  
  /// Returns a span over all but the given number of initial elements.
  @_lifetime(inout self)
  mutating public func extracting(droppingFirst k: Int) -> Self
}
```

We also provide unchecked variants of the `extracting()` functions as alternatives in situations where repeated bounds-checking is costly and has already been performed:

```swift
extension MutableRawSpan {
  /// Constructs a new span over the items within the supplied range of
  /// positions within this span.
  ///
  /// This function does not validate `byteOffsets`; this is an unsafe operation.
  @unsafe
  @_lifetime(inout self)
  mutating func extracting(unchecked byteOffsets: Range<Int>) -> Self
  
  /// Constructs a new span over the items within the supplied range of
  /// positions within this span.
  ///
  /// This function does not validate `byteOffsets`; this is an unsafe operation.
  @unsafe
  @_lifetime(inout self)
  mutating func extracting(unchecked byteOffsets: ClosedRange<Int>) -> Self
}
```

##### Interoperability with unsafe code:

```swift
extension MutableRawSpan {
  /// Calls a closure with a pointer to the underlying bytes of
  /// the viewed contiguous storage.
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result

  /// Calls a closure with a pointer to the underlying bytes of
  /// the viewed mutable contiguous storage.
  mutating func withUnsafeMutableBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```
These functions use a closure to define the scope of validity of `buffer`, ensuring that the underlying `MutableSpan` and the binding it depends on both remain valid through the end of the closure. They have the same shape as the equivalents on `Array` because they fulfill the same purpose, namely to keep the underlying binding alive.

#### <a name="extensions"></a>Properties providing `MutableSpan` or `MutableRawSpan` instances

##### Accessing and mutating the raw bytes of a `MutableSpan`

When a `MutableSpan`'s element is `BitwiseCopyable`, we allow mutations of the underlying storage as raw bytes, as a `MutableRawSpan`.

```swift
extension MutableSpan where Element: BitwiseCopyable {
  /// Access the underlying raw bytes of this `MutableSpan`'s elements
  ///
  /// Note: mutating the bytes may result in the violation of
  ///       invariants in the internal representation of `Element`
  @unsafe
  var mutableBytes: MutableRawSpan { @_lifetime(inout self) mutating get }
}
```

The standard library will provide `mutating` computed properties providing lifetime-dependent `MutableSpan` instances. These `mutableSpan` computed properties are intended as the safe and composable replacements for the existing `withUnsafeMutableBufferPointer` closure-taking functions.

##### <a name="extensions"></a>Extensions to Standard Library types

```swift
extension Array {
  /// Access this Array's elements as mutable contiguous storage.
  var mutableSpan: MutableSpan<Element> { @_lifetime(inout self) mutating get }
}

extension ContiguousArray {
  /// Access this Array's elements as mutable contiguous storage.
  var mutableSpan: MutableSpan<Element> { @_lifetime(inout self) mutating get }
}

extension ArraySlice {
  /// Access this Array's elements as mutable contiguous storage.
  var mutableSpan: MutableSpan<Element> { @_lifetime(inout self) mutating get }
}

extension InlineArray {
  /// Access this Array's elements as mutable contiguous storage.
  var mutableSpan: MutableSpan<Element> { @_lifetime(inout self) mutating get }
}

extension CollectionOfOne {
  /// Access this Collection's element as mutable contiguous storage.
  var mutableSpan: MutableSpan<Element> { @_lifetime(inout self) mutating get }
}
```

##### Extensions to unsafe buffer types

We hope that `MutableSpan` and `MutableRawSpan` will become the standard ways to delegate mutations of shared contiguous memory in Swift. Many current API delegate mutations via closure-based functions that receive an `UnsafeMutableBufferPointer` parameter. We will provide ways to unsafely obtain `MutableSpan` instances from `UnsafeMutableBufferPointer` and `MutableRawSpan` instances from `UnsafeMutableRawBufferPointer`, in order to bridge these unsafe types to newer, safer contexts.

```swift
extension UnsafeMutableBufferPointer {
  /// Unsafely access this buffer as a MutableSpan
  @unsafe
  var mutableSpan: MutableSpan<Element> { @_lifetime(borrow self) get }
}

extension UnsafeMutableRawBufferPointer {
  /// Unsafely access this buffer as a MutableRawSpan
  @unsafe
  var mutableBytes: MutableRawSpan { @_lifetime(borrow self) get }
}
```

These unsafe conversions returns a value whose lifetime is dependent on the _binding_ of the `UnsafeMutable[Raw]BufferPointer`. This dependency does not keep the underlying memory alive. As is usual where the `UnsafePointer` family of types is involved, the programmer must ensure the memory remains allocated while it is in use. Additionally, the following invariants must remain true for as long as the `MutableSpan` or `MutableRawSpan` value exists:

  - The underlying memory remains initialized.
  - The underlying memory is not accessed through another means.

Failure to maintain these invariants results in undefined behaviour.

##### Extensions to `Foundation.Data`

While the `swift-foundation` package and the `Foundation` framework are not governed by the Swift evolution process, `Data` is similar in use to standard library types, and the project acknowledges that it is desirable for it to have similar API when appropriate. Accordingly, we plan to propose the following additions to `Foundation.Data`:

```swift
extension Foundation.Data {
  // Access this instance's bytes as mutable contiguous storage
  var mutableSpan: MutableSpan<UInt8> { @_lifetime(inout self) mutating get }
  
  // Access this instance's bytes as mutable contiguous bytes
  var mutableBytes: MutableRawSpan { @_lifetime(inout self) mutating get }
}
```

#### <a name="performance"></a>Performance

The `mutableSpan` and `mutableBytes` properties should be performant and return their `MutableSpan` or `MutableRawSpan` with very little work, in O(1) time. In copy-on-write types, however, obtaining a `MutableSpan` is the start of the mutation. When the backing buffer is not uniquely referenced then a full copy must be made ahead of returning the `MutableSpan`.

Note that `MutableSpan` incurs no special behaviour for bridged types, since mutable bindings always require a defensive copy of data bridged from Objective-C data structures.

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library.

## Alternatives considered

#### Adding `withMutableSpan()` closure-taking functions

The `mutableSpan` and `mutableBytes` properties aim to be safe replacements for the `withUnsafeMutableBufferPointer()` and `withUnsafeMutableBytes()` closure-taking functions. We could consider `withMutableSpan()` and `withMutableBytes()` closure-taking functions that would provide a quicker migration away from the older unsafe functions. We do not believe the closure-taking functions are desirable in the long run. In the short run, there may be a desire to clearly mark the scope where a `MutableSpan` instance is used. The default method would be to explicitly consume a `MutableSpan` instance:

```swift
var a = ContiguousArray(0..<8)
var span = a.mutableSpan
modify(&span)
_ = consume span
a.append(8)
```

During the evolution of Swift, we have learned that closure-based API are difficult to compose, especially with one another. They can also require alterations to support new language features. For example, the generalization of closure-taking API for non-copyable values as well as typed throws is ongoing; adding more closure-taking API may make future feature evolution more labor-intensive. By instead relying on returned values, whether from computed properties or functions, we build for **greater** composability. Use cases where this approach falls short should be reported as enhancement requests or bugs.

#### Omitting extensions to `UnsafeBufferPointer` and related types

We could omit the extensions to `UnsafeMutableBufferPointer` and related types, and rely instead of future `MutableSpan` and `MutableRawSpan` initializers. The initializers can have the advantage of being able to communicate semantics (somewhat) through their parameter labels. However, they also have a very different shape than the `storage` computed properties we are proposing for the safe types such as `Array`. We believe that the adding the same API on both safe and unsafe types is advantageous, even if the preconditions for the properties cannot be statically enforced.

## <a name="directions"></a>Future directions

Note: The future directions stated in [SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md#Directions) apply here as well.

#### <a name="initializers"></a>Initializing and returning `MutableSpan` instances

`MutableSpan` represents a region of memory and, as such, must be initialized using an unsafe pointer. This is an unsafe operation which will typically be performed internally to a container's implementation. In order to bridge to safe code, these initializers require new annotations that indicate to the compiler how the newly-created `Span` can be used safely.

These annotations have been [pitched][PR-2305-pitch] and, after revision, are expected to be pitched again soon. `MutableSpan` initializers using lifetime annotations will be proposed alongside the annotations themselves.

#### Splitting `MutableSpan` instances – `MutableSpan` in divide-and-conquer algorithms

It is desirable to have a way to split a `MutableSpan` in multiple parts, for divide-and-conquer algorithms or other reasons:

```swift
extension MutableSpan where Element: ~Copyable {
  public mutating func split(at index: Index) -> (part1: Self, part2: Self)
}
```

Unfortunately, tuples do not support non-copyable or non-escapable values yet. We may be able to use `InlineArray` ([SE-0453][SE-0453]), or a bespoke type, but destructuring the non-copyable constituent part remains a challenge. Solving this issue for `Span` and `MutableSpan` is a top priority.

#### Mutating algorithms

Algorithms defined on `MutableCollection` such as `sort(by:)` and `partition(by:)` could be defined on `MutableSpan`. We believe we will be able to define these more generally once we have a generalized container protocol hierarchy.

#### Exclusive Access

The `mutating` functions in this proposal generally do not represent mutations of the binding itself, but of memory being referenced. `mutating` is necessary in order to model the necessary exclusive access to the memory. We could conceive of an access level between "shared" (`let`) and "exclusive" (`var`) that would model an exclusive access while allowing the pointer and count information to be stored in registers.

#### Harmonizing `extracting()` functions across types

The range of `extracting()` functions proposed here expands upon the range accepted in [SE-0437][SE-0437]. If the prefix and suffix variants are accepted, we should add them to `UnsafeBufferPointer` types as well. `Span` and `RawSpan` should also have `extracting()` functions with appropriate lifetime dependencies.

#### <a name="OutputSpan"></a>Delegated initialization with `OutputSpan<T>`

Some data structures can delegate initialization of parts of their owned memory. The standard library added the `Array` initializer `init(unsafeUninitializedCapacity:initializingWith:)` in [SE-0223][SE-0223]. This initializer relies on `UnsafeMutableBufferPointer` and correct usage of initialization primitives. We should present a simpler and safer model of initialization by leveraging non-copyability and non-escapability.

We expect to propose an `OutputSpan<T>` type to represent partially-initialized memory, and to support to the initialization of memory by appending to the initialized portion of the underlying storage.
