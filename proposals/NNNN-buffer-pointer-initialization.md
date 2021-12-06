# Initialization improvements for UnsafePointer and UnsafeBufferPointer family

* Proposal: [SE-NNNN Initialization improvements for UnsafePointer and UnsafeBufferPointer family][proposal]
* Author: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: [Draft Pull Request][draft-pr]
* Implementation: pending
* Bugs: rdar://51817146, https://bugs.swift.org/browse/SR-14982 (rdar://81168547), rdar://74655413
* Previous Revision: none

[proposal]: https://gist.github.com/glessard/3bb47dce974aa483fd6df072d265005c
[draft-pr]: https://github.com/apple/swift/pull/39981
[pitch-thread]: https://forums.swift.org/t/53168


## Introduction

The types in the `UnsafeMutablePointer` family typically require manual management of memory allocations,
including the management of their initialization state.
The states involved are, after allocation:
1. Unbound and uninitialized (as returned from `UnsafeMutableRawPointer.allocate()`)
2. Bound to a type, and uninitialized (as returned from `UnsafeMutablePointer<T>.allocate()`)
3. Bound to a type, and initialized

Memory can be safely deallocated whenever it is uninitialized.

Unfortunately, not every relevant type in the family has the necessary functionality to fully manage the initialization state of its memory.
We intend to address this issue in this proposal,
and provide functionality to manage initialization state in a much expanded variety of situations.

Swift-evolution thread: [Pitch thread][pitch-thread]

## Motivation

Memory allocated using `UnsafeMutablePointer`, `UnsafeMutableRawPointer`,
`UnsafeMutableBufferPointer` and `UnsafeMutableRawBufferPointer` is passed to the user in an uninitialized state.
In the general case, such memory needs to be initialized before it is used in Swift.
Memory can be "initialized" or "uninitialized".
We hereafter refer to this as a memory region's "initialization state".

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

In a complex use-case such as a custom-written data structure,
a subrange of memory may transition between the initialized and uninitialized state multiple times during the life of a memory allocation.
For example, if a mutable and contiguously allocated `CustomArray` is called with a sequence of alternating `append` and `removeLast` calls,
one storage location will get repeatedly initialized and deinitialized.
The implementor of `CustomArray` might want to represent the allocated buffer using `UnsafeMutableBufferPointer`,
but that means they will have to use the `UnsafeMutablePointer` type instead for initialization and deinitialization.

We would like to have a full complement of corresponding functions to operate on `UnsafeMutableBufferPointer`,
but we only have the following:
- `func initialize(repeating repeatedValue: Element)`
- `func initialize<S: Sequence>(from source: S) -> (S.Iterator, Index)`
- `func assign(repeating repeatedValue: Element)`

Missing are methods to update memory from a `Sequence` or a `Collection`,
move elements from another `UnsafeMutableBufferPointer`,
modify the initialization state of a range of memory for a particular index of the buffer,
or to deinitialize (at all).
Such functions would add some safety to these operations,
as they would add some bounds checking,
unlike the equivalent operations on `UnsafeMutablePointer`,
which have no concept of bounds checking.

Similarly, the functions that change the initialization state for `UnsafeMutableRawPointer` are:
- `func initializeMemory<T>(as type: T.Type, repeating repeatedValue: T, count: Int) -> UnsafeMutablePointer<T>`
- `func initializeMemory<T>(as type: T.Type, from source: UnsafePointer<T>, count: Int) -> UnsafeMutablePointer<T>`
- `func moveInitializeMemory<T>(as type: T.Type, from source: UnsafeMutablePointer<T>, count: Int) -> UnsafeMutablePointer<T>`

Since initialized memory is bound to a type, these cover the essential operations.
(The `assign` and `deinitialize` operations only make sense on typed `UnsafePointer<T>`.)

