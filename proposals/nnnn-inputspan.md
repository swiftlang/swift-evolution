# InputSpan for consumption of contiguous memory

* Proposal: [SE-NNNN](nnnn-inputspan.md)
* Authors: [Guillaume Lessard](https://github.com/glessard), [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: TBD
* Status: **Awaiting review**
* Roadmap: [BufferView Roadmap](https://forums.swift.org/t/66211)
* Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/t/NNNNN))

[SE-0485]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md
[SE-0516]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md
[SE-0525]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0525-rawspan-safe-loading-api.md
[SE-0527]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md
[SE-0558]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0558-mutablespan-bulk-updates.md

## Summary of changes

Adds `InputSpan` and `InputRawSpan`, duals of `OutputSpan` and `OutputRawSpan`. They represent a region of memory where contiguous initialized elements follow a region of uninitialized memory.

## Motivation

Containers of noncopyable elements currently do not have an efficient method to selectively deinitialize their elements in place. For example, an `InlineArray` of noncopyable elements cannot provide a subset of its contents to another container. We propose `InputSpan` to provide this functionality.

```swift
struct MyNonCopyable: ~Copyable {}
let vector: [4 of MyNonCopyable] = ...
let selected = vector.consumeAll {
  (span: consuming InputSpan) in
  let n = span.indices.randomElement()!
  span.removeFirst(n)
  return span.removeFirst()
}
```

`InlineArray`'s `consumeAll(consumingWith:)` method (shown above) passes the entire contents of the array to be consumed by a closure receiving an `InputSpan` parameter.

