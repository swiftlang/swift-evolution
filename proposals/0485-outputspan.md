# OutputSpan: delegate initialization of contiguous memory

* Proposal: [SE-0485](0485-outputspan.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 6.2)** ([Extensions to standard library types](#extensions) pending)
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: [swiftlang/swift#81637](https://github.com/swiftlang/swift/pull/81637)
* Review: [Pitch](https://forums.swift.org/t/pitch-outputspan/79473), [Review](https://forums.swift.org/t/se-0485-outputspan-delegate-initialization-of-contiguous-memory/80032), [Acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0485-outputspan-delegate-initialization-of-contiguous-memory/80435)

[SE-0446]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[SE-0456]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md
[SE-0467]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md
[PR-LifetimeAnnotations]: https://github.com/swiftlang/swift-evolution/pull/2750
[Forum-LifetimeAnnotations]: https://forums.swift.org/t/78638
[SE-0453]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md


#### Table of Contents

- [Introduction](#introduction)

- [Motivation](#motivation)

- [Proposed solution](#proposed-solution)

- [Detailed Design](#design)

- [Source compatibility](#source-compatibility)

- [ABI compatibility](#abi-compatibility)

- [Implications on adoption](#implications-on-adoption)

- [Alternatives Considered](#alternatives-considered)

- [Future directions](#future-directions)

- [Acknowledgements](#acknowledgements)


## Introduction

Following the introduction of [`Span`][SE-0447] and [`MutableSpan`][SE-0467], this proposal adds a general facility for initialization of exclusively-borrowed memory with the `OutputSpan` and `OutputRawSpan` types. The memory represented by `OutputSpan` consists of a number of initialized elements, followed by uninitialized memory. The operations of `OutputSpan` can change the number of initialized elements in memory, unlike `MutableSpan` which always represent initialized memory representing a fixed number of elements.

## Motivation

Some standard library container types can delegate initialization of some or all of their storage to user code. Up to now, it has only been possible to do so with explicitly unsafe functions, which have also proven error-prone. The standard library provides this unsafe functionality with the closure-taking initializers `Array.init(unsafeUninitializedCapacity:initializingWith:)` and `String.init(unsafeUninitializedCapacity:initializingUTF8With:)`.

These functions have a few different drawbacks, most prominently their reliance on unsafe types, which makes them unpalatable in security-conscious environments. We continue addressing these issues with `OutputSpan` and `OutputRawSpan`, new non-copyable and non-escapable types that manage initialization of typed and untyped memory.

In addition to the new types, we propose adding new API for some standard library types to take advantage of `OutputSpan` and `OutputRawSpan`.

## Proposed solution

#### OutputSpan

`OutputSpan` allows delegating the initialization of a type's memory, by providing access to an exclusively-borrowed view of a range of contiguous memory. `OutputSpan`'s contiguous memory always consists of a prefix of initialized memory, followed by a suffix of uninitialized memory. `OutputSpan`'s operations manage the initialization state in order to preserve that invariant. The common usage pattern we expect to see for `OutputSpan` consists of passing it as an `inout` parameter to a function, allowing the function to produce an output by writing into a previously uninitialized region.

Like `MutableSpan`, `OutputSpan` relies on two guarantees: (a) that it has exclusive access to the range of memory it represents, and (b) that the memory locations it represents will remain valid for the duration of the access. These guarantee data race safety and lifetime safety. `OutputSpan` performs bounds-checking on every access to preserve bounds safety. `OutputSpan` manages the initialization state of the memory in represents on behalf of the memory's owner.

#### OutputRawSpan

`OutputRawSpan` allows delegating the initialization of heterogeneously-typed memory, such as memory being prepared by an encoder. It makes the same safety guarantees as `OutputSpan`, but manages untyped memory.

#### Extensions to standard library types

The standard library will provide new container initializers that delegate to an `OutputSpan`. Delegated initialization generally requires a container to perform some operations after the initialization has happened. In the case of `Array` this is simply noting the number of initialized elements; in the case of `String` this consists of validating the input, then noting metadata about the input. This post-processing implies the need for a scope, and we believe that scope is best represented by a closure. The `Array` initializer will be as follows:

```swift
extension Array {
  public init<E: Error>(
    capacity: Int,
    initializingWith: (_ span: inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}
```

We will also extend `String`, `UnicodeScalarView` and `InlineArray` with similar initializers, and add append-in-place operations where appropriate.

#### `@_lifetime` attribute

Some of the API presented here must establish a lifetime relationship between a non-escapable returned value and a callee binding. This relationship will be illustrated using the `@_lifetime` attribute recently [pitched][PR-LifetimeAnnotations] and [formalized][Forum-LifetimeAnnotations]. For the purposes of this proposal, the lifetime attribute ties the lifetime of a function's return value to one of its input parameters.

Note: The eventual lifetime annotations proposal may adopt a syntax different than the syntax used here. We expect that the Standard Library will be modified to adopt an updated lifetime dependency syntax as soon as it is finalized.

## <a name="design"></a>Detailed Design

#### OutputSpan

`OutputSpan<Element>` is a simple representation of a partially-initialized region of memory. It is non-copyable in order to enforce exclusive access during mutations of its memory, as required by the law of exclusivity:

````swift
@frozen
public struct OutputSpan<Element: ~Copyable>: ~Copyable, ~Escapable {
  internal let _start: UnsafeMutableRawPointer?
  public let capacity: Int
  internal var _count: Int
}
````

The memory represented by an `OutputSpan` instance consists of `count` initialized instances of `Element`, followed by uninitialized memory with storage space for `capacity - count` additional elements of `Element`.

```swift
extension OutputSpan where Element: ~Copyable {
  /// The number of initialized elements in this `OutputSpan`.
  public var count: Int { get }

  /// A Boolean value indicating whether the span is empty.
  public var isEmpty: Bool { get }

  /// A Boolean value indicating whether the span is full.
  public var isFull: Bool { get }

  /// The number of additional elements that can be added to this `OutputSpan`
  public var freeCapacity: Int { get } // capacity - count
}
```

##### Single-element operations

The basic operation supported by `OutputSpan` is appending an element. When an element is appended, the correct amount of memory needed to represent it is initialized, and the `count` property is incremented by 1. If the `OutputSpan` has no available space (`capacity == count`), this operation traps.
```swift
extension OutputSpan where Element: ~Copyable {
  /// Append a single element to this `OutputSpan`.
  @_lifetime(self: copy self)
  public mutating func append(_ value: consuming Element)
}

extension OutputSpan {
  /// Repeatedly append an element to this `OutputSpan`.
  @_lifetime(self: copy self)
  public mutating func append(repeating repeatedValue: Element, count: Int)
}
```
The converse operation `removeLast()` is also supported, and returns the removed element if `count` was greater than zero.
```swift
extension OutputSpan where Element: ~Copyable {
  /// Remove the last initialized element from this `OutputSpan`.
  ///
  /// Returns the last element. The `OutputSpan` must not be empty.
  @discardableResult
  @_lifetime(self: copy self)
  public mutating func removeLast() -> Element
}
```

##### Bulk removals from an `OutputSpan`'s memory:

Bulk operations to deinitialize some or all of an `OutputSpan`'s memory are also available:
```swift
extension OutputSpan where Element: ~Copyable {
  /// Remove the last N elements, returning the memory they occupy
  /// to the uninitialized state.
  ///
  /// `n` must not be greater than `count`
  @_lifetime(self: copy self)
  public mutating func removeLast(_ n: Int)

  /// Remove all this span's elements and return its memory to the uninitialized state.
  @_lifetime(self: copy self)
  public mutating func removeAll()
}
```

##### Accessing an `OutputSpan`'s initialized memory:

The initialized elements are accessible for read-only or mutating access via the `span` and `mutableSpan` properties:

```swift
extension OutputSpan where Element: ~Copyable {
  /// Borrow the underlying initialized memory for read-only access.
  public var span: Span<Element> {
    @_lifetime(borrow self) borrowing get
  }

  /// Exclusively borrow the underlying initialized memory for mutation.
  public mutating var mutableSpan: MutableSpan<Element> {
    @_lifetime(&self) mutating get
  }
}
```

`OutputSpan` also provides the ability to access its individual initialized elements by index:
```swift
extension OutputSpan where Element: ~Copyable {
  /// The type that represents an initialized position in an `OutputSpan`.
  typealias Index = Int

  /// The range of initialized positions for this `OutputSpan`.
  var indices: Range<Index> { get }

  /// Accesses the element at the specified initialized position.
  subscript(_ index: Index) -> Element { borrow; mutate }
      // accessor syntax from accessors roadmap (https://forums.swift.org/t/76707)

  /// Exchange the elements at the two given offsets
  mutating func swapAt(_ i: Index, _ j: Index)
}
```

##### Interoperability with unsafe code

We provide a method to process or populate an `OutputSpan` using unsafe operations, which can also be used for out-of-order initialization.

```swift
extension OutputSpan where Element: ~Copyable {
  /// Call the given closure with the unsafe buffer pointer addressed by this
  /// OutputSpan and a mutable reference to its count of initialized elements.
  ///
  /// This method provides a way to process or populate an `OutputSpan` using
  /// unsafe operations, such as dispatching to code written in legacy
  /// (memory-unsafe) languages.
  ///
  /// The supplied closure may process the buffer in any way it wants; however,
  /// when it finishes (whether by returning or throwing), it must leave the
  /// buffer in a state that satisfies the invariants of the output span:
  ///
  /// 1. The inout integer passed in as the second argument must be the exact
  ///     number of initialized items in the buffer passed in as the first
  ///     argument.
  /// 2. These initialized elements must be located in a single contiguous
  ///     region starting at the beginning of the buffer. The rest of the buffer
  ///     must hold uninitialized memory.
  ///
  /// This function cannot verify these two invariants, and therefore
  /// this is an unsafe operation. Violating the invariants of `OutputSpan`
  /// may result in undefined behavior.
  @_lifetime(self: copy self)
  public mutating func withUnsafeMutableBufferPointer<E: Error, R: ~Copyable>(
    _ body: (
      UnsafeMutableBufferPointer<Element>,
      _ initializedCount: inout Int
    ) throws(E) -> R
  ) throws(E) -> R
}
```

##### Creating an `OutputSpan` instance:

Creating an `OutputSpan` is an unsafe operation. It requires having knowledge of the initialization state of the range of memory being targeted. The range of memory must be in two regions: the first region contains initialized instances of `Element`, and the second region is uninitialized. The number of initialized instances is passed to the `OutputSpan` initializer through its `initializedCount` argument.

```swift
extension OutputSpan where Element: ~Copyable {
  /// Unsafely create an OutputSpan over partly-initialized memory.
  ///
  /// The memory in `buffer` must remain valid throughout the lifetime
  /// of the newly-created `OutputSpan`. Its prefix must contain
  /// `initializedCount` initialized instances, followed by uninitialized
  /// memory.
  ///
  /// - Parameters:
  ///   - buffer: an `UnsafeMutableBufferPointer` to be initialized
  ///   - initializedCount: the number of initialized elements
  ///                       at the beginning of `buffer`.
  @unsafe
  @_lifetime(borrow buffer)
  public init(
    buffer: UnsafeMutableBufferPointer<Element>,
    initializedCount: Int
  )
}

extension OutputSpan {
  /// Unsafely create an OutputSpan over partly-initialized memory.
  ///
  /// The memory in `buffer` must remain valid throughout the lifetime
  /// of the newly-created `OutputSpan`. Its prefix must contain
  /// `initializedCount` initialized instances, followed by uninitialized
  /// memory.
  ///
  /// - Parameters:
  ///   - buffer: an `UnsafeMutableBufferPointer` to be initialized
  ///   - initializedCount: the number of initialized elements
  ///                       at the beginning of `buffer`.
  @unsafe
  @_lifetime(borrow buffer)
  public init(
    buffer: borrowing Slice<UnsafeMutableBufferPointer<Element>>,
    initializedCount: Int
  )
}
```

We also provide a default (no-parameter) initializer to create an empty, zero-capacity `OutputSpan`. Such an initializer is useful in order to be able to materialize an empty span for the `nil` case of an Optional, for example, or to exchange with another span in a mutable struct.

```swift
extension OutputSpan where Element: ~Copyable {
  /// Create an OutputSpan with zero capacity
  @_lifetime(immortal)
  public init()
}
```

Such an empty `OutputSpan` does not depend on a memory allocation, and therefore has the longest lifetime possible :`immortal`. This capability is important enough that we also propose to immediately define similar empty initializers for `Span<T>`, `RawSpan`, `MutableSpan<T>` and `MutableRawSpan`.

##### Retrieving initialized memory from an `OutputSpan`

Once memory has been initialized using `OutputSpan`, the owner of the memory must consume the `OutputSpan` in order to retake ownership of the initialized memory. The owning type must pass the memory used to initialize the `OutputSpan` to the `finalize(for:)` function. Passing the wrong buffer is a programmer error and the function traps; this requirement also ensures that user code does not wrongly replace the `OutputSpan` with an unrelated instance. The `finalize(for:)` function consumes the `OutputSpan` instance and returns the number of initialized elements. If `finalize(for:)` is not called, the initialized portion of `OutputSpan`'s memory will be deinitialized when the binding goes out of scope.

```swift
extension OutputSpan where Element: ~Copyable {
  /// Consume the OutputSpan and return the number of initialized elements.
  ///
  /// Parameters:
  /// - buffer: The buffer being finalized. This must be the same buffer as used
  ///           to initialize the `OutputSpan` instance.
  /// Returns: The number of elements that were initialized.
  @unsafe
  public consuming func finalize(
    for buffer: UnsafeMutableBufferPointer<Element>
  ) -> Int
}

extension OutputSpan {
  /// Consume the OutputSpan and return the number of initialized elements.
  ///
  /// Parameters:
  /// - buffer: The buffer being finalized. This must be the same buffer as used
  ///           to initialize the `OutputSpan` instance.
  /// Returns: The number of bytes that were initialized.
  @unsafe
  public consuming func finalize(
    for buffer: Slice<UnsafeMutableBufferPointer<Element>>
  ) -> Int
}
```


#### `OutputRawSpan`
`OutputRawSpan` is similar to `OutputSpan<T>`, but its initialized memory is untyped. Its API supports appending the bytes of  instances of `BitwiseCopyable` types, as well as a variety of bulk initialization operations.

```swift
@frozen
public struct OutputRawSpan: ~Copyable, ~Escapable {
  internal var _start: UnsafeMutableRawPointer?
  public let capacity: Int
  internal var _count: Int
}
```

The memory represented by an `OutputRawSpan` contains `byteCount` initialized bytes, followed by uninitialized memory.

```swift
extension OutputRawSpan {
  /// The number of initialized bytes in this `OutputRawSpan`
  public var byteCount: Int { get }

  /// A Boolean value indicating whither the span is empty.
  public var isEmpty: Bool { get }

  /// A Boolean value indicating whither the span is full.
  public var isFull: Bool { get }

  /// The number of uninitialized bytes remaining in this `OutputRawSpan`
  public var freeCapacity: Int { get } // capacity - byteCount
}
```


##### Appending to `OutputRawSpan`

The basic operation is to append the bytes of some value to an `OutputRawSpan`. Note that since the fundamental operation is appending bytes, `OutputRawSpan` does not concern itself with memory alignment.
```swift
extension OutputRawSpan {
  /// Append a single byte to this span
  @_lifetime(self: copy self)
  public mutating func append(_ value: UInt8)

  /// Appends the given value's bytes to this span's initialized bytes
  @_lifetime(self: copy self)
  public mutating func append<T: BitwiseCopyable>(
    _ value: T, as type: T.Type
  )

  /// Appends the given value's bytes repeatedly to this span's initialized bytes
  @_lifetime(self: copy self)
  public mutating func append<T: BitwiseCopyable>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )
}
```

An `OutputRawSpan`'s initialized memory is accessible for read-only or mutating access via the `bytes` and `mutableBytes` properties:

```swift
extension OutputRawSpan {
  /// Borrow the underlying initialized memory for read-only access.
  public var bytes: RawSpan {
    @_lifetime(borrow self) borrowing get
  }

  /// Exclusively borrow the underlying initialized memory for mutation.
  public var mutableBytes: MutableRawSpan {
    @_lifetime(&self) mutating get
  }
}
```

Deinitializing memory from an `OutputRawSpan`:

```swift
extension OutputRawSpan {

  /// Remove the last byte from this span
  @_lifetime(self: copy self)
  public mutating func removeLast() -> UInt8 {

  /// Remove the last N elements, returning the memory they occupy
  /// to the uninitialized state.
  ///
  /// `n` must not be greater than `count`
  @_lifetime(self: copy self)
  public mutating func removeLast(_ n: Int)

  /// Remove all this span's elements and return its memory
  /// to the uninitialized state.
  @_lifetime(self: copy self)
  public mutating func removeAll()
}
```

##### Interoperability with unsafe code

We provide a method to process or populate an `OutputRawSpan` using unsafe operations, which can also be used for out-of-order initialization.

```swift
extension OutputRawSpan {
  /// Call the given closure with the unsafe buffer pointer addressed by this
  /// OutputRawSpan and a mutable reference to its count of initialized bytes.
  ///
  /// This method provides a way to process or populate an `OutputRawSpan` using
  /// unsafe operations, such as dispatching to code written in legacy
  /// (memory-unsafe) languages.
  ///
  /// The supplied closure may process the buffer in any way it wants; however,
  /// when it finishes (whether by returning or throwing), it must leave the
  /// buffer in a state that satisfies the invariants of the output span:
  ///
  /// 1. The inout integer passed in as the second argument must be the exact
  ///     number of initialized bytes in the buffer passed in as the first
  ///     argument.
  /// 2. These initialized elements must be located in a single contiguous
  ///     region starting at the beginning of the buffer. The rest of the buffer
  ///     must hold uninitialized memory.
  ///
  /// This function cannot verify these two invariants, and therefore
  /// this is an unsafe operation. Violating the invariants of `OutputRawSpan`
  /// may result in undefined behavior.
  @_lifetime(self: copy self)
  public mutating func withUnsafeMutableBytes<E: Error, R: ~Copyable>(
    _ body: (
      UnsafeMutableRawBufferPointer,
      _ initializedCount: inout Int
    ) throws(E) -> R
  ) throws(E) -> R
}
```

##### Creating `OutputRawSpan` instances

Creating an `OutputRawSpan` is an unsafe operation. It requires having knowledge of the initialization state of the range of memory being targeted. The range of memory must be in two regions: the first region contains initialized bytes, and the second region is uninitialized. The number of initialized bytes is passed to the `OutputRawSpan` initializer through its `initializedCount` argument.

```swift
extension OutputRawSpan {

  /// Unsafely create an OutputRawSpan over partly-initialized memory.
  ///
  /// The memory in `buffer` must remain valid throughout the lifetime
  /// of the newly-created `OutputRawSpan`. Its prefix must contain
  /// `initializedCount` initialized bytes, followed by uninitialized
  /// memory.
  ///
  /// - Parameters:
  ///   - buffer: an `UnsafeMutableBufferPointer` to be initialized
  ///   - initializedCount: the number of initialized elements
  ///                       at the beginning of `buffer`.
  @unsafe
  @_lifetime(borrow buffer)
  public init(
    buffer: UnsafeMutableRawBufferPointer,
    initializedCount: Int
  )

  /// Create an OutputRawSpan with zero capacity
  @_lifetime(immortal)
  public init()

  /// Unsafely create an OutputRawSpan over partly-initialized memory.
  ///
  /// The memory in `buffer` must remain valid throughout the lifetime
  /// of the newly-created `OutputRawSpan`. Its prefix must contain
  /// `initializedCount` initialized bytes, followed by uninitialized
  /// memory.
  ///
  /// - Parameters:
  ///   - buffer: an `UnsafeMutableBufferPointer` to be initialized
  ///   - initializedCount: the number of initialized elements
  ///                       at the beginning of `buffer`.
  @unsafe
  @_lifetime(borrow buffer)
  public init(
    buffer: Slice<UnsafeMutableRawBufferPointer>,
    initializedCount: Int
  )
}
```

##### Retrieving initialized memory from an `OutputRawSpan`

Once memory has been initialized using `OutputRawSpan`, the owner of the memory must consume the instance in order to retake ownership of the initialized memory. The owning type must pass the memory used to initialize the `OutputRawSpan` to the `finalize(for:)` function. Passing the wrong buffer is a programmer error and the function traps. `finalize()` consumes the `OutputRawSpan` instance and returns the number of initialized bytes.

```swift
extension OutputRawSpan {
  /// Consume the OutputRawSpan and return the number of initialized bytes.
  ///
  /// Parameters:
  /// - buffer: The buffer being finalized. This must be the same buffer as used
  ///           to create the `OutputRawSpan` instance.
  /// Returns: The number of initialized bytes.
  @unsafe
  public consuming func finalize(
    for buffer: UnsafeMutableRawBufferPointer
  ) -> Int

  /// Consume the OutputRawSpan and return the number of initialized bytes.
  ///
  /// Parameters:
  /// - buffer: The buffer being finalized. This must be the same buffer as used
  ///           to create the `OutputRawSpan` instance.
  /// Returns: The number of initialized bytes.
  @unsafe
  public consuming func finalize(
    for buffer: Slice<UnsafeMutableRawBufferPointer>
  ) -> Int
}
```


#### <a name="extensions"></a>Extensions to Standard Library types

The standard library and Foundation will add a few initializers that enable initialization in place, intermediated by an `OutputSpan` instance, passed as a parameter to a closure:

```swift
extension Array {
  /// Creates an array with the specified capacity, then calls the given
  /// closure with an OutputSpan to initialize the array's contents.
  public init<E: Error>(
    capacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)

  /// Grows the array to ensure capacity for the specified number of elements,
  /// then calls the closure with an OutputSpan covering the array's
  /// uninitialized memory.
  public mutating func append<E: Error>(
    addingCapacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}

extension ContiguousArray {
  /// Creates an array with the specified capacity, then calls the given
  /// closure with an OutputSpan to initialize the array's contents.
  public init<E: Error>(
    capacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)

  /// Grows the array to ensure capacity for the specified number of elements,
  /// then calls the closure with an OutputSpan covering the array's
  /// uninitialized memory.
  public mutating func append<E: Error>(
    addingCapacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}

extension ArraySlice {
  /// Grows the array to ensure capacity for the specified number of elements,
  /// then calls the closure with an OutputSpan covering the array's
  /// uninitialized memory.
  public mutating func append<E: Error>(
    addingCapacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}

extension String {
  /// Creates a new string with the specified capacity in UTF-8 code units, and
  /// then calls the given closure with a OutputSpan to initialize the string's
  /// contents.
  ///
  /// This initializer replaces ill-formed UTF-8 sequences with the Unicode
  /// replacement character (`"\u{FFFD}"`). This may require resizing
  /// the buffer beyond its original capacity.
  public init<E: Error>(
    repairingUTF8WithCapacity capacity: Int,
    initializingUTF8With initializer: (
      inout OutputSpan<UTF8.CodeUnit>
    ) throws(E) -> Void
  ) throws(E)

  /// Creates a new string with the specified capacity in UTF-8 code units, and
  /// then calls the given closure with a OutputSpan to initialize the string's
  /// contents.
  ///
  /// This initializer does not try to repair ill-formed code unit sequences.
  /// If any are found, the result of the initializer is `nil`.
  public init<E: Error>?(
    validatingUTF8WithCapacity capacity: Int,
    initializingUTF8With initializer: (
      inout OutputSpan<UTF8.CodeUnit>
    ) throws(E) -> Void
  ) throws(E)

  /// Grows the string to ensure capacity for the specified number
  /// of UTF-8 code units, then calls the closure with an OutputSpan covering
  /// the string's uninitialized memory.
  public mutating func append<E: Error>(
    addingUTF8Capacity: Int,
    initializingUTF8With initializer: (
      inout OutputSpan<UTF8.CodeUnit>
    ) throws(E) -> Void
  ) throws(E)
}

extension UnicodeScalarView {
  /// Creates a new string with the specified capacity in UTF-8 code units, and
  /// then calls the given closure with a OutputSpan to initialize
  /// the string's contents.
  ///
  /// This initializer replaces ill-formed UTF-8 sequences with the Unicode
  /// replacement character (`"\u{FFFD}"`). This may require resizing
  /// the buffer beyond its original capacity.
  public init<E: Error>(
    repairingUTF8WithCapacity capacity: Int,
    initializingUTF8With initializer: (
      inout OutputSpan<UTF8.CodeUnit>
    ) throws(E) -> Void
  ) throws(E)

  /// Creates a new string with the specified capacity in UTF-8 code units, and
  /// then calls the given closure with a OutputSpan to initialize
  /// the string's contents.
  ///
  /// This initializer does not try to repair ill-formed code unit sequences.
  /// If any are found, the result of the initializer is `nil`.
  public init<E: Error>?(
    validatingUTF8WithCapacity capacity: Int,
    initializingUTF8With initializer: (
      inout OutputSpan<UTF8.CodeUnit>
    ) throws(E) -> Void
  ) throws(E)

  /// Grows the string to ensure capacity for the specified number
  /// of UTF-8 code units, then calls the closure with an OutputSpan covering
  /// the string's uninitialized memory.
  public mutating func append<E: Error>(
    addingUTF8Capacity: Int,
    initializingUTF8With initializer: (
      inout OutputSpan<UTF8.CodeUnit>
    ) throws(E) -> Void
  ) throws(E)
}

extension InlineArray {
  /// Creates an array, then calls the given closure with an OutputSpan
  /// to initialize the array's elements.
  ///
  /// NOTE: The closure must initialize every element of the `OutputSpan`.
  ///       If the closure does not do so, the initializer will trap.
  public init<E: Error>(
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}
```

#### Extensions to `Foundation.Data`

While the `swift-foundation` package and the `Foundation` framework are not governed by the Swift evolution process, `Data` is similar in use to standard library types, and the project acknowledges that it is desirable for it to have similar API when appropriate. Accordingly, we plan to propose the following additions to `Foundation.Data`:
```swift
extension Data {
  /// Creates a data instance with the specified capacity, then calls
  /// the given closure with an OutputSpan to initialize the instances's
  /// contents.
  public init<E: Error>(
    capacity: Int,
    initializingWith initializer: (inout OutputSpan<UInt8>) throws(E) -> Void
  ) throws(E)

  /// Creates a data instance with the specified capacity, then calls
  /// the given closure with an OutputSpan to initialize the instances's
  /// contents.
  public init<E: Error>(
    rawCapacity: Int,
    initializingWith initializer: (inout OutputRawSpan) throws(E) -> Void
  ) throws(E)

  /// Ensures the data instance has enough capacity for the specified
  /// number of bytes, then calls the closure with an OutputSpan covering
  /// the uninitialized memory.
  public mutating func append<E: Error>(
    addingCapacity: Int,
    initializingWith initializer: (inout OutputSpan<UInt8>) throws(E) -> Void
  ) throws(E)

  /// Ensures the data instance has enough capacity for the specified
  /// number of bytes, then calls the closure with an OutputSpan covering
  /// the uninitialized memory.
  public mutating func append<E: Error>(
    addingRawCapacity: Int,
    initializingWith initializer: (inout OutputRawSpan) throws(E) -> Void
  ) throws(E)
}
```

#### Changes to `MutableSpan` and `MutableRawSpan`

This proposal considers the naming of `OutputSpan`'s bulk-initialization methods, and elects to defer their implementation until we have more experience with the various kinds of container we need to support. We also introduced bulk updating functions to `MutableSpan` and `MutableRawSpan` in [SE-0467][SE-0467]. It is clear that they have the same kinds of parameters as `OutputSpan`'s bulk-initialization methods, but the discussion has taken a [different direction](#contentsOf) in the latter case. We would like both of these sets of operations to match. Accordingly, we will remove the bulk `update()` functions proposedin [SE-0467][SE-0467], to be replaced with a better naming scheme later. Prototype bulk-update functionality will also be added via a package in the meantime.

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library and runtime.


## Alternatives Considered

#### Vending `OutputSpan` as a property

`OutputSpan` changes the number of initialized elements in a container (or collection), and this requires some operation to update the container after the `OutputSpan` is consumed. Let's call that update operation a "cleanup" operation. The cleanup operation needs to be scheduled in some way. We could associate the cleanup with the `deinit` of `OutputSpan`, or the `deinit` of a wrapper of `OutputSpan`. Neither of these seem appealing; the mechanisms would involve an arbitrary closure executed at `deinit` time, or having to write a full wrapper for each type that vends an `OutputSpan`. We could potentially schedule the cleanup operation as part of a coroutine accessor, but these are not productized yet. The pattern established by closure-taking API is well established, and that pattern fits the needs of `OutputSpan` well.

#### Container construction pattern

A constrained version of possible `OutputSpan` use consists of in-place container initialization. This proposal introduces a few initializers in this vein, such as `Array.init(capacity:initializingWith:)`, which rely on closure to establish a scope. A different approach would be to use intermediate types to perform such operations:

```swift
struct ArrayConstructor<Element>: ~Copyable {
  @_lifetime(&self) mutating var outputSpan: OutputSpan<Element>
  private let _ArrayBuffer<Element>
  
  init(capacity: Int)
}

extension Array<Element> {
  init(_: consuming ArrayConstructor<Element>)
}
```

## <a name="directions"></a>Future directions

#### Helpers to initialize memory in an arbitrary order

Some applications may benefit from the ability to initialize a range of memory in a different order than implemented by `OutputSpan`. This may be from back-to-front or even arbitrary order. There are many possible forms such an initialization helper can take, depending on how much memory safety the application is willing to give up in the process of initializing the memory. At the unsafe end, this can be delegating to an `UnsafeMutableBufferPointer` along with a set of requirements; this option is proposed here. At the safe end, this could be delegating to a data structure which keeps track of initialized memory using a bitmap. It is unclear how much need there is for this more heavy-handed approach, so we leave it as a future enhancement if it is deemed useful.

#### Insertions

A use case similar to appending is insertions. Appending is simply inserting at the end. Inserting at positions other than the end is an important capability. We expect to add insertions soon in a followup proposal if `OutputSpan` is accepted. Until then, a workaround is to append, then rotate the elements to the desired position using the `mutableSpan` view.

#### Generalized removals

Similarly to generalized insertions (i.e. not from the end), we can think about removals of one or more elements starting at a given position. We expect to add generalized removals along with insertions in a followup proposal after `OutputSpan` is accepted.

#### Variations on `Array.append(addingCapacity:initializingWith:)`

The function proposed here only exposes uninitialized capacity in the `OutputSpan` parameter to its closure. A different function (perhaps named `edit()`) could also pass the initialized portion of the container, allowing an algorithm to remove or to add elements. This could be considered in addition to `append()`.

#### <a name="contentsOf"></a>Methods to initialize or update in bulk

The `RangeReplaceableCollection` protocol has a foundational method `append(contentsOf:)` for which this document does not propose a corresponding method. We expect to first add such bulk-copying functions as part of of a package.

`OutputSpan` lays the groundwork for new, generalized `Container` protocols that will expand upon and succeed the `Collection` hierarchy while allowing non-copyability and non-escapability to be applied to both containers and elements. We hope to find method and property names that will be generally applicable. The `append(contentsOf:)` method we refer to above always represents copyable and escapable collections with copyable and escapable elements. The definition is as follows: `mutating func append<S: Sequence>(contentsOf newElements: __owned S)`. This supports copying elements from the source, while also destroying the source if we happen to hold its only copy. This is obviously not sufficient if the elements are non-copyable, or if we only have access to a borrowed source.

When the elements are non-copyable, we must append elements that are removed from the source. Afterwards, there are two possible dispositions of the source: destruction (`consuming`), where the source can no longer be used, or mutation (`inout`), where the source has been emptied but is still usable.

When the elements are copyable, we can simply copy the elements from the source. Afterwards, there are two possible dispositions of the source: releasing a borrowed source, or `consuming`. The latter is approximately the same behaviour as `RangeReplaceableCollection`'s `append(contentsOf:)` function shown above.

In an ideal world, we would like to use the same name for all of these variants:

```swift
extension OutputSpan {
  mutating func append(contentsOf: consuming some Sequence<Element>)
  mutating func append(contentsOf: borrowing some Container<Element>)
}
extension OutputSpan where Element: ~Copyable {
  mutating func append(contentsOf: consuming some ConsumableContainer<Element>)
  mutating func append(contentsOf: inout some RangeReplaceableContainer<Element>)
}
```

However, this would break down in particular for `UnsafeMutableBufferPointer`, since it would make it impossible to differentiate between just copying the elements out of it, or moving its elements out (and deinitializing its memory). Once the `Container` protocols exist, we can expect that the same issue would exist for any type that conforms to more than one of the protocols involved in the list above. For example if a type conforms to `Container` as well as `Sequence`, then there would be an ambiguity.

We could fix this by extending the syntax of the language. It is already possible to overload two functions where they differ only by whether a parameter is `inout`, for example. This is a more advanced [future direction](#contentsOf-syntax).

Instead of the "ideal" solution, we could propose `append()` functions in the following form:

```swift
extension OutputSpan {
  mutating func append(contentsOf: consuming some Sequence<Element>)
  mutating func append(copying: borrowing some Container<Element>)
}
extension OutputSpan where Element: ~Copyable {
  mutating func append(consuming: consuming some ConsumableContainer<Element>)
  mutating func append(moving: inout some RangeReplaceableContainer<Element>)
}
```

In this form, we continue to use the `contentsOf` label for `Sequence` parameters, but use different labels for the other types of containers. The `update()` methods of `MutableSpan` could be updated in a similar manner, for the same reasons.

We note that the four variants of `append()` are required for generalized containers. We can therefore expect that the names we choose will appear later on many types of collections that interact with the future `Container` protocols. Since this nomenclature could become ubiquitous when interacting with `Collection` and `Container` instances, we defer a formal proposal until we have more experience and feedback.

In the meantime, many applications will work efficiently with repeated calls to `append()` in a loop. The bulk initialization functions are implementable by using `withUnsafeBufferPointer` as a workaround as well, if performance is an issue before a package-based solution is released.

#### <a name="contentsOf-syntax"></a>Language syntax to distinguish between ownership modes for function arguments

In the previous "Future Direction" subsection about [bulk initialization methods](#contentsOf), we suggest a currently unachievable naming scheme:
```swift
extension OutputSpan {
  mutating func append(contentsOf: consuming some Sequence<Element>)
  mutating func append(contentsOf: borrowing some Container<Element>)
}
extension OutputSpan where Element: ~Copyable {
  mutating func append(contentsOf: consuming some ConsumableContainer<Element>)
  mutating func append(contentsOf: inout some RangeReplaceableContainer<Element>)
}
```

The language partially supports disambiguating this naming scheme, in that we can already distinguish functions over the mutability of a single parameter:

```swift
func foo(_ a: borrowing A) {}
func foo(_ a: inout A) {}

var a = A()
foo(a)
foo(&a)
```

We could expand upon this ability to disambiguate by using keywords or even new sigils:

```swift
let buffer: UnsafeMutableBufferPointer<MyType> = ...
let array = Array(capacity: buffer.count*2) {
  (o: inout OutputSpan<MyType>) in
  o.append(contentsOf: borrow buffer)
  o.append(contentsOf: consume buffer)
}
```

## Acknowledgements

Thanks to Karoy Lorentey, Nate Cook and Tony Parker for their feedback.