On `UnsafeMutableRawBufferPointer`, we only have:
- `func initializeMemory<T>(as type: T.Type, repeating repeatedValue: T) -> UnsafeMutableBufferPointer<T> `
- `func initializeMemory<S: Sequence>(as type: S.Element.Type, from source: S) -> (unwritten: S.Iterator, initialized: UnsafeMutableBufferPointer<S.Element>)`

Missing is an equivalent to `moveInitializeMemory`, in particular.

Additionally, the buffer initialization functions from `Sequence` parameters are overly strict,
and trap in many situations where the buffer length and the number of elements in a `Collection` do not match exactly.
We can improve on this situation with initialization functions from `Collection`s that behave more nicely.

There are four existing functions that use the `assign` (or `moveAssign`) name.
This name is unfortunately not especially clear.
In _The Swift Programming Language_, `=` is called the
"[assignment operator](https://docs.swift.org/swift-book/LanguageGuide/BasicOperators.html#ID62)",
and is said to either initialize or update a variable.
The word "update" here is much clearer, as it implies the existence of a prior value,
which communicates the requirement that a given memory location must have been previously initialized.
For this reason, we propose to _rename_ "assign" to "update".
This would involve deprecating the existing (rarely-used) functions,
with a straightforward fixit.
The existing symbol can be reused for purposes of ABI stability.


## Proposed solution

Note: in the pseudo-diffs presented in this section, `+++` indicates an added symbol, while `---` indicates a renamed symbol.

We propose to modify `UnsafeMutableBufferPointer` as follows:

```swift
extension UnsafeMutableBufferPointer {
    func initialize(repeating repeatedValue: Element)
    func initialize<S>(from source: S) -> (S.Iterator, Index) where S: Sequence, S.Element == Element
+++ func initialize<C>(fromElements: C) -> Index where C: Collection, C.Element == Element
--- func assign(repeating repeatedValue: Element)
+++ func update(repeating repeatedValue: Element)
+++ func update<S>(from source: S) -> (unwritten: S.Iterator, updated: Index) where S: Sequence, S.Element == Element
+++ func update<C>(fromElements: C) -> Index where C: Collection, C.Element == Element
+++ func moveInitialize(fromElements: UnsafeMutableBufferPointer) -> Index
+++ func moveInitialize(fromElements: Slice<UnsafeMutableBufferPointer>) -> Index
+++ func moveUpdate(fromElements: `Self`) -> Index
+++ func moveUpdate(fromElements: Slice<`Self`>) -> Index
+++ func deinitialize() -> UnsafeMutableRawBufferPointer

+++ func initializeElement(at index: Index, to value: Element)
+++ func updateElement(at index: Index, to value: Element)
+++ func moveElement(from index: Index) -> Element
+++ func deinitializeElement(at index: Index)
}
```
<!-- UMBP needs a method to initialize a specific element: rdar://51817146 -->

The methods that initialize or update from a `Collection` will have forgiving semantics,
and copy the number of elements that they can, be that every available element or none,
and then return the next index in the buffer.
Unlike the existing `Sequence` functions,
they include no preconditions beyond having a valid `Collection` and valid buffer,
with the understanding that if a user wishes stricter behaviour,
they can compose it from these functions.

The above changes include a method to update a single element.
Evidently that is a synonym for the `subscript(_ i: Index)` setter.
We hope that documenting the update action specifically will help clarify the requirements of that action which,
as experience shows, get muddled when documented along with the subscript getter.

Similarly, we propose adding to `UnsafeMutablePointer` and `UnsafeMutableRawPointer`:
```swift
extension UnsafeMutablePointer {
    func initialize(to value: Pointee)
    func initialize(repeating repeatedValue: Pointee, count: Int)
    func initialize(from source: UnsafePointer<Pointee>, count: Int)
+++ func update(to value: Pointee)
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

extension UnsafeMutableRawPointer {
+++ func initializeMemory<T>(as type: T.Type, to value: T) -> UnsafeMutablePointer<T>
    func initializeMemory<T>(as type: T.Type, repeating repeatedValue: T, count: Int) -> UnsafeMutablePointer<T>
    func initializeMemory<T>(as type: T.Type, from source: UnsafePointer<T>, count: Int) -> UnsafeMutablePointer<T>
    func moveInitializeMemory<T>(as type: T.Type, from source: UnsafeMutablePointer<T>, count: Int) -> UnsafeMutablePointer<T>
}
```

