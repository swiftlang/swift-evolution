# Pointer Family Initialization Improvements and Better Buffer Slices

* Proposal: [SE-0370](0370-pointer-family-initialization-improvements.md)
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Active Review (August 17...29, 2022)**
* Implementation: [Draft Pull Request](https://github.com/apple/swift/pull/41608)
* Review: ([first pitch](https://forums.swift.org/t/pitch-pointer-family-initialization-improvements/53168)) ([second pitch](https://forums.swift.org/t/pitch-buffer-partial-initialization-better-buffer-slices/53795)) ([third pitch](https://forums.swift.org/t/pitch-pointer-family-initialization-improvements-better-buffer-slices/55689)) ([review](https://forums.swift.org/t/se-0370-pointer-family-initialization-improvements-and-better-buffer-slices/59724))

## Introduction

The types in the `UnsafeMutablePointer` family typically require manual management of memory allocations, including the management of their initialization state. Unfortunately, not every relevant type in the family has the necessary functionality to fully manage the initialization state of the memory it represents. The states involved are, after allocation:

1. Unbound and uninitialized (as returned from `UnsafeMutableRawPointer.allocate()`)
2. Bound to a type, and uninitialized (as returned from `UnsafeMutablePointer<T>.allocate()`)
3. Bound to a type, and initialized

Memory can be safely deallocated whenever it is uninitialized.

We intend to round out initialization functionality for every relevant member of that family: `UnsafeMutablePointer`, `UnsafeMutableRawPointer`, `UnsafeMutableBufferPointer`, `UnsafeMutableRawBufferPointer`,  `Slice<UnsafeMutableBufferPointer>` and `Slice<UnsafeMutableRawBufferPointer>`. The functionality will allow managing initialization state in a much greater variety of situations, including easier handling of partially-initialized buffers.

## Motivation

Memory allocated using `UnsafeMutablePointer`, `UnsafeMutableRawPointer`, `UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer` is passed to the user in an uninitialized state. In the general case, such memory needs to be initialized before it is used in Swift. Memory can be "initialized" or "uninitialized". We hereafter refer to this as a memory region's "initialization state".

The methods of `UnsafeMutablePointer` that interact with initialization state are:

- `func initialize(to value: Pointee)`
- `func initialize(repeating repeatedValue: Pointee, count: Int)`
- `func initialize(from source: UnsafePointer<Pointee>, count: Int)`
- `func assign(repeating repeatedValue: Pointee, count: Int)`
- `func assign(from source: UnsafePointer<Pointee>, count: Int)`
- `func move() -> Pointee`
- `func moveInitialize(from source: UnsafeMutablePointer<Pointee>, count: Int)`
- `func moveAssign(from source: UnsafeMutablePointer<Pointee>, count: Int)`
- `func deinitialize(count: Int) -> UnsafeMutableRawPointer`

This is a fairly complete set.

- The `initialize` functions change the state of memory locations from uninitialized to initialized,
  then assign the corresponding value(s).
- The `assign` functions update the values stored at memory locations that have previously been initialized.
- `deinitialize` changes the state of a range of memory from initialized to uninitialized.
- The `move()` function deinitializes a memory location, then returns its current contents.
- The `move` prefix means that the `source` range of memory will be deinitialized after the function returns.

Unfortunately, `UnsafeMutablePointer` is the only one of the list of types listed in the introduction to allow full control of initialization state, and this means that complex use cases such as partial initialization of a buffer become needlessly difficult.

An example of partial initialization is the insertion of elements in the middle of a collection. This is one of the possible operations needed in an implementation of `RangeReplaceableCollection.replaceSubrange(_:with:)`. Given a `RangeReplaceableCollection` whose unique storage can be represented by a partially-initialized `UnsafeMutableBufferPointer`:

```swift
mutating func replaceSubrange<C>(_ subrange: Range<Index>, with newElements: C)
  where C: Collection, Element == C.Element {

  // obtain unique storage as UnsafeMutableBufferPointer
  let buffer: UnsafeMutableBufferPointer<Element> = self.myUniqueStorage()
  let oldCount = self.count
  let growth = newElements.count - subrange.count
  let newCount = oldCount + growth
  if growth > 0 {
    assert(newCount < buffer.count)
    let oldTail = subrange.upperBound..<oldCount
    let newTail = subrange.upperBound+growth..<newCount
    let oldTailBase = buffer.baseAddress!.advanced(by: oldTail.lowerBound)
    let newTailBase = buffer.baseAddress!.advanced(by: newTail.lowerBound)
    newTailBase.moveInitialize(from: oldTailBase,
                               count: oldCount - subrange.upperBound)

    // Update still-initialized values in the original subrange
    var j = newElements.startIndex
    for i in subrange {
      buffer[i] = newElements[j]
      newElements.formIndex(after: &j)
    }
    // Initialize the remaining range
    for i in subrange.upperBound..<newTail.lowerBound {
      buffer.baseAddress!.advanced(by: i).initialize(to: newElements[j])
      newElements.formIndex(after: &j)
    }
    assert(newElements.distance(from: newElements.startIndex, to: j) == newElements.count)
  }
  ...
}
```

Here, we had to convert to `UnsafeMutablePointer` to use some of its API, as well as resort to element-by-element copying and initialization. With API enabling buffer operations on the slices of buffers, we could simplify things greatly:
```swift
mutating func replaceSubrange<C>(_ subrange: Range<Index>, with newElements: C)
  where C: Collection, Element == C.Element {

  // obtain unique storage as UnsafeMutableBufferPointer
  let buffer: UnsafeMutableBufferPointer<Element> = self.myUniqueStorage()
  let oldCount = self.count
  let growth = newElements.count - subrange.count
  let newCount = oldCount + growth
  if growth > 0 {
    assert(newCount < buffer.count)
    let oldTail = subrange.upperBound..<count
    let newTail = subrange.upperBound+growth..<newCount
    var m = buffer[newTail].moveInitialize(fromContentsOf: buffer[oldTail])
    assert(m == newTail.upperBound)

    // Update still-initialized values in the original subrange
    m = buffer[subrange].update(fromContentsOf: newElements)
    // Initialize the remaining range
    m = buffer[m..<newTail.lowerBound].initialize(
      fromContentsOf: newElements.dropFirst(m - subrange.lowerBound)
    )
    assert(m == newTail.lowerBound)
  }
  ...
}
```
In addition to simplifying the implementation, the new methods have the advantage of having the same bounds-checking behaviour as `UnsafeMutableBufferPointer`, relieving the implementation from being required to do its own bounds checking.

This proposal aims to add API to control initialization state and improve multiple-element copies for `UnsafeMutableBufferPointer`, `UnsafeMutableRawBufferPointer`,  `Slice<UnsafeMutableBufferPointer>` and `Slice<UnsafeMutableRawBufferPointer>`.


## Proposed solution

Note: the pseudo-diffs presented in this section denotes added functions with `+++` and renamed functions with `---`. Unmarked functions are unchanged.

##### `UnsafeMutableBufferPointer`

We propose to modify `UnsafeMutableBufferPointer` as follows:

```swift
extension UnsafeMutableBufferPointer {
    func initialize(repeating repeatedValue: Element)
+++ func initialize<S>(from source: S) -> (unwritten: S.Iterator, index: Index) where S: Sequence, S.Element == Element
--- func initialize<S>(from source: S) -> (S.Iterator, Index) where S: Sequence, S.Element == Element
+++ func initialize<C>(fromContentsOf source: C) -> Index where C: Collection, C.Element == Element
--- func assign(repeating repeatedValue: Element)
+++ func update(repeating repeatedValue: Element)
+++ func update<S>(from source: S) -> (unwritten: S.Iterator, index: Index) where S: Sequence, S.Element == Element
+++ func update<C>(fromContentsOf source: C) -> Index where C: Collection, C.Element == Element
+++ func moveInitialize(fromContentsOf source: UnsafeMutableBufferPointer) -> Index
+++ func moveInitialize(fromContentsOf source: Slice<UnsafeMutableBufferPointer>) -> Index
+++ func moveUpdate(fromContentsOf source: `Self`) -> Index
+++ func moveUpdate(fromContentsOf source: Slice<`Self`>) -> Index
+++ func deinitialize() -> UnsafeMutableRawBufferPointer

+++ func initializeElement(at index: Index, to value: Element)
+++ func moveElement(from index: Index) -> Element
+++ func deinitializeElement(at index: Index)
}
```

<!-- UMBP needs a method to initialize a specific element: rdar://51817146 -->

We would like to use the verb `update` instead of `assign`, in order to better communicate the intent of the API. It is currently a common programmer error to use one of the existing `assign` functions for uninitialized memory; using the verb `update` instead would express the precondition in the API name itself.

The methods that initialize or update from a `Collection` will have forgiving semantics, and copy the number of elements that they can, be that every available element or none, and then return the index in the buffer that follows the last element copied, which is cheaper than returning an iterator and a count. Unlike the existing `Sequence` functions, they include no preconditions beyond having a valid `Collection` and valid buffer, with the understanding that if a user needs stricter behaviour, it can be composed from these functions.

We also add functions to manipulate the initialization state for single elements of the buffer.  There is no `buffer.updateElement(at index: Index, to value: Element)`, because it can already be expressed as `buffer[index] = value`.

##### `UnsafeMutablePointer`

The proposed modifications to `UnsafeMutablePointer` are renamings:

```swift
extension UnsafeMutablePointer {
    func initialize(to value: Pointee)
    func initialize(repeating repeatedValue: Pointee, count: Int)
    func initialize(from source: UnsafePointer<Pointee>, count: Int)
--- func assign(repeating repeatedValue: Pointee, count: Int)
+++ func update(repeating repeatedValue: Pointee, count: Int)
--- func assign(from source: UnsafePointer<Pointee>, count: Int)
+++ func update(from source: UnsafePointer<Pointee>, count: Int)
    func move() -> Pointee
    func moveInitialize(from source: UnsafeMutablePointer, count: Int)
--- func moveAssign(from source: UnsafeMutablePointer, count: Int)
+++ func moveUpdate(from source: UnsafeMutablePointer, count: Int)
    func deinitialize(count: Int) -> UnsafeMutableRawPointer
}
```

The motivation for these renamings are explained above.

##### `UnsafeMutableRawBufferPointer`

We propose to add new functions to initialize memory referenced by `UnsafeMutableRawBufferPointer` instances.

```swift
extension UnsafeMutableRawBufferPointer {
    func initializeMemory<T>(
      as type: T.Type, repeating repeatedValue: T
    ) -> UnsafeMutableBufferPointer<T>

    func initializeMemory<S>(
      as type: S.Element.Type, from source: S
    ) -> (unwritten: S.Iterator, initialized: UnsafeMutableBufferPointer<S.Element>) where S: Sequence

+++ func initializeMemory<C>(
      as type: C.Element.Type, fromContentsOf source: C
    ) -> UnsafeMutableBufferPointer<C.Element> where C: Collection

+++ func moveInitializeMemory<T>(
      as type: T.Type, fromContentsOf source: UnsafeMutableBufferPointer<T>
    ) -> UnsafeMutableBufferPointer<T>

+++ func moveInitializeMemory<T>(
      as type: T.Type, fromContentsOf source: Slice<UnsafeMutableBufferPointer<T>>
    ) -> UnsafeMutableBufferPointer<T>
}
```

The first addition will initialize raw memory from a `Collection` and have similar behaviour as `UnsafeMutableBufferPointer.initialize(fromContentsOf:)`, described above. The other two initialize raw memory by moving data from another range of memory, leaving that other range of memory deinitialized.

##### `UnsafeMutableRawPointer`

```swift
extension UnsafeMutableRawPointer {
+++ func initializeMemory<T>(as type: T.Type, to value: T) -> UnsafeMutablePointer<T>

    func initializeMemory<T>(
      as type: T.Type, repeating repeatedValue: T, count: Int
    ) -> UnsafeMutablePointer<T>

    func initializeMemory<T>(
      as type: T.Type, from source: UnsafePointer<T>, count: Int
    ) -> UnsafeMutablePointer<T>

    func moveInitializeMemory<T>(
      as type: T.Type, from source: UnsafeMutablePointer<T>, count: Int
    ) -> UnsafeMutablePointer<T>
}
```

The addition here initializes a single value.

##### Slices of `BufferPointer`

We propose to extend slices of `Unsafe[Mutable][Raw]BufferPointer` with all the `BufferPointer`-specific methods of their `Base`. The following declarations detail the additions, which are all intended to behave exactly as the functions on the base BufferPointer types:

```swift
extension Slice<UnsafeBufferPointer<T>> {
  public func withMemoryRebound<T, Result>(
    to type: T.Type,
    _ body: (UnsafeBufferPointer<T>) throws -> Result
  ) rethrows -> Result
}
```

```swift
extension Slice<UnsafeMutableBufferPointer<T>> {
  func initialize(repeating repeatedValue: Element)

  func initialize<S: Sequence>(from source: S) -> (unwritten: S.Iterator, index: Index)
    where S.Element == Element

  func initialize<C: Collection>(fromContentsOf source: C) -> Index
    where C.Element == Element

  func update(repeating repeatedValue: Element)

  func update<S: Sequence>(
    from source: S
  ) -> (unwritten: S.Iterator, index: Index) where S.Element == Element

  func update<C: Collection>(
    fromContentsOf source: C
  ) -> Index where C.Element == Element

  func moveInitialize(fromContentsOf source: UnsafeMutableBufferPointer<Element>) -> Index
  func moveInitialize(fromContentsOf source: Slice<UnsafeMutableBufferPointer<Element>>) -> Index
  func moveUpdate(fromContentsOf source: UnsafeMutableBufferPointer<Element>) -> Index
  func moveUpdate(fromContentsOf source: Slice<UnsafeMutableBufferPointer<Element>>) -> Index

  func deinitialize() -> UnsafeMutableRawBufferPointer

  func initializeElement(at index: Index, to value: Element)
  func moveElement(at index: Index) -> Element
  func deinitializeElement(at index: Index)

  func withMemoryRebound<T, Result>(
    to type: T.Type,
    _ body: (UnsafeMutableBufferPointer<T>) throws -> Result
    ) rethrows -> Result
}
```

Slices of `Unsafe[Mutable]RawBufferPointer` will add memory binding functions, memory initialization functions, and variants of `load`, `loadUnaligned` and `storeBytes`.
```swift
extension Slice<UnsafeRawBufferPointer> {
  func bindMemory<T>(to type: T.Type) -> UnsafeBufferPointer<T>
  func assumingMemoryBound<T>(to type: T.Type) -> UnsafeBufferPointer<T>

  func withMemoryRebound<T, Result>(
    to type: T.Type, _ body: (UnsafeBufferPointer<T>) throws -> Result
  ) rethrows -> Result

  func load<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T
  func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T
}
```

```swift
extension Slice<UnsafeMutableRawBufferPointer> {
  func copyMemory(from source: UnsafeRawBufferPointer)
  func copyBytes<C: Collection>(from source: C) where C.Element == UInt8

  func initializeMemory<T>(
    as type: T.Type, repeating repeatedValue: T
  ) -> UnsafeMutableBufferPointer<T>

  func initializeMemory<S: Sequence>(
    as type: S.Element.Type, from source: S
  ) -> (unwritten: S.Iterator, initialized: UnsafeMutableBufferPointer<S.Element>)

  func initializeMemory<C: Collection>(
    as type: C.Element.Type, fromContentsOf source: C
  ) -> UnsafeMutableBufferPointer<C.Element>

  func moveInitializeMemory<T>(
    as type: T.Type, fromContentsOf source: UnsafeMutableBufferPointer<T>
  ) -> UnsafeMutableBufferPointer<T>

  func moveInitializeMemory<T>(
    as type: T.Type, fromContentsOf source: Slice<UnsafeMutableBufferPointer<T>>
  ) -> UnsafeMutableBufferPointer<T>

  func bindMemory<T>(to type: T.Type) -> UnsafeMutableBufferPointer<T>
  func assumingMemoryBound<T>(to type: T.Type) -> UnsafeMutableBufferPointer<T>

  func withMemoryRebound<T, Result>(
    to type: T.Type,
    _ body: (UnsafeMutableBufferPointer<T>) throws -> Result
  ) rethrows -> Result

  func load<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T
  func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T
  func storeBytes<T>(of value: T, toByteOffset offset: Int = 0, as type: T.Type)
}
```

## Detailed design

##### `UnsafeMutableBufferPointer`

```swift
extension UnsafeMutableBufferPointer {
  /// Initializes the buffer's memory with the given elements.
  ///
  /// Initializes the buffer's memory with the given elements.
  ///
  /// Prior to calling the `initialize(fromContentsOf:)` method on a buffer,
  /// the memory referenced by the buffer must be uninitialized,
  /// or the `Element` type must be a trivial type. After the call,
  /// the memory referenced by the buffer up to, but not including,
  /// the returned index is initialized.
  ///
  /// The returned index is the position of the next uninitialized element
  /// in the buffer, which is one past the last element written.
  /// If `source` contains no elements, the returned index is equal to
  /// the buffer's `startIndex`. If `source` contains an equal or greater
  /// number of elements than the buffer can hold, the returned index is equal
  /// to the buffer's `endIndex`.
  ///
  /// - Parameter source: A collection of elements to be used to
  ///   initialize the buffer's storage.
  /// - Returns: An index to the next uninitialized element in the buffer,
  ///   or `endIndex`.
  func initialize<C>(fromContentsOf source: C) -> Index
    where C: Collection, C.Element == Element

  /// Updates every element of this buffer's initialized memory.
  ///
  /// The buffer’s memory must be initialized or the buffer's `Element`
  /// must be a trivial type.
  ///
  /// - Note: All buffer elements must already be initialized.
  ///
  /// - Parameters:
  ///   - repeatedValue: The value used when updating this pointer's memory.
  public func update(repeating repeatedValue: Element)

  /// Updates the buffer's initialized memory with the given elements.
  ///
  /// The buffer's memory must be initialized or the buffer's `Element` type
  /// must be a trivial type.
  ///
  /// - Parameter source: A sequence of elements to be used to update
  ///   the buffer's contents.
  /// - Returns: An iterator to any elements of `source` that didn't fit in the
  ///   buffer, and the index one past the last updated element in the buffer.
  public func update<S>(from source: S) -> (unwritten: S.Iterator, index: Index)
    where S: Sequence, S.Element == Element

  /// Updates the buffer's initialized memory with the given elements.
  ///
  /// The buffer's memory must be initialized or the buffer's `Element` type
  /// must be a trivial type.
  ///
  /// - Parameter source: A collection of elements to be used to update
  ///   the buffer's contents.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func update<C>(fromContentsOf source: C) -> Index
    where C: Collection, C.Element == Element

  /// Moves instances from an initialized source buffer into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// The region of memory starting at this pointer and covering `source.count`
  /// instances of the buffer's `Element` type must be uninitialized, or
  /// `Element` must be a trivial type. After calling
  /// `moveInitialize(fromContentsOf:)`, the region is initialized and the memory
  /// region underlying `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to copy. The memory region
  ///   underlying `source` must be initialized. The memory regions
  ///   referenced by `source` and this buffer may overlap.
  /// - Returns: An index to the next uninitialized element in the buffer,
  ///   or `endIndex`.
  public func moveInitialize(fromContentsOf source: Self) -> Index

  /// Moves instances from an initialized source buffer slice into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// The region of memory starting at this pointer and covering `source.count`
  /// instances of the buffer's `Element` type must be uninitialized, or
  /// `Element` must be a trivial type. After calling
  /// `moveInitialize(fromContentsOf:)`, the region is initialized and the memory
  /// region underlying `source[..<source.endIndex]` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to copy. The memory
  ///   region underlying `source` must be initialized. The memory regions
  ///   referenced by `source` and this buffer may overlap.
  /// - Returns: An index one past the last replaced element in the buffer,
  ///   or `endIndex`.
  public func moveInitialize(fromContentsOf source: Slice<Self>) -> Index

  /// Updates this buffer's initialized memory initialized memory by moving
  /// all the elements from the source buffer, leaving the source memory
  /// uninitialized.
  ///
  /// The region of memory starting at this pointer and covering
  /// `source.count` instances of the buffer's `Element` type
  /// must be initialized, or `Element` must be a trivial type. After calling
  /// `moveUpdate(fromContentsOf:)`, the memory region underlying
  /// `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to move.
  ///   The memory region underlying `source` must be initialized. The
  ///   memory regions referenced by `source` and this pointer must not overlap.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func moveUpdate(fromContentsOf source: `Self`) -> Index

  /// Updates this buffer's initialized memory initialized memory by moving
  /// all the elements from the source buffer slice, leaving the source memory
  /// uninitialized.
  ///
  /// The region of memory starting at this pointer and covering
  /// `fromContentsOf.count` instances of the buffer's `Element` type
  /// must be initialized, or `Element` must be a trivial type. After calling
  /// `moveUpdate(fromContentsOf:)`, the memory region underlying
  /// `source[..<source.endIndex]` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to move.
  ///   The memory region underlying `source` must be initialized. The
  ///   memory regions referenced by `source` and this pointer must not overlap.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func moveUpdate(fromContentsOf source: Slice<`Self`>) -> Index

  /// Deinitializes every instance in this buffer.
  ///
  /// The region of memory underlying this buffer must be fully initialized.
  /// After calling `deinitialize(count:)`, the memory is uninitialized,
  /// but still bound to the `Element` type.
  ///
  /// - Note: All buffer elements must already be initialized.
  ///
  /// - Returns: A raw buffer to the same range of memory as this buffer.
  ///   The range of memory is still bound to `Element`.
  public func deinitialize() -> UnsafeMutableRawBufferPointer

  /// Initializes the buffer element at `index` to the given value.
  ///
  /// The destination element must be uninitialized or the buffer's `Element`
  /// must be a trivial type. After a call to `initialize(to:)`, the
  /// memory underlying this element of the buffer is initialized.
  ///
  /// - Parameters:
  ///   - value: The value used to initialize the buffer element's memory.
  ///   - index: The index of the element to initialize
  public func initializeElement(at index: Index, to value: Element)

  /// Updates the initialized buffer element at `index` with the given value.
  ///
  /// The destination element must be initialized, or
  /// `Element` must be a trivial type. This method is equivalent to:
  ///
  ///     self[index] = value
  ///
  /// - Parameters:
  ///   - value: The value used to update the buffer element's memory.
  ///   - index: The index of the element to update
  public func updateElement(at index: Index, to value: Element)

  /// Retrieves and returns the buffer element at `index`,
  /// leaving that element's memory uninitialized.
  ///
  /// The memory underlying buffer the element at `index` must be initialized.
  /// After calling `moveElement(from:)`, the memory underlying the buffer
  /// element at `index` is uninitialized, and still bound to type `Element`.
  ///
  /// - Parameters:
  ///   - index: The index of the buffer element to retrieve and deinitialize.
  /// - Returns: The instance referenced by this index in this buffer.
  public func moveElement(from index: Index) -> Element

  /// Deinitializes the buffer element at `index`.
  ///
  /// The memory underlying the buffer element at `index` must be initialized.
  /// After calling `deinitializeElement()`, the memory underlying the buffer
  /// element at `index` is uninitialized, and still bound to type `Element`.
  ///
  /// - Parameters:
  ///   - index: The index of the buffer element to deinitialize.
  public func deinitializeElement(at index: Index)
}
```

##### `UnsafeMutablePointer`

```swift
extension UnsafeMutablePointer {
  /// Update this pointer's initialized memory with the specified number of
  /// instances, copied from the given pointer's memory.
  ///
  /// The region of memory starting at this pointer and covering `count`
  /// instances of the pointer's `Pointee` type must be initialized or
  /// `Pointee` must be a trivial type. After calling
  /// `update(from:count:)`, the region is initialized.
  ///
  /// - Note: Returns without performing work if `self` and `source` are equal.
  ///
  /// - Parameters:
  ///   - source: A pointer to at least `count` initialized instances of type
  ///     `Pointee`. The memory regions referenced by `source` and this
  ///     pointer may overlap.
  ///   - count: The number of instances to copy from the memory referenced by
  ///     `source` to this pointer's memory. `count` must not be negative.
  public func update(from source: UnsafePointer<Pointee>, count: Int)

  /// Update this pointer's initialized memory by moving the specified number
  /// of instances the source pointer's memory, leaving the source memory
  /// uninitialized.
  ///
  /// The region of memory starting at this pointer and covering `count`
  /// instances of the pointer's `Pointee` type must be initialized or
  /// `Pointee` must be a trivial type. After calling
  /// `moveUpdate(from:count:)`, the region is initialized and the memory
  /// region `source..<(source + count)` is uninitialized.
  ///
  /// - Note: The source and destination memory regions must not overlap.
  ///
  /// - Parameters:
  ///   - source: A pointer to the values to be moved. The memory region
  ///     `source..<(source + count)` must be initialized. The memory regions
  ///     referenced by `source` and this pointer must not overlap.
  ///   - count: The number of instances to move from `source` to this
  ///     pointer's memory. `count` must not be negative.
  public func moveUpdate(from source: UnsafeMutablePointer, count: Int)
```

##### `UnsafeMutableRawPointer`

```swift
extension UnsafeMutableRawPointer {
  /// Initializes the memory referenced by this pointer with the given value,
  /// binds the memory to the value's type, and returns a typed pointer to the
  /// initialized memory.
  ///
  /// The memory referenced by this pointer must be uninitialized or
  /// initialized to a trivial type, and must be properly aligned for
  /// accessing `T`.
  ///
  /// The following example allocates raw memory for one instance of `UInt`,
  /// and then uses the `initializeMemory(as:to:)` method
  /// to initialize the allocated memory.
  ///
  ///     let bytePointer = UnsafeMutableRawPointer.allocate(
  ///             byteCount: MemoryLayout<UInt>.stride,
  ///             alignment: MemoryLayout<UInt>.alignment)
  ///     let int8Pointer = bytePointer.initializeMemory(as: UInt.self, to: 0)
  ///
  ///     // After using 'int8Pointer':
  ///     int8Pointer.deallocate()
  ///
  /// After calling this method on a raw pointer `p`, the region starting at
  /// `self` and continuing up to `p + MemoryLayout<T>.stride` is bound
  /// to type `T` and initialized. If `T` is a nontrivial type, you must
  /// eventually deinitialize the memory in this region to avoid memory leaks.
  ///
  /// - Parameters:
  ///   - type: The type to which this memory will be bound.
  ///   - value: The value used to initialize this memory.
  /// - Returns: A typed pointer to the memory referenced by this raw pointer.
  public func initializeMemory<T>(as type: T.Type, to value: T) -> UnsafeMutablePointer<T>
}
```

##### `UnsafeMutableRawBufferPointer`

```swift
extension UnsafeMutableRawBufferPointer {
  /// Initializes the buffer's memory with the given elements, binding the
  /// initialized memory to the elements' type.
  ///
  /// When calling the `initializeMemory(as:fromContentsOf:)` method on a buffer
  /// `b`, the memory referenced by `b` must be uninitialized, or initialized
  /// to a trivial type. `b` must be properly aligned for accessing `C.Element`.
  ///
  /// This method initializes the buffer with the contents of `source`,
  /// until `source` is exhausted or the buffer runs out of available
  /// space. After calling `initializeMemory(as:fromContentsOf:)`, the memory
  /// referenced by the returned `UnsafeMutableBufferPointer` instance is bound
  /// and initialized to type `C.Element`. This method does not change
  /// the binding state of the unused portion of `b`, if any.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - source: A collection of elements to be used to
  ///     initialize the buffer's storage.
  /// - Returns: A typed buffer containing the initialized elements.
  ///     The returned buffer references memory starting at the same
  ///     base address as this buffer, and its count indicates
  ///     the number of elements copied from the collection `elements`.
  func initializeMemory<C>(
    as: C.Element.Type, fromContentsOf source: C
  ) -> UnsafeMutableBufferPointer<C.Element>
    where C: Collection

  /// Moves instances from an initialized source buffer into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// When calling the `moveInitializeMemory(as:from:)` method on a buffer `b`,
  /// the memory referenced by `b` must be uninitialized, or initialized to a
  /// trivial type. `b` must be properly aligned for accessing `C.Element`.
  ///
  /// The region of memory starting at this pointer and covering
  /// `source.count` instances of the buffer's `Element` type
  /// must be uninitialized, or `Element` must be a trivial type. After
  /// calling `moveInitialize(as:from:)`, the region is initialized and the
  /// memory region underlying `source` is uninitialized.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - source: A buffer containing the values to copy.
  ///     The memory region underlying `source` must be initialized.
  ///     The memory regions referenced by `source` and this buffer may overlap.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   `source`.
  func moveInitializeMemory<T>(
    as type: T.Type,
    fromContentsOf source: UnsafeMutableBufferPointer<T>
  ) -> UnsafeMutableBufferPointer<T>

  /// Moves instances from an initialized source buffer slice into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// The region of memory starting at this pointer and covering
  /// `source.count` instances of the buffer's `Element` type
  /// must be uninitialized, or `Element` must be a trivial type. After
  /// calling `moveInitialize(as:from:)`, the region is initialized and the
  /// memory region underlying `source[..<source.endIndex]` is uninitialized.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - source: A buffer containing the values to copy.
  ///     The memory region underlying `source` must be initialized.
  ///     The memory regions referenced by `source` and this buffer may overlap.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   `source`.
  func moveInitializeMemory<T>(
    as type: T.Type,
    fromContentsOf source: Slice<UnsafeMutableBufferPointer<T>>
  ) -> UnsafeMutableBufferPointer<T>
}
```



For `Slice` of typed buffers, the functions need to add an additional generic parameter, which is immediately restricted in the `where` clause. This is necessary because "parameterized extensions" are not yet a Swift feature. Eventually, these functions should be able to have exactly the same generic signatures as the counterpart function on their `UnsafeBufferPointer`-family base. This change will be neither source-breaking nor ABI-breaking.

#####  `Slice<UnsafeBufferPointer<T>`

```swift
extension Slice {
  /// Executes the given closure while temporarily binding the memory referenced
  /// by this buffer slice to the given type.
  ///
  /// Use this method when you have a buffer of memory bound to one type and
  /// you need to access that memory as a buffer of another type. Accessing
  /// memory as type `T` requires that the memory be bound to that type. A
  /// memory location may only be bound to one type at a time, so accessing
  /// the same memory as an unrelated type without first rebinding the memory
  /// is undefined.
  ///
  /// The number of instances of `T` referenced by the rebound buffer may be
  /// different than the number of instances of `Element` referenced by the
  /// original buffer slice. The number of instances of `T` will be calculated
  /// at runtime.
  ///
  /// Any instance of `T` within the re-bound region may be initialized or
  /// uninitialized. Every instance of `Pointee` overlapping with a given
  /// instance of `T` should have the same initialization state (i.e.
  /// initialized or uninitialized.) Accessing a `T` whose underlying
  /// `Pointee` storage is in a mixed initialization state shall be
  /// undefined behaviour.
  ///
  /// Because this range of memory is no longer bound to its `Element` type
  /// while the `body` closure executes, do not access memory using the
  /// original buffer slice from within `body`. Instead,
  /// use the `body` closure's buffer argument to access the values
  /// in memory as instances of type `T`.
  ///
  /// After executing `body`, this method rebinds memory back to the original
  /// `Element` type.
  ///
  /// - Note: Only use this method to rebind the buffer's memory to a type
  ///   that is layout compatible with the currently bound `Element` type.
  ///   The stride of the temporary type (`T`) may be an integer multiple
  ///   or a whole fraction of `Element`'s stride.
  ///   To bind a region of memory to a type that does not match these
  ///   requirements, convert the buffer to a raw buffer and use the
  ///   `bindMemory(to:)` method.
  ///   If `T` and `Element` have different alignments, this buffer's
  ///   `baseAddress` must be aligned with the larger of the two alignments.
  ///
  /// - Parameters:
  ///   - type: The type to temporarily bind the memory referenced by this
  ///     buffer. The type `T` must be layout compatible
  ///     with the pointer's `Element` type.
  ///   - body: A closure that takes a typed buffer to the
  ///     same memory as this buffer, only bound to type `T`. The buffer
  ///     parameter contains a number of complete instances of `T` based
  ///     on the capacity of the original buffer and the stride of `Element`.
  ///     The closure's buffer argument is valid only for the duration of the
  ///     closure's execution. If `body` has a return value, that value
  ///     is also used as the return value for the `withMemoryRebound(to:_:)`
  ///     method.
  ///   - buffer: The buffer temporarily bound to `T`.
  /// - Returns: The return value, if any, of the `body` closure parameter.
  public func withMemoryRebound<T, Result, Element>(
    to type: T.Type, _ body: (UnsafeBufferPointer<T>) throws -> Result
  ) rethrows -> Result
    where Base == UnsafeBufferPointer<Element>
}
```

#####  `Slice<UnsafeMutableBufferPointer<T>>`

```swift
extension Slice {
  /// Initializes every element in this buffer slice's memory to
  /// a copy of the given value.
  ///
  /// The destination memory must be uninitialized or the buffer's `Element`
  /// must be a trivial type. After a call to `initialize(repeating:)`, the
  /// entire region of memory referenced by this buffer slice is initialized.
  ///
  /// - Parameter repeatedValue: The value with which to initialize this
  ///   buffer slice's memory.
  public func initialize<Element>(repeating repeatedValue: Element)
    where Base == UnsafeMutableBufferPointer<Element>

  /// Initializes the buffer slice's memory with the given elements.
  ///
  /// Prior to calling the `initialize(from:)` method on a buffer slice,
  /// the memory it references must be uninitialized,
  /// or the `Element` type must be a trivial type. After the call,
  /// the memory referenced by the buffer slice up to, but not including,
  /// the returned index is initialized.
  /// The buffer must contain sufficient memory to accommodate
  /// `source.underestimatedCount`.
  ///
  /// The returned index is the position of the next uninitialized element
  /// in the buffer slice, which is one past the last element written.
  /// If `source` contains no elements, the returned index is equal to
  /// the buffer's `startIndex`. If `source` contains an equal or greater number
  /// of elements than the buffer slice can hold, the returned index is equal to
  /// the buffer's `endIndex`.
  ///
  /// - Parameter source: A sequence of elements with which to initialize the
  ///   buffer.
  /// - Returns: An iterator to any elements of `source` that didn't fit in the
  ///   buffer, and an index to the next uninitialized element in the buffer.
  public func initialize<S>(
    from source: S
  ) -> (unwritten: S.Iterator, index: Index)
    where S: Sequence, Base == UnsafeMutableBufferPointer<S.Element>
  
  /// Initializes the buffer slice's memory with the given elements.
  ///
  /// Prior to calling the `initialize(fromContentsOf:)` method on a buffer slice,
  /// the memory it references must be uninitialized,
  /// or the `Element` type must be a trivial type. After the call,
  /// the memory referenced by the buffer slice up to, but not including,
  /// the returned index is initialized.
  ///
  /// The returned index is the position of the next uninitialized element
  /// in the buffer slice, which is one past the last element written.
  /// If `source` contains no elements, the returned index is equal to
  /// the buffer's `startIndex`. If `source` contains an equal or greater
  /// of elements than the buffer slice can hold, the returned index is equal to
  /// to the buffer's `endIndex`.
  ///
  /// - Parameter source: A collection of elements to be used to
  ///   initialize the buffer's storage.
  /// - Returns: An index to the next uninitialized element in the buffer,
  ///   or `endIndex`.
  public func initialize<C>(
    fromContentsOf source: C
  ) -> Index
    where C : Collection, Base == UnsafeMutableBufferPointer<C.Element>

  /// Updates every element of this buffer slice's initialized memory.
  ///
  /// The buffer slice’s memory must be initialized or its `Element`
  /// must be a trivial type.
  ///
  /// - Note: All buffer elements must already be initialized.
  ///
  /// - Parameters:
  ///   - repeatedValue: The value used when updating this pointer's memory.
  public func update<Element>(repeating repeatedValue: Element)
    where Base == UnsafeMutableBufferPointer<Element>

  /// Updates the buffer slice's initialized memory with the given elements.
  ///
  /// The buffer slice's memory must be initialized or its `Element` type
  /// must be a trivial type.
  ///
  /// - Parameter source: A sequence of elements to be used to update
  ///   the buffer's contents.
  /// - Returns: An iterator to any elements of `source` that didn't fit in the
  ///   buffer, and the index one past the last updated element in the buffer.
  public func update<S>(
    from source: S
  ) -> (unwritten: S.Iterator, index: Index)
    where S: Sequence, Base == UnsafeMutableBufferPointer<S.Element>

  /// Updates the buffer slice's initialized memory with the given elements.
  ///
  /// The buffer slice's memory must be initialized or the buffer's `Element` type
  /// must be a trivial type.
  ///
  /// - Parameter source: A collection of elements to be used to update
  ///   the buffer's contents.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func update<C>(
    fromContentsOf source: C
  ) -> Index
    where C: Collection, Base == UnsafeMutableBufferPointer<C.Element>
  
  /// Moves every element of an initialized source buffer into the
  /// uninitialized memory referenced by this buffer slice, leaving the
  /// source memory uninitialized and this buffer slice's memory initialized.
  ///
  /// The region of memory starting at the beginning of this buffer and
  /// covering `source.count` instances of its `Element` type must be
  /// uninitialized, or `Element` must be a trivial type. After calling
  /// `moveInitialize(fromContentsOf:)`, the region is initialized and
  /// the region of memory underlying `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to copy. The memory
  ///   region underlying `source` must be initialized. The memory regions
  ///   referenced by `source` and this buffer may overlap.
  /// - Returns: An index to the next uninitialized element in the buffer,
  ///   or `endIndex`.
  public func moveInitialize<Element>(
    fromContentsOf source: UnsafeMutableBufferPointer<Element>
  ) -> Index
    where Base == UnsafeMutableBufferPointer<Element>

  /// Moves every element of an initialized source buffer slice into the
  /// uninitialized memory referenced by this buffer slice, leaving the
  /// source memory uninitialized and this buffer slice's memory initialized.
  ///
  /// The region of memory starting at the beginning of this buffer slice and
  /// covering `source.count` instances of its `Element` type must be
  /// uninitialized, or `Element` must be a trivial type. After calling
  /// `moveInitialize(fromContentsOf:)`, the region is initialized and
  /// the region of memory underlying `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to copy. The memory
  ///   region underlying `source` must be initialized. The memory regions
  ///   referenced by `source` and this buffer may overlap.
  /// - Returns: An index one past the last replaced element in the buffer,
  ///   or `endIndex`.
  public func moveInitialize<Element>(
    fromContentsOf source: Slice<UnsafeMutableBufferPointer<Element>>
  ) -> Index
    where Base == UnsafeMutableBufferPointer<Element>
  
  /// Updates this buffer slice's initialized memory initialized memory by
  /// moving every element from the source buffer,
  /// leaving the source memory uninitialized.
  ///
  /// The region of memory starting at the beginning of this buffer slice and
  /// covering `source.count` instances of its `Element` type  must be
  /// initialized, or `Element` must be a trivial type. After calling
  /// `moveUpdate(fromContentsOf:)`,
  /// the region of memory underlying `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to move.
  ///   The memory region underlying `source` must be initialized. The
  ///   memory regions referenced by `source` and this pointer must not overlap.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func moveUpdate<Element>(
    fromContentsOf source: UnsafeMutableBufferPointer<Element>
  ) -> Index
    where Base == UnsafeMutableBufferPointer<Element>

  /// Updates this buffer slice's initialized memory initialized memory by
  /// moving every element from the source buffer slice,
  /// leaving the source memory uninitialized.
  ///
  /// The region of memory starting at the beginning of this buffer slice and
  /// covering `source.count` instances of its `Element` type  must be
  /// initialized, or `Element` must be a trivial type. After calling
  /// `moveUpdate(fromContentsOf:)`,
  /// the region of memory underlying `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to move.
  ///   The memory region underlying `source` must be initialized. The
  ///   memory regions referenced by `source` and this pointer must not overlap.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func moveUpdate<Element>(
    fromContentsOf source: Slice<UnsafeMutableBufferPointer<Element>>
  ) -> Index
    where Base == UnsafeMutableBufferPointer<Element>

  /// Deinitializes every instance in this buffer slice.
  ///
  /// The region of memory underlying this buffer slice must be fully
  /// initialized. After calling `deinitialize(count:)`, the memory
  /// is uninitialized, but still bound to the `Element` type.
  ///
  /// - Note: All buffer elements must already be initialized.
  ///
  /// - Returns: A raw buffer to the same range of memory as this buffer.
  ///   The range of memory is still bound to `Element`.
  public func deinitialize<Element>() -> UnsafeMutableRawBufferPointer
    where Base == UnsafeMutableBufferPointer<Element>

  /// Initializes the element at `index` to the given value.
  ///
  /// The memory underlying the destination element must be uninitialized,
  /// or `Element` must be a trivial type. After a call to `initialize(to:)`,
  /// the memory underlying this element of the buffer slice is initialized.
  ///
  /// - Parameters:
  ///   - value: The value used to initialize the buffer element's memory.
  ///   - index: The index of the element to initialize
  public func initializeElement<Element>(at index: Int, to value: Element)
    where Base == UnsafeMutableBufferPointer<Element>

  /// Updates the initialized element at `index` to the given value.
  ///
  /// The memory underlying the destination element must be initialized,
  /// or `Element` must be a trivial type. This method is equivalent to:
  ///
  ///     self[index] = value
  ///
  /// - Parameters:
  ///   - value: The value used to update the buffer element's memory.
  ///   - index: The index of the element to update
  public func updateElement<Element>(at index: Index, to value: Element)
    where Base == UnsafeMutableBufferPointer<Element>

  /// Retrieves and returns the element at `index`,
  /// leaving that element's underlying memory uninitialized.
  ///
  /// The memory underlying the element at `index` must be initialized.
  /// After calling `moveElement(from:)`, the memory underlying this element
  /// of the buffer slice is uninitialized, and still bound to type `Element`.
  ///
  /// - Parameters:
  ///   - index: The index of the buffer element to retrieve and deinitialize.
  /// - Returns: The instance referenced by this index in this buffer.
  public func moveElement<Element>(from index: Index) -> Element
    where Base == UnsafeMutableBufferPointer<Element>

  /// Deinitializes the memory underlying the element at `index`.
  ///
  /// The memory underlying the element at `index` must be initialized.
  /// After calling `deinitializeElement()`, the memory underlying this element
  /// of the buffer slice is uninitialized, and still bound to type `Element`.
  ///
  /// - Parameters:
  ///   - index: The index of the buffer element to deinitialize.
  public func deinitializeElement<Element>(at index: Base.Index)
    where Base == UnsafeMutableBufferPointer<Element>

  /// Executes the given closure while temporarily binding the memory referenced
  /// by this buffer slice to the given type.
  ///
  /// Use this method when you have a buffer of memory bound to one type and
  /// you need to access that memory as a buffer of another type. Accessing
  /// memory as type `T` requires that the memory be bound to that type. A
  /// memory location may only be bound to one type at a time, so accessing
  /// the same memory as an unrelated type without first rebinding the memory
  /// is undefined.
  ///
  /// The number of instances of `T` referenced by the rebound buffer may be
  /// different than the number of instances of `Element` referenced by the
  /// original buffer slice. The number of instances of `T` will be calculated
  /// at runtime.
  ///
  /// Any instance of `T` within the re-bound region may be initialized or
  /// uninitialized. Every instance of `Pointee` overlapping with a given
  /// instance of `T` should have the same initialization state (i.e.
  /// initialized or uninitialized.) Accessing a `T` whose underlying
  /// `Pointee` storage is in a mixed initialization state shall be
  /// undefined behaviour.
  ///
  /// Because this range of memory is no longer bound to its `Element` type
  /// while the `body` closure executes, do not access memory using the
  /// original buffer slice from within `body`. Instead,
  /// use the `body` closure's buffer argument to access the values
  /// in memory as instances of type `T`.
  ///
  /// After executing `body`, this method rebinds memory back to the original
  /// `Element` type.
  ///
  /// - Note: Only use this method to rebind the buffer's memory to a type
  ///   that is layout compatible with the currently bound `Element` type.
  ///   The stride of the temporary type (`T`) may be an integer multiple
  ///   or a whole fraction of `Element`'s stride.
  ///   To bind a region of memory to a type that does not match these
  ///   requirements, convert the buffer to a raw buffer and use the
  ///   `bindMemory(to:)` method.
  ///   If `T` and `Element` have different alignments, this buffer's
  ///   `baseAddress` must be aligned with the larger of the two alignments.
  ///
  /// - Parameters:
  ///   - type: The type to temporarily bind the memory referenced by this
  ///     buffer. The type `T` must be layout compatible
  ///     with the pointer's `Element` type.
  ///   - body: A closure that takes a ${Mutable.lower()} typed buffer to the
  ///     same memory as this buffer, only bound to type `T`. The buffer
  ///     parameter contains a number of complete instances of `T` based
  ///     on the capacity of the original buffer and the stride of `Element`.
  ///     The closure's buffer argument is valid only for the duration of the
  ///     closure's execution. If `body` has a return value, that value
  ///     is also used as the return value for the `withMemoryRebound(to:_:)`
  ///     method.
  ///   - buffer: The buffer temporarily bound to `T`.
  /// - Returns: The return value, if any, of the `body` closure parameter.
  public func withMemoryRebound<T, Result, Element>(
    to type: T.Type, _ body: (UnsafeMutableBufferPointer<T>) throws -> Result
  ) rethrows -> Result
    where Base == UnsafeMutableBufferPointer<Element>
}
```

#####  `Slice<UnsafeRawBufferPointer>`

```swift
extension Slice where Base: UnsafeRawBufferPointer {

