# Span: Safe Access to Contiguous Storage

* Proposal: [SE-0447](0447-span-access-shared-contiguous-storage.md)
* Authors: [Guillaume Lessard](https://github.com/glessard), [Michael Ilseman](https://github.com/milseman), [Andrew Trick](https://github.com/atrick)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 6.2)**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Bug: rdar://48132971, rdar://96837923
* Implementation: [apple/swift#76406](https://github.com/swiftlang/swift/pull/76406)
* Review: ([Pitch 1](https://forums.swift.org/t/69888))([Pitch 2](https://forums.swift.org/t/72745))([Review](https://forums.swift.org/t/se-0447-span-safe-access-to-contiguous-storage/74676))([Acceptance](https://forums.swift.org/t/accepted-se-0447-span-safe-access-to-contiguous-storage/75508))

## Introduction

We introduce `Span<T>`, an abstraction for container-agnostic access to contiguous memory. It will expand the expressivity of performant Swift code without compromising on the memory safety properties we rely on: temporal safety, spatial safety, definite initialization and type safety.

In the C family of programming languages, memory can be shared with any function by using a pointer and (ideally) a length. This allows contiguous memory to be shared with a function that doesn't know the layout of a container being used by the caller. A heap-allocated array, contiguously-stored named fields or even a single stack-allocated instance can all be accessed through a C pointer. We aim to enable a similar idiom in Swift, without compromising Swift's memory safety.

This proposal builds on [Nonescapable types][PR-2304] (`~Escapable`,) and is a precursor to [Compile-time Lifetime Dependency Annotations][PR-2305], which will be proposed in the following weeks. The [BufferView roadmap](https://forums.swift.org/t/66211) forum thread was an antecedent to this proposal. This proposal also depends on the following proposals:

- [SE-0426] BitwiseCopyable
- [SE-0427] Noncopyable generics
- [SE-0437] Non-copyable Standard Library Primitives
- [SE-0377] `borrowing` and `consuming` parameter ownership modifiers

[SE-0426]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0426-bitwise-copyable.md
[SE-0427]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0427-noncopyable-generics.md
[SE-0437]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0437-noncopyable-stdlib-primitives.md
[SE-0377]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md
[PR-2304]: https://github.com/swiftlang/swift-evolution/pull/2304
[PR-2305]: https://github.com/swiftlang/swift-evolution/pull/2305
[PR-2305-pitch]: https://forums.swift.org/t/69865

## <a name="Motivation"></a>Motivation

Swift needs safe and performant types for local processing over values in contiguous memory. Consider for example a program using multiple libraries, including one for [base64](https://datatracker.ietf.org/doc/html/rfc4648) decoding. The program would obtain encoded data from one or more of its dependencies, which could supply the data in the form of `[UInt8]`, `Foundation.Data` or even `String`, among others. None of these types is necessarily more correct than another, but the base64 decoding library must pick an input format. It could declare its input parameter type to be `some Sequence<UInt8>`, but such a generic function can significantly limit performance. This may force the library author to either declare its entry point as inlinable, or to implement an internal fast path using `withContiguousStorageIfAvailable()`, forcing them to use an unsafe type. The ideal interface would have a combination of the properties of both `some Sequence<UInt8>` and `UnsafeBufferPointer<UInt8>`.

The `UnsafeBufferPointer` passed to a `withUnsafeXXX` closure-style API, while performant, is unsafe in multiple ways:

1. The pointer itself is unsafe and unmanaged
2. `subscript` is only bounds-checked in debug builds of client code
3. It might escape the duration of the closure

Even if the body of the `withUnsafeXXX` call does not escape the pointer, other functions called within the closure have to be written in terms of unsafe pointers. This requires programmer vigilance across a project and potentially spreads the use of unsafe types, even if the helper functions could have been written in terms of safe constructs.

## Proposed solution

#### `Span`

`Span` will allow sharing the contiguous internal representation of a type, by providing access to a borrowed view of an interval of contiguous memory. `Span` does not copy the underlying data: it instead relies on a guarantee that the original container cannot be modified or destroyed while the `Span` exists. In the prototype that accompanies this first proposal, `Span`s will be constrained to closures from which they structurally cannot escape. Later, we will introduce a lifetime dependency between a `Span` and the binding of the type vending it, preventing its escape from the scope where it is valid for use. Both of these approaches guarantee temporal safety. `Span` also performs bounds-checking on every access to preserve spatial safety. Additionally `Span` always represents initialized memory, preserving the definite initialization guarantee.

`Span` is intended as the currency type for local processing over values in contiguous memory. It is a replacement for many API currently using `Array`, `UnsafeBufferPointer`, `Foundation.Data`, etc., that do not need to escape the owning container.

A `Span` provided by a container represents a borrow of that container. `Span` can therefore provide simultaneous access to a non-copyable container. It can also help avoid unwanted copies of copyable containers. Note that `Span` is not a replacement for a copyable container with owned storage; see [future directions](#Directions) for more details ([Resizable, contiguously-stored, untyped collection in the standard library](#Bytes).)

In this initial proposal, no initializers are proposed for `Span`. Initializers for non-escapable types such as `Span` require a concept of lifetime dependency, which does not exist at this time. The lifetime dependency annotation will indicate to the compiler how a newly-created `Span` can be used safely. See also ["Initializers"](#Initializers) in [future directions](#Directions).

#### `RawSpan`

`RawSpan` allows sharing contiguous memory representing values which may be heterogeneously-typed, such as memory intended for parsing. It makes the same safety guarantees as `Span`. Since it is a fully concrete type, it can achieve great performance in debug builds of client code as well as straightforward performance in library code.

A `RawSpan` can be obtained from containers of `BitwiseCopyable` elements, as well as be initialized directly from an instance of `Span<T: BitwiseCopyable>`.

## <a name="Design"></a>Detailed design

`Span<Element>` is a simple representation of a region of initialized memory.

```swift
@frozen
public struct Span<Element: ~Copyable>: Copyable, ~Escapable {
  internal var _start: UnsafeRawPointer?
  internal var _count: Int
}

extension Span: Sendable where Element: Sendable & ~Copyable {}
```

We store a `UnsafeRawPointer` value internally in order to explicitly support reinterpreted views of memory as containing different types of `BitwiseCopyable` elements. Note that the the optionality of the pointer does not affect usage of `Span`, since accesses are bounds-checked and the pointer is only dereferenced when the `Span` isn't empty, and the pointer cannot be `nil`.

It provides a buffer-like interface to the elements stored in that span of memory:

```swift
extension Span where Element: ~Copyable {
  public var count: Int { get }
  public var isEmpty: Bool { get }

  public typealias Index = Int
  public var indices: Range<Index> { get }
  
  public subscript(_ index: Index) -> Element { _read }
}
```

Note that `Span` does _not_ conform to `Collection`. This is because `Collection`, as originally conceived and enshrined in existing source code, assumes pervasive copyability and escapability of the `Collection` itself as well as of element type. In particular a subsequence of a `Collection` is semantically a separate value from the instance it was derived from. In the case of `Span`, a sub-span representing a subrange of its elements _must_ have the same lifetime as the `Span` from which it originates. Another proposal will consider collection-like protocols to accommodate different combinations of `~Copyable` and `~Escapable` for the collection and its elements.

Like `UnsafeBufferPointer`, `Span` uses a simple offset-based indexing. The first element of a given span is always at position zero, and its last element is always at position `count-1`.

As a side-effect of not conforming to `Collection` or `Sequence`, `Span` is not directly supported by `for` loops at this time. It is, however, easy to use in a `for` loop via indexing:

```swift
for i in mySpan.indices {
  calculation(mySpan[i])
}
```

### `Span` API:

Initializers, required for library adoption, will be proposed alongside [lifetime annotations][PR-2305]; for details, see "[Initializers](#Initializers)" in the [future directions](#Directions) section.

##### Basic API:

The following properties, functions and subscripts have direct counterparts in the `Collection` protocol hierarchy. Their semantics shall be as described where they counterpart is declared (in `Collection` or `RandomAccessCollection`).

```swift
extension Span where Element: ~Copyable {
  /// The number of initialized elements in the span.
  public var count: Int { get }

  /// A Boolean value indicating whether the span is empty.
  public var isEmpty: Bool { get }

  /// The type that represents a position in `Span`.
  public typealias Index = Int

  /// The range of indices valid for this `Span`
  public var indices: Range<Index> { get }

  /// Accesses the element at the specified position.
  public subscript(_ position: Index) -> Element { _read }
}
```

Note that we use a `_read` accessor for the subscript, a requirement in order to `yield` a borrowed non-copyable `Element` (see ["Coroutines"](#Coroutines).) This yields an element whose lifetime is scoped around this particular access, as opposed to matching the lifetime dependency of the `Span` itself. This is a language limitation we expect to resolve with a followup proposal introducing a new accessor model. The subscript will then be updated to use the new accessor semantics. We expect the updated accessor to be source-compatible, as it will provide a borrowed element with a wider lifetime than a `_read` accessor can provide.

##### Unchecked access to elements:

The `subscript` mentioned above has always-on bounds checking of its parameter, in order to prevent out-of-bounds accesses. We also want to provide unchecked variants as an alternative for cases where bounds-checking is proving costly, such as in tight loops:

```swift
extension Span where Element: ~Copyable {

  /// Accesses the element at the specified `position`.
  ///
  /// This subscript does not validate `position`; this is an unsafe operation.
  ///
  /// - Parameter position: The offset of the element to access. `position`
  ///     must be greater or equal to zero, and less than `count`.
  public subscript(unchecked position: Index) -> Element { _read }
}
```

When using the unchecked subscript, the index must be known to be valid. While we are not proposing explicit index validation API on `Span` itself, its `indices` property can be use to validate a single index, in the form of the function `Range<Int>.contains(_: Int) -> Bool`. We expect that `Range` will also add efficient containment checking of a subrange's endpoints, which should be generally useful for index range validation in this and other contexts.

##### Identifying whether a `Span` is a subrange of another:

When working with multiple `Span` instances, it is often desirable to know whether one is identical to or a subrange of another. We include functions to determine whether this is the case, as well as a function to obtain the valid offsets of the subrange within the larger span:

```swift
extension Span where Element: ~Copyable {
  /// Returns true if the other span represents exactly the same memory
  public func isIdentical(to span: borrowing Self) -> Bool
  
  /// Returns the indices within `self` where the memory represented by `span`
  /// is located, or `nil` if `span` is not located within `self`.
  ///
  /// Parameters:
  /// - span: a span that may be a subrange of `self`
  /// Returns: A range of offsets within `self`, or `nil`
  public func indices(of span: borrowing Self) -> Range<Index>?
}
```

##### Interoperability with unsafe code:

We provide two functions for interoperability with C or other legacy pointer-taking functions.

```swift
extension Span where Element: ~Copyable {
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
  func withUnsafeBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
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
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```

These functions use a closure to define the scope of validity of `buffer`, ensuring that the underlying `Span` and the binding it depends on both remain valid through the end of the closure. They have the same shape as the equivalents on `Array` because they fulfill the same function, namely to keep the underlying binding alive.

### RawSpan

In addition to `Span<T>`, we propose the addition of `RawSpan`, to represent heterogeneously-typed values in contiguous memory. `RawSpan` is similar to `Span<T>`, but represents _untyped_ initialized bytes. `RawSpan` is a specialized type that is intended to support parsing and decoding applications, as well as applications where heavily-used code paths require concrete types as much as possible. Its API supports the data loading operations `unsafeLoad(as:)` and `unsafeLoadUnaligned(as:)`.

#### `RawSpan` API:

```swift
@frozen
public struct RawSpan: Copyable, ~Escapable {
  internal var _start: UnsafeRawPointer
  internal var _count: Int
}

extension RawSpan: Sendable {}
```

Initializers, required for library adoption, will be proposed alongside [lifetime annotations][PR-2305]; for details, see "[Initializers](#Initializers)" in the [future directions](#Directions) section.

##### <a name="Load"></a>Accessing the memory of a `RawSpan`:

`RawSpan` has basic operations to access the contents of its memory: `unsafeLoad(as:)` and `unsafeLoadUnaligned(as:)`:

```swift
extension RawSpan {
  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// The memory at this pointer plus `offset` must be properly aligned for
  /// accessing `T` and initialized to `T` or another type that is layout
  /// compatible with `T`.
  ///
  /// This is an unsafe operation. Failure to meet the preconditions
  /// above may produce an invalid value of `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance is memory-managed and unassociated
  ///     with the value in the memory referenced by this pointer.
  public func unsafeLoad<T>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// The memory at this pointer plus `offset` must be initialized to `T`
  /// or another type that is layout compatible with `T`.
  ///
  /// This is an unsafe operation. Failure to meet the preconditions
  /// above may produce an invalid value of `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance isn't associated
  ///     with the value in the range of memory referenced by this pointer.
  public func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromByteOffset offset: Int = 0, as: T.Type
  ) -> T
```

These operations are not type-safe, in that the loaded value returned by the operation can be invalid, and violate type invariants. Some types have a property that makes the `unsafeLoad(as:)` function safe, but we don't have a way to [formally identify](#SurjectiveBitPattern) such types at this time.

The `unsafeLoad` functions have counterparts which omit bounds-checking for cases where redundant checks affect performance:

```swift
  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// The memory at this pointer plus `offset` must be properly aligned for
  /// accessing `T` and initialized to `T` or another type that is layout
  /// compatible with `T`.
  ///
  /// This is an unsafe operation. This function does not validate the bounds
  /// of the memory access, and failure to meet the preconditions
  /// above may produce an invalid value of `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance is memory-managed and unassociated
  ///     with the value in the memory referenced by this pointer.
  public func unsafeLoad<T>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T

  /// Returns a new instance of the given type, constructed from the raw memory
  /// at the specified offset.
  ///
  /// The memory at this pointer plus `offset` must be initialized to `T`
  /// or another type that is layout compatible with `T`.
  ///
  /// This is an unsafe operation. This function does not validate the bounds
  /// of the memory access, and failure to meet the preconditions
  /// above may produce an invalid value of `T`.
  ///
  /// - Parameters:
  ///   - offset: The offset from this pointer, in bytes. `offset` must be
  ///     nonnegative. The default is zero.
  ///   - type: The type of the instance to create.
  /// - Returns: A new instance of type `T`, read from the raw bytes at
  ///     `offset`. The returned instance isn't associated
  ///     with the value in the range of memory referenced by this pointer.
  public func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromUncheckedByteOffset offset: Int, as: T.Type
  ) -> T
}
```

`RawSpan` provides `withUnsafeBytes` for interoperability with C or other legacy pointer-taking functions:

```swift
extension RawSpan {
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
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```

##### Examining `RawSpan` bounds:

```swift
extension RawSpan {
  /// The number of bytes in the span.
  public var byteCount: Int { get }

  /// A Boolean value indicating whether the span is empty.
  public var isEmpty: Bool { get }
  
  /// The range of valid byte offsets into this `RawSpan`
  public var byteOffsets: Range<Int> { get }
}
```

##### Identifying whether a `RawSpan` is a subrange of another:

When working with multiple `RawSpan` instances, it is often desirable to know whether one is identical to or a subrange of another. We include a function to determine whether this is the case, as well as a function to obtain the valid offsets of the subrange within the larger span. The documentation is omitted here, as it is substantially the same as for the equivalent functions on `Span`:

```swift
extension RawSpan {
  public func isIdentical(to span: borrowing Self) -> Bool
  
  public func byteOffsets(of span: borrowing Self) -> Range<Int>?
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the standard library and runtime.

## <a name="Alternatives"></a>Alternatives considered

##### Make `Span` a noncopyable type
Making `Span` non-copyable was in the early vision of this type. However, we found that would make `Span` a poor match to model borrowing semantics. This realization led to the initial design for non-escapable declarations.

##### Use a non-escapable index type
A non-escapable index type implies that any indexing operation would borrow its `Span`. This would prevent using such an index for a mutation, since a mutation requires an _exclusive_ borrow. Noting that the usage pattern we desire for `Span` must also apply to `MutableSpan`(described [below](#MutableSpan),) a non-escapable index would make it impossible to also implement a mutating subscript, unless any mutating operation consumes the index. This seems untenable.

##### Naming

The ideas in this proposal previously used the name `BufferView`. While the use of the word "buffer" would be consistent with the `UnsafeBufferPointer` type, it is nevertheless not a great name, since "buffer" is commonly used in reference to transient storage. Another previous pitch used the term `StorageView` in reference to the `withContiguousStorageIfAvailable()` standard library function. We also considered the name `StorageSpan`, but that did not add much beyond the shorter name `Span`. `Span` clearly identifies itself as a relative of C++'s `std::span`.

The OpenTelemetry project and its related libraries use the word "span" for a concept of a timespan. The domains of use between that and direct memory access are very distinct, and we believe that the confusability between the use cases should be low. We also note that standard library type names can always be shadowed by type names from packages, mitigating the risk of source breaks.

##### <a name="Sendability"></a>Sendability of `RawSpan`

This proposal makes `RawSpan` a `Sendable` type. We believe this is the right decision. The sendability of `RawSpan` could be used to unsafely transfer a pointer value across an isolation boundary, despite the non-sendability of pointers. For example, suppose a `RawSpan` were obtained from an existing `Array<UnsafeRawPointer>` variable. We could send the `RawSpan` across the isolation boundary, and there extract the pointer using `rawSpan.unsafeLoad(as: UnsafeRawPointer.self)`. While this is an unsafe outcome, a similar operation can be done encoding a pointer as an `Int`, and then using `UnsafeRawPointer(bitPattern: mySentInt)` on the other side of the isolation boundary.

##### A more sophisticated approach to indexing

This is discussed more fully in the [indexing appendix](#Indexing) below.

## <a name="Directions"></a>Future directions

#### <a name="Initializers"></a>Initializing and returning `Span` instances

A `Span` represents a region of memory and, as such, must be initialized using an unsafe pointer. This is an unsafe operation which will typically be performed internally to a container's implementation. In order to bridge to safe code, these initializers require new annotations that indicate to the compiler how the newly-created `Span` can be used safely.

These annotations have been [pitched][PR-2305-pitch] and are expected to be formally [proposed][PR-2305] soon. `Span` initializers using lifetime annotations will be proposed alongside the annotations themselves.

#### Obtaining variant `Span`s and `RawSpan`s from `Span` and `RawSpan`

`Span`s representing subsets of consecutive elements could be extracted out of a larger `Span` with an API similar to the `extracting()` functions recently added to `UnsafeBufferPointer` in support of non-copyable elements:

```swift
extension Span where Element: ~Copyable {
  public func extracting(_ bounds: Range<Int>) -> Self
}
```

Each variant of such a function needs to return a `Span<Element>`, which requires a lifetime dependency. 

Similarly, a `RawSpan` should be initializable from a `Span<T: BitwiseCopyable>`, and `RawSpan` should provide a function to unsafely view its content as a typed `Span`:

```swift
extension RawSpan {
  public init<T: BitwiseCopyable>(_ span: Span<T>)

  public func unsafeView<T: BitwiseCopyable>(as type: T.Type) -> Span<T>
}
```

We are subsetting these functions of `Span` and `RawSpan` until the lifetime annotations are proposed.

#### <a name="Coroutines"></a>Coroutine or Projection Accessors

This proposal includes some `_read` accessors, the coroutine version of the `get` accessor. `_read` accessors are not an official part of the Swift language, but are necessary for some types to be able to provide borrowing access to their internal storage, in particular storage containing non-copyable elements. The correct solution may involve a projection of a different type than is provided by a coroutine. When correct, stable replacement for `_read` accessors is proposed and accepted, the implementation of `Span` and `RawSpan` will be adapted to the new syntax.

#### Extensions to Standard Library and Foundation types

The standard library and Foundation has a number of types that can in principle provide access to their internal storage as a `Span`. We could provide `withSpan()` and `withBytes()` closure-taking functions as safe replacements for the existing `withUnsafeBufferPointer()` and `withUnsafeBytes()` functions. We could also provide lifetime-dependent `span` or `bytes` properties. For example, `Array` could be extended as follows:

```swift
extension Array {
  public func withSpan<E: Error, Result: ~Copyable>(
    _ body: (_ elements: Span<Element>) throws(E) -> Result
  ) throws(E) -> Result
  
  public var span: Span<Element> { borrowing get }
}

extension Array where Element: BitwiseCopyable {
  public func withBytes<E: Error, Result: ~Copyable>(
    _ body: (_ bytes: RawSpan) throws(E) -> Result
  ) throws(E) -> Result where Element: BitwiseCopyable
  
  public var bytes: RawSpan { borrowing get }
}
```

Of these, the closure-taking functions can be implemented now, but it is unclear whether they are desirable. The lifetime-dependent computed properties require lifetime annotations, as initializers do. We are deferring proposing these extensions until the lifetime annotations are proposed.

#### <a name="ContiguousStorage"></a>A `ContiguousStorage` protocol

An earlier version of this proposal proposed a `ContiguousStorage` protocol by which a type could indicate that it can provide a `Span`. `ContiguousStorage` would form a bridge between generically-typed interfaces and a performant concrete implementation. It would supersede the rejected [SE-0256](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0256-contiguous-collection.md).

For example, for the hypothetical base64 decoding library mentioned in the [motivation](#Motivation) section, a possible API could be:

```swift
extension HypotheticalBase64Decoder {
  public func decode(bytes: some ContiguousStorage<UInt8>) -> [UInt8]
}
```

`ContiguousStorage` would have the following definition:

```swift
public protocol ContiguousStorage<Element>: ~Copyable, ~Escapable {
  associatedtype Element: ~Copyable & ~Escapable
  var storage: Span<Element> { _read }
}
```

Two issues prevent us from proposing it at this time: (a) the ability to suppress requirements on `associatedtype` declarations was deferred during the review of [SE-0427], and (b) we cannot declare a `_read` accessor as a protocol requirement.

Many of the standard library collections could conform to `ContiguousStorage`.

#### Index Validation Utilities 

This proposal originally included index validation utilities for `Span`. such as `boundsContain(_: Index) -> Bool` and `boundsContain(_: Range<Index>) -> Bool`. After review feedback, we believe that the utilities proposed would also be useful for index validation on `UnsafeBufferPointer`, `Array`, and other similar `RandomAccessCollection` types. `Range` already a single-element `contains(_: Bound) -> Bool` function which can be made even more efficient. We should add an additional function that identifies whether a `Range` contains the _endpoints_ of another `Range`. Note that this is not the same as the existing `contains(_: some Collection<Bound>) -> Bool`, which is about the _elements_ of the collection. This semantic difference can lead to different results when examining empty `Range` instances.

#### Support for `Span` in `for` loops

This proposal does not define an `IteratorProtocol` conformance, since an iterator for `Span` would need to be non-escapable. This is not compatible with `IteratorProtocol`. As such, `Span`  is not directly usable in `for` loops as currently defined. A `BorrowingIterator` protocol for non-escapable and non-copyable containers must be defined, providing a `for` loop syntax where the element is borrowed through each iteration. Ultimately we should arrive at a way to iterate through borrowed elements from a borrowed view:

```swift
func doSomething(_ e: borrowing Element) { ... }
let span: Span<Element> = ...
for borrowing element in span {
  doSomething(element)
}
```

In the meantime, it is possible to loop through a `Span`'s elements by direct indexing:

```swift
let span: Span<Element> = ...
// either:
var i = 0
while i < span.count {
  doSomething(span[i])
  i += 1
}

// ...or:
for i in 0..<span.count {
  doSomething(span[i])
}
```

#### Collection-like protocols for non-copyable and non-escapable container types

Non-copyable and non-escapable containers would benefit from a `Collection`-like protocol family to represent a set of basic, common operations. The existing `Collection` protocol assumes that its conformers are copyable and escapable, and retrofitting or replacing it is an extensive effort that should not preempt simpler types such as `Span`. `Span` can be retroactively conformed to the new protocol family when the new protocols are ready.

#### Sharing piecewise-contiguous memory

Some types store their internal representation in a piecewise-contiguous manner, such as [trees](https://en.wikipedia.org/wiki/Binary_tree) and [ropes](https://en.wikipedia.org/wiki/Rope_(data_structure)). Some operations naturally return information in a piecewise-contiguous manner, such as network operations. These could supply results iteratively by returning a series of contiguous chunks of memory.

#### <a name="SurjectiveBitPattern"></a>Layout constraint for safe loading of bit patterns

`RawSpan` has unsafe functions that interpret the raw bit patterns it contains as values of arbitrary `BitwiseCopyable` types. In order to have safe alternatives to these, we could add a layout constraint refining `BitwiseCopyable`, specifically for types whose mapping from bit pattern to values is a [surjective function](https://en.wikipedia.org/wiki/Surjective_function) (e.g. `SurjectiveBitPattern`). Such types would be safe to [load](#Load) from `RawSpan` instances. 1-byte examples are `Int8` (any of 256 values are valid) and `Bool` (256 bit patterns map to `true` or `false` because only one bit is considered.)

An alternative to a layout constraint is to add a type validation step to ensure that if a given bit pattern were to be interpreted as a value of type `T`, then all the invariants of type `T` would be respected. This alternative would be more flexible, but may have a higher runtime cost.

#### <a name="ByteParsingHelpers"></a>Byte parsing helpers

We could add some API to `RawSpan` to make it better suited for binary parsers and decoders.

```swift
extension RawSpan {
  public struct Cursor: Copyable, ~Escapable {
    public let base: RawSpan

    /// The current parsing position
    public var position: Int

    /// Parse an instance of `T` and advance.
    /// Returns `nil` if there are not enough bytes remaining for an instance of `T`.
    public mutating func parse<T: _BitwiseCopyable>(
      _ t: T.Type = T.self
    ) -> T?

    /// Parse `numBytes`and advance.
    /// Returns `nil` if there are fewer than `numBytes` remaining.
    public mutating func parse(
      numBytes: some FixedWidthInteger
    ) -> RawSpan?

    /// The bytes that we've parsed so far
    public var parsedBytes: RawSpan { get }
  }
}
```

`Cursor` stores and manages a parsing subrange, which alleviates the developer from managing one layer of slicing.

Alternatively, if some future `RawSpan.Iterator` were 3 words in size (start, current position, and end) instead of 2 (current pointer and end), making it a "resettable", it could host this API instead of introducing a new `Cursor` type or concept.

##### Example: Parsing PNG

The code snippet below parses a [PNG Chunk](https://www.w3.org/TR/png-3/#4Concepts.FormatChunks), using the byte parsing helpers defined above:

```swift
// Parse a PNG chunk
let length = try cursor.parse(UInt32.self).bigEndian
let type   = try cursor.parse(UInt32.self).bigEndian
let data   = try cursor.parse(numBytes: length)
let crc    = try cursor.parse(UInt32.self).bigEndian
```

#### <a name="MutableSpan"></a>Safe mutations of memory with `MutableSpan<T>`

Some data structures can delegate mutations of their owned memory. In the standard library the function `withMutableBufferPointer()` provides this functionality in an unsafe manner.

The `UnsafeMutableBufferPointer` passed to a `withUnsafeMutableXXX` closure-style API is unsafe in multiple ways:

1. The pointer itself is unsafe and unmanaged
2. `subscript` is only bounds-checked in debug builds of client code
3. It might escape the duration of the closure
4. Exclusivity of writes is not enforced
5. Initialization of any particular memory address is not ensured

in other words, it is unsafe in all the same ways as `UnsafeBufferPointer`-passing closure APIs, in addition to enforcing neither exclusivity nor initialization state.

Loading an uninitialized non-`BitwiseCopyable` value leads to undefined behavior. Loading an uninitialized `BitwiseCopyable` value does not immediately lead to undefined behavior, but it produces a garbage value which may lead to misbehavior of the program.

A `MutableSpan<T>` should provide a better, safer alternative to mutable memory in the same way that `Span<T>` provides a better, safer read-only type. `MutableSpan<T>` would apply to initialized memory and would enforce exclusivity of writes, thereby preserving the initialization state of its memory between mutations.

#### <a name="OutputSpan"></a>Delegating initialization of memory with `OutputSpan<T>`

Some data structures can delegate initialization of their initial memory representation, and in some cases the initialization of additional memory. For example, the standard library features the initializer`Array.init(unsafeUninitializedCapacity:initializingWith:)`, which depends on `UnsafeMutableBufferPointer` and is known to be error-prone.  A safer abstraction for initialization would make such initializers less dangerous, and would allow for a greater variety of them.

We can define an `OutputSpan<T>` type, which could support appending to the initialized portion of a data structure's underlying storage. `OutputSpan<T>` allows for uninitialized memory beyond the last position appended. Such an `OutputSpan<T>` would also be a useful abstraction to pass user-allocated storage to low-level API such as networking calls or file I/O.

#### <a name="Bytes"></a>Resizable, contiguously-stored, untyped collection in the standard library

The example in the [motivation](#Motivation) section mentions the `Foundation.Data` type. There has been some discussion of either replacing `Data` or moving it to the standard library. This document proposes neither of those. A major issue is that in the "traditional" form of `Foundation.Data`, namely `NSData` from Objective-C, it was easier to control accidental copies because the semantics of the language did not lead to implicit copying.

Even if `Span` were to replace all uses of a constant `Data` in API, something like `Data` would still be needed, for the same reason as `Array<T>` is needed: such a type allows for resizing mutations (e.g. `RangeReplaceableCollection` conformance.) We may want to add an untyped-element equivalent of `Array` to the standard library at a later time.

#### <a name="Conversions"></a>Syntactic Sugar for Automatic Conversions

Even with a `ContiguousStorage` protocol, a generic entry point in terms of `some ContiguousStorage` may add unwanted overhead to resilient libraries. As detailed above, an entry point in an evolution-enabled library requires an inlinable  generic public entry point which forwards to a publicly-accessible function defined in terms of `Span`. If `Span` does become a widely-used type to interface between libraries, we could simplify these conversions with a bit of compiler help.

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

#### Interoperability with C++'s `std::span` and with llvm's `-fbounds-safety`

The [`std::span`](https://en.cppreference.com/w/cpp/container/span) class template from the C++ standard library is a similar representation of a contiguous range of memory. LLVM may soon have a [bounds-checking mode](https://discourse.llvm.org/t/70854) for C. These are opportunities for better, safer interoperation with Swift, via a type such as `Span`.

## Acknowledgments

Joe Groff, John McCall, Tim Kientzle, Steve Canon and Karoy Lorentey contributed to this proposal with their clarifying questions and discussions.

### <a name="Indexing"></a>Appendix: Index and slicing design considerations

Early prototypes of this proposal defined an `Index` type, `Iterator` types, etc. We are proposing `Int`-based API and are deferring defining `Index` and `Iterator` until more of the non-escapable collection story is sorted out. The below is some of our research into different potential designs of an `Index` type.

There are 3 potentially-desirable features of `Span`'s `Index` design:

1. `Span` is its own slice type
2. Indices from a slice can be used on the base collection
3. Additional reuse-after-free checking

Each of these introduces practical tradeoffs in the design.

#### `Span` is its own slice type

Collections which own their storage have the convention of separate slice types, such as `Array` and `String`. This has the advantage of clearly delineating storage ownership in the programming model and the disadvantage of introducing a second type through which to interact.

When types do not own their storage, separate slice types can be [cumbersome](https://github.com/swiftlang/swift/blob/swift-5.10.1-RELEASE/stdlib/public/core/StringComparison.swift#L175). The reason `UnsafeBufferPointer` has a separate slice type is because it wants to allow indices to be reused across slices and its `Index` is a relative offset from the start (`Int`) rather than an absolute position (such as a pointer).

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

Note, however, that parsers tend to become more complex and copying slices for later index extraction becomes more common. At that point, it is better to use a more powerful approach such as the index-advancing or cursor API presented in *[Byte parsing helpers](#ByteParsingHelpers)*.

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

Future improvements to microarchitecture may make reuse after free checks cheaper, however we need something for the foreseeable future. Any validation we can do reduces the need to switch to other mitigation strategies or make other tradeoffs.

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