Finally, we propose adding additional functions to initialize `UnsafeMutableRawBufferPointer`s.
The first will initialize from a `Collection` and have less stringent semantics than the existing function that initializes from a `Sequence`.
The other two enable moving a range of memory into an `UnsafeMutableRawBufferPointer` while deinitializing a typed `UnsafeMutableBufferPointer`.
```
extension UnsafeMutableRawBufferPointer {
    func initializeMemory<T>(as type: T.Type, repeating repeatedValue: T) -> UnsafeMutableBufferPointer<T>
    func initializeMemory<S>(as type: S.Element.Type, from source: S) -> (unwritten: S.Iterator, initialized: UnsafeMutableBufferPointer<S.Element>) where S: Sequence
+++ func initializeMemory<C>(as type: C.Element.Type, fromElements: C) -> UnsafeMutableBufferPointer<C.Element> where C: Collection
+++ func moveInitializeMemory<T>(as type: T.Type, fromElements: UnsafeMutableBufferPointer<T>) -> UnsafeMutableBufferPointer<T>
+++ func moveInitializeMemory<T>(as type: T.Type, fromElements: Slice<UnsafeMutableBufferPointer<T>>) -> UnsafeMutableBufferPointer<T>
}
```
<!-- initializeMemory<C>: https://bugs.swift.org/browse/SR-14982, rdar://81168547 -->

## Detailed design

```swift
extension UnsafeMutableBufferPointer {
  /// Initializes the buffer's memory with the given elements.
  ///
  /// Initializes the buffer's memory with the given elements.
  ///
  /// Prior to calling the `initialize(fromElements:)` method on a buffer,
  /// the memory referenced by the buffer must be uninitialized,
  /// or the `Element` type must be a trivial type. After the call,
  /// the memory referenced by the buffer up to, but not including,
  /// the returned index is initialized.
  ///
  /// The returned index is the position of the next uninitialized element
  /// in the buffer, which is one past the last element written.
  /// If `fromElements` contains no elements, the returned index is equal to
  /// the buffer's `startIndex`. If `fromElements` contains an equal or greater
  /// number of elements than the buffer can hold, the returned index is equal
  /// to the buffer's `endIndex`.
  ///
  /// - Parameter fromElements: A collection of elements to be used to
  ///   initialize the buffer's storage.
  /// - Returns: An index to the next uninitialized element in the buffer,
  ///   or `endIndex`.
  func initialize<C>(fromElements source: C) -> Index
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
  public func update<S>(from source: S) -> (unwritten: S.Iterator, assigned: Index)
    where S: Sequence, S.Element == Element

  /// Updates the buffer's initialized memory with the given elements.
  ///
  /// The buffer's memory must be initialized or the buffer's `Element` type
  /// must be a trivial type.
  ///
  /// - Parameter fromElements: A collection of elements to be used to update
  ///   the buffer's contents.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func update<C>(fromElements source: C) -> Index
    where C: Collection, C.Element == Element

  /// Moves instances from an initialized source buffer into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// The region of memory starting at this pointer and covering `source.count`
  /// instances of the buffer's `Element` type must be uninitialized, or
  /// `Element` must be a trivial type. After calling
  /// `moveInitialize(fromElements:)`, the region is initialized and the memory
  /// region underlying `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to copy. The memory region
  ///   underlying `source` must be initialized. The memory regions
  ///   referenced by `source` and this buffer may overlap.
  /// - Returns: An index to the next uninitialized element in the buffer,
  ///   or `endIndex`.
  public func moveInitialize(fromElements: Self) -> Index

  /// Moves instances from an initialized source buffer slice into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// The region of memory starting at this pointer and covering `source.count`
  /// instances of the buffer's `Element` type must be uninitialized, or
  /// `Element` must be a trivial type. After calling
  /// `moveInitialize(fromElements:)`, the region is initialized and the memory
  /// region underlying `source[..<source.endIndex]` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to copy. The memory
  ///   region underlying `source` must be initialized. The memory regions
  ///   referenced by `source` and this buffer may overlap.
  /// - Returns: An index one past the last replaced element in the buffer,
  ///   or `endIndex`.
  public func moveInitialize(fromElements: Slice<Self>) -> Index

  /// Updates this buffer's initialized memory initialized memory by moving
  /// all the elements from the source buffer, leaving the source memory
  /// uninitialized.
  ///
  /// The region of memory starting at this pointer and covering
  /// `fromElements.count` instances of the buffer's `Element` type
  /// must be initialized, or `Element` must be a trivial type. After calling
  /// `moveUpdate(fromElements:)`, the memory region underlying
  /// `source` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to move.
  ///   The memory region underlying `source` must be initialized. The
  ///   memory regions referenced by `source` and this pointer must not overlap.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func moveUpdate(fromElements: `Self`) -> Index

  /// Updates this buffer's initialized memory initialized memory by moving
  /// all the elements from the source buffer slice, leaving the source memory
  /// uninitialized.
  ///
  /// The region of memory starting at this pointer and covering
  /// `fromElements.count` instances of the buffer's `Element` type
  /// must be initialized, or `Element` must be a trivial type. After calling
  /// `moveUpdate(fromElements:)`, the memory region underlying
  /// `source[..<source.endIndex]` is uninitialized.
  ///
  /// - Parameter source: A buffer containing the values to move.
  ///   The memory region underlying `source` must be initialized. The
  ///   memory regions referenced by `source` and this pointer must not overlap.
  /// - Returns: An index one past the last updated element in the buffer,
  ///   or `endIndex`.
  public func moveUpdate(fromElements: Slice<`Self`>) -> Index

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