  /// Binds this buffer’s memory to the specified type and returns a typed buffer
  /// of the bound memory.
  ///
  /// Use the `bindMemory(to:)` method to bind the memory referenced
  /// by this buffer to the type `T`. The memory must be uninitialized or
  /// initialized to a type that is layout compatible with `T`. If the memory
  /// is uninitialized, it is still uninitialized after being bound to `T`.
  ///
  /// - Warning: A memory location may only be bound to one type at a time. The
  ///   behavior of accessing memory as a type unrelated to its bound type is
  ///   undefined.
  ///
  /// - Parameters:
  ///   - type: The type `T` to bind the memory to.
  /// - Returns: A typed buffer of the newly bound memory. The memory in this
  ///   region is bound to `T`, but has not been modified in any other way.
  ///   The typed buffer references `self.count / MemoryLayout<T>.stride` instances of `T`.
  public func bindMemory<T>(to type: T.Type) -> UnsafeBufferPointer<T>

  /// Executes the given closure while temporarily binding the buffer to
  /// instances of type `T`.
  ///
  /// Use this method when you have a buffer to raw memory and you need
  /// to access that memory as instances of a given type `T`. Accessing
  /// memory as a type `T` requires that the memory be bound to that type.
  /// A memory location may only be bound to one type at a time, so accessing
  /// the same memory as an unrelated type without first rebinding the memory
  /// is undefined.
  ///
  /// Any instance of `T` within the re-bound region may be initialized or
  /// uninitialized. The memory underlying any individual instance of `T`
  /// must have the same initialization state (i.e.  initialized or
  /// uninitialized.) Accessing a `T` whose underlying memory
  /// is in a mixed initialization state shall be undefined behaviour.
  ///
  /// If the byte count of the original buffer is not a multiple of
  /// the stride of `T`, then the re-bound buffer is shorter
  /// than the original buffer.
  ///
  /// After executing `body`, this method rebinds memory back to its original
  /// binding state. This can be unbound memory, or bound to a different type.
  ///
  /// - Note: The buffer's base address must match the
  ///   alignment of `T` (as reported by `MemoryLayout<T>.alignment`).
  ///   That is, `Int(bitPattern: self.baseAddress) % MemoryLayout<T>.alignment`
  ///   must equal zero.
  ///
  /// - Note: A raw buffer may represent memory that has been bound to a type.
  ///   If that is the case, then `T` must be layout compatible with the
  ///   type to which the memory has been bound. This requirement does not
  ///   apply if the raw buffer represents memory that has not been bound
  ///   to any type.
  ///
  /// - Parameters:
  ///   - type: The type to temporarily bind the memory referenced by this
  ///     pointer. This pointer must be a multiple of this type's alignment.
  ///   - body: A closure that takes a typed pointer to the
  ///     same memory as this pointer, only bound to type `T`. The closure's
  ///     pointer argument is valid only for the duration of the closure's
  ///     execution. If `body` has a return value, that value is also used as
  ///     the return value for the `withMemoryRebound(to:capacity:_:)` method.
  ///   - buffer: The buffer temporarily bound to instances of `T`.
  /// - Returns: The return value, if any, of the `body` closure parameter.
  func withMemoryRebound<T, Result>(
    to type: T.Type, _ body: (UnsafeBufferPointer<T>) throws -> Result
  ) rethrows -> Result