Parsers will lend themselves to using instances of `InputSpan` (or `InputRawSpan`), and data structures such as ring buffers (or [`Deque`](https://github.com/apple/swift-collections/blob/main/Sources/DequeModule/Deque/Deque.swift)) will be able to provide their elements through `InputSpan` instances.

## Proposed solution

#### `InputSpan` and `InputRawSpan`

`InputSpan` and `InputRawSpan` are counterparts to `OutputSpan` and `OutputRawSpan`, introduced in [SE-0485][SE-0485]. They represent a single range of mutable memory separated in two parts: a prefix of uninitialized memory, followed by a suffix of initialized elements. This order is the opposite of `OutputSpan`, where the uninitialized memory is at the end of the range. `InputSpan`'s operations manage the initialization state to preserve the invariant that the initialized memory remains contiguous.

`InputSpan` and `InputRawSpan` rely on the same memory-safety guarantees as `OutputSpan` and `OutputRawSpan`. They manage the initialization state of the memory they represent on behalf of the memory's owner.

When an `InputSpan` goes out of scope, all of its remaining elements are deinitialized. This allows some container types to delegate the deinitialization of their contents to an `InputSpan`, without requiring a closure.

##### Naming

Beyond the fact that `InputSpan` is a dual of the pre-existing `OutputSpan`, there is a good reason to give these types the names "input" and "output". Computer architectures are built around a privileged order for addressable memory: it is most efficiently accessed in order from low addresses to high addresses.

As a consequence, an algorithm writing results out to memory will most efficiently write them out in the way an `OutputSpan` expects them: by appending values from low to high addresses.

Similarly, an algorithm reading in input values will efficiently read them from low to high addresses, and `InputSpan` provides those values in the order expected by such an algorithm.

##### API of `InputSpan` and `InputRawSpan`

`InputSpan` and `InputRawSpan` should have very similar API to their counterparts, `OutputSpan` and `OutputRawSpan`. The main difference is that the `append` family of functions for `Output[Raw]Span` corresponds to a `prepend` family of functions for `Input[Raw]Span`. Their privileged usage is for consuming rather than for initializing.

#### Extensions to standard library types

`InlineArray`, `UniqueArray` and `OutputSpan` add `consumeAll()` functions similar to the one shown in the motivation above. For example, `InlineArray`'s version is:

```swift
extension InlineArray where Element: ~Copyable {
  consuming func consumeAll<E: Error, R: ~Copyable>(
    consumingWith consumer: (consuming InputSpan<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

`UniqueArray` and `OutputSpan` add methods to consume a suffix of their elements as an `InputSpan`. One of `OutputSpan`'s additions is:

```swift
extension OutputSpan where Element: ~Copyable {
  @_lifetime(&self)
  mutating func consumeSuffix(maxCount: Int) -> InputSpan<Element>
}
```

## <a name="design"></a>Detailed design

### `InputSpan`

`InputSpan<Element>` represents a partly-initialized region of memory. Its noncopyability enforces exclusive access to its memory. Its nonescapability ensures that it does not outlive its memory.

```swift
@frozen
struct InputSpan<Element: ~Copyable>: ~Copyable, ~Escapable {
  /// The number of initialized elements in this span.
  var count: Int { get }

  /// The total number of elements that this input span can contain.
  var capacity: Int { get }

  /// The number of additional elements that can be prepended to this span.
  var freeCapacity: Int { get } // capacity - count

  /// A Boolean value indicating whether the span is empty.
  var isEmpty: Bool { get }

  /// A Boolean value indicating whether the span is full.
  var isFull: Bool { get }
}

extension InputSpan: @unchecked Sendable where Element: Sendable & ~Copyable {}
```

The memory represented by an `InputSpan` has room for `capacity` instances of `Element`. The `count` initialized elements are located at the end of the range of memory. They are preceded by `capacity - count` slots of uninitialized memory.

##### Removing elements

The basic operation supported by `InputSpan` is removing the first initialized element and returning it. The memory where the element was stored is deinitialized, and `count` decreases by 1. `removeFirst()` traps when the span is empty. `popFirst()` returns `nil` instead when the span is empty.

```swift
extension InputSpan where Element: ~Copyable {
  /// Remove the first initialized element from this span.
  mutating func removeFirst() -> Element

  /// Remove and return the first element of this span, if it exists.
  mutating func popFirst() -> Element?
}
```

Bulk operations to deinitialize multiple elements:

```swift
extension InputSpan where Element: ~Copyable {
  /// Remove the first n elements of this span,
  /// by deinitializing the memory they occupy.
  ///
  /// `n` must not be greater than `count`.
  mutating func removeFirst(_ n: Int)

  /// Remove all of this span's elements by deinitializing all its memory.
  mutating func removeAll()
}
```

`consumePrefix(maxCount:)` removes elements from the front of an `InputSpan` without deinitializing them. It transfers their ownership to a new `InputSpan`.

```swift
extension InputSpan where Element: ~Copyable {
  /// Remove up to maxCount elements from the beginning of this span, and return
  /// an input span that takes ownership of the removed elements.
  @_lifetime(&self)
  mutating func consumePrefix(maxCount: Int) -> InputSpan<Element>
}
```

The returned `InputSpan` has a `capacity` equal to its `count`, and it exclusively borrows the span it was taken from: the original span cannot be used again until the returned span's lifetime ends. The memory previously occupied by the consumed elements becomes part of the original span's free capacity.

```swift
extension InputSpan where Element: ~Copyable {
  /// Remove up to maxCount elements from the beginning of this span
  /// and pass them to a closure through an input span.
  mutating func consumePrefix<E: Error, R: ~Copyable>(
    maxCount: Int,
    consumingWith consumer: (consuming InputSpan<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

##### Prepending elements

While the primary operation of `InputSpan` is to remove or consume elements, it can also prepend elements into its uninitialized memory. For each element prepended, the span's `count` is incremented by 1. If the span doesn't have enough free capacity, the operation traps.

```swift
extension InputSpan where Element: ~Copyable {
  /// Prepend a single element to this span.
  mutating func prepend(_ value: consuming Element)
}

extension InputSpan {
  /// Repeatedly prepend an element to this span.
  mutating func prepend(repeating repeatedValue: Element, count: Int)
}
```

Since an `InputSpan`'s initialized elements are always a suffix of its memory, the front is the only end at which elements can be added or removed. `InputSpan` has `removeFirst()` and `prepend()`, but has neither `removeLast()` nor `append()`.

##### Accessing an `InputSpan`'s initialized elements

The `span` and `mutableSpan` properties provide read-only or mutating access to the initialized elements:

```swift
extension InputSpan where Element: ~Copyable {
  /// Borrow the underlying initialized memory for read-only access.
  var span: Span<Element> { get }

  /// Exclusively borrow the underlying initialized memory for mutation.
  var mutableSpan: MutableSpan<Element> { mutating get }
}
```

`InputSpan` also provides access to its initialized elements by index. Index 0 is the first initialized element, corresponding to the element that would be returned by `removeFirst()`.

```swift
extension InputSpan where Element: ~Copyable {
  /// The type that represents an initialized index in an input span.
  typealias Index = Int

  /// The range of initialized indices for this span.
  var indices: Range<Index> { get }

  /// Access the element at the specified index.
  subscript(_ index: Index) -> Element { borrow; mutate }

  /// Access the element at the specified index.
  @unsafe
  subscript(unchecked index: Index) -> Element { borrow; mutate }

  /// Exchange the elements at the two given indices.
  mutating func swapAt(_ i: Index, _ j: Index)

  /// Exchange the elements at the two given indices.
  @unsafe
  mutating func swapAt(unchecked i: Index, unchecked j: Index)
}
```

`InputSpan` conforms to the `Iterable` protocol of [SE-0516][SE-0516]. Iterating over an `InputSpan` borrows its initialized elements and does not consume them.

```swift
extension InputSpan: Iterable where Element: ~Copyable {
  typealias Failure = Never
  var underestimatedCount: Int { get }
  func makeBorrowingIterator() -> Span<Element>.BorrowingIterator
}
```

##### Unsafe buffer access

We provide a method to process or consume the contents of an `InputSpan` using unsafe operations, such as dispatching to code written in legacy (memory-unsafe) languages.

```swift
extension InputSpan where Element: ~Copyable {
  /// Call the given closure with the unsafe buffer pointer addressed by this
  /// InputSpan and a mutable reference to its count of initialized elements.
  ///
  /// This method provides a way to process or consume the contents of an
  /// `InputSpan` using unsafe operations, such as dispatching to code written
  /// in legacy (memory-unsafe) languages.
  ///
  /// The supplied closure may process the buffer in any way it wants; however,
  /// when it finishes (whether by returning or throwing), it must leave the
  /// buffer in a state that satisfies the invariants of the input span:
  ///
  /// 1. The inout integer passed in as the second argument must be the exact
  ///     number of initialized items in the buffer passed in as the first
  ///     argument.
  /// 2. These initialized elements must be located in a single contiguous
  ///     region located at the end of the buffer. The initialized region must
  ///     be preceded by uninitialized memory.
  ///
  /// This function cannot verify these two invariants, and therefore
  /// this is an unsafe operation. Violating the invariants of `InputSpan`
  /// may result in undefined behavior.
  @unsafe
  mutating func withUnsafeMutableBufferPointer<E: Error, R: ~Copyable>(
    _ body: (
      UnsafeMutableBufferPointer<Element>,
      _ initializedCount: inout Int
    ) throws(E) -> R
  ) throws(E) -> R
}
```

##### Creating an `InputSpan` instance

Creating an `InputSpan` is an unsafe operation. It requires having knowledge of the initialization state of the range of memory being targeted. The range of memory must be in two regions: the first region is uninitialized, and the second region contains initialized instances of `Element`. The number of initialized instances is passed to the `InputSpan` initializer through its `initializedCount` argument. The initializer traps if `initializedCount` is negative or greater than the buffer's count.

```swift
extension InputSpan where Element: ~Copyable {
  /// Unsafely create an InputSpan over partly-initialized memory.
  @unsafe
  init(
    buffer: UnsafeMutableBufferPointer<Element>,
    initializedCount: Int
  )
}

extension InputSpan {
  /// Unsafely create an InputSpan over partly-initialized memory.
  @unsafe
  init(
    buffer: borrowing Slice<UnsafeMutableBufferPointer<Element>>,
    initializedCount: Int
  )
}
```

As with `OutputSpan`, we also provide a default (no-parameter) initializer to create an empty, zero-capacity `InputSpan`. Such an initializer is useful to materialize an empty span for the `nil` case of an `Optional`, for example, or to exchange with another span in a mutable struct.

```swift
extension InputSpan where Element: ~Copyable {
  /// Create an InputSpan with zero capacity.
  @_lifetime(immortal)
  init()
}
```

##### Retrieving the remaining elements from an `InputSpan`

Once a function has finished consuming elements from an `InputSpan`, the owner of the memory must consume the `InputSpan` to retake ownership of the elements that remain. The owning type must pass the memory used to create the `InputSpan` to the `finalize(for:)` function. Passing the wrong buffer is a programmer error and the function traps; this requirement also ensures that user code does not wrongly replace the `InputSpan` with an unrelated instance. The `finalize(for:)` function consumes the `InputSpan` instance and returns the number of initialized elements still held in the buffer. If `finalize(for:)` is not called, the initialized elements of an `InputSpan` are deinitialized when the binding goes out of scope.

```swift
extension InputSpan where Element: ~Copyable {
  /// Consume the input span and return the number of initialized elements
  /// remaining at the end of the underlying memory region.
  @unsafe
  consuming func finalize(
    for buffer: UnsafeMutableBufferPointer<Element>
  ) -> Int
}

extension InputSpan {
  /// Consume the input span and return the number of initialized elements
  /// remaining at the end of the underlying memory region.
  @unsafe
  consuming func finalize(
    for buffer: Slice<UnsafeMutableBufferPointer<Element>>
  ) -> Int
}
```

### Extensions to `OutputSpan`

`OutputSpan` can empty all or a suffix of its elements into an `InputSpan`, either by returning it or by passing it to a closure.

```swift
extension OutputSpan where Element: ~Copyable {
  /// Remove all elements from this span, and return an input span that takes
  /// ownership of the elements.
  @_lifetime(&self)
  mutating func consumeAll() -> InputSpan<Element>

  /// Remove all elements from this span by passing them to
  /// a closure through an input span.
  mutating func consumeAll<E: Error, R: ~Copyable>(
    consumingWith consumer: (consuming InputSpan<Element>) throws(E) -> R
  ) throws(E) -> R

  /// Remove up to maxCount elements from the end of this span, and return
  /// an input span that takes ownership of the removed elements.
  @_lifetime(&self)
  mutating func consumeSuffix(maxCount: Int) -> InputSpan<Element>

  /// Remove up to maxCount elements from the end of this span, by
  /// passing them to a closure through an input span.
  mutating func consumeSuffix<E: Error, R: ~Copyable>(
    maxCount: Int,
    consumingWith consumer: (consuming InputSpan<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

We want the API of `OutputSpan` and `InputSpan` to be aligned. Accordingly, we propose an `OutputSpan` equivalent of `InputSpan`'s `popFirst()`:

```swift
extension OutputSpan where Element: ~Copyable {
  /// Remove and return the last element of this span, if it exists.
  mutating func popLast() -> Element?
}
```

### Extensions to `InlineArray`

An `InlineArray` can be consumed by passing its elements to a closure through an `InputSpan`. `consumeAll(consumingWith:)` consumes the array, and the `InputSpan` becomes the owner of the elements. The closure could be used to transfer some of the array's elements to a `UniqueArray`, for example.

```swift
extension InlineArray where Element: ~Copyable {
  /// Consume this array by passing all of its elements to a closure
  /// through an input span.
  ///
  /// The closure chooses how to dispose of the elements. Any remaining
  /// elements are deinitialized when the input span goes out of scope,
  /// whether the closure returns normally or by throwing.
  ///
  /// The `InputSpan` instance has a capacity equal to the array's count.
  ///
  /// - Parameter consumer: A closure that takes ownership of an `InputSpan`
  ///     containing the elements of this array.
  /// - Returns: The value returned by `consumer`.
  consuming func consumeAll<E: Error, R: ~Copyable>(
    consumingWith consumer: (consuming InputSpan<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

### Extensions to `UniqueArray`

`UniqueArray` adds the same consuming functions as `OutputSpan` does:

```swift
extension UniqueArray where Element: ~Copyable {
  /// Remove all elements from this array, and return an input span that takes
  /// ownership of the elements.
  @_lifetime(&self)
  mutating func consumeAll() -> InputSpan<Element>

  /// Remove all elements from this array by passing them to
  /// a closure through an input span.
  mutating func consumeAll<E: Error, R: ~Copyable>(
    consumingWith consumer: (consuming InputSpan<Element>) throws(E) -> R
  ) throws(E) -> R

  /// Remove up to maxCount elements from the end of this array, and return
  /// an input span that takes ownership of the removed elements.
  @_lifetime(&self)
  mutating func consumeSuffix(maxCount: Int) -> InputSpan<Element>

  /// Remove up to maxCount elements from the end of this array, by
  /// passing them to a closure through an input span.
  mutating func consumeSuffix<E: Error, R: ~Copyable>(
    maxCount: Int,
    consumingWith consumer: (consuming InputSpan<Element>) throws(E) -> R
  ) throws(E) -> R
}
```

### Extensions to `MutableSpan`

[SE-0558][SE-0558] adds `updateAll(moving:)` and `updateSubrange(_:moving:)` for `MutableSpan`, taking an `OutputSpan` as their source. We propose matching overloads taking an `InputSpan` instance instead. They overwrite elements of the destination by moving the source's elements. The overwritten elements are deinitialized. The source must have exactly as many elements as the destination (or the destination's target subrange), or the functions trap. The source `InputSpan` is empty afterwards.

```swift
extension MutableSpan where Element: ~Copyable {
  /// Overwrites every element of this span by moving the elements
  /// from the source.
  mutating func updateAll(moving source: inout InputSpan<Element>)

  /// Overwrites the elements within a range of indices by moving
  /// the elements from the source.
  mutating func updateSubrange(
    _ subrange: Range<Index>, moving source: inout InputSpan<Element>
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Index>,
    moving source: inout InputSpan<Element>
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, moving source: inout InputSpan<Element>
  )
}
```

### `InputRawSpan`

`InputRawSpan` is the untyped counterpart of `InputSpan`, as `OutputRawSpan` is to `OutputSpan`. Its memory is a prefix of uninitialized bytes followed by `byteCount` initialized bytes, and bytes are removed or prepended at the front. Its API is similar to `OutputRawSpan`'s, with `prepend` operations in place of `append`. Safe `prepend` overloads follow the precedent of [SE-0525][SE-0525].

```swift
@frozen
struct InputRawSpan: ~Copyable, ~Escapable {
  /// The number of initialized bytes in this span.
  var byteCount: Int { get }

  /// The total number of bytes that this input span can contain.
  var capacity: Int { get }

  /// The number of additional bytes that can be prepended to this span.
  var freeCapacity: Int { get } // capacity - byteCount

  /// A Boolean value indicating whether the span is empty.
  var isEmpty: Bool { get }

  /// A Boolean value indicating whether the span is full.
  var isFull: Bool { get }

  /// The indices that are valid for subscripting the span, in ascending order.
  var byteOffsets: Range<Int> { get }
}

extension InputRawSpan: @unchecked Sendable {}
```

##### Prepending and removing bytes from `InputRawSpan`

```swift
extension InputRawSpan {
  /// Prepend a single byte to this span.
  mutating func prepend(_ value: UInt8)

  /// Prepend the given value's bytes to this span.
  mutating func prepend<T: ConvertibleToBytes & BitwiseCopyable>(
    _ value: T, as type: T.Type
  )

  /// Prepend the given integer's bytes to this span, in the given byte order.
  mutating func prepend<
    T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  >(
    _ value: T, as type: T.Type, _ byteOrder: ByteOrder
  )

  /// Prepend the given value's bytes to this span, including any padding.
  @unsafe
  mutating func prepend<T: BitwiseCopyable>(
    paddedBytes value: T, as type: T.Type
  )

  /// Repeatedly prepend the given value's bytes to this span.
  mutating func prepend<T: ConvertibleToBytes & BitwiseCopyable>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )

  /// Repeatedly prepend the given integer's bytes to this span,
  /// in the given byte order.
  mutating func prepend<
    T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  >(
    repeating repeatedValue: T, count: Int, as type: T.Type,
    _ byteOrder: ByteOrder
  )

  /// Repeatedly prepend the given value's bytes to this span,
  /// including any padding.
  @unsafe
  mutating func prepend<T: BitwiseCopyable>(
    repeatingPaddedBytes repeatedValue: T, count: Int, as type: T.Type
  )
}
```

Some of the overloads of `prepend()` take a `BitwiseCopyable` value whose representation may include padding bytes. We use the word `padded` to denote that indeterminate byte values may be copied. This label has also been [proposed](https://github.com/swiftlang/swift-evolution/pull/3371) for updated names to `OutputRawSpan`'s matching `append` overloads.

```swift
extension InputRawSpan {
  /// Remove the first byte from this span.
  mutating func removeFirst() -> UInt8

  /// Remove and return the first byte of this span, if it exists.
  mutating func popFirst() -> UInt8?

  /// Remove the first n bytes from this span.
  ///
  /// `n` must not be greater than `byteCount`.
  mutating func removeFirst(_ n: Int)

  /// Remove all of this span's bytes.
  mutating func removeAll()

  /// Remove up to maxByteCount bytes from the beginning of this span, and
  /// return an input span that takes ownership of the removed bytes.
  @_lifetime(&self)
  mutating func consumePrefix(maxByteCount: Int) -> InputRawSpan

  /// Remove up to maxByteCount bytes from the beginning of this span
  /// and pass them to a closure through an input span.
  mutating func consumePrefix<E: Error, R: ~Copyable>(
    maxByteCount: Int,
    consumingWith consumer: (consuming InputRawSpan) throws(E) -> R
  ) throws(E) -> R
}
```

##### Accessing the initialized bytes of `InputRawSpan`

```swift
extension InputRawSpan {
  /// Access the byte at the specified offset in the span.
  subscript(_ byteOffset: Int) -> UInt8 { get set }

  /// Access the byte at the specified offset in the span.
  @unsafe
  subscript(unchecked byteOffset: Int) -> UInt8 { get set }

  /// Borrow the underlying initialized memory for read-only access.
  var bytes: RawSpan { get }

  /// Exclusively borrow the underlying initialized memory for mutation.
  var mutableBytes: MutableRawSpan { mutating get }
}

extension InputRawSpan: Iterable {
  typealias Failure = Never
  var underestimatedCount: Int { get }
  func makeBorrowingIterator() -> Span<UInt8>.BorrowingIterator
}
```

##### Unsafe byte access

```swift
extension InputRawSpan {
  /// Call the given closure with the unsafe buffer pointer addressed by this
  /// InputRawSpan and a mutable reference to its count of initialized bytes.
  @unsafe
  mutating func withUnsafeMutableBytes<E: Error, R: ~Copyable>(
    _ body: (
      UnsafeMutableRawBufferPointer,
      _ initializedCount: inout Int
    ) throws(E) -> R
  ) throws(E) -> R
}
```

##### Creating an `InputRawSpan` instance

Creating an `InputRawSpan` is an unsafe operation. It requires having knowledge of the initialization state of the range of memory being targeted. The range of memory must be in two regions: the first region is uninitialized, and the second region contains initialized bytes. The number of initialized bytes is passed to the `InputRawSpan` initializer through its `initializedCount` argument.

```swift
extension InputRawSpan {
  /// Create an InputRawSpan with zero capacity.
  @_lifetime(immortal)
  init()

  /// Unsafely create an InputRawSpan over partly-initialized memory.
  @unsafe
  init(buffer: UnsafeMutableRawBufferPointer, initializedCount: Int)

  /// Unsafely create an InputRawSpan over partly-initialized memory.
  @unsafe
  init(
    buffer: borrowing Slice<UnsafeMutableRawBufferPointer>,
    initializedCount: Int
  )
}
```

##### Retrieving the remaining initialized memory from an `InputRawSpan`

```swift
extension InputRawSpan {
  /// Consume the input span and return the number of initialized bytes
  /// remaining at the end of the underlying memory region.
  @unsafe
  consuming func finalize(
    for buffer: UnsafeMutableRawBufferPointer
  ) -> Int

  /// Consume the input span and return the number of initialized bytes
  /// remaining at the end of the underlying memory region.
  @unsafe
  consuming func finalize(
    for buffer: Slice<UnsafeMutableRawBufferPointer>
  ) -> Int
}
```

### Extensions to `OutputRawSpan`

`OutputRawSpan` gains the untyped counterparts of `OutputSpan`'s `consumeAll()` and `consumeSuffix(maxCount:)` functions, as well as `popLast()`.

```swift
extension OutputRawSpan {
  /// Remove all bytes from this span, and return an input span that takes
  /// ownership of the bytes.
  @_lifetime(&self)
  mutating func consumeAll() -> InputRawSpan

  /// Remove all bytes from this span by passing them to
  /// a closure through an input span.
  mutating func consumeAll<E: Error, R: ~Copyable>(
    consumingWith consumer: (consuming InputRawSpan) throws(E) -> R
  ) throws(E) -> R

  /// Remove up to maxByteCount bytes from the end of this span, and return
  /// an input span that takes ownership of the removed bytes.
  @_lifetime(&self)
  mutating func consumeSuffix(maxByteCount: Int) -> InputRawSpan

  /// Remove up to maxByteCount bytes from the end of this span, by
  /// passing them to a closure through an input span.
  mutating func consumeSuffix<E: Error, R: ~Copyable>(
    maxByteCount: Int,
    consumingWith consumer: (consuming InputRawSpan) throws(E) -> R
  ) throws(E) -> R

  /// Remove and return the last byte of this span, if it exists.
  mutating func popLast() -> UInt8?
}
```

### Extensions to `MutableRawSpan`

As with `MutableSpan`, [SE-0558][SE-0558] adds `updateAll(moving:)` and `updateSubrange(_:moving:)` to `MutableRawSpan`, taking an `OutputRawSpan` as their source. We propose matching overloads taking an `InputRawSpan`. They overwrite bytes of the destination by moving the source's bytes. The source must have exactly as many bytes as the destination (or the destination's target subrange), or the functions trap. The source `InputRawSpan` is empty afterwards.

```swift
extension MutableRawSpan {
  /// Overwrites every byte of this span by moving the bytes
  /// from the source.
  mutating func updateAll(moving source: inout InputRawSpan)

  /// Overwrites the bytes within a range of offsets by moving
  /// the bytes from the source.
  mutating func updateSubrange(
    _ subrange: Range<Int>, moving source: inout InputRawSpan
  )

  mutating func updateSubrange(
    _ subrange: some RangeExpression<Int>, moving source: inout InputRawSpan
  )

  mutating func updateSubrange(
    _ subrange: UnboundedRange, moving source: inout InputRawSpan
  )
}
```

## Source compatibility

This proposal is additive and source-compatible with existing code.

## ABI compatibility

This proposal adds to the ABI of the standard library.

## Implications on adoption

The additions described in this proposal require a new version of the Swift standard library and runtime. The additions to `OutputSpan`, `OutputRawSpan`, `InlineArray`, `UniqueArray`, `MutableSpan` and `MutableRawSpan` have the same availability as `InputSpan` and `InputRawSpan`.

## Future directions

#### Continuing API parity between `InputSpan` and `OutputSpan`

`InputSpan` and `OutputSpan` are counterparts with similar semantics. In the future, all API added to one should be considered for the other. In particular, API for insertions and bulk copies should be proposed for both at once.

#### A `Drain` protocol

The `Iterable` protocol of [SE-0516][SE-0516] provides borrowed access to a container's elements. Its future directions describe other protocols that would support the consuming iteration needed to move noncopyable elements from one container to another. One of these is a `Drain` protocol, for types that can "provide an in-place consumable sequence through a series of `InputSpan` instances, allowing direct consumption of elements from some container's storage, in bulk, without requiring them to be moved into any temporary buffer."

A `Drain` protocol would provide `InputSpan` instances to its clients. It would let generic code consume a container's elements in bulk through closures. Types such as `UniqueArray` ([SE-0527][SE-0527]) could conform to `Drain`. The `DrainableContainer` protocol in the `ContainersPreview` module of [swift-collections](https://github.com/apple/swift-collections) is a prototype of this functionality.

#### Bulk operations

We defer bulk operations, such as prepending the contents of an existing `Span`, to a future proposal. That proposal will be informed by the experience of [SE-0558][SE-0558].

#### Insertions and removals at any position

`OutputSpan`'s future directions include inserting and removing elements at positions other than the end. `InputSpan` could support the same operations at positions other than the front.

## Alternatives considered

#### Removing from the front of `OutputSpan`

An `OutputSpan`'s initialized elements form a prefix of its memory. Removing its first element would require moving every other element one position toward the front, an O(n) operation. `InputSpan`'s layout makes removing the first element O(1), which suits tasks that consume elements in order, such as taking elements from the head of a `Deque`.

#### Only returning an `InputSpan` from `OutputSpan.consumeAll()`

The returning form of `consumeAll()` is a complete solution for contiguous containers, but would fall short for non-contiguous containers. The closure form can be used as a witness for [protocol requirements](https://github.com/apple/swift-collections/blob/a807eb67ee7421ba6f1871be1ca6ae2c366b4bd1/Sources/ContainersPreview/Protocols/Container/DrainableContainer.swift#L235) that can be satisfied by non-contiguous containers.
