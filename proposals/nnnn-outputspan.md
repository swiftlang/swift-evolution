# OutputSpan: delegate initialization of contiguous memory

* Proposal: TBD
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Pitch**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: "Future" target of [swift-collections](https://github.com/apple/swift-collections/tree/future)
* Review: [Pitch](https://forums.swift.org/)

[SE-0446]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md
[SE-0447]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md
[SE-0456]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md
[SE-0467]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md
[PR-LifetimeAnnotations]: https://github.com/swiftlang/swift-evolution/pull/2750
[Forum-LifetimeAnnotations]: https://forums.swift.org/t/78638
[SE-0453]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md

## Introduction

Following the introduction of [`Span`][SE-0447] and [`MutableSpan`][SE-0467], this proposal adds a general facility for initialization of exclusively-borrowed memory with the `OutputSpan` and `OutputRawSpan` types. The memory represented by `OutputSpan` consists of a number of initialized elements, followed by uninitialized memory. The operations of `OutputSpan` can change the number of initialized elements in memory, unlike `MutableSpan` which always represents memory that is initialized.

## Motivation

Some standard library container types can delegate initialization of some or all of their storage to user code. Up to now, it has only been possible to do so with explicitly unsafe ways, which have also proven error-prone. The standard library provides this unsafe functionality with the closure-taking initializers `Array.init(unsafeUninitializedCapacity:initializingWith:)` and `String.init(unsafeUninitializedCapacity:initializingUTF8With:)`.

These functions have a few different drawbacks, most prominently their reliance on unsafe types, which makes them unpalatable in security-conscious environments. We continue addressing these issues with `OutputSpan` and `OutputRawSpan`, new non-copyable and non-escapable types that manage initialization of typed and untyped memory.

In addition to the new types, we will propose adding new API for some standard library types to take advantage of `OutputSpan` and `OutputRawSpan`, and improve upon the `Array` and `String` initializers mentioned above.

## Proposed solution

#### OutputSpan

`OutputSpan` allows delegating the initialization of a type's memory, by providing access to an exclusively-borrowed view of a range of contiguous memory. `OutputSpan`'s contiguous memory consists of a prefix of initialized memory, followed by a suffix of uninitialized memory. Like `MutableSpan`, `OutputSpan` relies on two guarantees: (a) that it has exclusive access to the range of memory it represents, and (b) that the memory locations it represents will remain valid for the duration of the access. These guarantee data race safety and temporal safety. `OutputSpan` performs bounds-checking on every access to preserve spatial safety.

An `OutputSpan` provided by a container represents a mutation of that container, and is therefore an exclusive access.

#### OutputRawSpan

`OutputRawSpan` allows delegating the initialization of heterogeneously-typed memory, such as memory being prepared by an encoder. It makes the same safety guarantees as `OutputSpan`.

#### Extensions to standard library types

The standard library will provide new container initializers that delegate to an `OutputSpan`. Delegated initialization generally requires a container to perform some operations after the initialization has happened. In the case of `Array` this is simply noting the number of initialized elements; in the case of `String` this consists of validating the input. This post-processing implies the need for a scope, and we believe that scope is best represented by a closure. The `Array` initializer will be as follows:

```swift
extension Array {
  public init<E: Error>(
    capacity: Int,
    initializingWith: (_ span: inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}
```

We will also extend `String`, `UnicodeScalarView` and `InlineArray` with similar initializers, and add append-in-place operations where appropriate.

#### `@lifetime` attribute

Some of the API presented here must establish a lifetime relationship between a non-escapable returned value and a callee binding. This relationship will be illustrated using the `@lifetime` attribute recently [pitched][PR-LifetimeAnnotations] and [formalized][Forum-LifetimeAnnotations]. For the purposes of this proposal, the lifetime attribute ties the lifetime of a function's return value to one of its input parameters.

Note: The eventual lifetime annotations proposal may adopt a syntax different than the syntax used here. We expect that the Standard Library will be modified to adopt an updated lifetime dependency syntax as soon as it is finalized.

## <a name="design"></a>Detailed Design

#### OutputSpan

`OutputSpan<Element>` is a simple representation of a partially-initialized region of memory. It is non-copyable in order to enforce exclusive access for mutations of its memory, as required by the law of exclusivity:

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
  @lifetime(self: copy self)
  public mutating func append(_ value: consuming Element)
}
```
The converse operation `removeLast()` is also supported, and returns the removed element if `count` was greater than zero.
```swift
extension OutputSpan where Element: ~Copyable {
  /// Remove the last initialized element from this `OutputSpan`.
  @discardableResult
  @lifetime(self: copy self)
  public mutating func removeLast() -> Element?
}
```

##### Bulk initialization of an `OutputSpan`'s memory:

We include functions to perform bulk initialization of the memory represented by an `OutputSpan`. Initializing an `OutputSpan` from a `Sequence` or a fixed-size source must use every element of the source. Initializing an `OutputSpan` from `IteratorProtocol` will copy as many items as possible, either until the input is empty or the `OutputSpan`'s available storage is zero.

```swift
extension OutputSpan {
  /// Initialize this span's suffix to the repetitions of the given value.
  @lifetime(self: copy self)
  public mutating func append(repeating repeatedValue: Element, count: Int)

  /// Initialize this span's suffix with the elements from the source.
  ///
  /// Returns true if the iterator has filled all the free capacity in the span.
  @discardableResult
  @lifetime(self: copy self)
  public mutating func append(
    from source: inout some IteratorProtocol<Element>
  ) -> Bool

  /// Initialize this span's suffix with every element of the source.
  ///
  /// It is a precondition that the `OutputSpan` can contain every element of the source.
  @lifetime(self: copy self)
  public mutating func append(
    fromContentsOf source: some Sequence<Element>
  )

  /// Initialize this span's suffix with every element of the source.
  ///
  /// It is a precondition that the `OutputSpan` can contain every element of the source.
  @lifetime(self: copy self)
  public mutating func append(
    fromContentsOf source: Span<Element>
  )

  /// Initialize this span's suffix with every element of the source.
  ///
  /// It is a precondition that the `OutputSpan` can contain every element of the source.
  @lifetime(self: copy self)
  public mutating func append(
    fromContentsOf source: UnsafeBufferPointer<Element>
  )
}

extension OutputSpan where Element: ~Copyable {
  /// Initialize this span's suffix by moving every element from the source.
  ///
  /// It is a precondition that the `OutputSpan` can contain every element of the source.
  @lifetime(self: copy self)
  public mutating func moveAppend(
    fromContentsOf source: inout OutputSpan<Element>
  )

  /// Initialize this span's suffix by moving every element from the source.
  ///
  /// It is a precondition that the `OutputSpan` can contain every element of the source.
  @lifetime(self: copy self)
  public mutating func moveAppend(
    fromContentsOf source: UnsafeMutableBufferPointer<Element>
  )
}

extension OutputSpan {
  /// Initialize this span's suffix by moving every element from the source.
  ///
  /// It is a precondition that the `OutputSpan` can contain every element of the source.
  @lifetime(self: copy self)
  public mutating func moveAppend(
    fromContentsOf source: Slice<UnsafeMutableBufferPointer<Element>>
  )
}
```

A bulk operation to deinitialize all of an `OutputSpan`'s memory is also available:
```swift
extension OutputSpan where Element: ~Copyable {
  /// Remove all this span's elements and return its memory to the uninitialized state.
  @lifetime(self: copy self)
  public mutating func removeAll()
}
```

##### Accessing an `OutputSpan`'s initialized memory:

The initialized elements are accessible for read-only or mutating access via the `span` and `mutableSpan` properties:

```swift
extension OutputSpan where Element: ~Copyable {
  /// Borrow the underlying initialized memory for read-only access.
  public var span: Span<Element> {
    @lifetime(borrow self) borrowing get
  }

  /// Exclusively borrow the underlying initialized memory for mutation.
  public mutating var mutableSpan: MutableSpan<Element> {
    @lifetime(&self) mutating get
  }
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
  @lifetime(self: copy self)
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
  @lifetime(borrow buffer)
  public init(
    buffer: UnsafeMutableBufferPointer<Element>,
    initializedCount: Int
  )

  /// Create an OutputSpan with zero capacity
  @lifetime(immortal)
  public init()
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
  @lifetime(borrow buffer)
  public init(
    buffer: borrowing Slice<UnsafeMutableBufferPointer<Element>>,
    initializedCount: Int
  )
}
```



##### Retrieving initialized memory from an `OutputSpan`

Once memory has been initialized using `OutputSpan`, the owner of the memory must consume the `OutputSpan` in order to retake ownership of the initialized memory. The owning type must pass the memory used to initialize the `OutputSpan` to the `finalize(for:)` function. Passing the wrong buffer is a programmer error and the function traps. `finalize()` consumes the `OutputSpan` instance and returns the number of initialized elements.

```swift
extension OutputSpan where Element: ~Copyable {
  /// Consume the OutputSpan and return the number of initialized elements.
  /// 
  /// Parameters:
  /// - buffer: The buffer being finalized. This must be the same buffer as used to
  ///           initialize the `OutputSpan` instance.
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
  /// - buffer: The buffer being finalized. This must be the same buffer as used to
  ///           initialize the `OutputSpan` instance.
  /// Returns: The number of bytes that were initialized.
  @unsafe
  public consuming func finalize(
    for buffer: Slice<UnsafeMutableBufferPointer<Element>>
  ) -> Int
}
```




#### `OutputRawSpan`
`OutputRawSpan` is similar to `OutputSpan<T>`, but represents an untyped partially-initialized region of memory. Its API supports appending the bytes of  instances of `BitwiseCopyable` types, as well as a variety of bulk initialization operations.
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

  /// The nmuber of uninitialized bytes remaining in this `OutputRawSpan`
  public var available: Int { get } // capacity - byteCount
}
```



##### Appending to `OutputRawSpan`

The basic operation is to append the bytes of some value to an `OutputRawSpan`:
```swift
extension OutputRawSpan {
  /// Appends the given value's bytes to this span's initialized bytes
  @lifetime(self: copy self)
  public mutating func appendBytes<T: BitwiseCopyable>(
    of value: T, as type: T.Type
  )
}
```

This is also supported with bulk operations. Initializing an `OutputRawSpan` from known-sized sources (such as `Collection` or `Span`) uses every element of the source. It is an error to do so when the available storage of the `OutputRawSpan` is too little to contain every element from the source. Initializing an `OutputRawSpan` from `Sequence` or `IteratorProtocol` will copy as many items as possible, either until the input is empty or the `OutputRawSpan` has too few bytes available to store another element.
```swift
extension OutputRawSpan
  /// Initialize this span's suffix to the repetitions of the given value's bytes.
  @lifetime(self: copy self)
  public mutating func append<T: BitwiseCopyable>(repeating repeatedValue: T, count: Int)

  /// Initialize the span's bytes with the bytes of the elements of the source.
  ///
  /// Returns true if the iterator has filled all the free capacity in the span.
  @lifetime(self: copy self)
  public mutating func append(
    from source: inout some IteratorProtocol<some BitwiseCopyable>
  ) -> Bool

  /// Initialize the span's bytes with every byte of the source.
  @lifetime(self: copy self)
  public mutating func append(
    fromContentsOf source: some Sequence<some BitwiseCopyable>
  )

  /// Initialize the span's bytes with every byte of the source.
  @lifetime(self: copy self)
  public mutating func append(
    fromContentsOf source: Span<some BitwiseCopyable>
  )

  /// Initialize the span's bytes with every byte of the source.
  @lifetime(self: copy self)
  public mutating func append(
    fromContentsOf source: RawSpan
  )

  /// Initialize the span's bytes with every byte of the source.
  @lifetime(self: copy self)
  public mutating func append(
    fromContentsOf source: UnsafeRawBufferPointer
  )
}
```

An `OutputRawSpan`'s initialized memory is accessible for read-only or mutating access via the `bytes` and `mutableBytes` properties:

```swift
extension OutputRawSpan {
  /// Borrow the underlying initialized memory for read-only access.
  public var bytes: RawSpan {
    @lifetime(borrow self) borrowing get
  }

  /// Exclusively borrow the underlying initialized memory for mutation.
  public var mutableBytes: MutableRawSpan {
    @lifetime(&self) mutating get
  }
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
  @lifetime(self: copy self)
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
  @lifetime(borrow buffer)
  public init(
    buffer: UnsafeMutableRawBufferPointer,
    initializedCount: Int
  )

  /// Create an OutputRawSpan with zero capacity
  @lifetime(immortal)
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
  @lifetime(borrow buffer)
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
  /// - buffer: The buffer being finalized. This must be the same buffer as used to
  ///           create the `OutputRawSpan` instance.
  /// Returns: The number of initialized bytes.
  @unsafe
  public consuming func finalize(
    for buffer: UnsafeMutableRawBufferPointer
  ) -> Int

  /// Consume the OutputRawSpan and return the number of initialized bytes.
  /// 
  /// Parameters:
  /// - buffer: The buffer being finalized. This must be the same buffer as used to
  ///           create the `OutputRawSpan` instance.
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
  public init<E: Error>(
    capacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
  
  public mutating func append<E: Error>(
    addingCapacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}

extension String {
  public init<E: Error>(
    utf8Capacity: Int,
    initializingUTF8With initializer: (inout OutputSpan<UTF8.CodeUnit>) throws(E) -> Void
  )

  public init<E: Error>?(
    utf8Capacity: Int,
    initializingValidUTF8With initializer: (inout OutputSpan<UTF8.CodeUnit>) throws(E) -> Void
  ) throws(E)
  
  public mutating func append<E: Error>(
    addingUTF8Capacity: Int,
    initializingUTF8With initializer: (inout OUtputSpan<UTF8.CodeUnit>) throws(E) -> Void
  ) throws(E)
}

extension UnicodeScalarView {
  public init<E: Error>(
    utf8Capacity: Int,
    initializingUTF8With initializer: (inout OutputSpan<UTF8.CodeUnit>) throws(E) -> Void
  )

  public init<E: Error>?(
    utf8Capacity: Int,
    initializingValidUTF8With initializer: (inout OutputSpan<UTF8.CodeUnit>) throws(E) -> Void
  ) throws(E)
  
  public mutating func append<E: Error>(
    addingUTF8Capacity: Int,
    initializingUTF8With initializer: (inout OUtputSpan<UTF8.CodeUnit>) throws(E) -> Void
  ) throws(E)
}

extension InlineArray {
  public init<E: Error>(
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}
```

#### Extensions to `Foundation.Data`

While the `swift-foundation` package and the `Foundation` framework are not governed by the Swift evolution process, `Data` is similar in use to standard library types, and the project acknowledges that it is desirable for it to have similar API when appropriate. Accordingly, we plan to propose the following additions to `Foundation.Data`:
```swift
extension Data {
  public init<E: Error>(
    capacity: Int,
    initializingWith initializer: (inout OutputSpan<UInt8>) throws(E) -> Void
  ) throws(E)

  public init<E: Error>(
    rawCapacity: Int,
    initializingWith initializer: (inout OutputRawSpan) throws(E) -> Void
  ) throws(E)
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal is additive and ABI-compatible with existing code.

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library and runtime.


## Alternatives Considered

#### Vending `OutputSpan` as a property

`OutputSpan` changes the number of initialized elements in a container (or collection), and this requires some operation to update the container after the `OutputSpan` is consumed. Let's call that update operation a "cleanup" operation. The cleanup operation needs to be scheduled in some way. We could associate the cleanup with the `deinit` of `OutputSpan`, or the `deinit` of a wrapper of `OutputSpan`. Neither of these seem appealing; the mechanisms would involve an arbitrary closure executed at `deinit` time, or having to write a full wrapper for each type that vends an `OutputSpan`. We could potentially schedule the cleanup operation as part of a coroutine accessor, but these are not productized yet. The pattern established by closure-taking API is well established, and it fits the needs of `OutputSpan` well.


## <a name="directions"></a>Future directions

#### Helpers to initialize memory in an arbitrary order

Some applications may benefit from the ability to initialize a range of memory in a different order than implemented by `OutputSpan`. This may be from back-to-front or even arbitrary order. There are many possible forms such an initialization helper can take, depending on how much memory safety the application is willing to give up in the process of initializing the memory. At the unsafe end, this can be delegating to an `UnsafeMutableBufferPointer` along with a set of requirements; this option is proposed here. At the safe end, this could be delegating to a data structure which keeps track of initialized memory using a bitmap. It is unclear how much need there is for this more heavy-handed approach, so we leave it as a future enhancement if it is deemed useful.

## Acknowledgements

Thanks to Karoy Lorentey, Nate Cook and Tony Parker for their feedback.