  /// Returns a typed buffer to the memory referenced by this buffer,
  /// assuming that the memory is already bound to the specified type.
  ///
  /// Use this method when you have a raw buffer to memory that has already
  /// been bound to the specified type. The memory starting at this pointer
  /// must be bound to the type `T`. Accessing memory through the returned
  /// pointer is undefined if the memory has not been bound to `T`. To bind
  /// memory to `T`, use `bindMemory(to:capacity:)` instead of this method.
  ///
  /// - Note: The buffer's base address must match the
  ///   alignment of `T` (as reported by `MemoryLayout<T>.alignment`).
  ///   That is, `Int(bitPattern: self.baseAddress) % MemoryLayout<T>.alignment`
  ///   must equal zero.
  ///
  /// - Parameter to: The type `T` that the memory has already been bound to.
  /// - Returns: A typed pointer to the same memory as this raw pointer.
  func assumingMemoryBound<T>(to type: T.Type) -> UnsafeBufferPointer<T>

  /// Returns a new instance of the given type, read from the
  /// specified offset into the buffer pointer slice's raw memory.
  ///
  /// The memory at `offset` bytes into this buffer pointer slice
  /// must be properly aligned for accessing `T` and initialized to `T` or
  /// another type that is layout compatible with `T`.
  ///
  /// You can use this method to create new values from the underlying
  /// buffer pointer's bytes. The following example creates two new `Int32`
  /// instances from the memory referenced by the buffer pointer `someBytes`.
  /// The bytes for `a` are copied from the first four bytes of `someBytes`,
  /// and the bytes for `b` are copied from the next four bytes.
  ///
  ///     let a = someBytes[0..<4].load(as: Int32.self)
  ///     let b = someBytes[4..<8].load(as: Int32.self)
  ///
  /// The memory to read for the new instance must not extend beyond the
  /// memory region represented by the buffer pointer slice---that is,
  /// `offset + MemoryLayout<T>.size` must be less than or equal
  /// to the slice's `count`.
  ///
  /// - Parameters:
  ///   - offset: The offset into the slice's memory, in bytes, at
  ///     which to begin reading data for the new instance. The default is zero.
  ///   - type: The type to use for the newly constructed instance. The memory
  ///     must be initialized to a value of a type that is layout compatible
  ///     with `type`.
  /// - Returns: A new instance of type `T`, copied from the buffer pointer
  ///   slice's memory.
  func load<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T

