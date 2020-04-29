# Low-Level Atomic Operations ⚛︎

* Proposal: [SE-0282](0282-atomics.md)
* Author: [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Bug: [SR-9144](https://bugs.swift.org/browse/SR-9144)
* Implementation: 
    - [apple/swift#30553][implementation] (Atomic operations)
    - [apple/swift#26969][constantPR] (Constant-constrained ordering arguments)
* Version: 2020-04-13
* Status: **Active Review (April 14...April 24, 2020)**

<!--
*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN) or [apple/swift-evolution-staging#NNNNN](https://github.com/apple/swift-evolution-staging/pull/NNNNN)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->


[implementation]: https://github.com/apple/swift/pull/30553
[constantPR]: https://github.com/apple/swift/pull/26969

## Introduction

This proposal adds a limited set of low-level atomic operations to the Standard Library, including native spellings for C++-style memory orderings. Our goal is to enable intrepid library authors to start building synchronization constructs directly in Swift.

Swift-evolution thread: [Low-Level Atomic Operations](https://forums.swift.org/t/low-level-atomic-operations/34683)

As a quick taste, this is how atomics will work:

```swift
import Atomics
import Dispatch

let counter = UnsafeAtomic<Int>.create(initialValue: 0)

DispatchQueue.concurrentPerform(iterations: 10) { _ in
  for _ in 0 ..< 1_000_000 {
    counter.wrappingIncrement(ordering: .relaxed)
  }
}
print(counter.load(ordering: .relaxed))
counter.destroy()
```

## Revision History

- 2020-04-13: Initial proposal version.

## Table of Contents

  * [Motivation](#motivation)
  * [Proposed Solution](#proposed-solution)
    * [The Atomics Module](#the-atomics-module)
    * [(Lack of) Memory Management](#lack-of-memory-management)
    * [Basic Atomic Operations](#basic-atomic-operations)
    * [Specialized Integer Operations](#specialized-integer-operations)
    * [Atomic Lazy References](#atomic-lazy-references)
    * [Atomic Memory Orderings](#atomic-memory-orderings)
    * [The Atomic Protocol Hierarchy](#the-atomic-protocol-hierarchy)
      * [Optional Atomics](#optional-atomics)
      * [Custom Atomic Types](#custom-atomic-types)
    * [Restricting Ordering Arguments to Compile\-Time Constants](#restricting-ordering-arguments-to-compile-time-constants)
  * [Interaction with Existing Language Features](#interaction-with-existing-language-features)
    * [Amendment to The Law of Exclusivity](#amendment-to-the-law-of-exclusivity)
    * [Interaction with Non\-Instantaneous Accesses](#interaction-with-non-instantaneous-accesses)
    * [Interaction with Implicit Pointer Conversions](#interaction-with-implicit-pointer-conversions)
  * [Detailed Design](#detailed-design)
    * [Atomic Memory Orderings](#atomic-memory-orderings-1)
    * [Atomic Protocols](#atomic-protocols)
      * [protocol AtomicProtocol](#protocol-atomicprotocol)
      * [protocol AtomicInteger](#protocol-atomicinteger)
    * [Atomic Types](#atomic-types)
      * [struct UnsafeAtomic&lt;Value&gt;](#struct-unsafeatomicvalue)
      * [struct UnsafeAtomicLazyReference&lt;Instance&gt;](#struct-unsafeatomiclazyreferenceinstance)
  * [Source Compatibility](#source-compatibility)
  * [Effect on ABI Stability](#effect-on-abi-stability)
  * [Effect on API Resilience](#effect-on-api-resilience)
  * [Potential Future Directions](#potential-future-directions)
    * [Memory\-Safe Atomic Constructs](#memory-safe-atomic-constructs)
    * [Double\-Wide Atomics and The ABA Problem](#double-wide-atomics-and-the-aba-problem)
    * [Atomic Strong References and The Problem of Memory Reclamation](#atomic-strong-references-and-the-problem-of-memory-reclamation)
    * [Additional Low\-Level Atomic Features](#additional-low-level-atomic-features)
  * [Alternatives Considered](#alternatives-considered)
    * [Default Orderings](#default-orderings)
    * [Alternative Names for UnsafeAtomic Types](#alternative-names-for-unsafeatomic-types)
    * [A Truly Universal Generic Atomic Type](#a-truly-universal-generic-atomic-type)
    * [Providing a value Property](#providing-a-value-property)
    * [Alternative Designs for Memory Orderings](#alternative-designs-for-memory-orderings)
      * [Encode Orderings in Method Names](#encode-orderings-in-method-names)
      * [Orderings As Generic Type Parameters](#orderings-as-generic-type-parameters)
      * [Ordering Views](#ordering-views)
  * [References](#references)

## Motivation

In Swift today, application developers use dispatch queues and Foundation's NSLocking protocol to synchronize access to mutable state across concurrent threads of execution.

However, for Swift to be successful as a systems programming language, it needs to also provide low-level primitives that can be used to implement such synchronization constructs (and many more!) directly within Swift.

One such low-level primitive is the concept of an atomic value, which (in the form we propose here) has two equally important roles:

- First, atomics introduce a limited set of types whose values provide well-defined semantics for certain kinds of concurrent access. This includes explicit support for concurrent mutations -- a concept that Swift never supported before.

- Second, atomic operations come with explicit memory ordering arguments, which provide guarantees on how/when the effects of earlier or later memory accesses become visible to other threads. Such guarantees are crucial for building higher-level synchronization abstractions.

These new primitives are intended for people who wish to implement synchronization constructs or concurrent data structures in pure Swift code. Note that this is a hazardous area that is full of pitfalls. While a well-designed atomics facility can help simplify building such tools, the goal here is merely to make it *possible* to build them, not necessarily to make it *easy* to do so. We expect that the higher-level synchronization tools that can be built on top of these atomic primitives will provide a nicer abstraction layer.

We want to limit this proposal to constructs that satisfy the following requirements:

1. All atomic operations need to be explicit in Swift source, and it must be possible to easily distinguish them from regular non-atomic operations on the underlying values.

2. The atomic types we provide must come with a lock-free implementation on every platform that implements them. (Platforms that are unable to provide lock-free implementations must not provide the affected constructs at all.)

3. Every atomic operation must compile down to the corresponding CPU instruction (when one is available), with minimal overhead. (Ideally even if the code is compiled without optimizations.) Wait-freedom isn't a requirement -- if no direct instruction is available for an operation, then it must still be implemented, e.g. by mapping it to a compare-exchange loop.

Note that while this proposal doesn't include a high-level concurrency design for Swift, it also doesn't preclude the eventual addition of one. Indeed, we expect that the addition of low-level atomics will serve as an important step towards language-level concurrency, by making it easier for motivated people to explore the design space on a library level.

The implementation of the constructs introduced in this document is available at the following URL: https://github.com/apple/swift/pull/30553

## Proposed Solution

We propose to officially adopt a C/C++-inspired memory model for Swift code:

* Concurrent write/write or read/write access to the same location in memory generally remains undefined/illegal behavior, unless all such access is done through a special set of primitive *atomic operations*.

* The same atomic operations can also apply *memory ordering* constraints that establish strict before/after relationships for accesses across multiple threads of execution. Such constraints can also be established by explicit *memory fences* that aren't tied to a particular atomic operation.

When applied carefully, atomic operations and memory ordering constraints can be used to implement higher-level synchronization algorithms that guarantee well-defined behavior for arbitrary variable accesses across multiple threads, by strictly confining their effects into some sequential timeline.

This document does not define a formal concurrency memory model in Swift, although we believe the methodology and tooling introduced for the C++ memory model and other languages could be adapted to work for Swift, too [[C++17], [Boehm 2008], [Batty 2011], [Nienhuis 2016], [Mattarei 2018]]. 

For now, we will be heavily relying on the Law of Exclusivity as defined in [[SE-0176]] and the [[Ownership Manifesto]], and we'll provide informal descriptions of how memory orderings interact with Swift's language features. The intention is that Swift's memory orderings will be fully interoperable with their C/C++ counterparts.


### The Atomics Module

While most Swift programs won't directly use the new atomic primitives, we still consider the new constructs to be an integral part of the core Standard Library.

 * The implementation of atomic operations needs access to compiler intrinsics that are only exposed to the Standard Library.
 * The memory orderings introduced here define a concurrency memory model for Swift code that has implications on the language as a whole. (Fortunately, Swift is already designed to interoperate with the C/C++ memory model, so introducing a subset of C++ memory orderings in the Standard Library doesn't by itself require language-level changes.)

That said, it seems highly undesirable to add low-level atomics to the default namespace of every Swift program, so we propose to place the atomic constructs in a new Standard Library module called `Atomics`. Code that needs to use low-level atomics will need to explicitly import the new module:

```swift
import Atomics
```

We expect that most Swift projects will use atomic operations only indirectly, through higher-level synchronization constructs. Therefore, importing the Atomics module will be a relatively rare occurrence, mostly limited to projects that implement such tools.

In this proposal, we are adding support for atomic operations on a small set of basic types.

All of these are covered by a single generic struct called `UnsafeAtomic` that implements an **unsafe reference type** holding a single, untagged primitive value of some atomic type:

```swift
struct UnsafeAtomic<Value: AtomicProtocol> { ... }
```

The full set of atomic types introduced in this proposal includes

- all standard fixed-width integer types, 
- standard pointer types and unmanaged references,
- optional pointers and optional unmanaged references,
- custom types that are raw-representable with an atomic type.

Here is a list of declarations demonstrating the variety of types supported:

```swift
// Standard signed integers:
let   i: UnsafeAtomic<Int> = ...
let i64: UnsafeAtomic<Int64> = ...
let i32: UnsafeAtomic<Int32> = ...
let i16: UnsafeAtomic<Int16> = ...
let  i8: UnsafeAtomic<Int8> = ...

// Standard unsigned integers:
let   u: UnsafeAtomic<UInt> = ...
let u64: UnsafeAtomic<UInt64> = ...
let u32: UnsafeAtomic<UInt32> = ...
let u16: UnsafeAtomic<UInt16> = ...
let  u8: UnsafeAtomic<UInt8> = ...

// Standard unsafe pointers:
let   r: UnsafeAtomic<UnsafeRawPointer> = ...
let  mr: UnsafeAtomic<UnsafeMutableRawPointer> = ...
let   p: UnsafeAtomic<UnsafePointer<T>> = ...
let  mp: UnsafeAtomic<UnsafeMutablePointer<T>> = ...

// Standard optional unsafe pointers:
let  or: UnsafeAtomic<Optional<UnsafeRawPointer>> = ...
let omr: UnsafeAtomic<Optional<UnsafeMutableRawPointer>> = ...
let  op: UnsafeAtomic<Optional<UnsafePointer<T>>> = ...
let omp: UnsafeAtomic<Optional<UnsafeMutablePointer<T>>> = ...

// Unmanaged references:
let   u: UnsafeAtomic<Unmanaged<T>> = ...
let  ou: UnsafeAtomic<Optional<Unmanaged<T>>> = ...

// Custom atomic representable types:
enum MyState: Int, AtomicProtocol {
  case starting
  case running
  case stopped
}
let  ar: UnsafeAtomic<MyState> = ...
```

As a special case, we are also introducing a lazily initializable but otherwise read-only atomic strong reference construct. This is unlike the others in that it offers a heavily restricted set of operations, and it is implemented by a standalone generic struct:

```
struct UnsafeAtomicLazyReference<Instance: AnyObject>
```

Most of these initial atomic types are built around "single-width" atomic operations -- meaning that all operations can be implemented using underlying compiler intrinsics that operate on *at most* a single, pointer-sized integer value. (The exceptions are `Int64` and `UInt64` on 32-bit platforms, which require double-wide atomics.)

Atomic operations for the pointer and reference types above could be implemented as mere convenience wrappers around atomic `Int` operations. In theory, we could therefore omit them without loss of performance or generality. However, in practice, we expect users will need to build abstractions for atomic pointers anyway, and it makes sense to standardize APIs to unify terminology, eliminate boilerplate and to prevent confusion across projects. By providing implementations for these directly in the Standard Library, we are able to add custom `AtomicProtocol` conformances to integrate them directly into `UnsafeAtomic`. We are adding support for custom atomic-representable types for the same reason.

Notably, none of these atomic types support composite values -- they provide no direct support for storing additional information (such as a version stamp) alongside the primary value. See the section on [*Double-Wide Atomics*](#double-wide-atomics-and-the-aba-problem) for some important constructs that we may want to add later. Our expectation is that the experience we'll gain with this initial batch will inform the design of those potential future additions.

The `Atomics` module also defines three enum-like structs representing the three flavors of memory orderings, and a standalone top-level function for issuing memory barriers. We'll describe these in [*Atomic Memory Orderings*](#atomic-memory-orderings).

### (Lack of) Memory Management

As implied by the `Unsafe` prefix, the new atomic constructs do not provide automated memory management for the memory location that holds their value. Both unsafe atomic types provide an `init(at:)` initializer that takes a pointer to appropriately initialized storage.

```swift
public struct UnsafeAtomic<Value: AtomicProtocol> {
  public struct Storage {
    // Transform `value` into a new storage instance.
    init(_ value: __owned Value)
    // Dispose of this storage instance, returning the final value it represents.
    mutating func dispose() -> Value
  }

  public init(at address: UnsafeMutablePointer<Storage>)
}

public struct UnsafeAtomicLazyReference<Instance: AnyObject> {
  public struct Storage {
    init()
    mutating func dispose() -> Instance?
  }

  public init(at address: UnsafeMutablePointer<Storage>)
}
```

Code that uses these unsafe atomic types must manually manage the lifecycle of the underlying memory location to ensure

1. that it is bound to the correct `Storage` type,
2. that it is initialized to a well-defined value through `Storage.init(_:)`,
3. that the location remains valid while it is being accessed through atomic operations, and
4. that the storage is properly disposed of (using `Storage.dispose()`) before the memory location is destroyed.

This is typically done by allocating a dynamic variable dedicated to holding storage for the atomic value:

```swift
func atomicDemo<Value: AtomicProtocol>(initialValue: Value) {
  // Create an initialized unsafe atomic value
  typealias Storage = UnsafeAtomic<Value>.Storage
  let ptr = UnsafeMutablePointer<Storage>.allocate(capacity: 1)
  ptr.initialize(to: Storage(initialValue))
  let atomic = UnsafeAtomic<Value>(at: ptr)

  ... // Use `atomic`

  // Destroy it
  _ = ptr.pointee.dispose()
  ptr.deinitialize(count: 1)
  ptr.deallocate()
}
```

In fact, this is such a commonly reoccurring pattern that both `UnsafeAtomic*` types provide a couple of convenience methods to do it for us:

``` swift
extension UnsafeAtomic {
  // Dynamically allocates & initializes storage
  public static func create(initialValue: __owned Value) -> Self
  
  // Deinitializes and deallocates storage, returning final value
  @discardableResult
  public func destroy() -> Value
}

extension UnsafeAtomicLazyReference {
  public static func create() -> Self // Initializes to `nil`

  @discardableResult
  public func destroy() -> Instance?
}
```

We can use these to improve readability:

```swift
let atomic = UnsafeAtomic<Value>.create(initialValue: 0)
... // Use `atomic`
atomic.destroy()
```

Consistent use of `create`/`destroy` makes it far easier to audit code that manages the lifetime of these constructs. For example, in the typical case where `UnsafeAtomic` values are used as class instance variables, we expect to see a call to `create` during initialization, and a call to `destroy` in `deinit`:

```swift
class AtomicCounter {
  private let _value = UnsafeAtomic<Int>.create(initialValue: 0)

  deinit {
    _value.destroy()
  }

  func increment() {
    _value.wrappingIncrement(by: 1, ordering: .relaxed)
  }

  func get() -> Int {
    _value.load(ordering: .relaxed)
  }
}
```

While `create`/`destroy` are convenient, the ability to manually control the storage location is critical for use cases where a separate allocation for every atomic value would be wasteful. (For example, these use cases can use `ManagedBuffer` APIs to create atomic storage directly within a class instance.)

Now that we know how to create and destroy atomic values, it's time to introduce some actual atomic operations.

### Basic Atomic Operations

`UnsafeAtomic` provides six basic atomic operations for all supported types:

```swift
extension UnsafeAtomic {
  // Atomically load and return the current value.
  public func load(ordering: AtomicLoadOrdering) -> Value
  
  // Atomically update the current value.
  public func store(_ desired: __owned Value, ordering: AtomicStoreOrdering)

  // Atomically update the current value, returning the original value.
  public func exchange(
    _ desired: __owned Value, 
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func compareExchange(
    expected: Value,
    desired: __owned Value,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Value)

  public func compareExchange(
    expected: Value,
    desired: __owned Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)

  public func weakCompareExchange(
    expected: Value,
    desired: __owned Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)
}
```

The `ordering` arguments indicate if the atomic operation is also expected to synchronize the effects of previous (or subsequent) accesses. This is explained in a separate section below.

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

All three variants implement the same algorithm. The first variant uses the same memory ordering whether or not the exchange succeeds, while the other two allow callers to specify two distinct memory orderings for the success and failure cases. The two orderings are independent from each other -- all combinations of update/load orderings are supported [[P0418]]. (Of course, the implementation may need to "round up" to the nearest ordering combination that is supported by the underlying code generation layer and the targeted CPU architecture.)

The `weakCompareExchange` form may sometimes return false even when the original and expected values are equal. (Such failures may happen when some transient condition prevents the underlying operation from succeeding -- such as an incoming interrupt during a load-link/store-conditional instruction sequence.) This variant is designed to be called in a loop that only exits when the exchange is successful; in such loops using `weakCompareExchange` may lead to a performance improvement by eliminating a nested loop in the regular, "strong", `compareExchange` variants.

The compare-exchange primitive is special: it is a universal operation that can be used to implement all other atomic operations, and more. For example, here is how we could use `compareExchange` to implement a wrapping increment operation over `UnsafeAtomic<Int>` values:

```swift
extension UnsafeAtomic where Value == Int {
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
        ordering: ordering)
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

`UnsafeAtomic<Value>` exposes these operations when `Value` conforms to the `AtomicInteger` protocol, which all standard fixed-width integer types do.

```swift
extension UnsafeAtomic where Value: AtomicInteger {
  public func loadThenWrappingIncrement(
    by delta: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value
  ...
  public func bitwiseOrThenLoad(
    with value: Value, 
    ordering: AtomicUpdateOrdering
  ) -> Value
  ...
  public func wrappingIncrement(
    by delta: Value,
    ordering: AtomicUpdateOrdering
  )
}

let counter = UnsafeAtomic<Int>.create(initialValue: 0)
defer { counter.destroy() }
counter.wrappingIncrement(by: 42, ordering: .relaxed)
```


### Atomic Lazy References

The operations provided by `UnsafeAtomic<Unmanaged<T>>` only operate on the unmanaged reference itself. They don't allow us directly access to the referenced object -- we need to manually invoke the methods `Unmanaged` provides for this purpose (usually, `takeUnretainedValue`).

Note that loading the atomic unmanaged reference and converting it to a strong reference are two distinct operations that won't execute as a single atomic transaction. This can easily lead to race conditions when a thread releases an object while another is busy loading it:

```swift
// BROKEN CODE. DO NOT EMULATE IN PRODUCTION.
let myAtomicRef = UnsafeAtomic<Unmanaged<Foo>>.create(initialValue: ...)

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

Such problems make `UnsafeAtomic<Unmanaged<T>>` exceedingly difficult to use in all but the simplest situations. The section on [*Atomic Strong References*](#atomic-strong-references-and-the-problem-of-memory-reclamation) below describes some new constructs we may introduce in future proposals to assist with this issue.

For now, we provide the standalone type `UnsafeAtomicLazyReference`; this is an example of a useful construct that could be built on top of `UnsafeAtomic<Unmanaged>` operations. (Of all the various atomic constructs introduced in this proposal, only `UnsafeAtomicLazyReference` represents a regular strong reference to a class instance -- the other pointer/reference types leave memory management entirely up to the user.)

An `UnsafeAtomicLazyReference` holds an optional reference that is initially set to `nil`. The value can be set exactly once, but it can be read an arbitrary number of times. Attempts to change the value after the first `storeIfNilThenLoad` call are ignored, and return the current value instead.

```swift
public struct UnsafeAtomicLazyReference<Instance: AnyObject> {
  public typealias Value = Instance?

  public struct Storage {
    public init()

    @discardableResult 
    public mutating func dispose() -> Value
  }

  public init(at address: UnsafeMutablePointer<Storage>)

  public static func create() -> Self
  @discardableResult 
  public func destroy() -> Value

  public func storeIfNilThenLoad(_ desired: __owned Instance) -> Instance
  public func load() -> Instance?
}
```

This is the only atomic type in this proposal that doesn't provide the usual `load`/`store`/`exchange`/`compareExchange` operations.

This construct allows library authors to implement a thread-safe lazy initialization pattern:

```swift
var _foo: UnsafeAtomicLazyReference<Foo> = ...

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

### Atomic Memory Orderings

To enable the implementation of synchronization constructs in pure Swift code, we must introduce a memory consistency model in the language. Luckily, Swift already interoperates with the C/C++ memory model, so it seems reasonable to adopt a C/C++-style memory model based on acquire and release orderings. In this model, concurrent access to shared state remains undefined behavior unless all such access is forced into a conflict-free timeline through explicit synchronization operations.

The atomic constructs above implement concurrent read/write access by mapping to atomic instructions in the underlying architecture. All accesses of a particular atomic value get serialized into some global sequential timeline, no matter what thread executed them.

However, this alone does not give us a way to synchronize accesses to regular variables, or between atomic accesses to different memory locations. To support such synchronization, each atomic operation can be configured to also act as a synchronization point for other variable accesses within the same thread, preventing previous accesses from getting executed after the atomic operation, and/or vice versa. Atomic operations on another thread can then synchronize with the same point, establishing a strict (although partial) timeline between accesses performed by both threads. This way, we can reason about the possible ordering of operations across threads, even if we know nothing about how those operations are implemented. (This is how locks or dispatch queues can be used to serialize the execution of arbitrary blocks containing regular accesses to shared variables.) For more details, see \[[C++17], [N2153], [Boehm 2008]].

We can use the the `ordering:` parameter of each atomic operation to specify the level of synchronization it needs to provide. This proposal introduces five distinct memory orderings, organized into three logical groups, from loosest to strictest:

* `.relaxed`
* `.acquiring`, `.releasing`, `.acquiringAndReleasing`
* `.sequentiallyConsistent`

These align with select members of the standard `std::memory_order` enumeration in C++, and are intended to carry the same semantic meaning:

| C++ | Swift |
| :---: | :---: |
| `std::memory_order_relaxed` | `.relaxed`   |
| `std::memory_order_consume` | *not adopted yet* [[P0735]] |
| `std::memory_order_acquire` | `.acquiring` |
| `std::memory_order_release` | `.releasing` |
| `std::memory_order_acq_rel` | `.acquiringAndReleasing` |
| `std::memory_order_seq_cst` | `.sequentiallyConsistent` |

We consider these ordering arguments to be an essential part of low-level atomic operations, and we require an explicit `ordering` argument on all atomic operations provided by `UnsafeAtomic`. The intention here is to force developers to carefully think about what ordering they need to use, each time they use one of these primitives. (Perhaps more importantly, this also makes it obvious to readers of the code what ordering is used -- making it far less likely that an unintended `.sequentiallyConsistent` ordering slips through code review.) 

Projects that prefer to default to sequentially consistent ordering are welcome to add non-public `UnsafeAtomic` extensions that implement that. However, we expect that providing an implicit default ordering would be highly undesirable in most production uses of atomics.

Atomic orderings are grouped into three frozen structs based on the kind of operation to which they are attached, as listed below. By modeling these as separate types, we can ensure that unsupported operation/ordering combinations (such as an atomic "releasing load") will lead to clear compile-time errors:


```swift
@frozen
struct AtomicLoadOrdering {
  static var relaxed: Self { get }
  static var acquiring: Self { get }
  static var sequentiallyConsistent: Self { get }
}

@frozen
struct AtomicStoreOrdering {
  static var relaxed: Self { get }
  static var releasing: Self { get }
  static var sequentiallyConsistent: Self { get }
}

@frozen
struct AtomicUpdateOrdering {
  static var relaxed: Self { get }
  static var acquiring: Self { get }
  static var releasing: Self { get }
  static var acquiringAndReleasing: Self { get }
  static var sequentiallyConsistent: Self { get }
}
```

These structs behave like non-frozen enums with a known (non-public) raw representation. This allows us to define additional memory orderings in the future (if and when they become necessary) while making use of the known representation to optimize existing cases. (These cannot be frozen enums because that would prevent us from adding more orderings, but regular resilient enums can't freeze their representation, and the layout indirection interferes with guaranteed optimizations, especially in -Onone.)

We also provide a top-level function called `atomicMemoryFence` that allows issuing a memory ordering constraint without directly associating it with a particular atomic operation. This corresponds to `std::memory_thread_fence` in C++ [[C++17]].

```swift
public func atomicMemoryFence(ordering: AtomicUpdateOrdering)
```

Fences are slightly more powerful (but even more difficult to use) than orderings tied to specific atomic operations [[N2153]]; we expect their use will be limited to the most performance-sensitive synchronization constructs.

### The Atomic Protocol Hierarchy

The notion of an atomic type is captured by the `AtomicProtocol` protocol. `AtomicInteger` refines it to add support for a select list of atomic integer operations.

```swift
public protocol AtomicProtocol {
  ...
}

public protocol AtomicInteger: AtomicProtocol, FixedWidthInteger
where ... {
  ...
}
```

While `AtomicProtocol` and `AtomicInteger` are public protocols, their requirements are considered an implementation detail of the Standard Library. (They are replaced by ellipses above.) 

These hidden requirements set up a bidirectional mapping between values of the atomic type and an associated (private) storage representation that implements the actual primitive atomic operations. 

The specific details are outside the scope of the Swift Evolution process and they are subject to arbitrarily change between Standard Library releases, as long as ABI compatibility is maintained (as necessary).

Following existing Standard Library conventions for such interfaces, the names of all associated types and member requirements of these protocols start with a leading underscore character. As with any other underscored interface exposed by the Standard Library, code that manually implements or directly uses these underscored requirements may fail to compile (or correctly run) when built using any Swift release other than the one for which it was initially written. 

The full set of standard types implementing `AtomicProtocol` is listed below.

```swift
extension UnsafeRawPointer: AtomicProtocol {...}
extension UnsafeMutableRawPointer: AtomicProtocol {...}
extension UnsafePointer: AtomicProtocol {...}
extension UnsafeMutablePointer: AtomicProtocol {...}
extension Unmanaged: AtomicProtocol {...}

extension Int: AtomicInteger {...}
extension Int64: AtomicInteger {...}
extension Int32: AtomicInteger {...}
extension Int16: AtomicInteger {...}
extension Int8: AtomicInteger {...}
extension UInt: AtomicInteger {...}
extension UInt64: AtomicInteger {...}
extension UInt32: AtomicInteger {...}
extension UInt16: AtomicInteger {...}
extension UInt8: AtomicInteger {...}

extension Optional: AtomicProtocol where Wrapped: AtomicProtocol, ... {...}
```

We only provide atomic arithmetic operations on integer types. While it would be technically possible to allow atomic pointer arithmetic, this would be inherently unsafe, unless it is integrated with explicit checks to prevent the pointer value from escaping the extents of the underlying buffer. We do not consider such operations to be useful enough to include in the Standard Library; and the compare-exchange loop that implements them can be easily provided in user code as desired.

#### Optional Atomics

The standard atomic pointer types and unmanaged references also support atomic operations on their optional-wrapped form. `Optional` implements this through a conditional conformance to `AtomicProtocol`; the exact constraint is an implementation detail. (It works by requiring the wrapped type's internal atomic storage representation to support a special nil value.)

```swift
extension Optional: AtomicProtocol where ... {
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

Atomic optional pointers and references are helpful when building lock-free data structures. (Although this initial set of reference types considerably limits the scope of what can be built; for more details, see the discussion on the ABA problem and memory reclamation in the [Potential Future Directions](#double-wide-atomics-and-the-aba-problem) section.)

For example, consider the lock-free, single-consumer stack implementation below. (It supports an arbitrary number of concurrently pushing threads, but it only allows a single pop at a time.)

```swift
class LockFreeSingleConsumerStack<Element> {
  struct Node {
    let value: Element
    var next: UnsafeMutablePointer<Node>?
  }
  typealias NodePtr = UnsafeMutablePointer<Node>

  private var _last = UnsafeAtomic<NodePtr?>.create(initialValue: nil)
  private var _consumerCount = UnsafeAtomic<Int>.create(initialValue: 0)

  deinit {
    // Discard remaining nodes
    while let _ = pop() {}
    _last.destroy()
    _consumerCount.destroy()
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
        ordering: .releasing)
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
        ordering: .acquiring)
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

To enable a limited set of user-defined atomic types, `AtomicProtocol` also provides a full set of default implementations for `RawRepresentable` types whose raw value is itself atomic:

```swift
extension AtomicProtocol 
where Self: RawRepresentable, RawValue: AtomicProtocol, ... {
  ...
}
```

The omitted constraint sets up the (hidden) atomic storage type to match that of the `RawValue`. The default implementations work by forwarding all atomic operations to the raw value's implementation, converting to/from as needed.

This enables code outside of the Standard Library to add new `AtomicProtocol` conformances without manually implementing any of the hidden requirements. This is especially handy for trivial raw-representable enumerations, such as in simple atomic state machines:

```swift
enum MyState: Int, AtomicProtocol {
  case starting
  case running
  case stopped
}

let currentState = UnsafeAtomic<MyState>.create(initialValue: .starting)
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
...
currentState.destroy()
```


### Restricting Ordering Arguments to Compile-Time Constants

Modeling orderings as regular function parameters allows us to specify them using syntax that's familiar to all Swift programmers. Unfortunately, it means that in the implementation of atomic operations we're forced to switch over the ordering argument:

```swift
extension Int: AtomicInteger {
  public typealias AtomicStorage = Self
  ...
  public func atomicCompareExchange(
    expected: Int,
    desired: Int,
    at address: UnsafeMutablePointer<AtomicStorage>,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Int) {
    // Note: This is a simplified version of the actual implementation
    let won: Bool
    let oldValue: Int
    switch ordering {
    case .relaxed:
      (oldValue, won) = Builtin.cmpxchg_monotonic_monotonic_Word(
        address, expected, desired)
    case .acquiring:
      (oldValue, won) = Builtin.cmpxchg_acquire_acquire_Word(
        address, expected, desired)
    case .releasing:
      (oldValue, won) = Builtin.cmpxchg_release_monotonic_Word(
        address, expected, desired)
    case .acquiringAndReleasing:
      (oldValue, won) = Builtin.cmpxchg_acqrel_acquire_Word(
        address, expected, desired)
    default: // .sequentiallyConsistent
      (oldValue, won) = Builtin.cmpxchg_seqcst_seqcst_Word(
        address, expected, desired)
    }
    return (won, oldValue)
  }
}
```

Given our requirement that primitive atomics must always compile down to the actual atomic instructions with minimal additional overhead, we must guarantee that these switch statements always get optimized away into the single case we need; they must never actually be evaluated at runtime.

Luckily, configuring these special functions to always get force-inlined into all callers guarantees that constant folding will get rid of the switch statement *as long as the supplied ordering is a compile-time constant*. Unfortunately, it's all too easy to accidentally violate this latter requirement, with dire consequences to the expected performance of the atomic operation.

Consider the following well-meaning attempt at using `compareExchange` to define an atomic integer addition operation that traps on overflow rather than allowing the result to wrap around:

```swift
extension UnsafeAtomic where Value == Int {
  // Non-inlinable
  public func checkedIncrement(by delta: Int, ordering: AtomicUpdateOrdering) {
    var done = false
    var current = load(ordering: .relaxed)
    while !done {
      (done, current) = compareExchange(
        expected: current,
        desired: current + operand, // Traps on overflow
        ordering: ordering)
    }
  }
}

// Elsewhere:
counter.checkedIncrement(by: 1, ordering: .relaxed)
```

If for whatever reason the Swift compiler isn't able (or willing) to inline the `checkedIncrement` call, then the value of `ordering` won't be known at compile time to the body of the function, so even though `compareExchange` will still get inlined, its switch statement won't be eliminated. This leads to a potentially significant performance regression that could interfere with the scalability of the operation.

To prevent these issues, we are adding a special type checking phase that artificially constrains the memory ordering arguments of all atomic operations to compile-time constants. Any attempt to pass a dynamic ordering value (such as in the `compareExchange` call above) will result in a compile-time error.

An ordering expression will be considered constant-evaluable if it's either (1) a direct call to one of the `Atomic*Ordering` factory methods (`.relaxed`, `.acquiring`, etc.), or (2) it is a direct reference to a variable that is in turn constrained to be constant-evaluable.

> **Note:** The implementation of this feature is available in a separate PR, [apple/swift#26969][constantPR].

The compiler work to make this happen could eventually form the basis of a new general-purpose language facility around constant-evaluable expressions; however, the initial implementation only supports the specific set of atomic operations introduced in this proposal. (For now, user-defined wrappers like `checkedIncrement` above won't be able to take an ordering parameter and pass it to an underlying atomic operation.)

## Interaction with Existing Language Features

### Amendment to The Law of Exclusivity

The new atomic operations appear to implement read or write access to some sort of variable, but unlike regular read/write accesses, it is inherently safe to execute them concurrently. Indeed, allowing concurrent access is the primary reason we want to introduce them! Therefore, we must make sure that the Law of Exclusivity won't disallow such use.

The proposed atomic operations are implemented as unsafe pointer operations; in fact, the new atomic types are merely thin wrappers around unsafe pointers. While [[SE-0176]] didn't introduce any active enforcement of the Law of Exclusivity for unsafe pointers, it still defined overlapping read/write access to their pointee as an exclusivity violation.

To resolve this problem, we propose to introduce the concept of *atomic access*, and to amend the Law of Exclusivity as follows:

> Two accesses to the same variable aren't allowed to overlap unless both accesses are reads **or both accesses are atomic**.

We define *atomic access* as a call to one of the atomic operations introduced in this proposal: `load(ordering:)`, `compareExchange(expected:desired:ordering:)`, etc. We consider two of these operations to *access the same variable* if they operate on the same underlying memory location. (Future proposals may introduce additional ways to perform atomic access.)

We view the amendment above as merely formalizing pre-existing practice, rather than introducing any actual new constraint. 

> **Note:** As such, this proposal is mostly about a library-level addition; its implementation doesn't need to change how the Swift compiler implements the Swift memory model. For example, there is no need to relax any existing compile-time or runtime checks for exclusivity violations, because unsafe pointer operations aren't currently covered by such checks. Similarly, because the new operations map directly to llvm's atomic instructions, they smoothly interoperate with the existing llvm-based Thread Sanitizer tool [[Tsan1], [TSan2]].

For now, we leave mixed atomic/non-atomic access to the same memory location as undefined behavior, even if the mixed accesses are guaranteed to never overlap. (This restriction does not apply to accesses during storage initialization and deinitialization; those are always nonatomic.) A future proposal may lift this limitation.

### Interaction with Non-Instantaneous Accesses

Note: This section merely highlights a preexisting consequence of the Law of Exclusivity. It doesn't propose any changes to the language or the Standard Library.

As described in [[SE-0176]], Swift allows accesses that are non-instantaneous. For example, calling a `mutating` method on a variable counts as a single write access that is active for the entire duration of the method call:

```swift
var integers: [Int] = ...
...
integers.sort() // A single, long write access
```

The Law of Exclusivity disallows overlapping read/write and write/write accesses to the same variable, so while one thread is performing `sort()`, no other thread is allowed to access `integers` at all. Note that this is independent of `sort()`'s implementation; it is merely a consequence of the fact that it is declared `mutating`.

> **Note:** One reason for this is that the compiler may decide to implement the mutating call by first copying the current value of `integers` into a temporary variable, running `sort` on that, and then copying the resulting value back to `integers`. If `integers` had a computed getter and setter, this is in fact the only reasonable way to implement the mutating call. If overlapping access wasn't disallowed, such implicit copying would lead to race conditions even if the `mutating` method did not actually mutate any data at all.

An important aspect of atomic memory orderings is that they can only synchronize accesses whose duration doesn't overlap with the atomic operations themselves. They inherently cannot synchronize variable accesses that are still in progress while the atomic operation is being executed.

This means that it isn't possible to implement any "thread-safe" `mutating` methods, no matter how much synchronization we add to their implementation. For example, the following attempt to implement an "atomic" increment operation on `Int` is inherently doomed to failure:

```swift
import Dispatch
import Foundation

let _mutex = NSLock()

extension Int {
  mutating func atomicIncrement() { // BROKEN, DO NOT USE
    _mutex.lock()
    self += 1
    _mutex.unlock()
  }
}

var i: Int
...
i = 0
DispatchQueue.concurrentPerform(iterations: 10) { _ in
  for _ in 0 ..< 1_000_000 {
    i.atomicIncrement()  // Exclusivity violation
  }
}
print(i)
```

Even though `NSLock` does guarantee that the `self += 1` line is always serialized, the concurrent `atomicIncrement` invocations still count as an exclusivity violation, because the write access to `i` starts when the function call begins, before the call to `_mutex.lock()`. Therefore, the code above has undefined behavior, despite all the locking. (For example, it may print any value between one and ten million, or it may trap in a runtime exclusivity check, or indeed it may do something else.)

Note that this restriction wasn't introduced by our new low-level atomic primitives -- it is a preexisting property of the language.

This is one of the reasons why `AtomicCounter` and `LockFreeSingleConsumerStack` were declared as classes above. Class instance methods are allowed to mutate their stored properties without declaring themselves `mutating`, and thus they are outside the scope of the Law of Exclusivity. (Of course, their implementation must still guarantee that the Law is upheld for any variables they access.)

> **Note:** A more fundamental reason why these constructs are classes is that synchronization constructs are difficult to model with value types -- their instances tend to have an inherent identity that prevents copies from working like the original, they often need to be backed by a stable memory location, etc. The [Ownership Manifesto]'s non-copiable types may eventually provide a more efficient and safer model for such constructs, but in today's Swift, we need to represent them with some reference type instead: typically, either a class (like `AtomicCounter`) or some unsafe pointer type (like `UnsafeAtomic`).

### Interaction with Implicit Pointer Conversions

To simplify interoperability with functions imported from C, Swift provides several forms of implicit conversions from Swift values to unsafe pointers. This often requires the use of Swift's special `&` syntax for passing inout values. At first glance, this use of the ampersand resembles C's address-of operator, and it seems to work in a similar way:

```swift
func a(_ ptr: UnsafePointer<CChar>)
func b(_ ptr: UnsafePointer<Int>)

// Implicit conversion from String to nul-terminated C string
a("Hello")

// Implicit conversion from Array to UnsafePointer<Element>
var array = [1, 2, 3]
b(array)  // passes a pointer to array's underlying storage buffer
b(&array) // another way to spell the same

// Implicit conversion from inout T to UnsafePointer<T>
var value = 42
b(&value)
b(&array[0])
```

Unfortunately, Swift variables do not necessarily have a stable location in memory, and even in case they happen to get assigned one, there is generally no reliable way to retrieve the address of their storage. (The obvious exceptions are dynamic variables that we explicitly allocate ourselves.) 

While these conversions sometimes allow us to call C functions with less typing, they are extremely misleading -- to the point of being actively harmful. The problem is that unlike in C, the resulting pointers are only guaranteed to be valid for the duration of the function call. The pointer conversions above may (and frequently do!) create a temporary copy of the inout value that gets destroyed when the function returns. Holding onto the pointer after the function returns leads to undefined behavior. (Even if it appears to work in a particular situation, it may break the next time the code is recompiled with seemingly irrelevant changes.)

For example, we may be tempted to eliminate a memory allocation for an `UnsafeAtomic` instance by using an inout-to-pointer conversion to "take the address of" a class instance variable, and passing it to the `UnsafeAtomic.init(at:)` initializer. This is not supported in the language, and it leads to undefined behavior.

```swift
class BrokenAtomicCounter { // THIS IS BROKEN; DO NOT USE
  private var _storage = UnsafeAtomic<Int>.Storage(0)
  private var _value: UnsafeAtomic<Int>?
      
  init() {
    // This escapes the ephemeral pointer generated by the inout expression,
    // so it leads to undefined behavior when the pointer gets dereferenced
    // in the atomic operations below. DO NOT DO THIS.
    _value = UnsafeAtomic<Int>(at: &_storage)
  }
  
  func increment() {
    _value!.wrappingIncrement(by: 1, ordering: .relaxed)
  }

  func get() -> Int {
    _value!.load(ordering: .relaxed)
  }
}
```

To prevent such misuse, in the current implementation of this proposal, the code above generates a warning:

```text
warning: inout expression creates a temporary pointer, but argument 'at' should be 
a pointer that outlives the call to 'init(at:)'
    _value = UnsafeAtomic<Int>(at: &_storage)
                                   ^~~~~~~~~
```

This is implemented using a preexisting diagnostic based on a compiler heuristic. Ideally this warning would be promoted to a compile-time error.

> **Note:** For an idea on how to add proper language support for taking the address of certain kinds of variables, see the discussion on the hypothetical `@addressable` attribute in [Memory\-Safe Atomic Constructs](#memory-safe-atomic-constructs).


## Detailed Design

In the interest of keeping this document (relatively) short, the following API synopsis does not include API documentation, inlinable method bodies, or `@usableFromInline` declarations, and omits most attributes (`@available`, `@inlinable`, etc.).

To allow atomic operations to compile down to their corresponding CPU instructions, most entry points listed here will be defined `@inlinable`.

For the full API definition, please refer to the [implementation][implementation].

### Atomic Memory Orderings

```swift
public func atomicMemoryFence(ordering: AtomicUpdateOrdering)

@frozen
public struct AtomicLoadOrdering: Equatable, Hashable, CustomStringConvertible {
  public static var relaxed: Self { get }
  public static var acquiring: Self { get }
  public static var sequentiallyConsistent: Self { get }

  public static func ==(left: Self, right: Self) -> Bool
  public func hash(into hasher: inout Hasher)
  public var description: String { get }
}

@frozen
public struct AtomicStoreOrdering: Equatable, Hashable, CustomStringConvertible {
  public static var relaxed: Self { get }
  public static var releasing: Self { get }
  public static var sequentiallyConsistent: Self { get }

  public static func ==(left: Self, right: Self) -> Bool
  public func hash(into hasher: inout Hasher)
  public var description: String { get }
}

@frozen
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
```

### Atomic Protocols

#### `protocol AtomicProtocol`

```swift
public protocol AtomicProtocol {
  // Requirements aren't public API.
}
```

The requirements set up a bidirectional mapping between values of the atomic type and an associated (private) storage representation that supplies the actual primitive atomic operations. 

The exact requirements are a private implementation detail of the Standard Library. They are outside the scope of the Swift Evolution process and they may arbitrarily change between library releases. User code must not directly use them or manually implement them.


Conforming types:

```swift
extension UnsafeRawPointer: AtomicProtocol {...}
extension UnsafeMutableRawPointer: AtomicProtocol {...}
extension UnsafePointer: AtomicProtocol {...}
extension UnsafeMutablePointer: AtomicProtocol {...}
extension Unmanaged: AtomicProtocol {...}

extension Optional: AtomicProtocol where Wrapped: AtomicProtocol, ... {...}
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

To support custom "atomic-representable" types, `AtomicProtocol` also comes with default implementations for all its requirements for `RawRepresentable` types whose `RawValue` is also atomic:

```swift
extension AtomicProtocol where Self: RawRepresentable, RawValue: AtomicProtocol, ... {
  // Implementations for all requirements.
}
```

The omitted constraint sets up the (private) atomic storage type to match that of the `RawValue`. The default implementations work by converting values to their `rawValue` form, and forwarding all atomic operations to it.



#### `protocol AtomicInteger`

```swift
public protocol AtomicInteger: AtomicProtocol, FixedWidthInteger {
  // Requirements aren't public API.
}
```

(One of the requirements is that atomic integers must serve as their own (private) atomic storage representation.)

Conforming types:

```swift
extension Int: AtomicInteger { ... }
extension Int64: AtomicInteger { ... }
extension Int32: AtomicInteger { ... }
extension Int16: AtomicInteger { ... }
extension Int8: AtomicInteger { ... }

extension UInt: AtomicInteger { ... }
extension UInt64: AtomicInteger { ... }
extension UInt32: AtomicInteger { ... }
extension UInt16: AtomicInteger { ... }
extension UInt8: AtomicInteger { ... }
```

This protocol is not designed to support user-provided conformances.

### Atomic Types

#### `struct UnsafeAtomic<Value>`

```swift
@frozen
public struct UnsafeAtomic<Value: AtomicProtocol> {
  @frozen
  public struct Storage {
    public init(_ value: __owned Value)

    @discardableResult
    public mutating func dispose() -> Value
  }

  public init(at pointer: UnsafeMutablePointer<Storage>)

  public static func create(initialValue: __owned Value) -> Self

  @discardableResult
  public func destroy() -> Value

  // Atomic operations:

  public func load(ordering: AtomicLoadOrdering) -> Value

  public func store(_ desired: __owned Value, ordering: AtomicStoreOrdering)

  public func exchange(
    _ desired: __owned Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func compareExchange(
    expected: Value,
    desired: __owned Value,
    ordering: AtomicUpdateOrdering
  ) -> (exchanged: Bool, original: Value)

  public func compareExchange(
    expected: Value,
    desired: __owned Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)

  public func weakCompareExchange(
    expected: Value,
    desired: __owned Value,
    successOrdering: AtomicUpdateOrdering,
    failureOrdering: AtomicLoadOrdering
  ) -> (exchanged: Bool, original: Value)
}
```

`UnsafeAtomic` also provides a handful of integer operations for the standard fixed-width integer types. This is implemented via the `AtomicInteger` protocol.

```swift
extension UnsafeAtomic where Value: AtomicInteger {
  public func loadThenWrappingIncrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func wrappingIncrementThenLoad(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func wrappingIncrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  )

  public func loadThenWrappingDecrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func wrappingDecrementThenLoad(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func wrappingDecrement(
    by operand: Value = 1,
    ordering: AtomicUpdateOrdering
  )

  public func loadThenBitwiseAnd(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func bitwiseAndThenLoad(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func loadThenBitwiseOr(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func bitwiseOrThenLoad(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func loadThenBitwiseXor(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value

  public func bitwiseXorThenLoad(
    _ operand: Value,
    ordering: AtomicUpdateOrdering
  ) -> Value
}
```

#### `struct UnsafeAtomicLazyReference<Instance>`

```swift
public struct UnsafeAtomicLazyReference<Instance: AnyObject> {
  public typealias Value = Instance?

  @frozen
  public struct Storage {
    public init()

    @discardableResult
    public mutating func dispose() -> Value
  }

  public init(at address: UnsafeMutablePointer<Storage>)

  public static func create() -> Self

  @discardableResult
  public func destroy() -> Value

  // Atomic operations:

  public func storeIfNilThenLoad(_ desired: __owned Instance) -> Instance
  public func load() -> Instance?
}
```

## Source Compatibility

This is a purely additive change with no source compatibility impact.

## Effect on ABI Stability

This proposal introduces new entry points to the Standard Library ABI in a standalone `Atomics` module, but otherwise it has no effect on ABI stability.

On ABI-stable platforms, the struct types and protocols introduced here will become part of the stdlib's ABI with availability matching the first OS releases that include them.

Most of the atomic methods introduced in this document will be force-inlined directly into
client code at every call site. As such, there is no reason to bake them into
the stdlib's ABI -- the stdlib binary will not export symbols for them.

## Effect on API Resilience

This is an additive change; it has no effect on the API of existing code.

For the new constructs introduced here, the proposed design allows us to make the following changes in future versions of the Swift Standard Library:

- Addition of new atomic types (and higher-level constructs built around them). (These new types would not directly back-deploy to OS versions that predate their introduction.)

- Addition of new memory orderings. Because all atomic operations compile directly into user code, new memory orderings that we decide to introduce later could potentially back-deploy to any OS release that includes this proposal.

- Addition of new atomic operations on the types introduced here. These would be reflected in internal protocol requirements, so they would not be directly back-deployable to previous ABI-stable OS releases.

- Introducing a default memory ordering for atomic operations (either by adding a default value to `ordering`, or by adding new overloads that lack that parameter). This too would be a back-deployable change.

(We don't necessarily plan to actually perform any of these changes; we merely leave the door open to doing them.)


## Potential Future Directions

### Memory-Safe Atomic Constructs

The [Ownership Manifesto] introduces the concept of *non-copiable types* that might enable us to efficiently represent constructs that require a stable (and known) memory location. Atomics and other synchronization tools are classic examples for such constructs, and modeling them with non-copiable types could potentially eliminate the need for unsafe dynamic variables and manual memory management -- a major benefit over the unsafe types in this proposal, with no apparent drawback.

```swift
moveonly struct Atomic<Value: AtomicProtocol> {
  typealias Storage = PrivateAtomicStorage<Value>

  @addressable private var storage: Storage

  init(_ value: Value) {
    storage = Storage(initialValue: value)
  }

  deinit {
    storage.dispose()
  }

  func load(ordering: AtomicLoadOrdering) -> Value {
    let ptr = mutablePointer(to: \.storage, in: self)
    let result = Storage.atomicLoad(at: ptr, ordering: ordering)
    return Storage(decoding: result)
  }
  func store(_ desired: Value, ordering: AtomicStoreOrdering) {
    let ptr = mutablePointer(to: \.storage, in: self)
    let desiredRaw = Storage(encoding: desired)
    Storage.atomicStore(desiredRaw, at: ptr, ordering: ordering)
  }
  ...
}

moveonly struct UnfairLock {
  @addressable private var value: os_unfair_lock
  
  init() {
   self.value = os_unfair_lock()
  }

  func lock() { 
    os_unfair_lock_lock(mutablePointer(to: \.value, in: self))
  }
  func unlock() { 
    os_unfair_lock_unlock(mutablePointer(to: \.value, in: self))
  }
}
```

Note: In addition to non-copiable types, this example also relies on a hypothetical language feature for retrieving the memory location of select stored properties in such types (`@addressable` and `mutablePointer(to:in:)`). As a major simplification, it also assumes that non-copiable types allow mutations to their state within methods not marked `mutating`.

Properly designing and implementing these features will require a considerable amount of work. However, we feel it's important to enable work on concurrency features to start even before non-copiable types get implemented. The types introduced in this proposal will not prevent us from introducing memory-safe, non-copiable (or maybe not even movable) atomic types later, if and when it becomes possible to do so.

Even though it would be possible today to model safe atomics using class types (e.g., see the `AtomicCounter` example in the discussion above), we believe that the potential additional overhead of a class-based approach wouldn't be acceptable in the long term. Therefore, we prefer to go with an unsafe but low-overhead approach for now, reserving the "nice" `Atomic<Value>` name for future use. (Swift programmers will still be able to define class-based atomics in their own modules if they do not wish to (directly) use unsafe constructs in their synchronization code.)

### Double-Wide Atomics and The ABA Problem

In their current single-word form, atomic pointer and reference types are susceptible to a class of race condition called the *ABA problem*. A freshly allocated object often happens to be placed at the same memory location as a recently deallocated one. Therefore, two successive `load`s of a simple atomic pointer may return the exact same value, even though the pointer may have received an arbitrary number of updates between the two loads, and the pointee may have been completely replaced. This can be a subtle, but deadly source of race conditions in naive implementations of many concurrent data structures.

While the single-word atomic primitives introduced in this document are already useful for some applications, it would be helpful to also provide a set of additional atomic operations that operate on two consecutive `Int`-sized values in the same transaction. All supported architectures provide direct hardware support for such "double-wide" atomic operations.

For example, the second word can be used to augment atomic values with a version counter (sometimes called a "stamp" or a "tag"), which can help resolve the ABA problem by allowing code to reliably verify if a value remained unchanged between two successive loads.

To add support for double-wide atomics within the Standard Library, we need to introduce a representation for their underlying value, including (potentially platform-specific) alignment requirements that match the requirements of the underlying CPU instructions. We consider this to be outside of the scope of this proposal, so we defer double-wide atomics to a separate future proposal.


### Atomic Strong References and The Problem of Memory Reclamation

Perhaps counter-intuitively, implementing a high-performance, *lock-free* atomic version of regular everyday strong references is not a trivial task. This proposal doesn't attempt to provide such a construct beyond the limited use-case of `UnsafeAtomicLazyReference`.

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

* support for additional kinds of atomic values (such as double-wide atomics or floating-point atomics [[P0020]]),
* new memory orderings, such as a consuming load ordering [[P0750]] or tearable atomics [[P0690]],
* "volatile" atomics that prevent certain compiler optimizations
* memory fences that only affect the compiler (to prevent single-threaded race conditions such as with signal handlers)
* and more

We defer these for future proposals.


## Alternatives Considered

### Default Orderings

We considered defaulting all atomic operations throughout the `Atomics` module to sequentially consistent ordering. While we concede that doing so would make atomics slightly more approachable, implicit ordering values tend to interfere with highly performance-sensitive use cases of atomics (which is *most* use cases of atomics). Sequential consistency tends to be relatively rarely used in these contexts, and implicitly defaulting to it would allow accidental use to easily slip through code review.

Users who wish for default orderings are welcome to define their own overloads for atomic operations:

```swift
extension UnsafeAtomic {
  func load() -> Value { 
    load(ordering: .sequentiallyConsistent)
  }

  func store(_ desired: Value) { 
    store(desired, ordering: .sequentiallyConsistent) 
  }

  func exchange(_ desired: Value) -> Value {
    exchange(desired, ordering: .sequentiallyConsistent)
  }
  
  func compareExchange(
    expected: Value,
    desired: Value
  ) -> (exchanged: Bool, original: Value) {
    compareExchange(
      expected: expected, 
      desired: desired, 
      ordering: .sequentiallyConsistent)
  }

  func weakCompareExchange(
    expected: Value,
    desired: Value
  ) -> (exchanged: Bool, original: Value) {
    weakCompareExchange(
      expected: expected, 
      desired: desired, 
      successOrdering: .sequentiallyConsistent,
      failureOrdering: .sequentiallyConsistent)
  }
}

extension UnsafeAtomic where Value: AtomicInteger {
  func wrappingIncrement(by delta: Value = 1) {
    wrappingIncrement(by: delta, ordering: .sequentiallyConsistent)
  }
  etc.
}
```

### Alternative Names for `UnsafeAtomic` Types

We briefly considered naming the unsafe atomic reference types in this proposal `UnsafePointerToAtomic` and `UnsafePointerToAtomicLazyReference`, to highlight the fact that they are simple wrappers around unsafe pointer types.

However, after living on these names for a while, we had to reject them as unsuitable. These new generic types *emphatically aren't* pointers -- they merely happen to contain a pointer value in their internal representation. 

It's far more instructive to think of these types as unsafe precursors to corresponding non-copiable constructs, allowing us to fully define and start using the functionality they will eventually provide even before non-copiable types become available in the language.

We expect code using these unsafe precursors will be easily upgradeable to their eventual non-copiable variants when it becomes possible to implement those. In the meantime, since these are memory-unsafe variants of eventual `Atomic` and `AtomicLazyReference` types, it seems appropriate to simply prefix their names with the customary `Unsafe` prefix.

Logically, `UnsafeAtomic` and `UnsafeAtomicLazyReference` are both reference types with an independent storage representation and manual memory management. The common set of APIs between these types establishes a new pattern geared specifically for modeling low-overhead synchronization constructs in current versions of Swift:

```swift
struct UnsafeDemo {
  typealias Value

  struct Storage {
    // Initialize a new storage instance by converting the given value.
    // The conversion may involve side effects such as unbalanced retain/release
    // operations; to ensure correct results, the resulting storage instance
    // must be used to initialize exactly one memory location.
    init(_ initialValue: __owned Value)
    
    // Dispose of this storage instance, and return the last stored value.
    // This undoes any side effects that happened when the value was stored.
    // (For example, it may balance previous retain/release operations.)
    //
    // Note: this is different from deinitializing a memory location holding
    // a Storage value.
    @discardableResult
    mutating func dispose() -> Value
  }
  
  // Initialize a new instance using the specified storage location.
  // The caller code must have previously initialized the storage location.
  //
  // It is the caller's code responsibility to keep the storage location
  // valid while accessing it through the resulting instance,
  // and to correctly dispose of the storage value at the end of its useful life.
  init(at address: UnsafeMutablePointer<Storage>)
  
  // Return a new instance by allocating and initializing a dynamic variable
  // dedicated to holding its storage. Must be paired with a call to `destroy()`.
  static func create(initialValue: Value) -> Self
  
  // Destroy an instance previously created by `Self.create(initialValue:)`,
  // deinitializing and deallocating the dynamic variable that backs it,
  // and returning the last value it held before destruction.
  func destroy() -> Value
  
  ... // Custom operations
}
```

Future proposals may add additional low-level synchronization constructs conforming to the same pattern. The advent of non-copiable types will eventually (mostly) obsolete the need for this pattern; although we may decide to keep these unsafe precursors around if their flexibility proves useful.


### A Truly Universal Generic Atomic Type

While future proposals may add a variety of other atomic types, we do not expect to ever provide a truly universal generic `Atomic<T>` construct. The Atomics module is designed to provide high-performance wait-free primitives, and these are heavily constrained by the atomic instruction sets of the CPU architectures Swift targets.

A universal `Atomic<T>` type that can hold *any* value is unlikely to be implementable without locks, so it is outside the scope of this proposal -- and indeed, it is outside the scope of the Atomics module in general. We may eventually consider adding such a construct in a future concurrency proposal:

```swift
@propertyWrapper
moveonly struct Serialized<Value> {
  private let _lock = UnfairLock()
  private var _value: Value
  
  init(wrappedValue: Value) {
    self._value = wrappedValue
  }

  var wrappedValue: Value {
    get { _lock.locked { _value } }
    modify { 
      _lock.lock()
      defer { _lock.unlock() }
      yield &_value
    }
  }
}
```

### Providing a `value` Property

Our atomic constructs are unusual because even though semantically they behave like containers holding a value, they do not provide direct access to it. Instead of exposing a getter and a setter on a handy `value` property, they expose cumbersome `load` and `store` methods. There are two reasons for this curious inconsistency:

First, there is the obvious issue that property getter/setters have no room for an ordering parameter.

Second, there is a deep underlying problem with the property syntax: it encourages silent race conditions. For example, consider the code below:

```swift
var counter = UnsafeAtomic<Int>.create(initialValue: 0)
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
  desired: 1)
```

We could find shorter names for the orderings (`Serialized`, `Barrier` etc.), but ultimately the problem is that this approach tries to cram too much information into the method name, and the resulting multitude of similar-but-not-exactly-the-same methods become an ill-structured mess.

#### Orderings As Generic Type Parameters

A second idea is model the orderings as generic type parameters on the atomic types themselves.

```swift
struct UnsafeAtomic<Value: AtomicProtocol, Ordering: AtomicMemoryOrdering> {
  ...
}
let counter = UnsafeAtomic<Int, Relaxed>.create(initialValue: 0)
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
var counter = UnsafeAtomic<Int>.create(initialValue: 0)

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

## References

[Ownership Manifesto]: https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md
**\[Ownership Manifesto]** John McCall. "Ownership Manifesto." *Swift compiler documentation*, May 2, 2017. https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md

[SE-0176]: https://github.com/apple/swift-evolution/blob/master/proposals/0176-enforce-exclusive-access-to-memory.md
**\[SE-0176]** John McCall. "Enforce Exclusive Access to Memory. *Swift Evolution Proposal,* SE-0176, May 2, 2017. https://github.com/apple/swift-evolution/blob/master/proposals/0176-enforce-exclusive-access-to-memory.md

[Generics Manifesto]: https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md
**\[Generics Manifesto]** Douglas Gregor. "Generics Manifesto." *Swift compiler documentation*, 2016. https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md

[C++17]: https://isocpp.org/std/the-standard
**\[C++17]** ISO/IEC. *ISO International Standard ISO/IEC 14882:2017(E) – Programming Language C++.* 2017.
  https://isocpp.org/std/the-standard

**\[Williams 2019]** Anthony Williams. *C++ Concurrency in Action.* 2nd ed., Manning, 2019.

**\[Nagarajan 2020]** Vijay Nagarajan, Daniel J. Sorin, Mark D. Hill, David A. Wood. *A Primer on Memory Consistency and Cache Coherence.* 2nd ed., Morgan & Claypool, February 2020. https://doi.org/10.2200/S00962ED2V01Y201910CAC049 

**\[Herlihy 2012]** Maurice Herlihy, Nir Shavit. *The Art of Multiprocessor Programming.* Revised 1st ed., Morgan Kauffmann, May 2012.

[Boehm 2008]: https://doi.org/10.1145/1375581.1375591
**\[Boehm 2008]** Hans-J. Boehm, Sarita V. Adve. "Foundations of the C++ Concurrency Memory Model." In *PLDI '08: Proc. of the 29th ACM SIGPLAN Conf. on Programming Language Design and Implementation*, pages 68–78, June 2008.
  https://doi.org/10.1145/1375581.1375591

[Batty 2011]: https://doi.org/10.1145/1925844.1926394
**\[Batty 2011]** Mark Batty, Scott Owens, Susmit Sarkar, Peter Sewell, Tjark Weber. "Mathematizing C++ Concurrency." In *ACM SIGPlan Not.,* volume 46, issue 1, pages 55–66, January 2011. https://doi.org/10.1145/1925844.1926394

[Boehm 2012]: https://doi.org/10.1145/2247684.2247688
**\[Boehm 2012]** Hans-J. Boehm. "Can Seqlocks Get Along With Programming Language Memory Models?" In *MSPC '12: Proc. of the 2012 ACM SIGPLAN Workshop on Memory Systems Performance and Correctness*, pages 12–20, June 2012. https://doi.org/10.1145/2247684.2247688

[Nienhuis 2016]: https://doi.org/10.1145/2983990.2983997
**\[Nienhuis 2016]** Kyndylan Nienhuis, Kayvan Memarian, Peter Sewell. "An Operational Semantics for C/C++11 Concurrency." In *OOPSLA 2016: Proc. of the 2016 ACM SIGPLAN Conf. on Object Oriented Programming, Systems, Languages, and Applications,* pages 111–128, October 2016. https://doi.org/10.1145/2983990.2983997

[Mattarei 2018]: https://doi.org/10.1007/978-3-319-89963-3_4
**\[Mattarei 2018]** Christian Mattarei, Clark Barrett, Shu-yu Guo, Bradley Nelson, Ben Smith. "EMME: a formal tool for ECMAScript Memory Model Evaluation." In *TACAS 2018: Lecture Notes in Computer Science*, vol 10806, pages 55–71, Springer, 2018. https://doi.org/10.1007/978-3-319-89963-3_4

[N2153]: http://wg21.link/N2153
**\[N2153]** Raúl Silvera, Michael Wong, Paul McKenney, Bob Blainey. *A simple and efficient memory model for weakly-ordered architectures.* WG21/N2153, January 12, 2007. http://wg21.link/N2153

[N4455]: http://wg21.link/N4455
**\[N4455]** JF Bastien *No Sane Compiler Would Optimize Atomics.* WG21/N4455, April 10, 2015. http://wg21.link/N4455

[P0020]: http://wg21.link/P0020
**\[P0020]** H. Carter Edwards, Hans Boehm, Olivier Giroux, JF Bastien, James Reus. *Floating Point Atomic.* WG21/P0020r6, November 10, 2017. http://wg21.link/P0020

[P0124]: http://wg21.link/P0124
**\[P0124]** Paul E. McKenney, Ulrich Weigand, Andrea Parri, Boqun Feng. *Linux-Kernel Memory Model.* WG21/P0124r6. September 27, 2018. http://wg21.link/P0124

[P0418]: http://wg21.link/P0418
**\[P0418]** JF Bastien, Hans-J. Boehm. *Fail or succeed: there is no atomic lattice.* WG21/P0417r2, November 9, 2016. http://wg21.link/P0418

[P0690]: http://wg21.link/P0690
**\[P0690]** JF Bastien, Billy Robert O'Neal III, Andrew Hunter. *Tearable Atomics.* WG21/P0690, February 10, 2018. http://wg21.link/P0690

[P0735]: http://wg21.link/P0735
**\[P0735]**: Will Deacon, Jade Alglave. *Interaction of `memory_order_consume` with release sequences.* WG21/P0735r1, June 17, 2019. http://wg21.link/P0735

[P0750]: http://wg21.link/P0750
**\[P0750]** JF Bastien, Paul E. McKinney. *Consume*. WG21/P0750, February 11, 2018. http://wg21.link/P0750 

[TSan1]: https://developer.apple.com/documentation/code_diagnostics/thread_sanitizer
**\[TSan1]** *Thread Sanitizer -- Audit threading issues in your code.* Apple Developer Documentation. Retrieved March 2020. https://developer.apple.com/documentation/code_diagnostics/thread_sanitizer

[TSan2]: https://clang.llvm.org/docs/ThreadSanitizer.html
**\[TSan2]** *ThreadSanitizer*. Clang 11 documentation. Retrieved March 2020. https://clang.llvm.org/docs/ThreadSanitizer.html


⚛︎︎

<!-- Local Variables: -->
<!-- mode: markdown -->
<!-- fill-column: 10000 -->
<!-- eval: (setq-local whitespace-style '(face tabs newline empty)) -->
<!-- eval: (whitespace-mode 1) -->
<!-- eval: (visual-line-mode 1) -->
<!-- End: -->
