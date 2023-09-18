# Low-Level Atomic Operations ⚛︎

* Proposal: [SE-NNNN](NNNN-atomics.md)
* Author: [Karoy Lorentey](https://github.com/lorentey), [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: TBD
* Bug: [SR-9144](https://github.com/apple/swift/issues/51640)
* Implementation: N/A
* Version: 2023-09-18
* Status: **Awaiting review**

<!--
*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction

This proposal adds a limited set of low-level atomic operations to the Standard Library, including native spellings for C++-style memory orderings. Our goal is to enable intrepid library authors and developers writing system level code to start building synchronization constructs directly in Swift.

Previous Swift-evolution thread: [Low-Level Atomic Operations](https://forums.swift.org/t/low-level-atomic-operations/34683)

New Swift-evolution thread: [Atomics]()

## Revision History

- 2020-04-13: Initial proposal version.
- 2020-06-05: Second revision.
  - Removed all new APIs; the proposal is now focused solely on C interoperability.
- 2023-09-18: Third revision.
  - Introduced new APIs to the standard library.

## Table of Contents

  * [Motivation](#motivation)
  * [Proposed Solution](#proposed-solution)
    * [The Synchronization Module](#the-synchronization-module)
    * [Atomic Memory Orderings](#atomic-memory-orderings)
    * [The Atomic Protocol Hierarchy](#the-atomic-protocol-hierarchy)
      * [Optional Atomics](#optional-atomics)
      * [Custom Atomic Types](#custom-atomic-types)
    * [DoubleWord](#doubleword)
    * [The Atomic type](#the-atomic-type)
    * [Basic Atomic Operations](#basic-atomic-operations)
    * [Specialized Integer Operations](#specialized-integer-operations)
    * [Specialized Boolean Operations](#specialized-boolean-operations)
    * [Atomic Lazy References](#atomic-lazy-references)
    * [Restricting Ordering Arguments to Compile\-Time Constants](#restricting-ordering-arguments-to-compile-time-constants)
  * [Interaction with Existing Language Features](#interaction-with-existing-language-features)
    * [Interaction with Swift Concurrency](#interaction-with-swift-concurrency)
  * [Detailed Design](#detailed-design)
    * [Atomic Memory Orderings](#atomic-memory-orderings-1)
    * [Atomic Protocols](#atomic-protocols)
      * [AtomicStorage](#atomicstorage)
      * [AtomicValue](#atomicvalue)
    * [DoubleWord](#doubleword-1)
    * [Atomic Types](#atomic-types)
      * [Atomic&lt;Value&gt;](#atomicvalue-1)
      * [AtomicLazyReference&lt;Instance&gt;](#atomiclazyreferenceinstance)
  * [Source Compatibility](#source-compatibility)
  * [Effect on ABI Stability](#effect-on-abi-stability)
  * [Effect on API Resilience](#effect-on-api-resilience)
  * [Potential Future Directions](#potential-future-directions)
    * [Atomic Strong References and The Problem of Memory Reclamation](#atomic-strong-references-and-the-problem-of-memory-reclamation)
    * [Additional Low\-Level Atomic Features](#additional-low-level-atomic-features)
  * [Alternatives Considered](#alternatives-considered)
    * [Default Orderings](#default-orderings)
    * [A Truly Universal Generic Atomic Type](#a-truly-universal-generic-atomic-type)
    * [Providing a value Property](#providing-a-value-property)
    * [Alternative Designs for Memory Orderings](#alternative-designs-for-memory-orderings)
      * [Encode Orderings in Method Names](#encode-orderings-in-method-names)
      * [Orderings As Generic Type Parameters](#orderings-as-generic-type-parameters)
      * [Ordering Views](#ordering-views)
    * [Directly bring over `swift-atomics`'s API](#directly-bring-over-swift-atomicss-api)
  * [References](#references)

## Motivation

In Swift today, application developers use Swift's recently accepted concurrency features including async/await, structured concurrency with Task and TaskGroup, AsyncSequence/AsyncStream, etc. as well as dispatch queues and Foundation's NSLocking protocol to synchronize access to mutable state across concurrent threads of execution.

However, for Swift to be successful as a systems programming language, it needs to also provide low-level primitives that can be used to implement such synchronization constructs (and many more!) directly within Swift. Such low-level synchronization primitives allow developers more flexible ways to synchronize access to specific properties or storage allowing them to opt their types into Swift conconcurrency by declaring their types `@unchecked Sendable`. Of course these low-level primitives also allow library authors to build more high level synchronization structures that are both easier and safer to use that developers can also utilize to synchronize memory access.

One such low-level primitive is the concept of an atomic value, which (in the form we propose here) has two equally important roles:

- First, atomics introduce a limited set of types whose values provide well-defined semantics for certain kinds of concurrent access. This includes explicit support for concurrent mutations -- a concept that Swift never supported before.

- Second, atomic operations come with explicit memory ordering arguments, which provide guarantees on how/when the effects of earlier or later memory accesses become visible to other threads. Such guarantees are crucial for building higher-level synchronization abstractions.

These new primitives are intended for people who wish to implement synchronization constructs or concurrent data structures in pure Swift code. Note that this is a hazardous area that is full of pitfalls. While a well-designed atomics facility can help simplify building such tools, the goal here is merely to make it *possible* to build them, not necessarily to make it *easy* to do so. We expect that the higher-level synchronization tools that can be built on top of these atomic primitives will provide a nicer abstraction layer.

We want to limit this proposal to constructs that satisfy the following requirements:

1. All atomic operations need to be explicit in Swift source, and it must be possible to easily distinguish them from regular non-atomic operations on the underlying values.

2. The atomic type we provide must come with a lock-free implementation on every platform that implements them. (Platforms that are unable to provide lock-free implementations must not provide the affected constructs at all.)

3. Every atomic operation must compile down to the corresponding CPU instruction (when one is available), with minimal overhead. (Ideally even if the code is compiled without optimizations.) Wait-freedom isn't a requirement -- if no direct instruction is available for an operation, then it must still be implemented, e.g. by mapping it to a compare-exchange loop.

Following the acceptance of [Clarify the Swift memory consistency model (SE-0282)](https://github.com/apple/swift-evolution/blob/main/proposals/0282-atomics.md), the [swift-atomics package](https://github.com/apple/swift-atomics) was shortly created to experiment and design what a standard atomic API would look like. This proposal is relying heavily on some of the ideas that package has spent years developing and designing.

## Proposed Solution

We propose to introduce new low-level atomic APIs to the standard library via a new module. These atomic APIs will serve as the foundation for building higher-level concurrent code directly in Swift.

As a quick taste, this is how atomics will work:

```swift
import Synchronization
import Dispatch

let counter = Atomic<Int>(0)

DispatchQueue.concurrentPerform(iterations: 10) { _ in
  for _ in 0 ..< 1_000_000 {
    counter.wrappingIncrement(ordering: .relaxed)
  }
}

print(counter.load(ordering: .relaxed))
```

### The Synchronization Module

While most Swift programs won't directly use the new atomic primitives, we still consider the new constructs to be an integral part of the core Standard Library.

 * The implementation of atomic operations needs access to compiler intrinsics that are only exposed to the Standard Library.
 * The memory orderings introduced here define a concurrency memory model for Swift code that has implications on the language as a whole. (Fortunately, Swift is already designed to interoperate with the C/C++ memory model, so introducing a subset of C++ memory orderings in the Standard Library doesn't by itself require language-level changes.)

That said, it seems highly undesirable to add low-level atomics to the default namespace of every Swift program, so we propose to place the atomic constructs in a new Standard Library module called `Synchronization`. Code that needs to use low-level atomics will need to explicitly import the new module:

```swift
import Synchronization
```

We expect that most Swift projects will use atomic operations only indirectly, through higher-level synchronization constructs. Therefore, importing the Synchronization module will be a relatively rare occurrence, mostly limited to projects that implement such tools.

### Atomic Memory Orderings

The atomic constructs later in this proposal implement concurrent read/write access by mapping to atomic instructions in the underlying architecture. All accesses of a particular atomic value get serialized into some global sequential timeline, no matter what thread executed them.

However, this alone does not give us a way to synchronize accesses to regular variables, or between atomic accesses to different memory locations. To support such synchronization, each atomic operation can be configured to also act as a synchronization point for other variable accesses within the same thread, preventing previous accesses from getting executed after the atomic operation, and/or vice versa. Atomic operations on another thread can then synchronize with the same point, establishing a strict (although partial) timeline between accesses performed by both threads. This way, we can reason about the possible ordering of operations across threads, even if we know nothing about how those operations are implemented. (This is how locks or dispatch queues can be used to serialize the execution of arbitrary blocks containing regular accesses to shared variables.) For more details, see \[[C++17], [N2153], [Boehm 2008]].

In order to enable atomic synchronization within Swift, we must first introduce memory orderings who will give us control of the timeline of these operations across threads. Luckily, with the acceptance of [Clarify the Swift memory consistency model (SE-0282)](https://github.com/apple/swift-evolution/blob/main/proposals/0282-atomics.md), Swift already adopts the C/C++ concurrency memory model. In this model, concurrent access to shared state remains undefined behavior unless all such access is forced into a conflict-free timeline through explicit synchronization operations.

This proposal introduces five distinct memory orderings, organized into three logical groups, from loosest to strictest:

* `.relaxed`
* `.acquiring`, `.releasing`, `.acquiringAndReleasing`
* `.sequentiallyConsistent`

These align with select members of the standard `std::memory_order` enumeration in C++, and are intended to carry the same semantic meaning:

|             C++             |            Swift            |
|             :---:           |            :---:            |
| `std::memory_order_relaxed` |         `.relaxed`          |
| `std::memory_order_consume` | *not yet adopted [[P0735]]* |
| `std::memory_order_acquire` |        `.acquiring`         |
| `std::memory_order_release` |        `.releasing`         |
| `std::memory_order_acq_rel` |  `.acquiringAndReleasing`   |
| `std::memory_order_seq_cst` |  `.sequentiallyConsistent`  |

Atomic orderings are grouped into three frozen structs based on the kind of operation to which they are attached, as listed below. By modeling these as separate types, we can ensure that unsupported operation/ordering combinations (such as an atomic "releasing load") will lead to clear compile-time errors:

```swift
/// Specifies the memory ordering semantics of an atomic load operation.
public struct AtomicLoadOrdering {
  public static var relaxed: Self { get }
  public static var acquiring: Self { get }
  public static var sequentiallyConsistent: Self { get }
}

/// Specifies the memory ordering semantics of an atomic store operation.
public struct AtomicStoreOrdering {
  public static var relaxed: Self { get }
  public static var releasing: Self { get }
  public static var sequentiallyConsistent: Self { get }
}

/// Specifies the memory ordering semantics of an atomic read-modify-write
/// operation.
public struct AtomicUpdateOrdering {
  public static var relaxed: Self { get }
  public static var acquiring: Self { get }
  public static var releasing: Self { get }
  public static var acquiringAndReleasing: Self { get }
  public static var sequentiallyConsistent: Self { get }
}
```

These structs behave like non-frozen enums with a known (non-public) raw representation. This allows us to define additional memory orderings in the future (if and when they become necessary, specifically `std::memory_order_consume`) while making use of the known representation to optimize existing cases. (These cannot be frozen enums because that would prevent us from adding more orderings, but regular resilient enums can't freeze their representation, and the layout indirection interferes with guaranteed optimizations, especially in -Onone.)

Every atomic operation introduced later in this proposal requires an ordering argument. We consider these ordering arguments to be an essential part of these low-level atomic APIs, and we require an explicit `ordering` argument on all atomic operations. The intention here is to force developers to carefully think about what ordering they need to use, each time they use one of these primitives. (Perhaps more importantly, this also makes it obvious to readers of the code what ordering is used -- making it far less likely that an unintended default `.sequentiallyConsistent` ordering slips through code review.) 

Projects that prefer to default to sequentially consistent ordering are welcome to add non-public `Atomic` extensions that implement that. However, we expect that providing an implicit default ordering would be highly undesirable in most production uses of atomics.

We also provide a top-level function called `atomicMemoryFence` that allows issuing a memory ordering constraint without directly associating it with a particular atomic operation. This corresponds to `std::memory_thread_fence` in C++ [[C++17]].

```swift
/// Establishes a memory ordering without associating it with a
/// particular atomic operation.
///
/// - A relaxed fence has no effect.
/// - An acquiring fence ties to any preceding atomic operation that
///   reads a value, and synchronizes with any releasing operation whose
///   value was read.
/// - A releasing fence ties to any subsequent atomic operation that
///   modifies a value, and synchronizes with any acquiring operation
///   that reads the result.
/// - An acquiring and releasing fence is a combination of an
///   acquiring and a releasing fence.
/// - A sequentially consistent fence behaves like an acquiring and
///   releasing fence, and ensures that the fence itself is part of
///   the single, total ordering for all sequentially consistent
///   operations.
///
/// This operation corresponds to `std::atomic_thread_fence` in C++.
///
/// Be aware that Thread Sanitizer does not support fences and may report
/// false-positive races for data protected by a fence.
public func atomicMemoryFence(ordering: AtomicUpdateOrdering)
```

Fences are slightly more powerful (but even more difficult to use) than orderings tied to specific atomic operations [[N2153]]; we expect their use will be limited to the most performance-sensitive synchronization constructs.

### The Atomic Protocol Hierarchy

The notion of an atomic type is captured by the `AtomicValue` protocol.

```swift
/// A type that supports atomic operations through a separate atomic storage
/// representation.
public protocol AtomicValue {
  associatedtype AtomicRepresentation: AtomicStorage

  static func encodeAtomicRepresentation(
    _ value: consuming Self
  ) -> AtomicRepresentation

  static func decodeAtomicRepresentation(
    _ representation: consuming AtomicRepresentation
  ) -> Self
}
```

Backing the atomic representation is an `AtomicStorage` protocol that defines all of the atomic operations one must implement in order for the type itself to be used when lowering atomic operations.

```swift
/// The storage representation for an atomic value, providing pointer-based
/// atomic operations. This is a low-level implementation detail of atomic
/// types.
public protocol AtomicStorage {
  ...
}
```

While `AtomicStorage` is a public protocol, its requirements are considered an implementation detail of the Standard Library. (They are replaced by ellipses above.)

The requirements in `AtomicValue` set up a bidirectional mapping between values of the atomic type and an associated storage representation that implements the actual primitive atomic operations.

Following existing Standard Library conventions for such interfaces, the names of all associated types and member requirements of the `AtomicStorage` protocol start with a leading underscore character. As with any other underscored interface exposed by the Standard Library, code that manually implements or directly uses these underscored requirements may fail to compile (or correctly run) when built using any Swift release other than the one for which it was initially written.

The full set of standard types implementing `AtomicStorage` is listed below:

```swift
extension Int {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension Int8 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension Int16 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension Int32 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension Int64 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension UInt {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension UInt8 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension UInt16 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension UInt32 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
extension UInt64 {
  public struct AtomicRepresentation: AtomicStorage {...}
}
```

The full set of standard types implementing `AtomicValue` is listed below:

```swift
extension Int: AtomicValue {...}
extension Int64: AtomicValue {...}
extension Int32: AtomicValue {...}
extension Int16: AtomicValue {...}
extension Int8: AtomicValue {...}
extension UInt: AtomicValue {...}
extension UInt64: AtomicValue {...}
extension UInt32: AtomicValue {...}
extension UInt16: AtomicValue {...}
extension UInt8: AtomicValue {...}

extension Bool: AtomicValue {...}

extension UnsafeRawPointer: AtomicValue {...}
extension UnsafeMutableRawPointer: AtomicValue {...}
extension UnsafePointer: AtomicValue {...}
extension UnsafeMutablePointer: AtomicValue {...}
extension Unmanaged: AtomicValue {...}

extension Optional: AtomicValue where Wrapped: AtomicValue, ... {...}
```

#### Optional Atomics

The standard atomic pointer types and unmanaged references also support atomic operations on their optional-wrapped form. `Optional` implements this through a conditional conformance to `AtomicValue`; the exact constraint is an implementation detail. (It works by requiring the wrapped type's internal atomic storage representation to support a special nil value.)

```swift
extension Optional: AtomicValue where Wrapped: AtomicValue, ... {
  ...
}
```

This proposal enables optional-atomics support for the following types:

```swift
UnsafeRawPointer
UnsafeMutableRawPointer
UnsafePointer<Pointee>
UnsafeMutablePointer<Pointee>
Unmanaged<Instance>
```

User code is not allowed to extend this list with additional types; this capability is reserved for potential future proposals.

Atomic optional pointers and references are helpful when building lock-free data structures. (Although this initial set of reference types considerably limits the scope of what can be built; for more details, see the discussion on the [ABA problem](#doubleword) and [memory reclamation](#atomic-strong-references-and-the-problem-of-memory-reclamation).)

For example, consider the lock-free, single-consumer stack implementation below. (It supports an arbitrary number of concurrently pushing threads, but it only allows a single pop at a time.)

```swift
class LockFreeSingleConsumerStack<Element> {
  struct Node {
    let value: Element
    var next: UnsafeMutablePointer<Node>?
  }
  typealias NodePtr = UnsafeMutablePointer<Node>

  private var _last = Atomic<NodePtr?>(nil)
  private var _consumerCount = Atomic<Int>(0)

  deinit {
    // Discard remaining nodes
    while let _ = pop() {}
  }

  // Push the given element to the top of the stack.
  // It is okay to concurrently call this in an arbitrary number of threads.
  func push(_ value: Element) {
    let new = NodePtr.allocate(capacity: 1)
    new.initialize(to: Node(value: value, next: nil))

    var done = false
    var current = _last.load(ordering: .relaxed)
    while !done {
      new.pointee.next = current
      (done, current) = _last.compareExchange(
        expected: current,
        desired: new,
        ordering: .releasing
      )
    }
  }

  // Pop and return the topmost element from the stack.
  // This method does not support multiple overlapping concurrent calls.
  func pop() -> Element? {
    precondition(
      _consumerCount.loadThenWrappingIncrement(ordering: .acquiring) == 0,
      "Multiple consumers detected")
    defer { _consumerCount.wrappingDecrement(ordering: .releasing) }
    var done = false
    var current = _last.load(ordering: .acquiring)
    while let c = current {
      (done, current) = _last.compareExchange(
        expected: c,
        desired: c.pointee.next,
        ordering: .acquiring
      )

      if done {
        let result = c.move()
        c.deallocate()
        return result.value
      }
    }
    return nil
  }
}
```

#### Custom Atomic Types

To enable a limited set of user-defined atomic types, `AtomicValue` also provides a full set of default implementations for `RawRepresentable` types whose raw value is itself atomic:

```swift
extension RawRepresentable where Self: AtomicValue, RawValue: AtomicValue {
  ...
}
```

The default implementations work by forwarding all atomic operations to the raw value's implementation, converting to/from as needed.

This enables code outside of the Standard Library to add new `AtomicValue` conformances without manually implementing any of the requirements. This is especially handy for trivial raw-representable enumerations, such as in simple atomic state machines:

```swift
enum MyState: Int, AtomicValue {
  case starting
  case running
  case stopped
}

let currentState = Atomic<MyState>(.starting)
...
if currentState.compareExchange(
  expected: .starting, 
  desired: .running, 
  ordering: .sequentiallyConsistent
).exchanged {
  ...
}
...
currentState.store(.stopped, ordering: .sequentiallyConsistent)
```

### `DoubleWord`

In their current single-word form, atomic pointer and reference types are susceptible to a class of race condition called the *ABA problem*. A freshly allocated object often happens to be placed at the same memory location as a recently deallocated one. Therefore, two successive `load`s of a simple atomic pointer may return the exact same value, even though the pointer may have received an arbitrary number of updates between the two loads, and the pointee may have been completely replaced. This can be a subtle, but deadly source of race conditions in naive implementations of many concurrent data structures.

While the single-word atomic primitives introduced in this document are already useful for some applications, it would be helpful to also provide a set of additional atomic operations that operate on two consecutive `Int`-sized values in the same transaction. All supported architectures provide direct hardware support for such "double-wide" atomic operations.

We propose a new separate type that provides an abstraction over the layout of what a double word is for a platform.

```swift
public struct DoubleWord {
  public var first: UInt { get }
  public var second: UInt { get }

  public init(first: UInt, second: UInt)
}

extension DoubleWord: AtomicValue {
  public struct AtomicRepresentation: AtomicStorage {
    ...
  }

  ...
}
```

For example, the second word can be used to augment atomic values with a version counter (sometimes called a "stamp" or a "tag"), which can help resolve the ABA problem by allowing code to reliably verify if a value remained unchanged between two successive loads.

Note that not all CPUs support double-wide atomic operations and for that reason this type is not always available. Platforms that do not have this support must not make this type available for use. Perhaps a future direction for this is something akin to `#if canImport(struct DoubleWord)` to conditionally compile against this type if it's available.

### The Atomic type

So far, we've introduced memory orderings, giving us control of memory access around atomic operations; the atomic protocol hierarchy, which give us the initial list of standard types that can be as atomic values; and the `DoubleWord` type, providing an abstraction over a platform's double word type. However, we haven't yet introduced a way to actually _use_ atomics. Here we introduce the single Atomic type that exposes atomic operations for us:

```swift
/// An atomic value.
public struct Atomic<Value: AtomicValue>: ~Copyable {
  public init(_ initialValue: consuming Value)
}
```

A value of `Atomic<Value>` shares the same layout as `Value.AtomicRepresentation`.

Now that we know how to create an atomic value, it's time to introduce some actual atomic operations.

### Basic Atomic Operations

`Atomic` provides seven basic atomic operations for all supported types:

```swift
extension Atomic {
  /// Atomically loads and returns the current value, applying the specified
  /// memory ordering.
  ///
  /// - Parameter ordering: The memory ordering to apply on this operation.
  /// - Returns: The current value.
  public borrowing func load(ordering: AtomicLoadOrdering) -> Value
  
  /// Atomically sets the current value to `desired`, applying the specified
  /// memory ordering.
  ///
  /// - Parameter desired: The desired new value.
  /// - Parameter ordering: The memory ordering to apply on this operation.
  public borrowing func store(
    _ desired: consuming Value,
    ordering: AtomicStoreOrdering
  )

  /// Atomically sets the current value to `desired` and returns the original
  /// value, applying the specified memory ordering.
  ///
  /// - Parameter desired: The desired new value.
  /// - Parameter ordering: The memory ordering to apply on this operation.
  /// - Returns: The original value.
  public borrowing func exchange(
    _ desired: consuming Value, 
    ordering: AtomicUpdateOrdering
  ) -> Value

  /// Perform an atomic compare and exchange operation on the current value,
  /// applying the specified memory ordering.
  ///
  /// This operation performs the following algorithm as a single atomic
  /// transaction:
  ///
  /// ```
  /// atomic(self) { currentValue in
  ///   let original = currentValue
  ///   guard original == expected else { return (false, original) }
  ///   currentValue = desired
  ///   return (true, original)
  /// }
  /// ```
  ///
  /// This method implements a "strong" compare and exchange operation
  /// that does not permit spurious failures.
  ///
  /// - Parameter expected: The expected current value.
  /// - Parameter desired: The desired new value.
  /// - Parameter ordering: The memory ordering to apply on this operation.
  /// - Returns: A tuple `(exchanged, original)`, where `exchanged` is true if
  ///   the exchange was successful, and `original` is the original value.
  public borrowing func compareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Value)

  /// Perform an atomic compare and exchange operation on the current value,
  /// applying the specified success/failure memory orderings.
  ///
  /// This operation performs the following algorithm as a single atomic
  /// transaction:
  ///
  /// ```
  /// atomic(self) { currentValue in
  ///   let original = currentValue
  ///   guard original == expected else { return (false, original) }
  ///   currentValue = desired
  ///   return (true, original)
  /// }
  /// ```
  ///
  /// The `successOrdering` argument specifies the memory ordering to use when
  /// the operation manages to update the current value, while `failureOrdering`
  /// will be used when the operation leaves the value intact.
  ///
  /// This method implements a "strong" compare and exchange operation
  /// that does not permit spurious failures.
  ///
  /// - Parameter expected: The expected current value.
  /// - Parameter desired: The desired new value.
  /// - Parameter successOrdering: The memory ordering to apply if this
  ///    operation performs the exchange.
  /// - Parameter failureOrdering: The memory ordering to apply on this
  ///    operation if it does not perform the exchange.
  /// - Returns: A tuple `(exchanged, original)`, where `exchanged` is true if
  ///   the exchange was successful, and `original` is the original value.
  public borrowing func compareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)

  /// Perform an atomic weak compare and exchange operation on the current
  /// value, applying the memory ordering. This compare-exchange variant is
  /// allowed to spuriously fail; it is designed to be called in a loop until
  /// it indicates a successful exchange has happened.
  ///
  /// This operation performs the following algorithm as a single atomic
  /// transaction:
  ///
  /// ```
  /// atomic(self) { currentValue in
  ///   let original = currentValue
  ///   guard original == expected else { return (false, original) }
  ///   currentValue = desired
  ///   return (true, original)
  /// }
  /// ```
  ///
  /// (In this weak form, transient conditions may cause the `original ==
  /// expected` check to sometimes return false when the two values are in fact
  /// the same.)
  ///
  /// - Parameter expected: The expected current value.
  /// - Parameter desired: The desired new value.
  /// - Parameter ordering: The memory ordering to apply on this operation.
  /// - Returns: A tuple `(exchanged, original)`, where `exchanged` is true if
  ///   the exchange was successful, and `original` is the original value.
  public borrowing func weakCompareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Value)

  /// Perform an atomic weak compare and exchange operation on the current
  /// value, applying the specified success/failure memory orderings. This
  /// compare-exchange variant is allowed to spuriously fail; it is designed to
  /// be called in a loop until it indicates a successful exchange has happened.
  ///
  /// This operation performs the following algorithm as a single atomic
  /// transaction:
  ///
  /// ```
  /// atomic(self) { currentValue in
  ///   let original = currentValue
  ///   guard original == expected else { return (false, original) }
  ///   currentValue = desired
  ///   return (true, original)
  /// }
  /// ```
  ///
  /// (In this weak form, transient conditions may cause the `original ==
  /// expected` check to sometimes return false when the two values are in fact
  /// the same.)
  ///
  /// The `ordering` argument specifies the memory ordering to use when the
  /// operation manages to update the current value, while `failureOrdering`
  /// will be used when the operation leaves the value intact.
  ///
  /// - Parameter expected: The expected current value.
  /// - Parameter desired: The desired new value.
  /// - Parameter successOrdering: The memory ordering to apply if this
  ///    operation performs the exchange.
  /// - Parameter failureOrdering: The memory ordering to apply on this
  ///    operation does not perform the exchange.
  /// - Returns: A tuple `(exchanged, original)`, where `exchanged` is true if
  ///   the exchange was successful, and `original` is the original value.
  public borrowing func weakCompareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)
}
```

The first three operations are relatively simple:

- `load` returns the current value.
- `store` updates it.
- `exchange` is a combination of `load` and `store`; it updates the
  current value and returns the previous one as a single atomic
  operation.

The three `compareExchange` variants are somewhat more complicated: they implement a version of `exchange` that only performs the update if the original value is the same as a supplied expected value. To be specific, they execute the following algorithm as a single atomic transaction:

```swift
  guard currentValue == expected else { 
    return (exchanged: false, original: currentValue) 
  }
  currentValue = desired
  return (exchanged: true, original: expected)
```

All four variants implement the same algorithm. The single ordering variants use the same memory ordering whether or not the exchange succeeds, while the others allow callers to specify two distinct memory orderings for the success and failure cases. The two orderings are independent from each other -- all combinations of update/load orderings are supported [[P0418]]. (Of course, the implementation may need to "round up" to the nearest ordering combination that is supported by the underlying code generation layer and the targeted CPU architecture.)

The `weakCompareExchange` form may sometimes return false even when the original and expected values are equal. (Such failures may happen when some transient condition prevents the underlying operation from succeeding -- such as an incoming interrupt during a load-link/store-conditional instruction sequence.) This variant is designed to be called in a loop that only exits when the exchange is successful; in such loops, using `weakCompareExchange` may lead to a performance improvement by eliminating a nested loop in the regular, "strong", `compareExchange` variants.

The compare-exchange primitive is special: it is a universal operation that can be used to implement all other atomic operations, and more. For example, here is how we could use `compareExchange` to implement a wrapping increment operation over `Atomic<Int>` values:

```swift
extension Atomic where Value == Int {
  func wrappingIncrement(
    by operand: Int,
    ordering: AtomicUpdateOrdering
  ) {
    var done = false
    var current = load(ordering: .relaxed)
    while !done {
      (done, current) = compareExchange(
        expected: current,
        desired: current &+ operand,
        ordering: ordering
      )
    }
  }
}
```

### Specialized Integer Operations

Most CPU architectures provide dedicated atomic instructions for certain integer operations, and these are generally more efficient than implementations using `compareExchange`. Therefore, it makes sense to expose a set of dedicated methods for common integer operations so that these will always get compiled into the most efficient implementation available.

These specialized integer operations generally come in two variants, based on whether they're returning the value before or after the operation:

| Method Name | Returns | Implements |
| --- | --- | --- |
| `loadThenWrappingIncrement(by:ordering:)`  | original value | `a &+= b`  |
| `loadThenWrappingDecrement(by:ordering:)`  | original value | `a &-= b`  |
| `loadThenBitwiseAnd(with:ordering)`        | original value | `a &= b`  |
| `loadThenBitwiseOr(with:ordering)`         | original value | `a \|= b`  |
| `loadThenBitwiseXor(with:ordering)`        | original value | `a ^= b`   |
| `wrappingIncrementThenLoad(by:ordering:)`  | new value  | `a &+= b`  |
| `wrappingDecrementThenLoad(by:ordering:)`  | new value  |`a &-= b`   |
| `bitwiseAndThenLoad(with:ordering)`        | new value  |`a &= b`    |
| `bitwiseOrThenLoad(with:ordering)`         | new value  |`a \|= b`   |
| `bitwiseXorThenLoad(with:ordering)`        | new value  |`a ^= b`    |
| `wrappingIncrement(by:ordering:)`          | none   | `a &+= b` |
| `wrappingDecrement(by:ordering:)`          | none   | `a &-= b` |

The `wrappingIncrement` and `wrappingDecrement` operations are provided as a convenience for incrementing/decrementing values in the common case when a return value is not required.

While we require all atomic operations to be free of locks, we don't require wait-freedom. Therefore, on architectures that don't provide direct hardware support for some or all of these operations, we still require them to be implemented using `compareExchange` loops like the one for `wrappingIncrement` above.

`Atomic<Value>` exposes these operations when `Value` is one of the standard fixed-width integer types.

```swift
extension Atomic where Value == Int {...}
extension Atomic where Value == UInt8 {...}
...

let counter = Atomic<Int>(0)
counter.wrappingIncrement(by: 42, ordering: .relaxed)
```

### Specialized Boolean Operations

Similar to the specialized integer operations, we can provide similar ones for booleans with the same two variants:

| Method Name                          | Returns        | Implements     |
|--------------------------------------|----------------|----------------|
| `loadThenLogicalAnd(with:ordering:)` | original value | `a = a && b`   |
| `loadThenLogicalOr(with:ordering:)`  | original value | `a = a \|\| b` |
| `loadThenLogicalXor(with:ordering:)` | original value | `a = a ^ b`    |
| `logicalAndThenLoad(with:ordering:)` | new value      | `a = a && b`   |
| `logicalOrThenLoad(with:ordering:)`  | new value      | `a = a \|\| b` |
| `logicalXorThenLoad(with:ordering:)` | new value      | `a = a ^ b`    |

`Atomic<Value>` exposes these operations when `Value` is `Bool`.

```swift
extension Atomic where Value == Bool {...}

let tracker = Atomic<Bool>(false)
let new = tracker.logicalOrThenLoad(with: true, ordering: .relaxed)
```

### Atomic Lazy References

The operations provided by `Atomic<Unmanaged<T>>` only operate on the unmanaged reference itself. They don't allow us to directly access the referenced object -- we need to manually invoke the methods `Unmanaged` provides for this purpose (usually, `takeUnretainedValue`).

Note that loading the atomic unmanaged reference and converting it to a strong reference are two distinct operations that won't execute as a single atomic transaction. This can easily lead to race conditions when a thread releases an object while another is busy loading it:

```swift
// BROKEN CODE. DO NOT EMULATE IN PRODUCTION.
let myAtomicRef = Atomic<Unmanaged<Foo>>(...)

// Thread A: Load the unmanaged value and then convert it to a regular
//           strong reference.
let ref = myAtomicRef.load(ordering: .acquiring).takeUnretainedValue()
...

// Thread B: Store a new reference in the atomic unmanaged value and 
//           release the previous reference.
let new = Unmanaged.passRetained(...)
let old = myAtomicRef.exchange(new, ordering: .acquiringAndReleasing)
old.release() // RACE CONDITION
```

If thread B happens to release the same object that thread A is in the process of loading, then thread A's `takeUnretainedValue` may attempt to retain a deallocated object.

Such problems make `Atomic<Unmanaged<T>>` exceedingly difficult to use in all but the simplest situations. The section on [*Atomic Strong References*](#atomic-strong-references-and-the-problem-of-memory-reclamation) below describes some new constructs we may introduce in future proposals to assist with this issue.

For now, we provide the standalone type `AtomicLazyReference`; this is an example of a useful construct that could be built on top of `Atomic<Unmanaged<Instance>>` operations. (Of the atomic constructs introduced in this proposal, only `AtomicLazyReference` represents a regular strong reference to a class instance -- the other pointer/reference types leave memory management entirely up to the user.)

An `AtomicLazyReference` holds an optional reference that is initially set to `nil`. The value can be set exactly once, but it can be read an arbitrary number of times. Attempts to change the value after the first `storeIfNilThenLoad` call are ignored, and return the current value instead.

```swift
/// A lazily initializable atomic strong reference.
///
/// These values can be set (initialized) exactly once, but read many
/// times.
public struct AtomicLazyReference<Instance: AnyObject>: ~Copyable {
  /// The value logically stored in an atomic lazy reference value.
  public typealias Value = Instance?

  /// Initializes a new managed atomic lazy reference with a nil value.
  public init()
}

extension AtomicLazyReference {
  /// Atomically initializes this reference if its current value is nil, then
  /// returns the initialized value. If this reference is already initialized,
  /// then `storeIfNilThenLoad(_:)` discards its supplied argument and returns
  /// the current value without updating it.
  ///
  /// The following example demonstrates how this can be used to implement a
  /// thread-safe lazily initialized reference:
  ///
  /// ```
  /// class Image {
  ///   var _histogram: AtomicLazyReference<Histogram> = .init()
  ///
  ///   // This is safe to call concurrently from multiple threads.
  ///   var atomicLazyHistogram: Histogram {
  ///     if let histogram = _histogram.load() { return histogram }
  ///     // Note that code here may run concurrently on
  ///     // multiple threads, but only one of them will get to
  ///     // succeed setting the reference.
  ///     let histogram = ...
  ///     return _histogram.storeIfNilThenLoad(histogram)
  /// }
  /// ```
  ///
  /// This operation uses acquiring-and-releasing memory ordering.
  public borrowing func storeIfNilThenLoad(
    _ desired: consuming Instance
  ) -> Instance

  /// Atomically loads and returns the current value of this reference.
  ///
  /// The load operation is performed with the memory ordering
  /// `AtomicLoadOrdering.acquiring`.
  public borrowing func load() -> Instance?
}
```

This is the only atomic type in this proposal that doesn't provide the usual `load`/`store`/`exchange`/`compareExchange` operations.

This construct allows library authors to implement a thread-safe lazy initialization pattern:

```swift
var _foo: AtomicLazyReference<Foo> = ...

// This is safe to call concurrently from multiple threads.
var atomicLazyFoo: Foo {
  if let foo = _foo.load() { return foo }
  // Note: the code here may run concurrently on multiple threads.
  // All but one of the resulting values will be discarded.
  let foo = Foo()
  return _foo.storeIfNilThenLoad(foo)
}
```

The Standard Library has been internally using such a pattern to implement deferred bridging for `Array`, `Dictionary` and `Set`.

Note that unlike the rest of the atomic types, `load` and `storeIfNilThenLoad(_:)` do not expose `ordering` parameters. (Internally, they map to acquiring/releasing operations to guarantee correct synchronization.)

### Restricting Ordering Arguments to Compile-Time Constants

Modeling orderings as regular function parameters allows us to specify them using syntax that's familiar to all Swift programmers. Unfortunately, it means that in the implementation of atomic operations we're forced to switch over the ordering argument:

```swift
extension Int: AtomicStorage {
  public func atomicCompareExchange(
    expected: Int,
    desired: Int,
    at address: UnsafeMutablePointer<Int>,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Int) {
    // Note: This is a simplified version of the actual implementation
    let won: Bool
    let oldValue: Int

    switch ordering {
    case .relaxed:
      (oldValue, won) = Builtin.cmpxchg_monotonic_monotonic_Word(
        address, expected, desired
      )

    case .acquiring:
      (oldValue, won) = Builtin.cmpxchg_acquire_acquire_Word(
        address, expected, desired
      )

    case .releasing:
      (oldValue, won) = Builtin.cmpxchg_release_monotonic_Word(
        address, expected, desired
      )

    case .acquiringAndReleasing:
      (oldValue, won) = Builtin.cmpxchg_acqrel_acquire_Word(
        address, expected, desired
      )

    case .sequentiallyConsistent:
      (oldValue, won) = Builtin.cmpxchg_seqcst_seqcst_Word(
        address, expected, desired
      )

    default:
      fatalError("Unknown atomic memory ordering")
    }

    return (exchanged: won, original: oldValue)
  }
}
```

Given our requirement that primitive atomics must always compile down to the actual atomic instructions with minimal additional overhead, we must guarantee that these switch statements always get optimized away into the single case we need; they must never actually be evaluated at runtime.

Luckily, configuring these special functions to always get force-inlined into all callers guarantees that constant folding will get rid of the switch statement *as long as the supplied ordering is a compile-time constant*. Unfortunately, it's all too easy to accidentally violate this latter requirement, with dire consequences to the expected performance of the atomic operation.

Consider the following well-meaning attempt at using `compareExchange` to define an atomic integer addition operation that traps on overflow rather than allowing the result to wrap around:

```swift
extension Atomic where Value == Int {
  // Non-inlinable
  public func checkedIncrement(by delta: Int, ordering: AtomicUpdateOrdering) {
    var done = false
    var current = load(ordering: .relaxed)

    while !done {
      (done, current) = compareExchange(
        expected: current,
        desired: current + operand, // Traps on overflow
        ordering: ordering
      )
    }
  }
}

// Elsewhere:
counter.checkedIncrement(by: 1, ordering: .relaxed)
```

If for whatever reason the Swift compiler isn't able (or willing) to inline the `checkedIncrement` call, then the value of `ordering` won't be known at compile time to the body of the function, so even though `compareExchange` will still get inlined, its switch statement won't be eliminated. This leads to a potentially significant performance regression that could interfere with the scalability of the operation.

To prevent these issues, we are constraining the memory ordering arguments of all atomic operations to be compile-time constants. Any attempt to pass a dynamic ordering value (such as in the `compareExchange` call above) will result in a compile-time error.

An ordering expression will be considered constant-evaluable if it's either (1) a direct call to one of the `Atomic*Ordering` factory methods (`.relaxed`, `.acquiring`, etc.), or (2) it is a direct reference to a variable that is in turn constrained to be constant-evaluable.

## Interaction with Existing Language Features

Please refer to the [Clarify the Swift memory consistency model (SE-0282)](https://github.com/apple/swift-evolution/blob/main/proposals/0282-atomics.md#interaction-with-non-instantaneous-accesses) proposal which goes over how atomics interact with the Law of Exclusivity, Non-Instantaneous Accesses, and Implicit Pointer Conversions.

An additional note with regards to the Law of Exclusivity, atomic values should never be declared with a `var` binding, always prefer a `let` one. Consider the following:

```swift
class Counter {
  var value: Atomic<Int>
}
```

By declaring this atomic value as a `var`, we've opted into Swift's dynamic exclusivity checking for this property, so all reads are checking whether or not it's currently being written to. This inherently means the atomic value is no longer, atomic. In general, if one is unsure if a `var` atomic value will incur the dynamic exclusivity checking, use a `let`. We can achieve store operations with these atomic types while only needing a borrow of the value, so there's no need to have a mutable reference to the value.

It is very important, however, that one must never pass an `Atomic` as `inout` or `consuming` because then you declare the parameter to have exclusive access of the atomic value which as we said, makes the value no longer atomic.

### Interaction with Swift Concurrency

The `Atomic` type is `Sendable` where `Value: Sendable`. One can pass a value of an `Atomic` to an actor or any other async context by using a borrow reference.

```swift
actor Updater {
  ...

  func update(_ counter: borrowing Atomic<Int>) {
    ...
  }

  func doOtherWork() {}
}

func version1() async {
  let counter = Atomic<Int>(0)

  //                   |--- There are no suspension points in this function, so
  //                   |    this atomic value will be allocated on whatever
  //                   |    thread's stack that decides to run this async function.
  //                   |
  //                   v
  let updatedCount = counter.load(ordering: .relaxed)
}

func version2() async {
  let counter = Atomic<Int>(0)

  let updater = Updater()
  await updater.update(counter) //  <--------- Potential suspension point that
                                //             uses the atomic value directly.
                                //             The atomic value will get
                                //             promoted to the async stack frame
                                //             meaning it will be available until
                                //             this async function has ended.

  //                   |----- Atomic value used after suspension point.
  //                   |      Because of the fact that we're passing it to a
  //                   |      suspension point, it's already been allocated on
  //                   |      the async stack frame, and accessing it later will
  //                   |      access that same resource, preserving atomicity.
  //                   |
  //                   v
  let updatedCount = counter.load(ordering: .relaxed)
}

func version3() async {
  let counter = Atomic<Int>(0)

  let updater = Updater()
  await updater.doOtherWork() //  <--------- Potential suspension point that
                              //             doesn't use the atomic value directly.


  //                   |----- Atomic value used after suspension point, so it is
  //                   |      promoted to the async stack frame which makes this
  //                   |      value's lifetime persist even after the await.
  //                   |      The compiler could in theory also reorder the
  //                   |      atomic value's initialization after the suspension
  //                   |      because it isn't used before nor during meaning it
  //                   |      could be allocated on whatever thread's stack frame.
  //                   |
  //                   v
  let updatedCount = counter.load(ordering: .relaxed)
}
```

Considering these factors, we can safely say that `extension Atomic: Sendable where Value: Sendable {}`. All of the places where one can store a value an `Atomic`, is either as a global, as a class ivar, or as a local. For globals and class ivars, everyone agrees that they exist at a single location and will never try to perform atomic operations by moving the value to some local. As explained above, we can safely reason about local atomic values in async contexts and all of the places where we care about preserving atomicity will do the right thing for us, either by just using the thread's stack frame for allocation or by promoting it to some async coroutine's stack frame on the heap.

## Detailed Design

In the interest of keeping this document (relatively) short, the following API synopsis does not include API documentation, inlinable method bodies, or `@usableFromInline` declarations, and omits most attributes (`@available`, `@inlinable`, etc.).

To allow atomic operations to compile down to their corresponding CPU instructions, most entry points listed here will be defined `@inlinable`.

For the full API definition, please refer to the [implementation][implementation].

### Atomic Memory Orderings

```swift
public struct AtomicLoadOrdering: Equatable, Hashable, CustomStringConvertible {
  public static var relaxed: Self { get }
  public static var acquiring: Self { get }
  public static var sequentiallyConsistent: Self { get }

  public static func ==(left: Self, right: Self) -> Bool
  public func hash(into hasher: inout Hasher)
  public var description: String { get }
}

public struct AtomicStoreOrdering: Equatable, Hashable, CustomStringConvertible {
  public static var relaxed: Self { get }
  public static var releasing: Self { get }
  public static var sequentiallyConsistent: Self { get }

  public static func ==(left: Self, right: Self) -> Bool
  public func hash(into hasher: inout Hasher)
  public var description: String { get }
}

public struct AtomicUpdateOrdering: Equatable, Hashable, CustomStringConvertible {
  public static var relaxed: Self { get }
  public static var acquiring: Self { get }
  public static var releasing: Self { get }
  public static var acquiringAndReleasing: Self { get }
  public static var sequentiallyConsistent: Self { get }

  public static func ==(left: Self, right: Self) -> Bool
  public func hash(into hasher: inout Hasher)
  public var description: String { get }
}

public func atomicMemoryFence(ordering: AtomicUpdateOrdering)
```

### Atomic Protocols

#### `AtomicStorage`

```swift
public protocol AtomicStorage {
  // Requirements aren't public API
}
```

This protocol supplies the actual primitive atomic operations for conformers. The exact requirements are a private implementation detail of the Standard Library. They are outside the scope of the Swift Evolution process and they may arbitrarily change between library releases. User code must not directly use them or manually implement them.

Conforming types:

```swift
extension Int.AtomicRepresentation: AtomicStorage {...}
extension Int64.AtomicRepresentation: AtomicStorage {...}
extension Int32.AtomicRepresentation: AtomicStorage {...}
extension Int16.AtomicRepresentation: AtomicStorage {...}
extension Int8.AtomicRepresentation: AtomicStorage {...}
extension UInt.AtomicRepresentation: AtomicStorage {...}
extension UInt64.AtomicRepresentation: AtomicStorage {...}
extension UInt32.AtomicRepresentation: AtomicStorage {...}
extension UInt16.AtomicRepresentation: AtomicStorage {...}
extension UInt8.AtomicRepresentation: AtomicStorage {...}

extension DoubleWord.AtomicRepresentation: AtomicStorage {...}
```

#### `AtomicValue`

```swift
public protocol AtomicValue {
  associatedtype AtomicRepresentation: AtomicStorage

  static func encodeAtomicRepresentation(
    _ value: consuming Self
  ) -> AtomicRepresentation

  static func decodeAtomicRepresentation(
    _ representation: consuming AtomicRepresentation
  ) -> Self
}
```

The requirements set up a bidirectional mapping between values of the atomic type and an associated storage representation that supplies the actual primitive atomic operations.

Conforming types:

```swift
extension Int: AtomicValue {...}
extension Int64: AtomicValue {...}
extension Int32: AtomicValue {...}
extension Int16: AtomicValue {...}
extension Int8: AtomicValue {...}
extension UInt: AtomicValue {...}
extension UInt64: AtomicValue {...}
extension UInt32: AtomicValue {...}
extension UInt16: AtomicValue {...}
extension UInt8: AtomicValue {...}

extension DoubleWord: AtomicValue {...}

extension Bool: AtomicValue {...}

extension UnsafeRawPointer: AtomicValue {...}
extension UnsafeMutableRawPointer: AtomicValue {...}
extension UnsafePointer: AtomicValue {...}
extension UnsafeMutablePointer: AtomicValue {...}
extension Unmanaged: AtomicValue {...}

extension Optional: AtomicValue where Wrapped: AtomicValue, ... {...}
```

The exact constraints on `Optional`'s conditional conformance are a private implementation detail. (They specify that the underlying (private) storage representation must be able to represent an extra `nil` value.)

Atomic `Optional` operations are currently enabled for the following `Wrapped` types:

```swift
UnsafeRawPointer
UnsafeMutableRawPointer
UnsafePointer<Pointee>
UnsafeMutablePointer<Pointee>
Unmanaged<Instance>
```

User code is not allowed to extend this list with additional types; this capability is reserved for potential future proposals.

To support custom "atomic-representable" types, `AtomicValue` also comes with default implementations for all its requirements for `RawRepresentable` types whose `RawValue` is also atomic:

```swift
extension RawRepresentable where Self: AtomicValue, RawValue: AtomicValue, ... {
  // Implementations for all requirements.
}
```

The omitted constraint sets up the (private) atomic storage type to match that of the `RawValue`. The default implementations work by converting values to their `rawValue` form, and forwarding all atomic operations to it.

### `DoubleWord`

```swift
public struct DoubleWord {
  public var first: UInt { get }
  public var second: UInt { get }

  public init(first: UInt, second: UInt)
}
```

### Atomic Types

#### `Atomic<Value>`

```swift
public struct Atomic<Value: AtomicValue>: ~Copyable {
  public init(_ initialValue: consuming Value)

  // Atomic operations:

  public borrowing func load(ordering: AtomicLoadOrdering) -> Value

  public borrowing func store(
    _ desired: consuming Value,
    ordering: AtomicStoreOrdering
  )

  public borrowing func exchange(
    _ desired: consuming Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func compareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Value)

  public borrowing func compareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)

  public borrowing func weakCompareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Value)

  public borrowing func weakCompareExchange(
    expected: borrowing Value,
    desired: consuming Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)
}
```

`Atomic` also provides a handful of integer operations for the standard fixed-width integer types. This is implemented via same type requirements:

```swift
extension Atomic where Value == Int {
  public borrowing func loadThenWrappingIncrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func wrappingIncrementThenLoad(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func wrappingIncrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  )

  public borrowing func loadThenWrappingDecrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func wrappingDecrementThenLoad(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func wrappingDecrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  )

  public borrowing func loadThenBitwiseAnd(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func bitwiseAndThenLoad(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func loadThenBitwiseOr(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func bitwiseOrThenLoad(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func loadThenBitwiseXor(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func bitwiseXorThenLoad(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value
}

extension Atomic where Value == Int8 {...}
...
```

as well as providing convenience functions for boolean operations:

```swift
extension Atomic where Value == Bool {
  public borrowing func loadThenLogicalAnd(
    with operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func loadThenLogicalOr(
    with operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func loadThenLogicalXor(
    with operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func logicalAndThenLoad(
    with operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func logicalOrThenLoad(
    with operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public borrowing func logicalXorThenLoad(
    with operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value
}
```

#### `AtomicLazyReference<Instance>`

```swift
public struct AtomicLazyReference<Instance: AnyObject>: ~Copyable {
  public typealias Value = Instance?

  public init(_ initialValue: consuming Instance)

  // Atomic operations:

  public borrowing func storeIfNilThenLoad(
    _ desired: consuming Instance
  ) -> Instance

  public borrowing func load() -> Instance?
}
```

## Source Compatibility

This is a purely additive change with no source compatibility impact.

## Effect on ABI Stability

This proposal introduces new entry points to the Standard Library ABI in a standalone `Synchronization` module, but otherwise it has no effect on ABI stability.

On ABI-stable platforms, the struct types and protocols introduced here will become part of the stdlib's ABI with availability matching the first OS releases that include them.

Most of the atomic methods introduced in this document will be force-inlined directly into client code at every call site. As such, there is no reason to bake them into the stdlib's ABI -- the stdlib binary will not export symbols for them.

## Effect on API Resilience

This is an additive change; it has no effect on the API of existing code.

For the new constructs introduced here, the proposed design allows us to make the following changes in future versions of the Swift Standard Library:

- Addition of new atomic types (and higher-level constructs built around them). (These new types would not directly back-deploy to OS versions that predate their introduction.)

- Addition of new memory orderings. Because all atomic operations compile directly into user code, new memory orderings that we decide to introduce later could potentially back-deploy to any OS release that includes this proposal.

- Addition of new atomic operations on the types introduced here. These would be reflected in internal protocol requirements, so they would not be directly back-deployable to previous ABI-stable OS releases.

- Introducing a default memory ordering for atomic operations (either by adding a default value to `ordering`, or by adding new overloads that lack that parameter). This too would be a back-deployable change.

(We don't necessarily plan to actually perform any of these changes; we merely leave the door open to doing them.)

## Potential Future Directions

### Atomic Strong References and The Problem of Memory Reclamation

Perhaps counter-intuitively, implementing a high-performance, *lock-free* atomic version of regular everyday strong references is not a trivial task. This proposal doesn't attempt to provide such a construct beyond the limited use-case of `AtomicLazyReference`.

Under the hood, Swift's strong references have always been using atomic operations to implement reference counting. This allows references to be read (but not mutated) from multiple, concurrent threads of execution, while also ensuring that each object still gets deallocated as soon as its last outstanding reference disappears. However, atomic reference counts on their own do not allow threads to safely share a single *mutable* reference without additional synchronization.

The difficulty is in the implementation of the atomic load operation, which boils down to two separate sub-operations, both of which need to be part of the *same atomic transaction*:

1. Load the value of the reference.
2. Increment the reference count of the corresponding object.

If an intervening store operation were allowed to release the reference between steps 1 and 2, then the loaded reference could already be deallocated by the time `load` tries to increment its refcount.

Without an efficient way to implement these two steps as a single atomic transaction, the implementation of `store` needs to delay releasing the overwritten value until it can guarantee that every outstanding load operation is completed. Exactly how to implement this is the problem of *memory reclamation* in concurrent data structures.

There are a variety of approaches to tackle this problem, some of which may be general enough to consider in future proposals. (One potential solution can be built on top of double-wide atomic operations, by offloading some of the reference counting operations into the second word of a double-wide atomic reference.)

(It'd be straightforward to use locks to build an atomic strong reference; while such a construct obviously wouldn't be lock-free, it is still a useful abstraction, so it may be a worthy addition to the Standard Library. However, locking constructs are outside the scope of this proposal.)

### Additional Low-Level Atomic Features

To enable use cases that require even more fine-grained control over atomic operations, it may be useful to introduce additional low-level atomics features:

* support for additional kinds of atomic values (such as floating-point atomics [[P0020]]),
* new memory orderings, such as a consuming load ordering [[P0750]] or tearable atomics [[P0690]],
* "volatile" atomics that prevent certain compiler optimizations
* and more

We defer these for future proposals.

## Alternatives Considered

### Default Orderings

We considered defaulting all atomic operations throughout the `Synchronization` module to sequentially consistent ordering. While we concede that doing so would make atomics slightly more approachable, implicit ordering values tend to interfere with highly performance-sensitive use cases of atomics (which is *most* use cases of atomics). Sequential consistency tends to be relatively rarely used in these contexts, and implicitly defaulting to it would allow accidental use to easily slip through code review.

Users who wish for default orderings are welcome to define their own overloads for atomic operations:

```swift
extension Atomic {
  func load() -> Value { 
    load(ordering: .sequentiallyConsistent)
  }

  func store(_ desired: consuming Value) { 
    store(desired, ordering: .sequentiallyConsistent) 
  }

  func exchange(_ desired: consuming Value) -> Value {
    exchange(desired, ordering: .sequentiallyConsistent)
  }
  
  func compareExchange(
    expected: borrowing Value,
    desired: consuming Value
  ) -> (exchanged: Bool, original: Value) {
    compareExchange(
      expected: expected, 
      desired: desired, 
      ordering: .sequentiallyConsistent
    )
  }

  func weakCompareExchange(
    expected: borrowing Value,
    desired: consuming Value
  ) -> (exchanged: Bool, original: Value) {
    weakCompareExchange(
      expected: expected, 
      desired: desired, 
      successOrdering: .sequentiallyConsistent,
      failureOrdering: .sequentiallyConsistent
    )
  }
}

extension Atomic where Value == Int {
  func wrappingIncrement(by delta: Value = 1) {
    wrappingIncrement(by: delta, ordering: .sequentiallyConsistent)
  }

  etc.
}
```

### A Truly Universal Generic Atomic Type

While future proposals may add a variety of other atomic types, we do not expect to ever provide a truly universal generic `Atomic<T>` construct. The Synchronization module is designed to provide high-performance wait-free primitives, and these are heavily constrained by the atomic instruction sets of the CPU architectures Swift targets.

A universal `Atomic<T>` type that can hold *any* value is unlikely to be implementable without locks, so it is outside the scope of this proposal. We may eventually consider adding such a construct in a future concurrency proposal:

```swift
struct Serialized<Value>: ~Copyable {
  private let _lock = UnfairLock()
  private var _value: Value
  
  func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    _lock.lock()
    defer { _lock.unlock() }

    return try body(&_value)
  }
}
```

### Providing a `value` Property

Our atomic constructs are unusual because even though semantically they behave like containers holding a value, they do not provide direct access to it. Instead of exposing a getter and a setter on a handy `value` property, they expose cumbersome `load` and `store` methods. There are two reasons for this curious inconsistency:

First, there is the obvious issue that property getter/setters have no room for an ordering parameter.

Second, there is a deep underlying problem with the property syntax: it encourages silent race conditions. For example, consider the code below:

```swift
let counter = Atomic<Int>(0)
...
counter.value += 1
```

Even though this increment looks like it may be a single atomic operation, it gets executed as two separate atomic transactions:

```swift
var temp = counter.value // atomic load
temp += 1
counter.value = temp     // atomic store
```

If some other thread happens to update the value after the atomic load, then that update gets overwritten by the subsequent store, resulting in data loss.

To prevent this gotcha, none of the proposed atomic types provide a property for accessing their value, and we don't foresee adding such a property in the future, either.

(Note that this problem cannot be mitigated by implementing [modify accessors]. Lock-free updates cannot be implemented without the ability to retry the update multiple times, and modify accessors can only yield once.)

[modify accessors]: https://forums.swift.org/t/modify-accessors/31872

### Alternative Designs for Memory Orderings

Modeling memory orderings with enumeration(-like) values fits well into the Standard Library's existing API design practice, but `ordering` arguments aren't without problems. Most importantly, the quality of code generation depends greatly on the compiler's ability to constant-fold switch statements over these ordering values into a single instruction. This can be fragile -- especially in unoptimized builds. We think [constraining these arguments to compile-time constants](#restricting-ordering-arguments-to-compile-time-constants) strikes a good balance between readability and performance, but it's instructive to look at some of the approaches we considered before settling on this choice.

#### Encode Orderings in Method Names

One obvious idea is to put the ordering values directly in the method name for every atomic operation. This would be easy to implement but it leads to practically unusable API names. Consider the two-ordering compare/exchange variant below:

```swift
flag.sequentiallyConsistentButAcquiringAndReleasingOnFailureCompareExchange(
  expected: 0,
  desired: 1
)
```

We could find shorter names for the orderings (`Serialized`, `Barrier` etc.), but ultimately the problem is that this approach tries to cram too much information into the method name, and the resulting multitude of similar-but-not-exactly-the-same methods become an ill-structured mess.

#### Orderings As Generic Type Parameters

A second idea is model the orderings as generic type parameters on the atomic types themselves.

```swift
struct Atomic<Value: AtomicProtocol, Ordering: AtomicMemoryOrdering> {
  ...
}

let counter = Atomic<Int, Relaxed>(0)
counter.wrappingIncrement()
```

This simplifies the typical case where all operations on a certain atomic value use the same "level" of ordering (relaxed, acquire/release, or sequentially consistent). However, there are considerable drawbacks:

* This design puts the ordering specification far away from the actual operations -- obfuscating their meaning. 
* It makes it a lot more difficult to use custom orderings for specific operations (like the speculative relaxed load in the `wrappingIncrement` example in the section on [Atomic Operations](#atomic-operations) above).
* We wouldn't be able to provide a default value for a generic type parameter. 
* Finally, there is also the risk of unspecialized generics interfering with runtime performance.

#### Ordering Views

The most promising alternative idea to represent memory orderings was to model them like `String`'s encoding views:

```swift
let counter = Atomic<Int>(0)

counter.relaxed.increment()

let current = counter.acquiring.load()
```

There are some things that we really like about this "ordering view" approach:

- It eliminates the need to ever switch over orderings, preventing any and all constant folding issues.
- It makes it obvious that memory orderings are supposed to be compile-time parameters.
- The syntax is arguably more attractive.

However, we ultimately decided against going down this route, for the following reasons:

  - **Composability.** Such ordering views are unwieldy for the variant of `compareExchange` that takes separate success/failure orderings. Ordering views don't nest very well at all:

    ```swift
    counter.acquiringAndReleasing.butAcquiringOnFailure.compareExchange(...)
    ```

  - **API surface area and complexity.** Ordering views act like a multiplier for API entry points. In our prototype implementation, introducing ordering views increased the API surface area of atomics by 3×: we went from 6 public structs with 53 public methods to 27 structs with 175 methods. While clever use of protocols and generics could reduce this factor, the increased complexity seems undesirable. (E.g., generic ordering views would reintroduce potential performance problems in the form of unspecialized generics.)

    API surface area is not necessarily the most important statistic, but public methods do have some cost. (In e.g. the size of the stdlib module, API documentation etc.)

  - **Unintuitive syntax.** While the syntax is indeed superficially attractive, it feels backward to put the memory ordering *before* the actual operation. While memory orderings are important, I suspect most people would consider them secondary to the operations themselves.

  - **Limited Reuse.** Implementing ordering views takes a rather large amount of (error-prone) boilerplate-heavy code that is not directly reusable. Every new atomic type would need to implement a new set of ordering views, tailor-fit to its own use-case.

### Directly bring over `swift-atomics`'s API

The `swift-atomics` package has many years of experience using their APIs to interface with atomic values and it would be beneficial to simply bring over the same API. However, once we designed the general purpose `Atomic<Value>` type, we noticied a few deficiencies with the atomic protocol hierarchy that made using this type awkward for users. We've redesigned these protocols to make using the atomic type easier to use and easier to reason about.

While there are some API differences between this proposal and the package, most of the atomic operations are the same and should feel very familiar to those who have used the package before. We don't plan on drastically renaming any core atomic operation because we believe `swift-atomics` already got those names correct.

## References

[Clarify the Swift memory consistency model (SE-0282)]: https://github.com/apple/swift-evolution/blob/main/proposals/0282-atomics.md
**\[Clarify the Swift memory consistency model (SE-0282)]** Karoy Lorenty. "Clarify the Swift memory consistency model."*Swift Evolution Proposal*, 2020. https://github.com/apple/swift-evolution/blob/main/proposals/0282-atomics.md

[C++17]: https://isocpp.org/std/the-standard
**\[C++17]** ISO/IEC. *ISO International Standard ISO/IEC 14882:2017(E) – Programming Language C++.* 2017.
  https://isocpp.org/std/the-standard

[Boehm 2008]: https://doi.org/10.1145/1375581.1375591
**\[Boehm 2008]** Hans-J. Boehm, Sarita V. Adve. "Foundations of the C++ Concurrency Memory Model." In *PLDI '08: Proc. of the 29th ACM SIGPLAN Conf. on Programming Language Design and Implementation*, pages 68–78, June 2008.
  https://doi.org/10.1145/1375581.1375591

[N2153]: http://wg21.link/N2153
**\[N2153]** Raúl Silvera, Michael Wong, Paul McKenney, Bob Blainey. *A simple and efficient memory model for weakly-ordered architectures.* WG21/N2153, January 12, 2007. http://wg21.link/N2153

[P0020]: http://wg21.link/P0020
**\[P0020]** H. Carter Edwards, Hans Boehm, Olivier Giroux, JF Bastien, James Reus. *Floating Point Atomic.* WG21/P0020r6, November 10, 2017. http://wg21.link/P0020

[P0418]: http://wg21.link/P0418
**\[P0418]** JF Bastien, Hans-J. Boehm. *Fail or succeed: there is no atomic lattice.* WG21/P0417r2, November 9, 2016. http://wg21.link/P0418

[P0690]: http://wg21.link/P0690
**\[P0690]** JF Bastien, Billy Robert O'Neal III, Andrew Hunter. *Tearable Atomics.* WG21/P0690, February 10, 2018. http://wg21.link/P0690

[P0735]: http://wg21.link/P0735
**\[P0735]**: Will Deacon, Jade Alglave. *Interaction of `memory_order_consume` with release sequences.* WG21/P0735r1, June 17, 2019. http://wg21.link/P0735

[P0750]: http://wg21.link/P0750
**\[P0750]** JF Bastien, Paul E. McKinney. *Consume*. WG21/P0750, February 11, 2018. http://wg21.link/P0750 

⚛︎︎

<!-- Local Variables: -->
<!-- mode: markdown -->
<!-- fill-column: 10000 -->
<!-- eval: (setq-local whitespace-style '(face tabs newline empty)) -->
<!-- eval: (whitespace-mode 1) -->
<!-- eval: (visual-line-mode 1) -->
<!-- End: -->