  /// Returns a new instance of the given type, read from the
  /// specified offset into the buffer pointer slice's raw memory.
  ///
  /// This function only supports loading trivial types.
  /// A trivial type does not contain any reference-counted property
  /// within its in-memory stored representation.
  /// The memory at `offset` bytes into the buffer slice must be laid out
  /// identically to the in-memory representation of `T`.
  ///
  /// You can use this method to create new values from the buffer pointer's
  /// underlying bytes. The following example creates two new `Int32`
  /// instances from the memory referenced by the buffer pointer `someBytes`.
  /// The bytes for `a` are copied from the first four bytes of `someBytes`,
  /// and the bytes for `b` are copied from the fourth through seventh bytes.
  ///
  ///     let a = someBytes[..<4].loadUnaligned(as: Int32.self)
  ///     let b = someBytes[3...].loadUnaligned(as: Int32.self)
  ///
  /// The memory to read for the new instance must not extend beyond the
  /// memory region represented by the buffer pointer slice---that is,
  /// `offset + MemoryLayout<T>.size` must be less than or equal
  /// to the slice's `count`.
  ///
  /// - Parameters:
  ///   - offset: The offset into the slice's memory, in bytes, at
  ///     which to begin reading data for the new instance. The default is zero.
  ///   - type: The type to use for the newly constructed instance. The memory
  ///     must be initialized to a value of a type that is layout compatible
  ///     with `type`.
  /// - Returns: A new instance of type `T`, copied from the buffer pointer's
  ///   memory.
  func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T
}
```

#####  `Slice<UnsafeMutableRawBufferPointer>`

```swift
extension Slice where Base == UnsafeMutableRawBufferPointer {

