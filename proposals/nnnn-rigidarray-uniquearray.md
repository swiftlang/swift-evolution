# RigidArray and UniqueArray

* Proposal: [SE-NNNN](NNNN-rigidarray-uniquearray.md)
* Authors: [Karoy Lorentey](https://github.com/lorentey), [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#87521](https://github.com/swiftlang/swift/pull/87521)
* Review: ([pitch](https://forums.swift.org/t/pitch-rigidarray-and-uniquearray/85455))

## Summary of changes

We propose to introduce two new array types to the standard library,
`RigidArray` and `UniqueArray`, that are both capable of storing noncopyable
elements.

## Motivation

Swift 5.9 introduced noncopyable struct and enums into the language and we've
steadily been adding more new API that helps support these types. The standard
library has even implemented noncopyable API like `Atomic` and `Mutex` as well
as `InlineArray` that can store values of noncopyable types in inline storage.
One of the areas that's still a sore spot however, is that there are no data
structures in the standard library itself that support heap allocating a list
of noncopyable values.

Most users reach for `Array` when it comes to needing to store a list of values
somewhere that can be readily accessed. `Array` unfortunately does not support
noncopyable values and its default copy on write (🐮) behavior is quite
problematic for these kinds of types as well:

```swift
struct File: ~Copyable {
  let fd: UInt32

  init(_ path: String) { ... }

  deinit {
    close(fd)
  }
}

let file1 = File("file1.txt")
let file2 = File("file2.md")

var a = [file1, file2]

let file3 = File("file3.swift")

// Ok, 'a' is still uniquely referenced so performing this mutation
// doesn't need to copy on write.
a.append(file3)

var b = a

let file4 = File("file4.tar.gz")

// Error!
b.append(file4)
```

Appending to `b` triggers a copy on write on the underlying array buffer, but
we're holding noncopyable values! This particular example is problematic because
if we blindly copied the values within the array, then when we go to destroy `b`
we would call `close` on `file1`, `file2`, and `file3`. Working with these files
on `a` would all be closed!

Storing noncopyable elements in an array means that sharing the array cannot
mutate the elements unless we can dynamically ensure we have exclusive access to
the array buffer and we can unique the array buffer to guarantee exclusiveness.
`Array` can dynamically guarantee it has exclusive access, but it doesn't know
how to actually unique the buffer if there are noncopyable elements. There are
no hooks during something like an `.append` call on an array to inform it how to
potentially copy or clone a noncopyable element.

## Proposed solution

The standard library proposes to add two new array types `RigidArray` and
`UniqueArray`.

`RigidArray` is a noncopyable, heap allocated, fixed capacity array type, while
`UniqueArray` is its dynamically resizing variant. `UniqueArray` provides the
ease-of-use benefits of an automatically self-resizing container type, but that
inherently comes with the cost of those implicit reallocations -- making it far
more difficult to reliably reason about how much storage the data structure will
allocate during its use, and precisely when those allocations may happen. In
contrast, `RigidArray` requires its storage to be carefully (and explicitly) sized
in advance; this makes it far more difficult to use, but in exchange its
operations have much tighter time and space complexity guarantees, making it
better suited for low-latency or memory-constrained use cases.

In a nutshell, `UniqueArray` gives us a slightly reimagined, ownership-aware
version of the familiar `Array` type with uniquely held storage. `RigidArray`
turns that into a fixed-capacity construct that feels quite inflexible (or
rigid), but its rigidity makes it far more suited for realtime or embedded use.

```swift
var a = UniqueArray<File>()
a.append(file1)
a.append(file2)

var b = a

// Ok
b.append(file3)

// Error: 'a' used after consume
a.append(file4)
```

`var b = a` is now a _move_ rather than it copying the `Array` class reference.
This means that `a` is no longer valid to use. Statically we guarantee that
`UniqueArray`'s are only _uniquely_ held. Note that `a` doesn't perform
deinitialization anymore, it has transferred ownership to `b` and once `b` goes
out of scope we deinitialize the elements.

`RigidArray` shares all of those semantics, but it has a very strict capacity
limit that will cause it to fatal error the process if one tries to over append
to it:

```swift
var a = RigidArray<Int>(capacity: 2)
a.append(1)
a.append(2)

// Runtime error: out of capacity
a.append(3)
```

This is an extremely important detail. Performance critical contexts that
cannot sacrifice an implicit allocation from underneath their feet would greatly
prefer to use `RigidArray` where it's possible to do so. Solutions that try to
carefully use `UniqueArray` without implicitly allocating will almost certainly
be met with bugs. `RigidArray` provides this guarantee at the type level. These
semantics come with concrete time and space complexity guarantees that aren't
present with `UniqueArray`.

## Detailed design

### `RigidArray`

```swift
/// A fixed capacity, heap allocated, noncopyable array of potentially
/// noncopyable elements.
///
/// `RigidArray` instances are created with a specific maximum capacity. Elements
/// can be added to the array up to that capacity, but no more: trying to add an
/// item to a full array results in a runtime trap.
///
///      var items = RigidArray<Int>(capacity: 2)
///      items.append(1)
///      items.append(2)
///      items.append(3) // Runtime error: RigidArray capacity overflow
///
/// Rigid arrays provide convenience properties to help verify that it has
/// enough available capacity: `isFull` and `freeCapacity`.
///
///     guard items.freeCapacity >= 4 else { throw CapacityOverflow() }
///     items.append(copying: newItems)
///
/// It is possible to extend or shrink the capacity of a rigid array instance,
/// but this needs to be done explicitly, with operations dedicated to this
/// purpose (such as ``reserveCapacity`` and ``reallocate(capacity:)``).
/// The array never resizes itself automatically.
///
/// It therefore requires careful manual analysis or up front runtime capacity
/// checks to prevent the array from overflowing its storage. This makes
/// this type more difficult to use than a dynamic array. However, it allows
/// this construct to provide predictably stable performance.
///
/// This trading of usability in favor of stable performance limits `RigidArray`
/// to the most resource-constrained of use cases, such as space-constrained
/// environments that require carefully accounting of every heap allocation, or
/// time-constrained applications that cannot accommodate unexpected latency
/// spikes due to a reallocation getting triggered at an inopportune moment.
///
/// For use cases outside of these narrow domains, we generally recommmend
/// the use of ``UniqueArray`` rather than `RigidArray`. (For copyable elements,
/// the standard `Array` is an even more convenient choice.)
public struct RigidArray<Element: ~Copyable>: ~Copyable {}

extension RigidArray: Sendable where Element: Sendable & ~Copyable {}
```

### `UniqueArray`

```swift
/// A dynamically self-resizing, heap allocated, noncopyable array of
/// potentially noncopyable elements.
///
/// `UniqueArray` instances automatically resize their underlying storage as
/// needed to accommodate newly inserted items, using a geometric growth curve.
/// This frees code using `UniqueArray` from having to allocate enough
/// capacity in advance; on the other hand, it makes it difficult to tell
/// when and where such reallocations may happen.
///
/// For example, appending an element to a dynamic array has highly variable
/// complexity; often, it runs at a constant cost, but if the operation has to
/// resize storage, then the cost of an individual append suddenly becomes
/// proportional to the size of the whole array.
///
/// The geometric growth curve allows the cost of such latency spikes to
/// get amortized across repeated invocations, bringing the average cost back
/// to O(1); but they make this construct less suitable for use cases that
/// expect predictable, consistent performance on every operation.
///
/// Implicit growth also makes it more difficult to predict/analyze the amount
/// of memory an algorithm would need. Developers targeting environments with
/// stringent limits on heap allocations may prefer to avoid using dynamically
/// resizing array types as a matter of policy. The type `RigidArray` provides
/// a fixed-capacity array variant that caters specifically for these use cases,
/// trading ease-of-use for more consistent/predictable execution.
public struct UniqueArray<Element: ~Copyable>: ~Copyable {}

extension UniqueArray: Sendable where Element: Sendable & ~Copyable {}
```

### API on _both_ `RigidArray` and `UniqueArray`

#### Basics

```swift
extension [Rigid|Unique]Array where Element: ~Copyable {
  /// The maximum number of elements this array can hold without having to
  /// reallocate its storage.
  ///
  /// - Complexity: O(1)
  public var capacity: Int {
    get
  }

  /// The number of additional elements that can be added to this array without
  /// reallocating its storage.
  ///
  /// - Complexity: O(1)
  public var freeCapacity: Int {
    get
  }

  /// A span over the elements of this array, providing direct read-only access.
  ///
  /// - Complexity: O(1)
  public var span: Span<Element> {
    get
  }

  /// A mutable span over the elements of this array, providing direct
  /// mutating access.
  ///
  /// - Complexity: O(1)
  public var mutableSpan: MutableSpan<Element> {
    mutating get
  }

  /// Arbitrarily edit the storage underlying this array by invoking a
  /// user-supplied closure with a mutable `OutputSpan` view over it.
  /// This method calls its function argument at most once, allowing it to
  /// arbitrarily modify the contents of the output span it is given.
  /// The argument is free to add, remove or reorder any items; however,
  /// it is not allowed to replace the span or change its capacity.
  ///
  /// When the function argument finishes (whether by returning or throwing an
  /// error) the {rigid|unique} array instance is updated to match the final contents of
  /// the output span.
  ///
  /// - Parameter body: A function that edits the contents of this array through
  ///    an `OutputSpan` argument. This method invokes this function
  ///    at most once.
  /// - Returns: This method returns the result of its function argument.
  /// - Complexity: Adds O(1) overhead to the complexity of the function
  ///    argument.
  public mutating func edit<E: Error, R: ~Copyable>(
    _ body: (inout OutputSpan<Element>) throws(E) -> R
  ) throws(E) -> R

  /// Grow or shrink the capacity of a {rigid|unique} array instance without discarding
  /// its contents.
  ///
  /// This operation replaces the array's storage buffer with a newly allocated
  /// buffer of the specified capacity, moving all existing elements
  /// to its new storage. The old storage is then deallocated.
  ///
  /// - Parameter newCapacity: The desired new capacity. `newCapacity` must be
  ///    greater than or equal to the current count.
  ///
  /// - Complexity: O(`count`)
  public mutating func reallocate(capacity newCapacity: Int)

  /// Ensure that the array has capacity to store the specified number of
  /// elements, by growing its storage buffer if necessary.
  ///
  /// If `capacity < n`, then this operation reallocates the {rigid|unique} array's
  /// storage to grow it; on return, the array's capacity becomes `n`.
  /// Otherwise the array is left as is.
  ///
  /// - Complexity: O(`count`)
  public mutating func reserveCapacity(_ n: Int)
}

extension [Rigid|Unique]Array where Element: Copyable {
  /// Copy the contents of this array into a newly allocated {rigid|unique} array
  /// instance with just enough capacity to hold all its elements.
  ///
  /// - Complexity: O(`count`)
  public func clone() -> Self

  /// Copy the contents of this array into a newly allocated {rigid|unique} array
  /// instance with the specified capacity.
  ///
  /// - Parameter capacity: The desired capacity of the resulting {rigid|unique} array.
  ///    `capacity` must be greater than or equal to `count`.
  ///
  /// - Complexity: O(`count`)
  public func clone(capacity: Int) -> Self
}
```

#### Initializers

```swift
extension [Rigid|Unique]Array where Element: ~Copyable {
  /// Initializes a new {rigid|unique} array with zero capacity and no elements.
  ///
  /// - Complexity: O(1)
  public init()

  /// Initializes a new {rigid|unique} array with the specified capacity and no elements.
  public init(capacity: Int)

  /// Creates a new array with the specified capacity, directly initializing
  /// its storage using an output span.
  ///
  /// - Parameters:
  ///   - capacity: The storage capacity of the new array.
  ///   - body: A callback that gets called at most once to directly
  ///       populate newly reserved storage within the array. The function
  ///       is allowed to add fewer than `capacity` items. The array is
  ///       initialized with however many items the callback adds to the
  ///       output span before it returns (or before it throws an error).
  public init<E: Error>(
    capacity: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}

extension [Rigid|Unique]Array where Element: Copyable {
  /// Creates a new array containing the specified number of a single,
  /// repeated value.
  ///
  /// - Parameters:
  ///   - repeatedValue: The element to repeat.
  ///   - count: The number of times to repeat the value passed in the
  ///     `repeating` parameter. `count` must be zero or greater.
  ///
  /// - Complexity: O(`count`)
  public init(repeating repeatedValue: Element, count: Int)

  /// Creates a new array with the specified capacity, holding a copy
  /// of the contents of the given span.
  ///
  /// - Parameters:
  ///   - capacity: The storage capacity of the new array, or nil to allocate
  ///      just enough capacity to store the contents of the span.
  ///   - span: The span whose contents to copy into the new array.
  ///      The span must not contain more than `capacity` elements.
  public init(
    capacity: Int? = nil,
    copying span: Span<Element>
  )
}
```

#### Collection based API

```swift
extension [Rigid|Unique]Array where Element: ~Copyable {
  /// A type that represents a position in the array: an integer offset from the
  /// start.
  ///
  /// Valid indices consist of the position of every element and a "past the
  /// end” position that’s not valid for use as a subscript argument.
  public typealias Index = Int

  /// A Boolean value indicating whether this array contains no elements.
  ///
  /// - Complexity: O(1)
  public var isEmpty: Bool {
    get
  }

  /// The number of elements in this array.
  ///
  /// - Complexity: O(1)
  public var count: Int {
    get
  }

  /// The position of the first element in a nonempty array. This is always zero.
  ///
  /// - Complexity: O(1)
  public var startIndex: Int {
    get
  }

  /// The array’s "past the end” position—that is, the position one greater than
  /// the last valid subscript argument. This is always equal to the array's
  /// count.
  ///
  /// - Complexity: O(1)
  public var endIndex: Int {
    get
  }

  /// The range of indices that are valid for subscripting the array.
  ///
  /// - Complexity: O(1)
  public var indices: Range<Int> {
    get
  }

  /// Accesses the element at the specified position.
  ///
  /// - Parameter position: The position of the element to access.
  ///     The position must be a valid index of the array that is not equal
  ///     to the `endIndex` property.
  ///
  /// - Complexity: O(1)
  public subscript(position: Int) -> Element {
    borrow

    mutate
  }

  /// Exchanges the values at the specified indices of the array.
  ///
  /// Both parameters must be valid indices of the array and not equal to
  /// endIndex. Passing the same index as both `i` and `j` has no effect.
  ///
  /// - Parameter i: The index of the first value to swap.
  /// - Parameter j: The index of the second valud to swap.
  ///
  /// - Complexity: O(1)
  public mutating func swapAt(_ i: Int, _ j: Int)

  /// Returns the position immediately after the given index.
  ///
  /// - Note: To improve performance, this method does not validate that the
  ///    index is valid before incrementing it. Index validation is
  ///    deferred until the resulting index is used to access an element.
  ///    This optimization may be removed in future versions; do not rely on it.
  ///
  /// - Parameter index: A valid index of the array. `i` must be less
  ///     than `endIndex`.
  /// - Returns: The index immediately following `i`.
  /// - Complexity: O(1)
  public func index(after index: Int) -> Int
  
  /// Returns the position immediately before the given index.
  ///
  /// - Note: To improve performance, this method does not validate that the
  ///    index is valid before decrementing it. Index validation is
  ///    deferred until the resulting index is used to access an element.
  ///    This optimization may be removed in future versions; do not rely on it.
  ///
  /// - Parameter index: A valid index of the array. `i` must be greater
  ///     than `startIndex`.
  /// - Returns: The index immediately preceding `i`.
  /// - Complexity: O(1)
  public func index(before index: Int) -> Int

  /// Replaces the given index with its successor.
  ///
  /// - Note: To improve performance, this method does not validate that the
  ///    given index is valid before incrementing it. Index validation is
  ///    deferred until the resulting index is used to access an element.
  ///    This optimization may be removed in future versions; do not rely on it.
  ///
  /// - Parameter index: A valid index of the array. `i` must be less
  ///     than `endIndex`.
  /// - Complexity: O(1)
  public func formIndex(after index: inout Int)

  /// Replaces the given index with its predecessor.
  ///
  /// - Note: To improve performance, this method does not validate that the
  ///    given index is valid before decrementing it. Index validation is
  ///    deferred until the resulting index is used to access an element.
  ///    This optimization may be removed in future versions; do not rely on it.
  ///
  /// - Parameter index: A valid index of the array. `i` must be greater than
  ///     `startIndex`.
  /// - Complexity: O(1)
  public func formIndex(before index: inout Int)

  /// Returns an index that is the specified distance from the given index.
  ///
  /// The value passed as `n` must not offset `index` beyond the bounds of the
  /// array.
  ///
  /// - Note: To improve performance, this method does not validate that the
  ///    given index is valid before offseting it. Index validation is
  ///    deferred until the resulting index is used to access an element.
  ///    This optimization may be removed in future versions; do not rely on it.
  ///
  /// - Parameter index: A valid index of the array.
  /// - Parameter n: The distance by which to offset `index`.
  /// - Returns: An index offset by distance from `index`. If `n` is positive,
  ///    this is the same value as the result of `n` calls to `index(after:)`.
  ///    If `n` is negative, this is the same value as the result of `abs(n)`
  ///    calls to `index(before:)`.
  /// - Complexity: O(1)
  public func index(_ index: Int, offsetBy n: Int) -> Int
  
  /// Returns the distance between two indices.
  ///
  /// - Note: To improve performance, this method does not validate that the
  ///    given index is valid before offseting it. Index validation is
  ///    deferred until the resulting index is used to access an element.
  ///    This optimization may be removed in future versions; do not rely on it.
  ///
  /// - Parameter start: A valid index of the collection.
  /// - Parameter end: Another valid index of the collection. If end is equal
  ///    to start, the result is zero.
  /// - Returns: The distance between `start` and `end`.
  /// - Complexity: O(1)
  public func distance(from start: Index, to end: Index) -> Int
  
  /// Offsets the given index by the specified distance, but no further than
  /// the given limiting index.
  ///
  /// If the operation was able to offset `index` by exactly the requested
  /// number of steps without hitting `limit`, then on return `n` is set to `0`,
  /// and `index` is set to the adjusted index.
  ///
  /// If the operation hits the limit before it can take the requested number
  /// of steps, then on return `index` is set to `limit`, and `n` is set
  /// to the number of steps that couldn't be taken.
  ///
  /// The value passed as `n` must not offset `index` beyond the bounds of the
  /// container, unless the index passed as `limit` prevents offsetting beyond
  /// those bounds.
  ///
  /// - Note: To improve performance, this method does not validate that the
  ///    given index is valid before offseting it. Index validation is
  ///    deferred until the resulting index is used to access an element.
  ///    This optimization may be removed in future versions; do not rely on it.
  ///
  /// - Parameter index: A valid index of the array. On return, `index` is
  ///    set to `limit` if
  /// - Parameter n: The distance to offset `index`.
  ///    On return, `n` is set to zero if the operation succeeded without
  ///    hitting the limit; otherwise, `n` reflects the number of steps that
  ///    couldn't be taken.
  /// - Parameter limit: A valid index of the array to use as a limit.
  ///    If `n > 0`, a limit that is less than `index` has no effect.
  ///    Likewise, if `n < 0`, a limit that is greater than `index` has no
  ///    effect.
  /// - Complexity: O(1)
  public func formIndex(
    _ index: inout Index,
    offsetBy n: inout Int,
    limitedBy limit: Index
  )
}
```

#### Appends

```swift
extension [Rigid|Unique]Array where Element: ~Copyable {
  /// Adds an element to the end of the array.
  ///
  /// If the rigid array does not have sufficient capacity to hold any more
  /// elements, then this triggers a runtime error.
  ///
  /// If the unqiue array does not have sufficient capacity to hold any more
  /// elements, then this reallocates the array's storage to grow its capacity,
  /// using a geometric growth rate.
  ///
  /// - Parameter item: The element to append to the collection.
  ///
  /// - Complexity: O(1)
  public mutating func append(_ item: consuming Element)

  /// Append a given number of items to the end of this array by populating
  /// an output span.
  ///
  /// If the rigid array does not have sufficient capacity to store the new items in
  /// the buffer, then this triggers a runtime error.
  ///
  /// If the unqieu array does not have sufficient capacity to hold the requested
  /// number of new elements, then this reallocates the array's storage to
  /// grow its capacity, using a geometric growth rate.
  ///
  /// If the callback fails to fully populate its output span or if
  /// it throws an error, then the array keeps all items that were
  /// successfully initialized before the callback terminated the insertion.
  ///
  /// - Parameters:
  ///    - newItemCount: The number of items to append to the array.
  ///    - initializer: A callback that gets called at most once to directly
  ///       populate newly reserved storage within the array. The function
  ///       is allowed to initialize fewer than `newItemCount` items.
  ///       The array is appended however many items the callback adds to
  ///       the output span before it returns (or before it throws an error).
  ///
  /// - Complexity: O(`newItemCount`)
  public mutating func append<E: Error>(
    addingCount newItemCount: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)

  /// Moves the elements of a buffer to the end of this array, leaving the
  /// buffer uninitialized.
  ///
  /// If the rigid array does not have sufficient capacity to hold all items in
  /// the buffer, then this triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold all items in
  /// the buffer, then this reallocates the array's storage to grow its capacity,
  /// using a geometric growth rate.
  ///
  /// - Parameters:
  ///    - items: A fully initialized buffer whose contents to move into
  ///        the array.
  ///
  /// - Complexity: O(`items.count`)
  public mutating func append(
    moving items: UnsafeMutableBufferPointer<Element>
  )

  /// Moves the elements of an output span to the end of this array, leaving the
  /// span empty.
  ///
  /// If the rigid array does not have sufficient capacity to hold all items in its
  /// storage, then this triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold all new items,
  /// then this reallocates the array's storage to grow its capacity,
  /// using a geometric growth rate.
  ///
  /// - Parameters:
  ///    - items: An output span whose contents need to be appended to this array.
  ///
  /// - Complexity: O(`items.count`)
  public mutating func append(
    moving items: inout OutputSpan<Element>
  )
}

extension [Rigid|Unique]Array where Element: Copyable {
  /// Copies the elements of a buffer to the end of this array.
  ///
  /// If the rigid array does not have sufficient capacity to hold all items in its
  /// storage, then this triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold all items
  /// in the source buffer, then this automatically grows the array's
  /// capacity, using a geometric growth rate.
  ///
  /// - Parameters:
  ///    - newElements: A fully initialized buffer whose contents to copy into
  ///       the array.
  ///
  /// - Complexity: O(`newElements.count`) when amortized over many
  ///     invocations on the same array.
  public mutating func append(
    copying newElements: UnsafeBufferPointer<Element>
  )

  /// Copies the elements of a buffer to the end of this array.
  ///
  /// If the rigid array does not have sufficient capacity to hold all items in
  /// the buffer, then this triggers a runtime error.
  ///
  /// If the unqiue array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using
  /// a geometric growth rate.
  ///
  /// - Parameters:
  ///    - newElements: A fully initialized buffer whose contents to copy into
  ///       the array.
  ///
  /// - Complexity: O(`newElements.count`) when amortized over many
  ///     invocations on the same array.
  public mutating func append(
    copying newElements: UnsafeMutableBufferPointer<Element>
  )

  /// Copies the elements of a span to the end of this array.
  ///
  /// If the rigid array does not have sufficient capacity to hold all items in
  /// the buffer, then this triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// - Parameters:
  ///    - newElements: A span whose contents to copy into the array.
  ///
  /// - Complexity: O(`newElements.count`) when amortized over many
  ///     invocations on the same array.
  public mutating func append(copying newElements: Span<Element>)

  /// Copies the elements of a sequence to the end of this array.
  ///
  /// If the rigid array does not have sufficient capacity to hold all items in
  /// the buffer, then this triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using
  /// a geometric growth rate. If the input sequence does not provide a precise
  /// estimate of its count, then the array's storage may need to be resized
  /// more than once.
  ///
  /// - Parameters:
  ///    - newElements: The new elements to copy into the array.
  ///
  /// - Complexity: O(*m*), where *m* is the length of `newElements`, when
  ///     amortized over many invocations over the same array.
  public mutating func append(copying newElements: some Sequence<Element>)
}
```

#### Insertions

```swift
extension [Rigid|Unique]Array where Element: ~Copyable {
  /// Inserts a new element into the array at the specified position.
  ///
  /// If the rigid array does not have sufficient capacity to hold any more elements,
  /// then this triggers a runtime error.
  ///
  /// If the unqieu array does not have sufficient capacity to hold any more elements,
  /// then this reallocates storage to extend its capacity, using a geometric
  /// growth rate.
  ///
  /// The new element is inserted before the element currently at the specified
  /// index. If you pass the array's `endIndex` as the `index` parameter, then
  /// the new element is appended to the container.
  ///
  /// All existing elements at or following the specified position are moved to
  /// make room for the new item.
  ///
  /// - Parameter item: The new element to insert into the array.
  /// - Parameter i: The position at which to insert the new element.
  ///   `index` must be a valid index in the array.
  ///
  /// - Complexity: O(`self.count`)
  public mutating func insert(_ item: consuming Element, at index: Int)

  /// Inserts a given number of new items into this array at the specified
  /// position, using a callback to directly initialize array storage by
  /// populating an output span.
  ///
  /// Existing elements in the array's storage are moved towards the back as
  /// needed to make room for the new items.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the specified
  /// number of new elements, then this method triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold the new elements,
  /// then this operation reallocates storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  ///     var buffer = RigidArray<Int>(capacity: 20)
  ///     buffer.append([-999, 999])
  ///     var i = 0
  ///     buffer.insert(capacity: 3, at: 1) { target in
  ///       while !target.isFull {
  ///         target.append(i)
  ///         i += 1
  ///       }
  ///     }
  ///     // `buffer` now contains [-999, 0, 1, 2, 999]
  ///
  /// If the callback fails to fully populate its output span or if
  /// it throws an error, then the array keeps all items that were
  /// successfully initialized before the callback terminated the insertion.
  ///
  /// Partial insertions create a gap in array storage that needs to be
  /// closed by moving already inserted items to their correct positions given
  /// the adjusted count. This adds some overhead compared to adding exactly as
  /// many items as promised.
  ///
  /// - Parameters:
  ///    - newItemCount: The maximum number of items to insert into the array.
  ///    - index: The position at which to insert the new items.
  ///       `index` must be a valid index in the array.
  ///    - initializer: A callback that gets called at most once to directly
  ///       populate newly reserved storage within the array. The function
  ///      is always called with an empty output span.
  ///
  /// - Complexity: O(`self.count` + `newItemCount`) in addition to the complexity
  ///    of the callback invocations.
  public mutating func insert<E: Error>(
    addingCount newItemCount: Int,
    at index: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)

  /// Moves the elements of a fully initialized buffer into this array,
  /// starting at the specified position, and leaving the buffer
  /// uninitialized.
  ///
  /// All existing elements at or following the specified position are moved to
  /// make room for the new items.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unqiue array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// - Parameters:
  ///    - items: A fully initialized buffer whose contents to move into
  ///        the array.
  ///    - index: The position at which to insert the new items.
  ///       `index` must be a valid index in the array.
  ///
  /// - Complexity: O(`self.count` + `items.count`)
  public mutating func insert(
    moving items: UnsafeMutableBufferPointer<Element>,
    at index: Int
  )

  /// Moves the elements of an output span into this array,
  /// starting at the specified position, and leaving the span empty.
  ///
  /// All existing elements at or following the specified position are moved to
  /// make room for the new items.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// - Parameters:
  ///    - items: An output span whose contents to move into
  ///        the array.
  ///    - index: The position at which to insert the new items.
  ///       `index` must be a valid index in the array.
  ///
  /// - Complexity: O(`self.count` + `items.count`)
  public mutating func insert(
    moving items: inout OutputSpan<Element>,
    at index: Int
  )
}

extension [Rigid|Unique]Array where Element: Copyable {
  /// Copyies the elements of a fully initialized buffer pointer into this
  /// array at the specified position.
  ///
  /// The new elements are inserted before the element currently at the
  /// specified index. If you pass the array’s `endIndex` as the `index`
  /// parameter, then the new elements are appended to the end of the array.
  ///
  /// All existing elements at or following the specified position are moved to
  /// make room for the new item.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the uniquearray does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// - Parameters:
  ///    - newElements: The new elements to insert into the array. The buffer
  ///       must be fully initialized.
  ///    - index: The position at which to insert the new elements. It must be
  ///       a valid index of the array.
  ///
  /// - Complexity: O(`self.count` + `newElements.count`)
  public mutating func insert(
    copying newElements: UnsafeBufferPointer<Element>, at index: Int
  )

  /// Copyies the elements of a fully initialized buffer pointer into this
  /// array at the specified position.
  ///
  /// The new elements are inserted before the element currently at the
  /// specified index. If you pass the array’s `endIndex` as the `index`
  /// parameter, then the new elements are appended to the end of the array.
  ///
  /// All existing elements at or following the specified position are moved to
  /// make room for the new item.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unqiue array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// - Parameters:
  ///    - newElements: The new elements to insert into the array. The buffer
  ///       must be fully initialized.
  ///    - index: The position at which to insert the new elements. It must be
  ///       a valid index of the array.
  ///
  /// - Complexity: O(`self.count` + `newElements.count`)
  public mutating func insert(
    copying newElements: UnsafeMutableBufferPointer<Element>,
    at index: Int
  )

  /// Copies the elements of a span into this array at the specified position.
  ///
  /// The new elements are inserted before the element currently at the
  /// specified index. If you pass the array’s `endIndex` as the `index`
  /// parameter, then the new elements are appended to the end of the array.
  ///
  /// All existing elements at or following the specified position are moved to
  /// make room for the new item.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// - Parameters:
  ///    - newElements: The new elements to insert into the array.
  ///    - index: The position at which to insert the new elements. It must be
  ///        a valid index of the array.
  ///
  /// - Complexity: O(`self.count` + `newElements.count`)
  public mutating func insert(
    copying newElements: Span<Element>, at index: Int
  )

  /// Copies the elements of a collection into this array at the specified
  /// position.
  ///
  /// The new elements are inserted before the element currently at the
  /// specified index. If you pass the array’s `endIndex` as the `index`
  /// parameter, then the new elements are appended to the end of the array.
  ///
  /// All existing elements at or following the specified position are moved
  /// to make room for the new item.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to hold enough elements,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// - Parameters:
  ///    - newElements: The new elements to insert into the array.
  ///    - index: The position at which to insert the new elements. It must be
  ///        a valid index of the array.
  ///
  /// - Complexity: O(`self.count` + `newElements.count`)
  public mutating func insert(
    copying newElements: some Collection<Element>, at index: Int
  )
}
```

#### Removals

```swift
extension [Rigid|Unique]Array where Element: ~Copyable {
  /// Removes and returns the last element of the array, if there is one.
  ///
  /// - Returns: The last element of the array if the array is not empty;
  ///    otherwise, `nil`.
  ///
  /// - Complexity: O(1)
  public mutating func popLast() -> Element?

  /// Removes all elements from the array, optionally preserving its
  /// allocated capacity.
  ///
  /// - Complexity: O(*n*), where *n* is the original count of the array.
  public mutating func removeAll(keepingCapacity keepCapacity: Bool = false)

  /// Removes and returns the last element of the array.
  ///
  /// The array must not be empty.
  ///
  /// - Returns: The last element of the original array.
  ///
  /// - Complexity: O(1)
  public mutating func removeLast() -> Element

  /// Removes and discards the specified number of elements from the end of the
  /// array.
  ///
  /// Attempting to remove more elements than exist in the array triggers a
  /// runtime error.
  ///
  /// - Parameter k: The number of elements to remove from the array.
  ///   `k` must be greater than or equal to zero and must not exceed
  ///    the count of the array.
  ///
  /// - Complexity: O(`k`)
  public mutating func removeLast(_ k: Int)

  /// Removes and returns the element at the specified position.
  ///
  /// All the elements following the specified position are moved to close the
  /// gap.
  ///
  /// - Parameter i: The position of the element to remove. `index` must be
  ///   a valid index of the array that is not equal to the end index.
  /// - Returns: The removed element.
  ///
  /// - Complexity: O(`self.count`)
  public mutating func remove(at index: Int) -> Element

  /// Removes the specified subrange of elements from the array.
  ///
  /// All the elements following the specified subrange are moved to close the
  /// resulting gap.
  ///
  /// - Parameter bounds: The subrange of the array to remove. The bounds
  ///   of the range must be valid indices of the array.
  ///
  /// - Complexity: O(`self.count`)
  public mutating func removeSubrange(_  bounds: Range<Int>)

  /// Removes the specified subrange of elements from the array.
  ///
  /// - Parameter bounds: The subrange of the array to remove. The bounds
  ///   of the range must be valid indices of the array.
  ///
  /// - Complexity: O(`self.count`)
  public mutating func removeSubrange(_  bounds: some RangeExpression<Int>)
}
```

#### Replacements

```swift
extension [Rigid|Unique]Array where Element: ~Copyable {
  /// Replaces the specified range of elements by a given count of new items,
  /// using a callback to directly initialize array storage by populating
  /// an output span.
  ///
  /// The number of new items need not match the number of elements being
  /// removed.
  ///
  /// This method has the same overall effect as calling
  ///
  ///     try array.removeSubrange(subrange)
  ///     try array.insert(
  ///       addingCount: newItemCount,
  ///       at: subrange.lowerBound,
  ///       initializingWith: initializer)
  ///
  /// Except it performs faster (by a constant factor), by avoiding moving
  /// some items in the array twice.
  ///
  /// If the rigid array does not have sufficient capacity to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unqiue array does not have sufficient capacity to perform the replacement,
  /// then this reallocates storage to extend its capacity, using a geometric
  /// growth rate.
  ///
  /// If the callback fails to fully populate its output span or if
  /// it throws an error, then the array keeps all items that were
  /// successfully initialized before the callback terminated the prepend.
  ///
  /// Partial insertions create a gap in array storage that needs to be
  /// closed by moving newly inserted items to their correct positions given
  /// the adjusted count. This adds some overhead compared to adding exactly as
  /// many items as promised.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the array to replace. The bounds of
  ///      the range must be valid indices in the array.
  ///   - newItemCount: the maximum number of items to replace the old subrange.
  ///   - initializer: A callback that gets called at most once to directly
  ///      populate newly reserved storage within the array. The function
  ///      is always called with an empty output span.
  ///
  /// - Complexity: O(`self.count` + `newItemCount`) in addition to the complexity
  ///    of the callback invocations.
  public mutating func replace<E: Error>(
    removing subrange: Range<Int>,
    addingCount newItemCount: Int,
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E) -> Void

  /// Replaces the specified range of elements by moving the elements of a
  /// fully initialized buffer into their place. On return, the buffer is left
  /// in an uninitialized state.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the array and inserting the new elements starting at the same
  /// location. The number of new elements need not match the number of elements
  /// being removed.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to perform the replacement,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// If you pass a zero-length range as the `subrange` parameter, this method
  /// inserts the elements of `newElements` at `subrange.lowerBound`. Calling
  /// the `insert(copying:at:)` method instead is preferred in this case.
  ///
  /// Likewise, if you pass a zero-length buffer as the `newElements`
  /// parameter, this method removes the elements in the given subrange
  /// without replacement. Calling the `removeSubrange(_:)` method instead is
  /// preferred in this case.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the array to replace. The bounds of
  ///     the range must be valid indices in the array.
  ///   - newElements: A fully initialized buffer whose contents to move into
  ///     the array.
  ///
  /// - Complexity: O(`self.count` + `newElements.count`)
  public mutating func replace(
    removing subrange: Range<Int>,
    moving newElements: UnsafeMutableBufferPointer<Element>,
  )

  /// Replaces the specified range of elements by moving the contents of an
  /// output span into their place. On return, the span is left empty.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the array and inserting the new elements starting at the same
  /// location. The number of new elements need not match the number of elements
  /// being removed.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the unique array does not have sufficient capacity to perform the replacement,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// If you pass a zero-length range as the `subrange` parameter, this method
  /// inserts the elements of `newElements` at `subrange.lowerBound`. Calling
  /// the `insert(moving:at:)` method instead is preferred in this case.
  ///
  /// Likewise, if you pass a zero-length buffer as the `newElements`
  /// parameter, this method removes the elements in the given subrange
  /// without replacement. Calling the `removeSubrange(_:)` method instead is
  /// preferred in this case.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the array to replace. The bounds of
  ///     the range must be valid indices in the array.
  ///   - items: An output span whose contents are to be moved into the array.
  ///
  /// - Complexity: O(`self.count` + `items.count`)
  public mutating func replace(
    removing subrange: Range<Int>,
    moving items: inout OutputSpan<Element>
  )
}

extension [Rigid|Unique]Array where Element: Copyable {
  /// Replaces the specified subrange of elements by copying the elements of
  /// the given buffer pointer, which must be fully initialized.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the array and inserting the new elements starting at the same location.
  /// The number of new elements need not match the number of elements being
  /// removed.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the capacity of the unique array isn't sufficient to perform the replacement,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// If you pass a zero-length range as the `subrange` parameter, this method
  /// inserts the elements of `newElements` at `subrange.lowerBound`. Calling
  /// the `insert(copying:at:)` method instead is preferred in this case.
  ///
  /// Likewise, if you pass a zero-length buffer as the `newElements`
  /// parameter, this method removes the elements in the given subrange
  /// without replacement. Calling the `removeSubrange(_:)` method instead is
  /// preferred in this case.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the array to replace. The bounds of
  ///     the range must be valid indices in the array.
  ///   - newElements: The new elements to copy into the collection.
  ///
  /// - Complexity: O(*n* + *m*), where *n* is count of this array and
  ///   *m* is the count of `newElements`.
  public mutating func replace(
    removing subrange: Range<Int>,
    copying newElements: UnsafeBufferPointer<Element>
  )

  /// Replaces the specified subrange of elements by copying the elements of
  /// the given buffer pointer, which must be fully initialized.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the array and inserting the new elements starting at the same location.
  /// The number of new elements need not match the number of elements being
  /// removed.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the capacity of the unqiue array isn't sufficient to perform the replacement,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// If you pass a zero-length range as the `subrange` parameter, this method
  /// inserts the elements of `newElements` at `subrange.lowerBound`. Calling
  /// the `insert(copying:at:)` method instead is preferred in this case.
  ///
  /// Likewise, if you pass a zero-length buffer as the `newElements`
  /// parameter, this method removes the elements in the given subrange
  /// without replacement. Calling the `removeSubrange(_:)` method instead is
  /// preferred in this case.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the array to replace. The bounds of
  ///     the range must be valid indices in the array.
  ///   - newElements: The new elements to copy into the collection.
  ///
  /// - Complexity: O(*n* + *m*), where *n* is count of this array and
  ///   *m* is the count of `newElements`.
  public mutating func replace(
    removing subrange: Range<Int>,
    copying newElements: UnsafeMutableBufferPointer<Element>
  )

  /// Replaces the specified subrange of elements by copying the elements of
  /// the given span.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the array and inserting the new elements starting at the same location.
  /// The number of new elements need not match the number of elements being
  /// removed.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the capacity of the unique array isn't sufficient to perform the replacement,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// If you pass a zero-length range as the `subrange` parameter, this method
  /// inserts the elements of `newElements` at `subrange.lowerBound`. Calling
  /// the `insert(copying:at:)` method instead is preferred in this case.
  ///
  /// Likewise, if you pass a zero-length span as the `newElements`
  /// parameter, this method removes the elements in the given subrange
  /// without replacement. Calling the `removeSubrange(_:)` method instead is
  /// preferred in this case.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the array to replace. The bounds of
  ///     the range must be valid indices in the array.
  ///   - newElements: The new elements to copy into the collection.
  ///
  /// - Complexity: O(*n* + *m*), where *n* is count of this array and
  ///   *m* is the count of `newElements`.
  public mutating func replace(
    removing subrange: Range<Int>,
    copying newElements: Span<Element>
  )

  /// Replaces the specified subrange of elements by copying the elements of
  /// the given collection.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the array and inserting the new elements starting at the same location.
  /// The number of new elements need not match the number of elements being
  /// removed.
  ///
  /// If the capacity of the rigid array isn't sufficient to accommodate the new
  /// elements, then this method triggers a runtime error.
  ///
  /// If the capacity of the unique array isn't sufficient to perform the replacement,
  /// then this reallocates the array's storage to extend its capacity, using a
  /// geometric growth rate.
  ///
  /// If you pass a zero-length range as the `subrange` parameter, this method
  /// inserts the elements of `newElements` at `subrange.lowerBound`. Calling
  /// the `insert(copying:at:)` method instead is preferred in this case.
  ///
  /// Likewise, if you pass a zero-length collection as the `newElements`
  /// parameter, this method removes the elements in the given subrange
  /// without replacement. Calling the `removeSubrange(_:)` method instead is
  /// preferred in this case.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the array to replace. The bounds of
  ///     the range must be valid indices in the array.
  ///   - newElements: The new elements to copy into the collection.
  ///
  /// - Complexity: O(*n* + *m*), where *n* is count of this array and
  ///   *m* is the count of `newElements`.
  public mutating func replace(
    removing subrange: Range<Int>,
    copying newElements: consuming some Collection<Element>
  )
}
```

#### Conformances

```swift
extension [Rigid|Unique]Array: Equatable where Element: Equatable & ~Copyable {
  public static func ==(left: borrowing Self, right: borrowing Self) -> Bool

  public func isTriviallyIdentical(to: borrowing Self) -> Bool
}

extension [Rigid|Unique]Array: Hashable where Element: Hashable & ~Copyable {}

extension [Rigid|Unique]Array: CustomStringConvertible where Element: ~Copyable {}

extension [Rigid|Unique]Array: CustomDebugStringConvertible where Element: ~Copyable {}

extension [Rigid|Unique]Array: BorrowingSequence where Element: ~Copyable {
  @lifetime(borrow self)
  func makeBorrowingIterator() -> SpanIterator<Element>
}
```

It's important to note that these array types will conform to the newly introduced
`BorrowingSequence` proposed [here](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md).
They will use the `SpanIterator` defined in that proposal as their iterators as
well.

### API _only_ on `RigidArray`

#### Basics

```swift
extension RigidArray where Element: ~Copyable {
  /// A Boolean value indicating whether this rigid array is fully populated.
  /// If this property returns true, then the array's storage is at capacity,
  /// and it cannot accommodate any additional elements.
  ///
  /// - Complexity: O(1)
  public var isFull: Bool {
    get
  }
}
```

#### Initializers

```swift
extension RigidArray where Element: ~Copyable {
  /// Creates a new array with the specified capacity, holding a copy
  /// of the contents of a given sequence.
  ///
  /// - Parameters:
  ///   - capacity: The storage capacity of the new array.
  ///   - contents: The sequence whose contents to copy into the new array.
  ///      The sequence must not contain more than `capacity` elements.
  public init(
    capacity: Int,
    copying contents: some Sequence<Element>
  )

  /// Creates a new array with the specified capacity, holding a copy
  /// of the contents of a given collection.
  ///
  /// - Parameters:
  ///   - capacity: The storage capacity of the new array, or nil to allocate
  ///      just enough capacity to store the contents.
  ///   - contents: The collection whose contents to copy into the new array.
  ///      The collection must not contain more than `capacity` elements.
  public init(
    capacity: Int? = nil,
    copying contents: some Collection<Element>
  )
}
```

#### Appends

```swift
extension RigidArray where Element: ~Copyable {
  /// Adds an element to the end of the array, if possible.
  ///
  /// If the array does not have sufficient capacity to hold any more elements,
  /// then this returns the given item without appending it; otherwise it
  /// returns nil.
  ///
  /// - Parameter item: The element to append to the array.
  /// - Returns: `item` if the array is full; otherwise nil.
  ///
  /// - Complexity: O(1)
  public mutating func pushLast(_ item: consuming Element) -> Element?
}
```

### API _only_ on `UniqueArray`

#### Initializers

```swift
extension UniqueArray where Element: ~Copyable {
  /// Creates a new array with the specified initial capacity, holding a copy
  /// of the contents of a given sequence.
  ///
  /// - Parameters:
  ///   - capacity: The storage capacity of the new array, or nil to allocate
  ///      just enough capacity to store the contents.
  ///   - contents: The sequence whose contents to copy into the new array.
  public init(
    capacity: Int? = nil,
    copying contents: some Sequence<Element>
  )
}
```

## Source compatibility

`RigidArray` and `UniqueArray` are new types within the standard library, so
source should still be compatible. For developers using these types from
[swift-collections](https://github.com/apple/swift-collections), those versions
of these types will still be preferred by the compiler due to the shadowing
rule for standard library type names.

## ABI compatibility

The API introduced in this proposal are purely additive to the standard library's
ABI; thus existing ABI is compatible.

## Implications on adoption

`RigidArray` and `UniqueArray` are new types within the standard library, so
adopters must use at least the version of Swift that introduced these types.
For developers using these types from
[swift-collections](https://github.com/apple/swift-collections), it may make
sense to continue using those versions of these types due to the backward
deployment nature of having the source from a package.

## Future directions

### `Clonable`

This proposal, like the [`UniqueBox`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0517-uniquebox.md)
proposal, introduces `clone()` (and `clone(capacity:)`) for both `RigidArray`
and `UniqueArray`. Clone is an explicit deep copy returning an owned array
instance for the caller. Note that this API currently requires
`Element: Copyable`, but this disallows nested 2d arrays
`UniqueArray<UniqueArray<Int>>` for example. As mentioned in the `UniqueBox`
proposal, there is a hidden protocol here `Cloneable` that would enable such
functionality:

```swift
public protocol Cloneable: ~Copyable {
  func clone() -> Self
}
```

### Rigid and Unique variants of other standard data structures

The [swift-collections](https://github.com/apple/swift-collections) package
defines other flavors of `Set` and `Dictionary` that correlate to the `Rigid`
and `Unique` semantics defined for the proposed array types here. There's also
`Deque` variants that would be a potentially welcome change to the standard
library as well.

* `RigidDeque` and `UniqueDeque`

* `RigidSet` and `UniqueSet`

* `RigidDictionary` and `UniqueDictionary`

### Container protocols

While this proposal does add the `BorrowingSequence` conformance for both of
the proposed array types, we still aren't ready to propose any container
protocols on top of it. [swift-collections](https://github.com/apple/swift-collections)
is currently exploring designs for such a protocol here: https://github.com/apple/swift-collections/blob/main/Sources/ContainersPreview/Protocols/Container.swift

### Literal initialization

The proposed array types are explicitly not `ExpressibleByArrayLiteral`
regardless of if the element is copyable or not. It feels strange that it would
work for some cases and not in others. We would need to overhaul the expressible
protocol for noncopyable elements since that protocol traffics in an `Array`
which can never support such elements. We could also do a macro based solution
that desugars to insertions.

## Alternatives considered

### Allocator arguments

Since we're proposing new array types, we have the unique (pun intended)
opportunity to allow these data structures to be allocated with custom allocators.

```swift
public struct UniqueArray<Element: ~Copyable, Alloc: Allocator>: ~Copyable {}
```

Adding an allocator generic argument is very reminiscent of how it works with
`std::vector` in C++ and `Vec` in Rust.

This approach would require an `Allocator` protocol that custom allocators could
conform to and provide some `SystemAllocator` that comes by default in the
standard library (similar to SystemRandomNumberGenerator):

```swift
protocol Allocator {
  func allocate<T>(_: T.Type) -> UnsafePointer<T>

  func deallocate<T>(_: UnsafePointer<T>)

  ...
}
```

However, this makes working with these types a little more awkward:

```swift
func foo(with x: borrowing Unique<Int>)

error: generic type 'UniqueArray' specialized with too few type parameters (got 1, but expected 2)
1 | protocol Allocator {}
2 | 
3 | struct UniqueArray<Element: ~Copyable, Alloc: Allocator>: ~Copyable {
  |        `- note: generic struct 'UniqueArray' declared here
4 | 
5 | }
6 | 
7 | func foo(with x: borrowing UniqueArray<Int>) {}
  |                            `- error: generic type 'UniqueArray' specialized with too few type parameters (got 1, but expected 2)
8 | 
```

You could alleviate this with `UniqueArray<Int, some Allocator>` (or an explicit
generic parameter), but you’ve made working with this type much harder than it
needs to be. C++ and Rust solve this particular issue with default values for
generic parameters. So in our original Unique definition we could have:

```swift
public struct UniqueArray<Element: ~Copyable, Alloc: Allocator = SystemAllocator>: ~Copyable
```

Which helps working with this type significantly. Again, this is reliant on
language features that unfortunately do not exist at the time.

All that said, some folks are very hesitant to add default generic parameters
for a few reasons:

* Forgetting to be generic over the allocator could lead to situations where you
provide API for only the system allocator (which isn’t that bad!). ABI stable
libraries wouldn’t be able to modify this function definition unless they
deprecate the old symbol and add a new one (or used `@export(implementation)` to
begin with).
* Default values for generic parameters could lead to a worse developer
experience especially when debugging stack traces. C++ is pretty infamous for
having ridiculously long specializations that while in source are easy to grok,
its output in a stack trace is less so.
* Being generic over an `Allocator` specifically means you now need to care about
the copyability of the allocator you’re storing. For `SystemAllocator`, it would
just be a zero sized type that is a wrapper over `UnsafeMutablePointer.allocate`
and deallocate, so we can easily copy it. However, in Rust especially there are
many places where API is only available when the allocator is clonable which
makes writing the most generic API possible a little more difficult. While the
folks on the standard library are happy to deal with these challenges, we can’t
guarantee that the community at a whole will. It’s very possible folks extending
`UniqueArray` (or other potential future collections) won’t deal with it and
just provide the API where `Alloc = SystemAllocator` which like I mentioned
earlier, is a great default.

