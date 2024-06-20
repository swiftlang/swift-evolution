# Safe Access to Contiguous Storage

* Proposal: [SE-NNNN](nnnn-safe-shared-contiguous-storage.md)
* Authors: [Guillaume Lessard](https://github.com/glessard), [Andrew Trick](https://github.com/atrick), [Michael Ilseman](https://github.com/milseman)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Bug: rdar://48132971, rdar://96837923
* Implementation: Prototyped in https://github.com/apple/swift-collections (on branch "future")
* Review: ([pitch 1](https://forums.swift.org/t/69888))([pitch 2]())

## Introduction

We introduce `Span<T>`, an abstraction for container-agnostic access to contiguous memory. It will expand the expressivity of performant Swift code without comprimising on the memory safety properties we rely on: temporal safety, spatial safety, definite initialization and type safety.

In the C family of programming languages, memory can be shared with any function by using a pointer and (ideally) a length. This allows contiguous memory to be shared with a function that doesn't know the layout of a container being used by the caller. A heap-allocated array, contiguously-stored named fields or even a single stack-allocated instance can all be accessed through a C pointer. We aim to create a similar idiom in Swift, without compromising Swift's memory safety.

This proposal is related to two other features being proposed along with it: [Nonescapable types](https://github.com/apple/swift-evolution/pull/2304) (`~Escapable`) and [Compile-time Lifetime Dependency Annotations](https://github.com/apple/swift-evolution/pull/2305). This proposal also supersedes the rejected proposal [SE-0256](https://github.com/apple/swift-evolution/blob/main/proposals/0256-contiguous-collection.md). The overall feature of ownership and lifetime constraints has previously been discussed in the [BufferView roadmap](https://forums.swift.org/t/66211) forum thread.

## Motivation

Swift needs safe and performant types for local processing over values in contiguous memory. Consider for example a program using multiple libraries, including one for [base64](https://datatracker.ietf.org/doc/html/rfc4648) decoding. The program would obtain encoded data from one or more of its dependencies, which could supply the data in the form of `[UInt8]`, `Foundation.Data` or even `String`, among others. None of these types is necessarily more correct than another, but the base64 decoding library must pick an input format. It could declare its input parameter type to be `some Sequence<UInt8>`, but such a generic function significantly limits performance. This may force the library author to either declare its entry point as inlinable, or to implement an internal fast path using `withContiguousStorageIfAvailable()`, forcing them to use an unsafe type. The ideal interface would have a combination of the properties of both `some Sequence<UInt8>` and `UnsafeBufferPointer<UInt8>`.

The `UnsafeBufferPointer` passed to a `withUnsafeXXX` closure-style API, while performant, is unsafe in multiple ways:

1. The pointer itself is unsafe and unmanaged
2. `subscript` is only bounds-checked in debug builds of client code
3. It might escape the duration of the closure

Even if the body of the `withUnsafeXXX` call does not escape the pointer, other functions called inside the closure have to be written in terms of unsafe pointers. This requires programmer vigilance across a project and potentially spreads the use of unsafe types, even when it could have been written in terms of safe constructs.

We want to take advantage of the features of non-escapable types to replace some closure-taking API with simple properties, resulting in more composable code:

```swift
let array = Array("Hello\0".utf8)

// Old
array.withUnsafeBufferPointer {
  // use `$0` here for direct memory access
}

// New
let span: Span<UInt8> = array.storage
// use `span` in the same scope as `array` for direct memory access

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

Even better, an interface can be defined in terms of the concrete type `Span<UInt8>`:

```swift
extension Hypothetical Base64Decoder {
  public func decode(bytes: Span<UInt8>) -> [UInt8]
}
```

Advanced libraries might add use an inlinable generic-dispatch interface in addition to a concrete interface defined in terms of `Span`

### `RawSpan`

`RawSpan` allows sharing the contiguous internal representation for values which may be heterogenously-typed, such as in decoders. Since it is a fully concrete type, it can achieve better performance in debug builds of client code as well as a more straight-forwards understanding of performance for library code.

`Span<some BitwiseCopyable>` can always be converted to `RawSpan`, using a conditionally-available property or a constructor.

## Detailed design

`Span<Element>` is a simple representation of a span of initialized memory.

```swift
public struct Span<Element: ~Copyable & ~Escapable>: Copyable, ~Escapable {
  internal var _start: UnsafePointer<Element>
  internal var _count: Int
}
```

It provides a buffer-like interface to the elements stored in that span of memory:

```swift
extension Span {
  public var count: Int { get }
  public var isEmpty: Bool { get }
  public var indices: Range<Int> { get }

  subscript(_ position: Int) -> Element { get }
}
```

Note that `Span` does _not_ conform to `Collection`. This is because `Collection`, as originally conceived and enshrined in existing source code, assumes pervasive copyability and escapability for itself as well as its elements. In particular a subsequence of a `Collection` is semantically a separate value from the instance it was derived from. In the case of `Span`, a sub-span representing a subrange of its elements _must_ have the same lifetime as the view from which it originates. Another proposal will consider collection-like protocols to accommodate different combinations of `~Copyable` and `~Escapable` for the collection and its elements.

`Span`s representing subsets of consecutive elements can be extracted out of a larger `Span` with an API similar to the recently added `extracting()` functions of `UnsafeBufferPointer`:

```swift
extension Span {
  public func extracting(_ bounds: Range<Int>) -> Self
}
```

The first element of a given span is _always_ at position zero, and its last it as position `count-1`.

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
```

In addition to the the safe types above gaining the `storage` property, the `UnsafeBufferPointer` family of types will also gain access to a `storage` property. This enables interoperability of `Span`-taking API. While a `Span` binding created from an `UnsafeBufferPointer` exists, the memory that underlies it must not be deinitialized or deallocated.

```swift
extension UnsafeBufferPointer: ContiguousStorage<Self.Element> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<Element> { get }
}
extension UnsafeMutableBufferPointer: ContiguousStorage<Self.Element> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<Element> { get }
}
extension UnsafeRawBufferPointer: ContiguousStorage<UInt8> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<UInt8> { get }
}
extension UnsafeMutableRawBufferPointer: ContiguousStorage<UInt8> {
  // note: additional preconditions apply until the end of the scope
  var storage: Span<UInt8> { get }
}
```

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



### Complete `Span` API:

```swift
public struct Span<Element: ~Copyable & ~Escapable>: Copyable, ~Escapable {
  internal var _start: Span<Element>.Index
  internal var _count: Int
}
```

##### Creating a `Span`:

The initialization of a `Span` instance from an unsafe pointer is an unsafe operation. When it is initialized correctly, subsequent uses of the borrowed instance are safe. Typically these initializers will be used internally to a container's implementation of functions or computed properties that return a borrowed `Span`.

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
  ///            the newly created `Span`.
  public init?<Owner>(
    unsafeElements buffer: UnsafeBufferPointer<Element>,
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
  ///            the newly created `Span`.
  public init<Owner>(
    unsafeStart pointer: UnsafePointer<Element>,
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
  ///            the newly created `Span`.
  public init<Owner>(
    unsafeBytes buffer: UnsafeRawBufferPointer,
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
  ///            the newly created `Span`.
  public init<Owner>(
    unsafeStart pointer: UnsafeRawPointer,
    byteCount: Int,
    owner: borrowing Owner
  ) -> dependsOn(owner) Self
}
```

#####  `Collection`-like API:

The following properties, functions and subscripts have direct counterparts in the `Collection` protocol hierarchy. Their semantics shall be as described where they counterpart is declared (in `Collection` or `RandomAccessCollection`). The only difference with their counterpart should be a lifetime dependency annotation where applicable, allowing them to return borrowed nonescapable values or borrowed noncopyable values.

```swift
extension Span {
  public var count: Int { get }
  public var isEmpty: Bool { get }
  public var indices: Range<Int> { get }

  public subscript(_ position: Int) -> dependsOn(self) Element { get }
}
```

##### Accessing subranges of elements:

In SE-0437, `UnsafeBufferPointer`'s slicing subscript was replaced by the `extracting(_ bounds:)` functions, due to the copyability assumption baked into the standard library's `Slice` type. `Span` has similar requirements as `UnsafeBufferPointer`, in that it must be possible to obtain an instance representing a subrange of the same memory as another `Span`. We therefore follow in the footsteps of SE-0437, and add a family of `extracting()` functions:

```swift
extension Span {
  func extracting(_ bounds: Range<Int>) -> dependsOn(self) Self
  func extracting(_ bounds: some RangeExpression<Int>) -> dependsOn(self) Self
  func extracting(_: UnboundedRange) -> dependsOn(self) Self
}
```

##### Unchecked access to elements and subranges of elements:

The `subscript` and the `extracting()` functions mentioned above all have always-on bounds checking of their parameters, in order to prevent out-of-bounds accesses. We also want to provide unchecked variants as an alternative for cases where bounds-checking is proving costly.

```swift
extension Span {
  // Unchecked subscripting and extraction

  /// Accesses the element at the specified `position`.
  ///
  /// This subscript does not validate `position`; this is an unsafe operation.
  ///
  /// - Parameter position: The position of the element to access. `position`
  ///     must be a valid index that is not equal to the `endIndex` property.
  public subscript(
    unchecked position: Index
  ) -> dependsOn(self) Element { get }

  /// Accesses a contiguous subrange of the elements represented by this `Span`
  ///
  /// This subscript does not validate `bounds`; this is an unsafe operation.
  ///
  /// - Parameter bounds: A range of the collection's indices. The bounds of
  ///     the range must be valid indices of the collection.
  public extracting(
    uncheckedBounds bounds: Range<Index>
  ) -> dependsOn(self) Self

  /// Accesses the contiguous subrange of the elements represented by
  /// this `Span`, specified by a range expression.
  ///
  /// This subscript does not validate `bounds`; this is an unsafe operation.
  ///
  /// - Parameter bounds: A range of the collection's indices. The bounds of
  ///     the range must be valid indices of the collection.
  public func extracting(
    uncheckedBounds bounds: some RangeExpression<Index>
  ) -> dependsOn(self) Span<Element>
}
```

##### Index validation utilities:

Every time `Span` uses a position parameter, it checks for its validity, unless the parameter is marked with the word "unchecked". The validation is performed with these functions:

```swift
extension Span {
  /// Traps if `position` is not a valid offset into this `Span`
  ///
  /// - Parameters:
  ///   - position: an position to validate
  public boundsCheckPrecondition(_ position: Int)

  /// Traps if `bounds` is not a valid range of offsets into this `Span`
  ///
  /// - Parameters:
  ///   - position: a range of positions to validate
  public boundsCheckPrecondition(_ bounds: Range<Index>)
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

### RawSpan

In addition to `Span<T>`, we propose the addition of `RawSpan`, to represent heterogenously-typed values in contiguous memory. `RawSpan` is similar to `Span<T>`, but represents _untyped_ initialized bytes. `RawSpan` is a specialized type that intends to support parsing and decoding applications, as well as applications where heavily-used code paths require concrete types as much as possible. Its API supports extracting sub-spans, along with the operations `load(as:)` and `loadUnaligned(as:)`.

#### Complete `RawSpan` API:

```swift
public struct RawSpan: Copyable, ~Escapable {
  internal var _start: UnsafeRawPointer
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
  ///            the newly created `RawSpan`.
  public init?<Owner: ~Copyable & ~Escapable>(
    unsafeBytes buffer: UnsafeRawBufferPointer,
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
  ///            the newly created `RawSpan`.
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
  public init<T: BitwiseCopyable>(
    _ span: borrowing Span<T>
  ) -> dependsOn(span) Self
}
```

##### Accessing the memory of a `RawSpan`:

The basic operations to access the contents of the memory underlying a `RawSpan` are `load(as:)` and `loadUnaligned(as:)`.

```swift
extension RawSpan {
  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// The memory at this pointer plus `offset` must be properly aligned for
  /// accessing `T` and initialized to `T` or another type that is layout
  /// compatible with `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance is memory-managed and unassociated
  ///     with the value in the memory referenced by this pointer.
  public func load<T>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// The memory at this pointer plus `offset` must be properly aligned for
  /// accessing `T` and initialized to `T` or another type that is layout
  /// compatible with `T`.
  ///
  /// This function does not validate the bounds of the memory access;
  /// this is an unsafe operation.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance is memory-managed and unassociated
  ///     with the value in the memory referenced by this pointer.
  public func load<T>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance isn't associated
  ///     with the value in the range of memory referenced by this pointer.
  public func loadUnaligned<T: BitwiseCopyable>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// This function does not validate the bounds of the memory access;
  /// this is an unsafe operation.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance isn't associated
  ///     with the value in the range of memory referenced by this pointer.
  public func loadUnaligned<T: BitwiseCopyable>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T
}
```

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

##### Index-related Operations:

```swift
extension RawSpan {
  /// The number of bytes in the span.
  public var count: Int { get }

  /// A Boolean value indicating whether the span is empty.
  public var isEmpty: Bool { get }

  /// The indices that are valid for subscripting the span, in ascending
  /// order.
  public var indices: Range<Int> { get }

  /// Traps if `offset` is not a valid offset into this `RawSpan`
  ///
  /// - Parameters:
  ///   - position: an offset to validate
  public func boundsCheckPrecondition(_ offset: Int)

  /// Traps if `bounds` is not a valid range of offsets into this `RawSpan`
  ///
  /// - Parameters:
  ///   - offsets: a range of offsets to validate
  public func boundsCheckPrecondition(_ offsets: Range<Int>)
}
```

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

##### Accessing subranges of elements:

Similarly to `Span`, `RawSpan` does not support slicing in the style of `Collection`. It supports a similar set of `extracting()` functions as `Span`:

```swift
extension RawSpan {
  /// Constructs a new span over the bytes within the supplied range of
  /// positions within this span.
  ///
  /// The returned span's first byte is always at offset 0; unlike buffer
  /// slices, extracted spans do not generally share their indices with the
  /// span from which they are extracted.
  ///
  /// - Parameter bounds: A valid range of positions. Every position in
  ///     this range must be within the bounds of this `RawSpan`.
  ///
  /// - Returns: A `Span` over the bytes within `bounds`
  public func extracting(_ bounds: Range<Int>) -> Self

  /// Constructs a new span over the bytes within the supplied range of
  /// positions within this span.
  ///
  /// The returned span's first byte is always at offset 0; unlike buffer
  /// slices, extracted spans do not generally share their indices with the
  /// span from which they are extracted.
  ///
  /// This function does not validate `bounds`; this is an unsafe operation.
  ///
  /// - Parameter bounds: A valid range of positions. Every position in
  ///     this range must be within the bounds of this `RawSpan`.
  ///
  /// - Returns: A `Span` over the bytes within `bounds`
  public func extracting(uncheckedBounds bounds: Range<Int>) -> Self

  /// Constructs a new span over the bytes within the supplied range of
  /// positions within this span.
  ///
  /// The returned span's first byte is always at offset 0; unlike buffer
  /// slices, extracted spans do not generally share their indices with the
  /// span from which they are extracted.
  ///
  /// - Parameter bounds: A valid range of positions. Every position in
  ///     this range must be within the bounds of this `RawSpan`.
  ///
  /// - Returns: A `Span` over the bytes within `bounds`
  public func extracting(_ bounds: some RangeExpression<Int>) -> Self

  /// Constructs a new span over the bytes within the supplied range of
  /// positions within this span.
  ///
  /// The returned span's first byte is always at offset 0; unlike buffer
  /// slices, extracted spans do not generally share their indices with the
  /// span from which they are extracted.
  ///
  /// This function does not validate `bounds`; this is an unsafe operation.
  ///
  /// - Parameter bounds: A valid range of positions. Every position in
  ///     this range must be within the bounds of this `RawSpan`.
  ///
  /// - Returns: A `Span` over the bytes within `bounds`
  public func extracting(
    uncheckedBounds bounds: some RangeExpression<Int>
  ) -> Self

  /// Constructs a new span over all the bytes of this span.
  ///
  /// The returned span's first byte is always at offset 0; unlike buffer
  /// slices, extracted spans do not generally share their indices with the
  /// span from which they are extracted.
  ///
  /// - Returns: A `RawSpan` over all the items of this span.
  public func extracting(_: UnboundedRange) -> Self

  /// Returns a span containing the initial bytes of this span,
  /// up to the specified maximum byte count.
  ///
  /// If the maximum length exceeds the length of this span,
  /// the result contains all the bytes.
  ///
  /// - Parameter maxLength: The maximum number of bytes to return.
  ///   `maxLength` must be greater than or equal to zero.
  /// - Returns: A span with at most `maxLength` bytes.
  public func extracting(first maxLength: Int) -> Self

  /// Returns a span over all but the given number of trailing bytes.
  ///
  /// If the number of elements to drop exceeds the number of elements in
  /// the span, the result is an empty span.
  ///
  /// - Parameter k: The number of bytes to drop off the end of
  ///   the span. `k` must be greater than or equal to zero.
  /// - Returns: A span leaving off the specified number of bytes at the end.
  public func extracting(droppingLast k: Int) -> Self

  /// Returns a span containing the trailing bytes of the span,
  /// up to the given maximum length.
  ///
  /// If the maximum length exceeds the length of this span,
  /// the result contains all the bytes.
  ///
  /// - Parameter maxLength: The maximum number of bytes to return.
  ///   `maxLength` must be greater than or equal to zero.
  /// - Returns: A span with at most `maxLength` bytes.
  public func extracting(last maxLength: Int) -> Self

  /// Returns a span over all but the given number of initial bytes.
  ///
  /// If the number of elements to drop exceeds the number of bytes in
  /// the span, the result is an empty span.
  ///
  /// - Parameter k: The number of bytes to drop from the beginning of
  ///   the span. `k` must be greater than or equal to zero.
  /// - Returns: A span starting after the specified number of bytes.
  public func extracting(droppingFirst k: Int = 1) -> Self
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

The ideas in this proposal previously used the name `BufferView`. While the use of the word "buffer" would be consistent with the `UnsafeBufferPointer` type, it is nevertheless not a great name, since "buffer" is usually used in reference to transient storage. On the other hand we already have a nomenclature using the term "Storage" in the `withContiguousStorageIfAvailable()` function, and we tried to allude to that in a previous pitch where we called this type `StorageView`. We also considered the name `StorageSpan`, but that did not add much beyond the name `Span`. `Span` clearly identifies itself as a relative of C++'s `std::span`.

##### Adding `load` and `loadUnaligned` to `Span<UInt8>`on `Span<some BitwiseCopyable>` instead of adding `RawSpan`

TKTKTK

`Cursor` stores and manages a parsing subrange, which alleviates the developer from managing one layer of slicing.

##### A more sophisticated approach to indexing

This is discussed more fully in the [indexing appendix](#Indexing) below.

## Future directions

### Byte parsing helpers

A handful of helper API can make `RawSpan` better suited for binary parsers and decoders.

```swift
extension RawSpan {
  @frozen
  public struct Cursor: Copyable, ~Escapable {
    public let base: RawSpan

    /// The current parsing position
    public var position: RawSpan.Index

    @inlinable
    public init(_ base: RawSpan)

    /// Parse an instance of `T` and advance
    @inlinable
    public mutating func parse<T: _BitwiseCopyable>(
      _ t: T.Type = T.self
    ) throws(OutOfBoundsError) -> T

    /// Parse `numBytes`and advance
    @inlinable
    public mutating func parse(
      numBytes: some FixedWidthInteger
    ) throws (OutOfBoundsError) -> RawSpan

    /// The bytes that we've parsed so far
    @inlinable
    public var parsedBytes: RawSpan { get }

    /// The remaining bytes left to parse
    @inlinable
    public var remainingBytes: RawSpan { get }
  }

  @inlinable
  public func makeCursor() -> Cursor
}
```

Alternatively, if some future `RawSpan.Iterator` were 3 words in size (start, current position, and end) instead of 2 (current pointer and end), that is it were a "resettable" iterator, it could host this API instead of introducing a new `Cursor` type or concept.

#### Example: Parsing PNG

The below parses [PNG Chunks](https://www.w3.org/TR/png-3/#4Concepts.FormatChunks).

```swift
struct PNGChunk: ~Escapable {
  let contents: RawSpan

  public init<Owner: ~Copyable & ~Escapable>(
    _ contents: RawSpan, _ owner: borrowing Owner
  ) throws (PNGValidationError) -> dependsOn(owner) Self {
    self.contents = contents
    try self._validate()
  }

  var length: UInt32 {
    contents.loadUnaligned(as: UInt32.self).bigEndian
  }
  var type: UInt32 {
    contents.loadUnaligned(
      fromUncheckedByteOffset: 4, as: UInt32.self).bigEndian
  }
  var data: RawSpan {
    contents[uncheckedOffsets: 8..<(contents.count-4)]
  }
  var crc: UInt32 {
    contents.loadUnaligned(
      fromUncheckedByteOffset: contents.count-4, as: UInt32.self
    ).bigEndian
  }
}

func parsePNGChunk<Owner: ~Copyable & ~Escapable>(
  _ span: RawSpan,
  _ owner: borrowing Owner
) throws -> dependsOn(owner) PNGChunk {
  var cursor = span.makeCursor()

  let length = try cursor.parse(UInt32.self).bigEndian
  _ = try cursor.parse(UInt32.self)             // type
  _ = try cursor.parse(numBytes: length)        // data
  _ = try cursor.parse(UInt32.self)             // crc

  return PNGChunk(cursor.parsedBytes, owner)
}
```




---

##### Defining `BorrowingIterator` with support in `for` loops
This proposal does not define an `IteratorProtocol` conformance, since it would need to be borrowed and non-escapable. This is not compatible with `IteratorProtocol`. As such, `Span`  is not directly usable in `for` loops as currently defined. A `BorrowingIterator` protocol for non-escapable and non-copyable containers must be defined, providing a `for` loop syntax where the element is borrowed through each iteration. Ultimately we should arrive at a way to iterate through borrowed elements from a borrowed view:

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
var i = 0
while i < view.count {
  doSomething(view[i])
  view.index(after: &i)
}

// ...or:
for i in 0..<view.indices {
  doSomething(view[i])
}
```

##### Collection-like protocols for non-copyable and non-escapable types

Non-copyable and non-escapable containers would benefit from a `Collection`-like protocol family to represent a set basic, common operations. This may be `Collection` if we find a way to make it work; it may be something else.

Alongside this work, it may make sense to add a `Span` alternative to `withContiguousStorageIfAvailable()`, `RawSpan` alternative to `withUnsafeBytes`, etc., and seek to deprecate any closure-based API around unsafe pointers.

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
The [`std::span`](https://en.cppreference.com/w/cpp/container/span) class template from the C++ standard library is a similar representation of a contiguous range of memory. LLVM may soon have a [bounds-checking mode](https://discourse.llvm.org/t/70854) for C. These are opportunities for better, safer interoperation with Swift, via a type such as `Span`.

## Acknowledgments

Joe Groff, John McCall, Tim Kientzle, Karoy Lorentey contributed to this proposal with their clarifying questions and discussions.



## <a name="Indexing"></a>Appendix: Index and slicing design considerations

Early prototypes of this proposal defined an `Index` type, `Iterator` types, etc. We are proposing `Int`-based API and are deferring defining `Index` and `Iterator` until more of the non-escapable collection story is sorted out. The below is some of our research into different potential designs of an `Index` type.

There are 3 potentially-desirable features of `Span`'s `Index` design:

1. `Span` is its own slice type
2. Indices from a slice can be used on the base collection
3. Additional reuse-after-free checking

Each of these introduces practical tradeoffs in the design.

#### `Span` is its own slice type

Collections which own their storage have the convention of separate slice types, such as `Array` and `String`. This has the advantage of clearly delineating storage ownership in the programming model and the disadvantage of introducing a second type through which to interact.

When types do not own their storage, separate slice types can be [cumbersome](https://github.com/apple/swift/blob/bcd08c0c9a74974b4757b4b8a2d1796659b1d940/stdlib/public/core/StringComparison.swift#L175). The reason `UnsafeBufferPointer` has a separate slice type is because it wants to allow indices to be reused across slices and its `Index` is a relative offset from the start (`Int`) rather than an absolute position (such as a pointer).

`Span` does not own its storage and there is no concern about leaking larger allocations. It would benefit from being its own slice type.


#### Indices from a slice can be used on the base collection

There is very strong stdlib precedent that indices from the base collection can be used in a slice and vice-versa. 

```swift
let myCollection = [0,1,2,3,4,5,6]
let idx = myCollection.index(myCollection.startIndex, offsetBy: 4)
myCollection[idx]                   // 4
let slice = myCollection[idx...]    // [4, 5, 6]
slice[idx]                          // 4
myCollection[slice.indices]         // [4, 5, 6]
```

Code can be written to take advantage of this fact. For example, a simplistic parser can be written as mutating methods on a slice. The slice's indices can be saved for reference into the original collection or another slice. 

```swift
extension Slice where Base == UnsafeRawBufferPointer {
  mutating func parse(numBytes: Int) -> Self {
    let end = index(startIndex, offsetBy: numBytes)
    defer { self = self[end...] }
    return self[..<end]
  }
  mutating func parseInt() -> Int {
    parse(numBytes: MemoryLayout<Int>.stride).loadUnaligned(as: Int.self)
  }

  mutating func parseHeader() -> Self {
    // Comments show what happens when ran with `myCollection`

    let copy = self
    parseInt()         // 0
    parseInt()         // 1
    parse(numBytes: 8) // [2, 0, 0, 0, 0, 0, 0, 0]
    parseInt()         // 3
    parse(numBytes: 7) // [4, 0, 0, 0, 0, 0, 0]

    // self: [0, 5, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0]
    parseInt()         // 1280 (0x00_00_05_00 little endian)
    // self: [0, 6, 0, 0, 0, 0, 0, 0, 0]

    return copy[..<self.startIndex]
  }  
}

myCollection.withUnsafeBytes {
  var byteParser = $0[...]
  let header = byteParser.parseHeader()

  // header:     [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 
  //              2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 
  //              4, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0]
  //
  // byteParser: [0, 6, 0, 0, 0, 0, 0, 0, 0]
}
```

Note, however, that parsers tend to become more complex and copying slices for later index extraction becomes more common. At that point, it is better to use a more powerful approach such as the index-advancing or cursor API presented in *Byte parsing helpers*.

That being said, if we had a time machine it's not clear that we would choose a design with index interchange, as it does introduce design tradeoffs and makes some code, especially when the index type is `Int`, troublesome:

```swift
func getFirst<C: Collection>(
  _ c: C
) -> C.Element where C.Index == Int {
  c[0]
}

getFirst(myCollection) // 0
getFirst(slice)        // Fatal error: Index out of bounds
```


#### Additional reuse-after-free checking

`Span` bounds-checks its indices, which is important for safety. If the index is based around a pointer (instead of an offset), then bounds checks will also ensure that indices are not used with the wrong span in most situations. However, it is possible for a memory address to be reused after being freed and using a stale index into this reused memory may introduce safety problems.

```swift
var idx: Span<T>.Index

let array1: Array<T> = ...
let span1 = array1.span
idx = span1.startIndex.advanced(by: ...)
...
// array1 is freed

let array2: Array<T> = ...
let span2 = array2.span
// array2 happens to be allocated within the same memory of array1
// but with a different base address whose offset is not an even
// multiple of `MemoryLayout<T>.stride`.

span2[idx] // misaligned load, what happens?
```

If `T` is `BitwiseCopyable`, then the misaligned load is not undefined behavior, but the value that is loaded is garbage. Whether the program is well-behaved going forwards depends on whether it is resilient to getting garbage values.

If `T` is not `BitwiseCopyable`, then the misaligned load may introduce undefined behavior. No matter how well-written the rest of the program is, it has a critical safety and security flaw.

When the reused allocation happens to be stride-aligned, there is no undefined behavior from undefined loads, nor are there "garbage" values in the strictest sense, but it is still reflective of a programming bug. The program may be interacting with an unexpected value.

Bounds checks protect against critical programmer errors. It would be nice, pending engineering tradeoffs, to also protect against some reuse after free errors and invalid index reuse, especially those that may lead to undefined behavior.

Future improvements to microarchitecture may make reuse after free checks cheaper, however we need something for the forseeable future. Any validation we can do reduces the need to switch to other mitigation strategies or make other tradeoffs.

#### Design approaches for indices

##### Index is an offset (`Int` or a wrapper around `Int`)

When `Index` is an offset, there is no undefined behavior from misaligned loads because the `Span`'s base address is advanced by `MemoryLayout<T>.stride * offset`. 

However, there is no protection against invalidly using an index derived from a different span, provided the offset is in-bounds.

Since `Span` is 2 words (base address and count), indices cannot be interchanged between slices and the base span. In order to do so, `Span` would need to additionally store a base offset, bringing it up to 3 words in size.

##### Index is a pointer (wrapper around `UnsafeRawPointer`)

When Index holds a pointer, `Span` only needs to be 2 words in size, as valid index interchange across slices falls out naturally. Additionally, invalid reuse of an index across spans will typically be caught during bounds checking.

However, in a reuse-after-free situation, misaligned loads (i.e. undefined behavior) are possible. If stride is not a multiple of 2, then alignment checking can be expensive. Alternatively, we could choose not to detect these bugs.

##### Index is a fat pointer (pointer and allocation ID)

We can create a per-allocation ID (e.g. a cryptographic `UInt64`) for both `Span` and `Span.Index` to store. This would make `Span` 3 words in size and `Span.Index` 2 words in size. This provides the most protection possible against all forms of invalid index use, including reuse-after-free. However, making `Span` be 3 words and `Span.Index` 2 words for this feature is unfortunate.

We could instead go with 2 word `Span` and 2 word `Span.Index` by storing the span's `baseAddress` in the `Index`'s second word. This will detect invalid reuse of indices across spans in addition to misaligned reuse-after-free errors. However, indices could not be interchanged without a way for the slice type to know the original span's base address (e.g. through a separate slice type or making `Span` 3 words in size).

In either approach, making `Span.Index` be 2 words in size is unfortunate. `Range<Span.Index>` is now 4 words in size, storing the allocation ID twice. Anything built on top of `Span` that wishes to store multiple indices is either bloated or must hand-extract the pointers and hand-manage the allocation ID.