  /// Copies the bytes from the given buffer to this buffer slice's memory.
  ///
  /// If the `source.count` bytes of memory referenced by this buffer are bound
  /// to a type `T`, then `T` must be a trivial type, the underlying pointer
  /// must be properly aligned for accessing `T`, and `source.count` must be a
  /// multiple of `MemoryLayout<T>.stride`.
  ///
  /// The memory referenced by `source` may overlap with the memory referenced
  /// by this buffer.
  ///
  /// After calling `copyMemory(from:)`, the first `source.count` bytes of
  /// memory referenced by this buffer are initialized to raw bytes. If the
  /// memory is bound to type `T`, then it contains values of type `T`.
  ///
  /// - Parameter source: A buffer of raw bytes. `source.count` must
  ///   be less than or equal to this buffer slice's `count`.
  func copyMemory(from source: UnsafeRawBufferPointer)

  /// Copies from a collection of `UInt8` into this buffer slice's memory.
  ///
  /// If the `source.count` bytes of memory referenced by this buffer are bound
  /// to a type `T`, then `T` must be a trivial type, the underlying pointer
  /// must be properly aligned for accessing `T`, and `source.count` must be a
  /// multiple of `MemoryLayout<T>.stride`.
  ///
  /// After calling `copyBytes(from:)`, the first `source.count` bytes of memory
  /// referenced by this buffer are initialized to raw bytes. If the memory is
  /// bound to type `T`, then it contains values of type `T`.
  ///
  /// - Parameter source: A collection of `UInt8` elements. `source.count` must
  ///   be less than or equal to this buffer slice's `count`.
  public func copyBytes<C: Collection>(from source: C) where C.Element == UInt8