```swift
extension UnsafeMutablePointer {
  /// Update this pointer's initialized memory.
  ///
  /// The range of memory starting at this pointer and covering one instance
  /// of `Pointee` must be initialized, or `Pointee` must be a trivial type.
  /// This method is equivalent to:
  ///
  ///     self.pointee = value
  ///
  /// - Parameters:
  ///   - value: The value used to update this pointer's memory.
  public func update(_ value: Pointee)
}

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

```
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

```swift
extension UnsafeMutableRawBufferPointer {
  /// Initializes the buffer's memory with the given elements, binding the
  /// initialized memory to the elements' type.
  ///
  /// When calling the `initializeMemory(as:fromElements:)` method on a buffer
  /// `b`, the memory referenced by `b` must be uninitialized, or initialized
  /// to a trivial type. `b` must be properly aligned for accessing `C.Element`.
  ///
  /// This method initializes the buffer with the contents of `fromElements`
  /// until `fromElements` is exhausted or the buffer runs out of available
  /// space. After calling `initializeMemory(as:fromElements:)`, the memory
  /// referenced by the returned `UnsafeMutableBufferPointer` instance is bound
  /// and initialized to type `C.Element`. This method does not change
  /// the binding state of the unused portion of `b`, if any.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - fromElements: A collection of elements to be used to
  ///     initialize the buffer's storage.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   the collection `elements`.
  func initializeMemory<C>(as: C.Element.Type, fromElements: C) -> UnsafeMutableBufferPointer<C.Element>
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
  /// `fromElements.count` instances of the buffer's `Element` type
  /// must be uninitialized, or `Element` must be a trivial type. After
  /// calling `moveInitialize(as:from:)`, the region is initialized and the
  /// memory region underlying `source` is uninitialized.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - fromElements: A buffer containing the values to copy.
  ///     The memory region underlying `source` must be initialized.
  ///     The memory regions referenced by `source` and this buffer may overlap.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   `source`.
  func moveInitializeMemory<T>(
    as type: T.Type,
    fromElements: UnsafeMutableBufferPointer<T>
  ) -> UnsafeMutableBufferPointer<T>

  /// Moves instances from an initialized source buffer slice into the
  /// uninitialized memory referenced by this buffer, leaving the source memory
  /// uninitialized and this buffer's memory initialized.
  ///
  /// The region of memory starting at this pointer and covering
  /// `fromElements.count` instances of the buffer's `Element` type
  /// must be uninitialized, or `Element` must be a trivial type. After
  /// calling `moveInitialize(as:from:)`, the region is initialized and the
  /// memory region underlying `source[..<source.endIndex]` is uninitialized.
  ///
  /// - Parameters:
  ///   - type: The type of element to which this buffer's memory will be bound.
  ///   - fromElements: A buffer containing the values to copy.
  ///     The memory region underlying `source` must be initialized.
  ///     The memory regions referenced by `source` and this buffer may overlap.
  /// - Returns: A typed buffer of the initialized elements. The returned
  ///   buffer references memory starting at the same base address as this
  ///   buffer, and its count indicates the number of elements copied from
  ///   `source`.
  func moveInitializeMemory<T>(
    as type: T.Type,
    fromElements: Slice<UnsafeMutableBufferPointer<T>>
  ) -> UnsafeMutableBufferPointer<T>
}
```

