# RigidArray and UniqueArray

* Proposal: [SE-0527](0527-rigidarray-uniquearray.md)
* Authors: [Karoy Lorentey](https://github.com/lorentey), [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active Review (April 13...27, 2026)**
* Implementation: [swiftlang/swift#87521](https://github.com/swiftlang/swift/pull/87521)
* Review: ([pitch](https://forums.swift.org/t/pitch-rigidarray-and-uniquearray/85455))
          ([review](https://forums.swift.org/t/se-0527-rigidarray-and-uniquearray/85985))

[swift-collections]: https://github.com/apple/swift-collections

## Summary of changes

We propose to introduce two new array types to the Swift Standard Library,
`RigidArray` and `UniqueArray`, that are both capable of storing noncopyable
elements.

## Motivation

Swift 5.9 introduced noncopyable struct and enum types into the language and we've
steadily been adding new API that helps support such types. The Standard
Library has implemented noncopyable types of its own, like `Atomic` and `Mutex`,
as well as the `InlineArray` container type that allows storing values of 
potentially noncopyable types in inline storage. However, the Standard Library 
is still lacking resizable data structure implementations that 
support noncopyable elements.

As Swift developers, we reach for `Array` when we need to store a dynamically 
resizable list of values with efficient operations for accessing them. 
Unfortunately, the classic  `Array` does not support noncopyable values. There 
are two ways we could try to shoehorn support for noncopyable elements onto it: 

1. One idea is to keep `Array` copyable, and tweak its mutation operations to 
   ensure uniqueness in some way other than copying noncopyable elements. 
   For example, we could have mutations trigger a runtime error, or we could add
   new arguments to mutations that describe specifically how to clone elements. 
   In practice, neither of these options lead to an acceptable programming 
   experience.

2. A (superficially) more attractive idea would be to make `Array` 
   _conditionally copyable_, depending on the copyability of its elements. 
   Mutation operations would then need to gain an additional runtime condition 
   that dispatches to  the copy-on-write path if and only if `Element` happens 
   to be copyable,  otherwise assuming uniqueness. There are two technical 
   issues here: 

    1. Swift code is currently unable to check whether a type argument is 
       copyable at runtime, and conditionally copy instances if so.
    2. The need for such a "conformance" check would add potential overhead to 
       every array mutation.
    
   The first problem is resolvable, but the second would be a difficult one to 
   swallow -- especially as it would particularly impact generic 
   contexts that allow `Element` to be noncopyable. The check for
   copyability needs to be a runtime condition in such contexts: we cannot have 
   `append` assume unique storage just because it is invoked in a context that 
   _allows_ noncopyable elements. Even if we decide to spend resources on 
   improving the optimizer in this area, it wouldn't possible to optimize the 
   condition away in every case, and consulting the Swift runtime every time
   a function needs to mutate an array instance seems unlikely to be acceptable.

Obviously, making `Array`'s performance even more tricky to analyze than it
already is would work directly against the goals of the 
[Swift Ownership Manifesto][ownership-manifesto], which led to the introduction
of noncopyable types in the first place. Our goal is not just to have an array
of noncopyables -- we need to do it with predictably good performance that is
easy to analyze. 

[ownership-manifesto]: https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md

Beyond its inherent lack of support for noncopyable elements, `Array` has two 
major sources of unpredictable complexity spikes that make it unpalatable to 
performance-minded use cases:

1. `Array` has **copy-on-write value semantics**, and it's relatively easy to 
   mutate a shared copy by accident. Every time we do that, the operation needs 
   to allocate a full copy of the entire array, turning even "usually" 
   constant-complexity operations like a simple subscript reassignment into 
   linear-complexity monsters. Use cases that cannot accept such irregular 
   performance spikes need to carefully avoid making copies, and 
   there is no indication if/when they get it wrong.

2. `Array` is a **dynamic data structure**: it implicitly resizes itself as needed 
   to accommodate the items added to it. This resizing is done by allocating a 
   brand new buffer of the appropriate size, and copying or moving all existing 
   elements into it. This happens automatically, and it leaves no mark in the 
   source: the "same" `append` invocation will run in constant space and time 
   in most cases, but once in a blue moon it triggers resizing and it suddenly 
   becomes linear. The geometric growth pattern ensures that `append` will still 
   average out into "amortized" O(1) complexity, but its _actual_ worse-case 
   complexity is O(`count`). Use cases that cannot accept such irregular 
   performance spikes need to go out of their way to reserve enough capacity in 
   advance, and getting it wrong leads to no obvious error.

These two features aren't inherently wrong -- in fact, they both have highly 
desirable benefits, as they greatly simplify Swift's programming model. When 
using `Array`, its copy-on-write value semantics means that copies can be 
cheaply made, and functions are empowered to hold onto array instances whenever 
they want, without having to change their interface, or even letting the caller 
know about it. Similarly, dynamic sizing lets us avoid having to constantly
think about what how much memory an operation will need to do its job.

However, when we use Swift in contexts where we need to ensure 
reliably high performance, then these features tend to get in the way of 
achieving that, by making it significantly more difficult to analyze or
guarantee how the code will behave at runtime. 

Complicating `Array` by bolting even more features onto it is not going to let 
us succeed here; what we actually need are _additional_ array implementations 
that are optimized specifically for use cases that require more predictable 
performance than what `Array` can provide. (Having several implementations for
the same underlying data structure is not a radical idea; indeed, the Standard
Library's own `ContiguousArray` and `Foundation`'s `NSArray` are preexisting
resizable array types, doing away with `Array` features that are undesirable in 
some contexts: Objective-C bridging and value semantics, respectively.)   

But how many new array types do we need? The two features above are technically 
orthogonal to each other, and we could independently turn them on or off as 
needed. This suggests four hypothetical array variants, with one of them being 
the existing `Array` type:

| | **Noncopyable** | **Copy-on-write** |
| ---: | :---: | :---: |
| **Fixed capacity** | ??? | ??? |
| **Dynamic** | ??? | `Array` |

The primary reason to reach for a fixed-capacity data structure is to avoid 
implicit allocations, but copy-on-write behavior would be in direct conflict 
with that. This means we can leave the top right corner empty, leaving us with
this table.

| | **Noncopyable** | **Copy-on-write** |
| ---: | :---: | :---: |
| **Fixed capacity** | ??? | --- |
| **Dynamic** | ??? | `Array` |

## Proposed solution

We propose to add two new array types to the Swift Standard Library: 
`RigidArray` and `UniqueArray`. 

Both of these are true array types, providing familiar array operations: we can 
append, insert, replace, remove elements, reorder them in arbitrary ways, and 
quickly access their contents using integer offsets as indices. They both use
a single, heap-allocated, contiguous memory region as storage, allowing it to 
be partially initialized, with initialized items collected at the front -- in a 
nutshell, they implement the classic variable-sized array data structure, just 
like the preexisting `Array` and `ContiguousArray` types.

These types come included in a new module in the Swift toolchain named
`Containers`. Like `Collections` from [swift-collections], this module will be
a home for future data structure implementations like ring buffers. More
examples of potential data structures are included in
[future directions](#Rigid-and-unique-variants-of-other-standard-data-structures).

### `UniqueArray`

`UniqueArray` is a great choice for general high-performance contexts where we
want to avoid using copy-on-write containers, but we aren't overly concerned 
about strictly budgeting memory, and we just want a simple, dynamically 
resizing array type, along the lines of `std::vector` in C++, or `Vec` in Rust.

`UniqueArray` gives us an `Array` variant whose storage is always 
_uniquely held_. This is statically enforced, by declaring `UniqueArray` as a
noncopyable type: a `UniqueArray` itself can only ever be held by 
a single variable (stored property, local variable, function argument,
etc) at any one time, and it can only be mutated through that single variable.
It is possible to move the array to another variable, but this consumes the 
original, rendering it unusable/uninitialized. For example, the `var b = a` 
statement in the example below is a move operation, not a copy:  

```swift
import Containers

struct FileHandle: ~Copyable {
  let fd: UInt32

  init(reading path: String) throws { fd = try open(path, .read) }

  deinit {
    try! close(fd)
  }
}

let foo = try FileHandle(reading: "foo.txt")
let bar = try FileHandle(reading: "bar.md")

var a = UniqueArray<FileHandle>()
a.append(foo) // OK, consumes `foo`
a.append(bar) // OK, consumes `bar`

var b = a // OK, consumes `a`, moving the array instance into `b`

b.append(try FileHandle(reading: "baz.swift")) // OK
// `b` now contains open handles for foo.txt, bar.md, and baz.swift

a.append(try FileHandle(reading: "Info.plist")) // error: `a` used after consume (used here)
```

By virtue of being noncopyable itself, `UniqueArray` is naturally able to hold
noncopyable elements like the (strictly illustrative) file handles in the 
example above. Array operations that take elements have been carefully designed
to take ownership into account, and they have been annotated with 
`consuming` or `borrowing` keywords to explain how they interact with element 
ownership. 

As expected of any proper dynamically resizing container, `UniqueArray` relies 
on a geometric growth curve to ensure acceptable (amortized) performance: when 
it needs to resize itself, it does so by multiplying its previous capacity by 
some constant factor, rather than simply growing itself linearly to cover the 
operation at hand. The growth factor is an internal implementation detail and
it is subject to change between environments, platforms and Swift releases; it 
is not user-configurable. 

### `RigidArray`  

For the lowest-level use cases (such as core systems programming, 
memory-constrained embedded platforms, or realtime contexts), `UniqueArray` is 
not quite enough: we also have a clear need for a fixed-capacity noncopyable 
array type.

For example, when we are trying to write Swift code for an environment where 
available memory is measured in _kilobytes_, we want every allocation to be 
explicit in the source, so that we are forced to precisely account and budget 
for it. In these contexts, there is no room for container types that helpfully 
resize or copy their storage whenever they feel like it -- we are quite happy 
to give up that flexibility in exchange for careful, pedantic control. 
`RigidArray` is intended to cater to such use cases; its name reflects its 
inflexible, _rigid_ nature. 

`RigidArray` instances are always allocated with a specific capacity, and they 
must operate entirely within that. Consequently, they can become full, when 
they are no longer able to accommodate any new items. Attempting to add a new 
value to a full `RigidArray` results in a runtime trap:

```swift
var c = RigidArray<Int>(capacity: 2)
print(c.isFull)       // => false
print(c.freeCapacity) // => 2

c.append(23)
print(c.isFull)       // => false
print(c.freeCapacity) // => 1

c.append(42)
print(c.isFull)       // => true
print(c.freeCapacity) // => 0

c.append(7) // runtime error: RigidArray capacity overflow 
```

Treating this as a precondition violation rather than a recoverable error allows
`RigidArray` to provide the same basic operations as `UniqueArray`. This 
preserves a path towards unifying them under [an ownership-aware 
`RangeReplaceableCollection`-like abstraction][RangeReplaceableContainer]. It 
also avoids the need to over-complicate `RigidArray`'s operations by forcing 
them to report failure in some recoverable way. 

[RangeReplaceableContainer]: https://github.com/apple/swift-collections/blob/1.4.1/Sources/ContainersPreview/Protocols/Container/RangeReplaceableContainer.swift

In practice, overflowing `RigidArray` storage indeed feels like a programmer 
error: it indicates a misuse of the type, rather than a routine issue. Trying to
remove the last item from an empty `Array` results in a trap -- and so trying 
to append one to a full `RigidArray` also naturally results in one.

While `RigidArray` never resizes itself automatically, its capacity is not
actually part of its type: rigid array instances are in fact arbitrarily 
resizable using a `reallocate` operation that can be explicitly invoked
to grow (or shrink) the array's storage: 

```swift
var d = RigidArray<Int>(capacity: 2)
d.append(10)
d.append(20)
print(d.isFull)       // => true
print(d.freeCapacity) // => 0

d.reallocate(capacity: 10)
print(d.isFull)       // => false
print(d.freeCapacity) // => 8

d.append(30) // OK!
```

The array allocates precisely as much storage as requested -- neither more nor 
less. This operation lets us use `RigidArray` to implement wrapper types that 
implement arrays with arbitrary, custom resizing logic. In fact, `UniqueArray`
is itself implemented as such.


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
@frozen
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
@frozen
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

  public func isTriviallyIdentical(to: borrowing Self) -> Bool

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
  ///    set to the resulting position.
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
  /// If the unique array does not have sufficient capacity to hold any more
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
  /// If the unique array does not have sufficient capacity to hold the requested
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
  /// If the unique array does not have sufficient capacity to hold enough elements,
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
  /// If the unique array does not have sufficient capacity to hold any more elements,
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
  /// If the unique array does not have sufficient capacity to hold enough elements,
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
  /// Copies the elements of a fully initialized buffer pointer into this
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

  /// Copies the elements of a fully initialized buffer pointer into this
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
  /// If the unique array does not have sufficient capacity to hold enough elements,
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
  /// If the unique array does not have sufficient capacity to perform the replacement,
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
}

extension [Rigid|Unique]Array: Hashable where Element: Hashable & ~Copyable {
  public func hash(into hasher: inout Hasher)
}

extension [Rigid|Unique]Array: CustomStringConvertible where Element: ~Copyable {
  public var description: String { get }
}

extension [Rigid|Unique]Array: CustomDebugStringConvertible where Element: ~Copyable {
  public var debugDescription: String { get }
}

extension [Rigid|Unique]Array: BorrowingSequence where Element: ~Copyable {
  @lifetime(borrow self)
  func makeBorrowingIterator() -> SpanIterator<Element>
}
```

Note that these array types will conform to the newly introduced
`BorrowingSequence` proposed in [SE-0516]. They will use the `SpanIterator` 
defined in that proposal as their iterators.

[SE-0516]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0516-borrowing-sequence.md

While this proposal lists conformances to `CustomStringConvertible` and 
`CustomDebugStringConvertible`, these conformances can only be shipped once
[SE-0499] gets implemented. Meanwhile, the types still provide (for now, rudimentary) 
implementations of the two `description` properties.

[SE-0499]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0499-support-non-copyable-simple-protocols.md

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

#### Removals

```swift
extension RigidArray where Element: ~Copyable {
  /// Removes all elements from the array, preserving its allocated capacity.
  ///
  /// - Complexity: O(*n*), where *n* is the original count of the array.
  @inlinable
  public mutating func removeAll()
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

  /// Initializes a new unique array with the specified capacity and no elements.
  public init(minimumCapacity: Int)
}
```

#### Removals

```swift
extension UniqueArray where Element: ~Copyable {
  /// Removes all elements from the array, optionally preserving its
  /// allocated capacity.
  ///
  /// - Complexity: O(*n*), where *n* is the original count of the array.
  public mutating func removeAll(keepingCapacity keepCapacity: Bool = false)
}
```


## Source compatibility

`RigidArray` and `UniqueArray` are new types within the Standard Library; adding
them is a source compatible change. Developers who currently import these 
types from [swift-collections] (or define their own types with the same names), 
the imported/custom types will still work, due to the shadowing rule for 
Standard Library type names.

## ABI compatibility

This proposal is purely additive to the Standard Library's ABI; the addition 
does not break any existing binary.

The types are proposed to be frozen; this prevents future changes to their 
representation. (This may be relevant for `UniqueArray`, which may want to 
keep track of its reserved capacity to implement shrinking.)

## Implications on adoption

`RigidArray` and `UniqueArray` are new types within the Standard Library, so
adopters must use at least the version of Swift that introduced these types.
For developers using these types from
[swift-collections](https://github.com/apple/swift-collections), it may make
sense to continue using those versions of these types due to the backward
deployment nature of having the source from a package.

## Future directions

### `Clonable`

This proposal, like the [`UniqueBox`][UniqueBox]
proposal, introduces `clone()` (and `clone(capacity:)`) for both `RigidArray`
and `UniqueArray`. Clone is an explicit deep copy returning an owned array
instance for the caller. Note that this API currently requires
`Element: Copyable`, but this disallows nested 2d arrays
`UniqueArray<UniqueArray<Int>>` for example. As mentioned in the `UniqueBox`
proposal, there is room for a potential `Clonable` protocol here that would 
enable such functionality:

[UniqueBox]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0517-uniquebox.md

```swift
public protocol Cloneable: ~Copyable {
  func clone() -> Self
}
```

### Rigid and unique variants of other standard data structures

The `Rigid` and `Unique` naming prefixes proposed by this proposal are 
intended to establish a general naming pattern for container types with similar
behavior.

The [swift-collections] package
defines `RigidDeque` and `UniqueDeque` types, implementing ring buffers with
the same semantics (and intended target audience) as `RigidArray` and 
`UniqueArray`. The package also comes with ownership-aware prototypes of the 
standard hashed `Set` and `Dictionary` container types, also using the `Rigid`
and `Unique` prefixes this way.

`RigidDeque`, `UniqueDeque`, `RigidSet`, `UniqueSet`, `RigidDictionary` and 
`UniqueDictionary` are all potential future additions to the Swift Standard 
Library.

### Container protocols

While this proposal does add the `BorrowingSequence` conformance for both of
the proposed array types, we still aren't ready to propose any container
protocols on top of it. [swift-collections]
is currently [exploring design approaches for such abstractions][containers]

[containers]: https://github.com/apple/swift-collections/tree/1.4.1/Sources/ContainersPreview/Protocols/Container

### Literal initialization

The proposed array types do not conform to `ExpressibleByArrayLiteral`,
regardless of whether the element is copyable or not. The existing protocol is 
built around the construction of an `Array` instance through a variadic 
initializer; this does not (easily) lend itself to generalization, and forcing
`RigidArray`/`UniqueArray` initialization to go through a temporary `Array` 
instance would not satisfy the performance goals of these types, even if
the conformance would be restricted to copyable elements.

One potentially workable way to reformulate array literal initialization 
would be to express it in terms of the in-place initialization 
of storage, through populating `OutputSpan` instances over the target type's 
storage buffer(s):

```swift
protocol ArrayLiterable: ~Copyable {
  associatedtype ArrayLiteralElement: ~Copyable

  init<E: Error>(
    arrayLiteralCount count: Int, 
    initializingWith initializer: (inout OutputSpan<Element>) throws(E) -> Void
  ) throws(E)
}
```

In this approach, an array initialization expression like `[a, b, c, d]` in 
type context `T` would get expanded into something like the following 
pseudocode: 

```swift
T(arrayLiteralCount: 4) { target in
  target.append(a)
  target.append(b)
  target.append(c)
  target.append(d)
}
```

(This assumes that T has contiguous storage. Allow the initialization of potentially 
discontiguous target storage is a little trickier, involving an inline array
of item-returning functions.)

Exploring this or other approaches is expected to be the subject of subsequent
work. 

## Alternatives considered

### Allocator arguments and similar configuration knobs

Since we're proposing new array types, we have the unique (pun intended)
opportunity to allow these data structures to be allocated with custom allocators.

```swift
public struct UniqueArray<Element: ~Copyable, Alloc: Allocator>: ~Copyable {}
```

Adding an allocator generic argument is very reminiscent of how container types
work in C++ and Rust.

This approach would require an `Allocator` protocol that custom allocators could
conform to and provide some `SystemAllocator` that comes by default in the
Standard Library (similar to SystemRandomNumberGenerator):

```swift
protocol Allocator {
  func allocate<T>(_: T.Type) -> UnsafeMutablePointer<T>

  func deallocate<T>(_: UnsafeMutablePointer<T>)

  ...
}
```

A similar idea would be for `UniqueArray` to support custom growth/shrink rates
by taking a type argument describing these parameters, perhaps by rolling these
into static property requirements in a refinement of the `Allocator` protocol. 

However, such type arguments make working with these types quite a bit more 
awkward:

```swift
func foo(_ x: borrowing UniqueArray<Int>)
// error: generic type 'UniqueArray' specialized with too few type parameters (got 1, but expected 2)
```

C++ and Rust solve this particular issue by allowing generic type parameters
to provide default values. So in our original Unique definition we could have:

```swift
public struct UniqueArray<Element: ~Copyable, Alloc: Allocator = SystemAllocator>: ~Copyable {
  init(allocator: Alloc) { ... }
}

extension UniqueArray where Allocator == SystemAllocator {
  init() { self.init(allocator: SystemAllocator()) }
}
```

At first glance, this would let us to work with such types with minimal pain. 
However, this assumes the implementation of a major new language feature that 
does not currently exist.

But an even worse issue has to do with the function `foo(_:)` above. With 
default type arguments, it would indeed become a valid declaration; but it would
typically overconstrain its parameter by requiring it to use the system 
allocator. In fact, that is generally the wrong choice! Functions that borrow
a unique array have no reason to care what allocator it uses, as they have no
way to mutate them anyway. `foo` would need to become generic:

```swift
func foo(_ x: borrowing UniqueArray<Int, some Allocator>)
```

So we'd effectively have to spell out the allocator arguments anyway, with the
extra twist of a new undiagnosed issue if we forget to do that.

For functions that want to consume or mutate arrays, these allocator arguments
would often need to be named and propagated throughout the code base, 
polluting interface definitions and obfuscating work. 
Indeed, such viral type argument pollution is a frequent complaint of C++ 
programmers. 

Generic type configuration parameters would lead to a worse developer
experience when debugging code unless we implement major debugger improvements, 
as stack traces would spell out the full type names, including defaulted 
arguments. (This is also a frequent issue with C++.)

The `Allocator` abstraction also raises the question of whether conforming 
implementations need to be copyable, whether their allocate/deallocate methods 
are marked mutating (and therefore incompatible with concurrent use), and 
how exactly we expect Swift programmers to implement allocators, anyway. Perhaps
most crucially, allocators traffic in unsafe pointers -- they would be a very
prominent plot hole in Swift's memory safety story.  

### Making `RigidArray`/`UniqueArray` share their storage representation with `Array`

As `UniqueArray` is simply a thin wrapper type around a `RigidArray` instance,
their instances are trivially cross-convertible: we can turn a `RigidArray` into
`UniqueArray` (or vice versa) with 𝛩(1) complexity initializers.

It would be wonderful if the classic `Array` type would also be part of this
cross-convertible family. Unfortunately, `Array`'s storage representation is 
part of its ABI, and is not amenable to changes. It would be inappropriate
for `RigidArray`/`UniqueArray` to borrow the same representation, as it was built
around a particular generic class with tail-allocated storage. Using the same
representation would introduce unnecessary performance overhead in the new 
low-level types, making them less competitive with similar types in competing
systems programming languages. Therefore, converting an `Array` instance to
one of the new types (or vice versa) requires copying/moving elements to newly
allocated storage in linear time. We do not expect this will be a major issue
in practice.

### Generalizing `Array` to support noncopyable elements

The authors consider copy-on-write value semantics to be a major feature of 
`Array` and its fellow standard Collection types, and of Swift itself. We 
currently believe that the idea of dismantling this feature by allowing `Array` 
to become conditionally noncopyable (or otherwise conditionalizing its 
copy-on-write behavior) would in fact be working against the goals of Swift's 
Ownership Manifesto, and it would be wholly impractical in practice.

Any such work would also not negate the need for dedicated the fixed-capacity and
guaranteed-noncopyable array variants that we propose in this document, either: 
it would not be appropriate to force developers to use the dynamically 
resizing, copy-on-write `Array` type just because their `Element` happens to be 
copyable. There is real, pressing need for a `RigidArray` of integers, or a 
`UniqueArray` of floats, whether or not `Array` eventually ends up supporting 
noncopyable contents. That said, this proposal does nothing to rule out such 
work in the future.   

### Move these types into the default Swift module

We don't feel as if these types should be included in the default namespace of
Swift programmers because `Array` should still be everyone's first choice. The
inclusion of these array types do not supersede `Array`, but are merely
alternative tools when working in more constrained environments.