  /// Initializes the memory referenced by this buffer with the given value,
  /// binds the memory to the value's type, and returns a typed buffer of the
  /// initialized memory.
  ///
  /// The memory referenced by this buffer must be uninitialized or
  /// initialized to a trivial type, and must be properly aligned for
  /// accessing `T`.
  ///
  /// After calling this method on a raw buffer with non-nil `baseAddress` `b`,
  /// the region starting at `b` and continuing up to
  /// `b + self.count - self.count % MemoryLayout<T>.stride` is bound to type `T` and
  /// initialized. If `T` is a nontrivial type, you must eventually deinitialize
  /// or move the values in this region to avoid leaks. If `baseAddress` is
  /// `nil`, this function does nothing and returns an empty buffer pointer.
  ///
  /// - Parameters:
  ///   - type: The type to bind this buffer’s memory to.
  ///   - repeatedValue: The instance to copy into memory.
  /// - Returns: A typed buffer of the memory referenced by this raw buffer.
  ///     The typed buffer contains `self.count / MemoryLayout<T>.stride`
  ///     instances of `T`.
  func initializeMemory<T>(
    as type: T.Type, repeating repeatedValue: T
  ) -> UnsafeMutableBufferPointer<T>

  /// Initializes the buffer's memory with the given elements, binding the
  /// initialized memory to the elements' type.
  ///
  /// When calling the `initializeMemory(as:from:)` method on a buffer `b`,
  /// the memory referenced by `b` must be uninitialized or initialized to a
  /// trivial type, and must be properly aligned for accessing `S.Element`.
  /// The buffer must contain sufficient memory to accommodate
  /// `source.underestimatedCount`.
  ///
  /// This method initializes the buffer with elements from `source` until
  /// `source` is exhausted or, if `source` is a sequence but not a
  /// collection, the buffer has no more room for its elements. After calling
  /// `initializeMemory(as:from:)`, the memory referenced by the returned
  /// `UnsafeMutableBufferPointer` instance is bound and initialized to type
  /// `S.Element`.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - source: A sequence of elements with which to initialize the buffer.
  /// - Returns: An iterator to any elements of `source` that didn't fit in the
  ///   buffer, and a typed buffer of the written elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer.
  public func initializeMemory<S: Sequence>(
    as type: S.Element.Type, from source: S
  ) -> (unwritten: S.Iterator, initialized: UnsafeMutableBufferPointer<S.Element>)