## Source compatibility

This proposal consists mostly of additions.

The proposal includes the renaming of four existing functions from `assign` to `update`.
The existing function names would be deprecated, producing a warning.
A fixit will support an easy transition to the renamed versions of these functions.


## Effect on ABI stability

The functions proposed here are generally small wrappers around existing functionality.
We expect to implement them as `@_alwaysEmitIntoClient` functions,
which means they would have no ABI impact.

The renamed functions can reuse the existing symbol,
while the deprecated functions can use an `@_alwaysEmitIntoClient` support the functionality under its previous name.
This would have no ABI impact.


## Effect on API resilience

All functionality implemented as `@_alwaysEmitIntoClient` will back-deploy.
Renamed functions that reuse a previous symbol will also back-deploy.


## Alternatives considered

The single-element update functions,
`UnsafeMutablePointer.update(to:)` and `UnsafeMutableBufferPointer.updateElement(at:to:)`,
are synonyms for the setters of `UnsafeMutablePointer.pointee` and `UnsafeMutableBufferPointer.subscript(_ i: Index)`, respectively.
Clearly we can elect to not add them.
The setters in question, like the update functions,
have a required precondition that the memory they refer to must be initialized.
Somehow this precondition is often overlooked and leads to bug reports.
The proposed names and cross-references should help clarify the requirements to users.

The renaming of `assign` to `update` could be omitted entirely,
although we believe that `update` communicates intent much better than `assign` does.
There are only four symbols affected by this renaming,
and their replacements are easily migrated by a fixit.
For context, this renaming would only 6 lines of code in the standard library, outside of the function definitions.
If the renaming is omitted, the four new functions proposed in the family should use the name `assign` as well.
The two single-element versions would be `assign(_ value:)` and `assignElement(at:_ value:)`.

The initializing and updating functions that copy from `Collection` inputs use the argument label `fromElements`.
This is different from the pre-existing functions that copy from `Sequence` inputs.
We could use the same argument label (`from`) is with the `Sequence` inputs,
but that would mean that we must return the `Iterator` for the `Collection` versions,
and that is generally not desirable.
If we did not return `Iterator`, then the `Sequence` and `Collection` versions of the `initialize(from:)` would be overloaded by their return type,
and that would be source-breaking:
an existing use of the current function that doesn't immediately destructure the returned tuple could pick up the `Collection` overload,
which would have a return value incompatible with the existing code that makes use the return value.


## Acknowledgments

[Kelvin Ma](https://github.com/kelvin13) (aka [Taylor Swift](https://forums.swift.org/u/taylorswift/summary))'s initial versions of the pitch that became SE-0184 included more functions to manipulate initialization state.
These were deferred, but the functionality has not been pitched again until now.