  /// Initializes the buffer's memory with the given elements, binding the
  /// initialized memory to the elements' type.
  ///
  /// When calling the `initializeMemory(as:fromContentsOf:)` method on a buffer
  /// `b`, the memory referenced by `b` must be uninitialized, or initialized
  /// to a trivial type. `b` must be properly aligned for accessing `C.Element`.
  ///
  /// This method initializes the buffer with the contents of `source`
  /// until `source` is exhausted or the buffer runs out of available
  /// space. After calling `initializeMemory(as:fromContentsOf:)`, the memory
  /// referenced by the returned `UnsafeMutableBufferPointer` instance is bound
  /// and initialized to type `C.Element`. This method does not change
  /// the binding state of the unused portion of `b`, if any.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - source: A collection of elements to be used to
  ///     initialize the buffer's storage.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   the collection `elements`.
  func initializeMemory<C: Collection>(
    as type: C.Element.Type,
    fromContentsOf source: C
  ) -> UnsafeMutableBufferPointer<C.Element>

  /// Moves instances from an initialized source buffer into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// When calling the `moveInitializeMemory(as:fromContentsOf:)` method on a buffer `b`,
  /// the memory referenced by `b` must be uninitialized, or initialized to a
  /// trivial type. `b` must be properly aligned for accessing `C.Element`.
  ///
  /// The region of memory starting at this pointer and covering
  /// `source.count` instances of the buffer's `Element` type
  /// must be uninitialized, or `Element` must be a trivial type. After
  /// calling `moveInitialize(as:from:)`, the region is initialized and the
  /// memory region underlying `source` is uninitialized.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - source: A buffer containing the values to copy.
  ///     The memory region underlying `source` must be initialized.
  ///     The memory regions referenced by `source` and this buffer may overlap.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   `source`.
  func moveInitializeMemory<T>(
    as type: T.Type,
    fromContentsOf source: UnsafeMutableBufferPointer<T>
  ) -> UnsafeMutableBufferPointer<T>

  /// Moves instances from an initialized source buffer slice into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// The region of memory starting at this pointer and covering
  /// `source.count` instances of the buffer's `Element` type
  /// must be uninitialized, or `Element` must be a trivial type. After
  /// calling `moveInitialize(as:from:)`, the region is initialized and the
  /// memory region underlying `source[..<source.endIndex]` is uninitialized.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - source: A buffer containing the values to copy.
  ///     The memory region underlying `source` must be initialized.
  ///     The memory regions referenced by `source` and this buffer may overlap.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   `source`.
  func moveInitializeMemory<T>(
    as type: T.Type,
    fromContentsOf source: Slice<UnsafeMutableBufferPointer<T>>
  ) -> UnsafeMutableBufferPointer<T>

  /// Binds this buffer’s memory to the specified type and returns a typed buffer
  /// of the bound memory.
  ///
  /// Use the `bindMemory(to:)` method to bind the memory referenced
  /// by this buffer to the type `T`. The memory must be uninitialized or
  /// initialized to a type that is layout compatible with `T`. If the memory
  /// is uninitialized, it is still uninitialized after being bound to `T`.
  ///
  /// - Warning: A memory location may only be bound to one type at a time. The
  ///   behavior of accessing memory as a type unrelated to its bound type is
  ///   undefined.
  ///
  /// - Parameters:
  ///   - type: The type `T` to bind the memory to.
  /// - Returns: A typed buffer of the newly bound memory. The memory in this
  ///   region is bound to `T`, but has not been modified in any other way.
  ///   The typed buffer references `self.count / MemoryLayout<T>.stride` instances of `T`.
  public func bindMemory<T>(to type: T.Type) -> UnsafeMutableBufferPointer<T>

  /// Executes the given closure while temporarily binding the buffer to
  /// instances of type `T`.
  ///
  /// Use this method when you have a buffer to raw memory and you need
  /// to access that memory as instances of a given type `T`. Accessing
  /// memory as a type `T` requires that the memory be bound to that type.
  /// A memory location may only be bound to one type at a time, so accessing
  /// the same memory as an unrelated type without first rebinding the memory
  /// is undefined.
  ///
  /// Any instance of `T` within the re-bound region may be initialized or
  /// uninitialized. The memory underlying any individual instance of `T`
  /// must have the same initialization state (i.e.  initialized or
  /// uninitialized.) Accessing a `T` whose underlying memory
  /// is in a mixed initialization state shall be undefined behaviour.
  ///
  /// If the byte count of the original buffer is not a multiple of
  /// the stride of `T`, then the re-bound buffer is shorter
  /// than the original buffer.
  ///
  /// After executing `body`, this method rebinds memory back to its original
  /// binding state. This can be unbound memory, or bound to a different type.
  ///
  /// - Note: The buffer's base address must match the
  ///   alignment of `T` (as reported by `MemoryLayout<T>.alignment`).
  ///   That is, `Int(bitPattern: self.baseAddress) % MemoryLayout<T>.alignment`
  ///   must equal zero.
  ///
  /// - Note: A raw buffer may represent memory that has been bound to a type.
  ///   If that is the case, then `T` must be layout compatible with the
  ///   type to which the memory has been bound. This requirement does not
  ///   apply if the raw buffer represents memory that has not been bound
  ///   to any type.
  ///
  /// - Parameters:
  ///   - type: The type to temporarily bind the memory referenced by this
  ///     pointer. This pointer must be a multiple of this type's alignment.
  ///   - body: A closure that takes a typed pointer to the
  ///     same memory as this pointer, only bound to type `T`. The closure's
  ///     pointer argument is valid only for the duration of the closure's
  ///     execution. If `body` has a return value, that value is also used as
  ///     the return value for the `withMemoryRebound(to:capacity:_:)` method.
  ///   - buffer: The buffer temporarily bound to instances of `T`.
  /// - Returns: The return value, if any, of the `body` closure parameter.
  func withMemoryRebound<T, Result>(
    to type: T.Type, _ body: (UnsafeMutableBufferPointer<T>) throws -> Result
  ) rethrows -> Result

  /// Returns a typed buffer to the memory referenced by this buffer,
  /// assuming that the memory is already bound to the specified type.
  ///
  /// Use this method when you have a raw buffer to memory that has already
  /// been bound to the specified type. The memory starting at this pointer
  /// must be bound to the type `T`. Accessing memory through the returned
  /// pointer is undefined if the memory has not been bound to `T`. To bind
  /// memory to `T`, use `bindMemory(to:capacity:)` instead of this method.
  ///
  /// - Note: The buffer's base address must match the
  ///   alignment of `T` (as reported by `MemoryLayout<T>.alignment`).
  ///   That is, `Int(bitPattern: self.baseAddress) % MemoryLayout<T>.alignment`
  ///   must equal zero.
  ///
  /// - Parameter to: The type `T` that the memory has already been bound to.
  /// - Returns: A typed pointer to the same memory as this raw pointer.
  func assumingMemoryBound<T>(to type: T.Type) -> UnsafeMutableBufferPointer<T>

  /// Returns a new instance of the given type, read from the
  /// specified offset into the buffer pointer slice's raw memory.
  ///
  /// The memory at `offset` bytes into this buffer pointer slice
  /// must be properly aligned for accessing `T` and initialized to `T` or
  /// another type that is layout compatible with `T`.
  ///
  /// You can use this method to create new values from the underlying
  /// buffer pointer's bytes. The following example creates two new `Int32`
  /// instances from the memory referenced by the buffer pointer `someBytes`.
  /// The bytes for `a` are copied from the first four bytes of `someBytes`,
  /// and the bytes for `b` are copied from the next four bytes.
  ///
  ///     let a = someBytes[0..<4].load(as: Int32.self)
  ///     let b = someBytes[4..<8].load(as: Int32.self)
  ///
  /// The memory to read for the new instance must not extend beyond the
  /// memory region represented by the buffer pointer slice---that is,
  /// `offset + MemoryLayout<T>.size` must be less than or equal
  /// to the slice's `count`.
  ///
  /// - Parameters:
  ///   - offset: The offset into the slice's memory, in bytes, at
  ///     which to begin reading data for the new instance. The default is zero.
  ///   - type: The type to use for the newly constructed instance. The memory
  ///     must be initialized to a value of a type that is layout compatible
  ///     with `type`.
  /// - Returns: A new instance of type `T`, copied from the buffer pointer
  ///   slice's memory.
  func load<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T

  /// Returns a new instance of the given type, read from the
  /// specified offset into the buffer pointer slice's raw memory.
  ///
  /// This function only supports loading trivial types.
  /// A trivial type does not contain any reference-counted property
  /// within its in-memory stored representation.
  /// The memory at `offset` bytes into the buffer slice must be laid out
  /// identically to the in-memory representation of `T`.
  ///
  /// You can use this method to create new values from the buffer pointer's
  /// underlying bytes. The following example creates two new `Int32`
  /// instances from the memory referenced by the buffer pointer `someBytes`.
  /// The bytes for `a` are copied from the first four bytes of `someBytes`,
  /// and the bytes for `b` are copied from the fourth through seventh bytes.
  ///
  ///     let a = someBytes[..<4].loadUnaligned(as: Int32.self)
  ///     let b = someBytes[3...].loadUnaligned(as: Int32.self)
  ///
  /// The memory to read for the new instance must not extend beyond the
  /// memory region represented by the buffer pointer slice---that is,
  /// `offset + MemoryLayout<T>.size` must be less than or equal
  /// to the slice's `count`.
  ///
  /// - Parameters:
  ///   - offset: The offset into the slice's memory, in bytes, at
  ///     which to begin reading data for the new instance. The default is zero.
  ///   - type: The type to use for the newly constructed instance. The memory
  ///     must be initialized to a value of a type that is layout compatible
  ///     with `type`.
  /// - Returns: A new instance of type `T`, copied from the buffer pointer's
  ///   memory.
  func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T

  /// Stores a value's bytes into the buffer pointer slice's raw memory at the
  /// specified byte offset.
  ///
  /// The type `T` to be stored must be a trivial type. The memory must also be
  /// uninitialized, initialized to `T`, or initialized to another trivial
  /// type that is layout compatible with `T`.
  ///
  /// The memory written to must not extend beyond
  /// the memory region represented by the buffer pointer slice---that is,
  /// `offset + MemoryLayout<T>.size` must be less than or equal
  /// to the slice's `count`.
  ///
  /// After calling `storeBytes(of:toByteOffset:as:)`, the memory is
  /// initialized to the raw bytes of `value`. If the memory is bound to a
  /// type `U` that is layout compatible with `T`, then it contains a value of
  /// type `U`. Calling `storeBytes(of:toByteOffset:as:)` does not change the
  /// bound type of the memory.
  ///
  /// - Note: A trivial type can be copied with just a bit-for-bit copy without
  ///   any indirection or reference-counting operations. Generally, native
  ///   Swift types that do not contain strong or weak references or other
  ///   forms of indirection are trivial, as are imported C structs and enums.
  ///
  /// If you need to store into memory a copy of a value of a type that isn't
  /// trivial, you cannot use the `storeBytes(of:toByteOffset:as:)` method.
  /// Instead, you must know either initialize the memory or,
  /// if you know the memory was already bound to `type`, assign to the memory.
  ///
  /// - Parameters:
  ///   - value: The value to store as raw bytes.
  ///   - offset: The offset in bytes into the buffer pointer slice's memory
  ///     to begin writing bytes from the value. The default is zero.
  ///   - type: The type to use for the newly constructed instance. The memory
  ///     must be initialized to a value of a type that is layout compatible
  ///     with `type`.
  func storeBytes<T>(of value: T, toByteOffset offset: Int = 0, as type: T.Type)
}
```

## Source compatibility

This proposal consists mostly of additions, which are by definition source compatible.

The proposal includes the renaming of four existing functions from `assign` to `update`. The existing function names would be deprecated, producing a warning. A fixit will support an easy transition to the renamed versions of these functions.


## Effect on ABI stability

The functions proposed here are generally small wrappers around existing functionality. They are implemented as `@_alwaysEmitIntoClient` functions, which means they have no ABI impact.

The renamed functions can reuse the existing symbol, while the deprecated functions can forward using an `@_alwaysEmitIntoClient` stub to support the functionality under its previous name. The renamings would therefore have no ABI impact.


## Effect on API resilience

All functionality implemented as `@_alwaysEmitIntoClient` will back-deploy. Renamed functions that reuse a previous symbol will also back-deploy.


## Alternatives considered

##### Single element update functions

An earlier version of this proposal included single-element update functions, `UnsafeMutablePointer.update(to:)` and `UnsafeMutableBufferPointer.updateElement(at:to:)`. These are synonyms for the setters of `UnsafeMutablePointer.pointee` and `UnsafeMutableBufferPointer.subscript(_ i: Index)`, respectively. They were intended to improve the documentation for that operation, in particular the  often overlooked initialization requirement.

##### Renaming `assign` to `update`

The renaming of `assign` to `update` could be omitted entirely, although we believe the word "update" communicates the API's intent much better than does the word "assign". In _The Swift Programming Language_ (_TSPL_,) the `=` symbol is named "the assignment operator", and its function is described as to either "initialize" or "update" a value. The current name (`assign`) seemingly conflates the two roles of `=` as described in *TSPL*, while the proposed name (`update`) builds on _TSPL_.

There are only four current symbols to be renamed by this proposal, and their replacements are easily migrated by a fixit. For context, this renaming would change only 6 lines of code in the standard library, outside of the function definitions. If the renaming is omitted, the four new functions proposed in the family should use the name `assign` as well. The two single-element versions would be `assign(_ value:)` and `assignElement(at:_ value:)`.

##### Element-by-element copies from `Collection` inputs

The initialization and updating functions that copy from `Collection` inputs use the argument label `fromContentsOf`. This is a different label than used by the pre-existing functions that copy from `Sequence` inputs. We could use the same argument label (`from`) as with the `Sequence` inputs, but that would mean that we must return the `Iterator` for the `Collection` versions, and that is not necessarily desirable, especially if a particular `Iterator` cannot be copied cheaply. If we used the same argument label (`from`) and did not return `Iterator`, then the `Sequence` and `Collection` versions of the `initialize(from:)` would be overloaded by their return type, and that would be source-breaking:
an existing use of the current function that doesn't destructure the returned tuple on assignment could now pick up the `Collection` overload, which would have a return value incompatible with the subsequent code which assumes that the return value is of type `(Iterator, Index)`.

##### Returned tuple labels

One of the pre-existing returned tuples does not have element labels, and the original version of the proposal did not change that. New labels are now proposed for this case. This is technically source-breaking, in that if existing source uses exactly the proposed labels in a different position, then the returned tuple value would be shuffled. The chosen labels have sufficiently pointed names that the risk is very small.

## Acknowledgments

[Kelvin Ma](https://github.com/kelvin13) (aka [Taylor Swift](https://forums.swift.org/u/taylorswift/summary))'s initial versions of the pitch that became SE-0184 included more functions to manipulate initialization state. These were deferred, but much of the deferred functionality has not been pitched again until now.

Members of the Swift Standard Library team for valuable discussions.
