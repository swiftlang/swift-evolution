# UnsafeRawPointer API

* Proposal: [SE-0107](0107-unsaferawpointer.md)
* Author: [Andrew Trick](https://github.com/atrick)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000231.html)

For detailed instructions on how to migrate your code to this new
Swift 3 API refer to the
[UnsafeRawPointer Migration Guide](https://swift.org/migration-guide-swift3/se-0107-migrate.html). See
also: See `bindMemory(to:capacity:)`, `assumingMemoryBound(to:)`, and
`withMemoryRebound(to:capacity:)`.

For quick reference on the full API, jump to:
- [Full UnsafeRawPointer API](#full-unsaferawpointer-api)

Contents:
- [Introduction](#introduction)
- [Proposed Solution](#proposed-solution)
- [Motivation](#motivation)
- [Memory model explanation](#memory-model-explanation)
- [Expected use cases](#expected-use-cases)
- [Detailed design](#detailed-design)
- [Impact on existing code](#impact-on-existing-code)
- [Implementation status](#implementation-status)
- [Future improvements and planned additive API](#future-improvements-and-planned-additive-api)
- [Variations under consideration](#variations-under-consideration)
- [Alternatives previously considered](#alternatives-previously-considered)

## Introduction

Swift enforces type safe access to memory and follows strict aliasing
rules. However, code that uses unsafe APIs or imported types can
circumvent the language's natural type safety. Consider the following
example of *type punning* using the `UnsafePointer` type:

```swift
let ptrT: UnsafeMutablePointer<T> = ...
// Store T at this address.
ptrT[0] = T()
// Load U at this address
let u = UnsafePointer<U>(ptrT)[0]
```

This code violates assumptions made by the compiler and falls into the
category of
"[undefined behavior](http://blog.llvm.org/2011/05/what-every-c-programmer-should-know.html)".
Undefined behavior is a way of saying that we cannot easily specify
constraints on the behavior of programs that violate a rule. The
program may crash, corrupt memory, or be miscompiled in other
ways. Miscompilation may include optimizing away code that was
expected to execute or executing code that was not expected to
execute.

Swift already protects against undefined behavior as long as the code
does not use "unsafe" constructs. However, `UnsafePointer` is an
important API for interoperability and building high performance data
structures. As such, the rules for safe, well-defined usage of the API
should be clear. Currently, it is too easy to use `UnsafePointer`
improperly. For example, innocuous argument conversion such as this
could lead to undefined behavior:

```swift
func takesUIntPtr(_ p: UnsafeMutablePointer<UInt>) -> UInt {
  return p[0]
}
func takesIntPtr(q: UnsafeMutablePointer<Int>) -> UInt {
  return takesUIntPtr(UnsafeMutablePointer(q))
}
```

Furthermore, no API currently exists for accessing raw, untyped
memory. `UnsafePointer<Pointee>` and `UnsafeMutablePointer<Pointee>`
refer to a typed region of memory, and the compiler assumes that the
element type (`Pointee`) is consistent with other access to the same
memory. For details of the compiler's rules for memory aliasing,
see [proposed Type Safe Memory Access documentation][1]. Making
`UnsafePointer` safer requires introducing a new pointer type that is
not subject to the same strict aliasing rules.

This proposal aims to achieve several goals in one coherent design:

1. Specify a memory model that encompasses all UnsafePointer access and
   defines which memory operations are subject to strict aliasing rules.

2. Inhibit `UnsafePointer` conversion that violates strict aliasing,
   in order to make violations of the model clear and verifiable.

3. Provide an untyped pointer type.

4. Provide an API for raw, untyped memory access (`memcpy` semantics).

5. Provide an API for manual memory layout (bytewise pointer arithmetic).

Swift-evolution threads:

- [\[RFC\] UnsafeBytePointer API for In-Memory Layout](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/thread.html#16909)

- [\[RFC\] UnsafeBytePointer API for In-Memory Layout (Round 2)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/thread.html#18156)

- [RFC] UnsafeRawPointer API (Round 3)
  - [Week #1](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/thread.html#22005)
  - [Week #2](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160627/thread.html#22230)
  - [Week #3](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/thread.html#23384)

[1]:https://github.com/atrick/swift/blob/type-safe-mem-docs/docs/TypeSafeMemory.rst

Mentions of `UnsafePointer` that appear in this document's prose also
apply to `UnsafeMutablePointer`.

## Proposed Solution

We first introduce each aspect of the proposed API so that the
Motivation section can show examples. The Detailed design section
lists the complete API.

### UnsafeRawPointer

New raw pointer types, `UnsafeRawPointer` and
`UnsafeMutableRawPointer`, will represent a "raw", untyped view of
memory. Typed pointers, `UnsafePointer<T>` and `UnsafeMutablePointer<T>`,
continue to represent a typed view of memory. Memory access through a
raw pointer accesses raw memory, and memory access through a typed
pointer accesses typed memory. Because a raw pointer may alias with
any type, the semantics of reading and writing through a raw pointer
are similar to C `memcpy`. Memory access through a typed pointer
adheres to strict aliasing.

### Memory allocation and initialization

`UnsafeMutableRawPointer` will provide `allocate` and `deallocate` methods:

```swift
UnsafeMutableRawPointer {
  static func allocate(bytes size: Int, alignedTo: Int)

  func deallocate(bytes: Int, alignedTo: Int)
}
```

Initializing memory via an `UnsafeMutableRawPointer` produces an
`UnsafeMutablePointer<Pointee>`, and deinitializing the
`UnsafeMutablePointer<Pointee>` returns an `UnsafeMutableRawPointer`.

```swift
UnsafeMutableRawPointer {
  // Returns an UnsafeMutablePointer into the newly initialized memory.
  func initializeMemory<T>(as: T.Type, count: Int = 1, to: T)
    -> UnsafeMutablePointer<T>
}

UnsafeMutablePointer<Pointee> {
  /// Returns a raw pointer to the uninitialized memory.
  public func deinitialize(count: Int = 1) -> UnsafeMutableRawPointer
}
```

The type parameter `T` passed to `initializeMemory` is an explicit
argument because the user must reason about the type's size and
alignment at the point of initialization. Inferring the type from the
value argument could result in miscompilation if the inferred type
ever deviates from the user's original expectations. The type
parameter also importantly conveys that the raw memory becomes
accessible via a pointer to that type at the point of the call. The
type should be explicitly spelled at this point because accesing the
memory via a typed pointer of an unrelated type could also result in
miscompilation.

### Binding memory to a type

With the above API for allocation and initialization, the only way to
acquire a typed pointer is by using a raw pointer to initialize
memory. Raw pointer initialization implicitly binds the memory to the
initialized type. A memory location's bound type is an abstract,
dynamic property of the memory used to formalize type safety.

Whenever memory is accessed via a typed pointer, the memory must be
bound to a related type. This includes operations on
Unsafe[Mutable]Pointer<T> in addition to regular language constructs,
which are always strictly typed. It does not include memory accessed
via a raw pointer, which is not strictly typed. Violations result in
undefined behavior.

The user may defer initialization and explicitly bind memory to a type
using the `bindMemory` API:

```swift
Unsafe[Mutable]RawPointer {
  /// Returns an `Unsafe[Mutable]Pointer<T>` pointing to this memory.
  func bindMemory<T>(to: T.Type, capacity: Int) -> Unsafe[Mutable]Pointer<T>
}
```

Calling `bindMemory` on a newly allocated raw pointer produces a typed
pointer to uninitialized memory. The bound memory can then be safely
initialized using a typed pointer:

```swift
let ptrToA = rawPtr.bindMemory(to: A.self, capacity: 1)
ptrToA.initialize(to: A())
```

Note that typed pointer initialization does not bind the type. The
memory must already be bound to the correct type as a precondition.

Allocating and binding memory to a type may be performed in one step
by using `UnsafeMutablePointer.allocate()`:

```swift
UnsafeMutablePointer<Pointee> {
  static func allocate(capacity count: Int) -> UnsafeMutablePointer<Pointee>
}
```

### Raw memory access

Loading from and storing to memory via an `Unsafe[Mutable]RawPointer`
is safe independent of the memory's bound type as long as layout
guarantees are met (per the ABI), and care is taken to properly
initialize and deinitialize nontrivial values (see
[Trivial types](#trivial-types)). This allows raw memory to be
reinterpreted without rebinding the memory type. Rebinding memory
invalidates existing typed pointers, but loading from and storing to
raw memory does not.

```swift
UnsafeMutableRawPointer {
  /// Read raw bytes from memory at `self + offset` and construct a
  /// value of type `T`.
  ///
  /// - Precondition: The underlying pointer plus `offset` is properly
  ///   aligned for accessing `T`.
  ///
  /// - Precondition: The memory is initialized to a value of some type, `U`,
  ///   such that `T` is layout compatible with `U`.
  func load<T>(fromByteOffset: Int = 0, as: T.Type) -> T

  /// Store a value's bytes into raw memory at `self + offset`.
  ///
  /// - Precondition: The underlying pointer plus `offset` is properly
  ///   aligned for storing type `T`.
  ///
  /// - Precondition: `T` is a trivial type.
  ///
  /// - Precondition: The memory is uninitialized, or initialized to some
  ///   trivial type `U` such that `T` and `U` are mutually layout
  ///   compatible.
  /// 
  /// - Postcondition: The memory is initialized to raw bytes. If the
  ///   memory is bound to type `U`, then it now contains a value of
  ///   type `U`.
  func storeBytes<T>(of: T, toByteOffset: Int = 0, as: T.Type)
}
```

The `load` and `storeBytes` operations are asymmetric. `load` reads raw
bytes but properly constructs a new value of type `T` with its own
lifetime. Any copied references will be retained. In contrast,
`storeBytes` only operates on a value's raw bytes, writing them into
untyped memory. The in-memory copy will not be constructed and any
previously initialized value in this memory will not be deinitialized
(it cannot be because its type is unknown). Consequently, `storeBytes`
should only be performed on trivial types.

Assigning memory to a nontrivial type via a raw pointer is done by
binding the type:

```swift
rawPtr.bindMemory(to: PreviousType.self, capacity: 1).deinitialize(count: 1)
rawPtr.initializeMemory(as: NewType.self, to: NewType())
```

### Bytewise pointer arithmetic

Providing an API for accessing raw memory would not serve much purpose
without the ability to compute byte offsets. Naturally,
`UnsafeRaw[Mutable]Pointer` is Strideable as a sequence of bytes.

```swift
UnsafeRawPointer : Strideable {
  public func distance(to : UnsafeRawPointer) -> Int

  public func advanced(by : Int) -> UnsafeRawPointer
}

public func == (lhs: UnsafeRawPointer, rhs: UnsafeRawPointer) -> Bool

public func < (lhs: UnsafeRawPointer, rhs: UnsafeRawPointer) -> Bool

public func + (lhs: UnsafeRawPointer, rhs: Int) -> UnsafeRawPointer

public func - (lhs: UnsafeRawPointer, rhs: UnsafeRawPointer) -> Int
```

### UnsafePointer conversion

Currently, an `UnsafePointer` initializer supports conversion between
potentially incompatible pointer types:

```swift
struct Unsafe[Mutable]Pointer<Pointee> {
  public init<U>(_ from : Unsafe[Mutable]Pointer<U>)
}
```

This initializer will be removed. `UnsafePointer` conversion is still
possible, but is now explicit and provably correct based on the
conversion's preconditions and postconditions.

Recall that `bindMemory(to:capacity:)` produces a typed pointer from a
raw pointer. As explained above, it can be used to bind uninitialized
memory for deferred initialization. When invoked on memory that is
already bound, and potentially already initialized, it effectively
rebinds the memory. Because memory can only be bound to one type at a
time, all strictly typed memory operations that subsequently access
this memory must be consistent with the newly bound type.

A convenience API makes it easy to handle type mismatches that arise
from interoperability without compromising on safety. In this case,
the user already has a typed pointer but needs to temporarily rebind
the memory for the purpose of invoking code that expects a different
type. `withMemoryRebound<T>(to:capacity:)` rebinds memory to the
specified type, executes a closure with a pointer to the rebound
memory, then rebinds memory to the original type before returning:

```swift
Unsafe[Mutable]Pointer<Pointee> {
  func withMemoryRebound<T>(to: T.Type, capacity count: Int,
    _ body: (Unsafe[Mutable]Pointer<T>) throws -> ()) rethrows
}
```

This is safe provided that the `body` closure does not capture `self`.

It is possible to directly acquire a typed pointer from a raw pointer
without rebinding the type, bypassing static safety. This does
not weaken the rules for typed memory access because it relies on the
precondition is that memory is already bound to the returned pointer's
type. This is useful when the memory's bound type is known but the
pointer's type has been erased:

```swift
Unsafe[Mutable]RawPointer {
  func assumingMemoryBound<T>(to: T.Type) -> Unsafe[Mutable]Pointer<T> 
}
```

For a more detailed discussion, see the
[Memory model explanation](#memory-model-explanation).

## Motivation

The following examples show the differences between memory access as
it currently would be done using `UnsafeMutablePointer` vs. the
proposed `UnsafeMutableRawPointer`.

Consider two layout compatible, but unrelated structs, `A` and `B`,
and helpers that read from these structs via unsafe pointers:

```swift
// --- common definitions used by old and new code ---
struct A {
  var value: Int
}

struct B {
  var value: Int
}

func printA(_ pA: UnsafePointer<A>) {
  print(pA[0])
}

func printB(_ pB: UnsafePointer<B>) {
  print(pB[0])
}
```

Normal allocation, initialization, access, and deinitialization of a
struct looks like this with `UnsafePointer`:

```swift
// --- old version ---
func initA(pA: UnsafeMutablePointer<A>) {
  pA.initialize(to: A(value:42))
}

func initB(pB: UnsafeMutablePointer<B>) {
  pB.initialize(to: B(value:13))
}

func normalLifetime() {
  let pA = UnsafeMutablePointer<A>.allocate(capacity: 1)

  initA(pA)

  printA(pA)

  pA.deinitialize(count: 1)

  pA.deallocateCapacity(1)
}
```

This code continues to work. However, with `UnsafeMutableRawPointer`,
it is possible to distinguish between raw allocated memory, and memory
that has been initialized as some type. First, we define new
initialization helpers that take raw pointers and return typed
pointers:

```swift
// --- new version ---
func initRawA(p: UnsafeMutableRawPointer) -> UnsafeMutablePointer<A> {
  return p.initializeMemory(as: A.self, to: A(value:42))
}

func initRawB(p: UnsafeMutableRawPointer) -> UnsafeMutablePointer<B> {
  return p.initializeMemory(as: B.self, to: B(value:13))
}
```

Now we can allocate raw memory and obtain a typed pointer through
initialization:

```swift
// --- new version ---
func normalLifetime() {
  let rawPtr = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<A>.stride,
                                                alignedTo: MemoryLayout<A>.alignment)

  // rawPtr cannot be assigned to a value of `A`, forcing initialization before
  // typed access.
  let pA = initRawA(rawPtr)

  printA(pA)

  let uninitPtr = pA.deinitialize(count: 1)
  uninitPtr.deallocate(bytes: MemoryLayout<A>.stride,
                       alignedTo: MemoryLayout<A>.alignment)
}
```

----

Consider another example, now ignoring memory deallocation for
brevity. Technically, it is correct to initialize values of type `A`
and `B` in different memory locations, but confusing and dangerous
with the current `UnsafeMutablePointer` API:

```swift
// --- old version ---
// Return a pointer to (A, B).
func initAB() -> UnsafeMutablePointer<A> {

  // Memory is uninitialized, but pA is already typed.
  let pA = UnsafeMutablePointer<A>.allocate(capacity: 2)

  // Part of the memory is initialized to `A`. Redundant conversion of
  // UnsafeMutablePointer values like this is not uncommon, and it is
  // nonobvious at the point of conversion that it does not actually
  // change the pointer type.
  initA(UnsafeMutablePointer(pA))

  // pA is recast as pB with no indication that the pointee type has changed.
  initB(UnsafeMutablePointer(pA + 1))
  return pA
}
```

Code in the caller is confusing:

```swift
// --- old version ---
func testInitAB() {
  let pA = initAB()
  printA(pA)

  // pA is again recast as pB with no indication that the pointee type changes.
  printB(UnsafeMutablePointer(pA + 1))

  // Or recast to pB first, which is also misleading because the pointer still
  // points to an initialized `A` value at the point of the cast.
  printB(UnsafeMutablePointer<B>(pA) + 1)
}
```

With `UnsafeMutableRawPointer` there is no need to cast to an invalid
pointer type in order to access manually allocated memory:

```swift
// --- new version ---
// Return a pointer to an untyped memory region initialized with (A, B).
func initRawAB() -> UnsafeMutableRawPointer {
  let rawPtr = UnsafeMutableRawPointer.allocate(bytes: 2 * MemoryLayout<Int>.stride,
                                                alignedTo: MemoryLayout<Int>.alignment)

  // Initialize the first Int with `A`, producing UnsafeMutablePointer<A>.
  let pA = initRawA(rawPtr)

  // Initialize the second Int with `B`.
  // This implicitly casts UnsafeMutablePointer<A> to UnsafeMutableRawPointer,
  // which is equivalent to initB(rawPtr + MemoryLayout<Int>.stride).
  // Unlike the old API, no unsafe pointer conversion is needed.
  initRawB(pA + 1)

  return rawPtr
}
```

Now, in the caller, unsafe conversion from raw memory to typed memory
is always explicit:

```swift
// --- new version ---
// Code in the caller is explicit:
func testInitAB() {
  // Get a raw pointer to (A, B).
  let p = initRawAB()

  // The untyped memory is explicitly converted to a pointer-to-A.
  // Safe because we know the underlying memory is bound to `A` via
  // raw pointer initialization.
  let pA = p.assumingMemoryBound(to: A.self)
  printA(pA)

  // Converting from a pointer-to-A into a pointer-to-B without
  // rebinding the type requires casting to an UnsafeRawPointer.
  printB(UnsafeRawPointer(pA + 1).assumingMemoryBound(to: B.self))

  // Or directly convert the original UnsafeRawPointer into pointer-to-B.
  printB((p + MemoryLayout<Int>.stride).assumingMemoryBound(to: B.self))
}
```

This is much more explicit and verifiable, but still not statically
type safe. However, now that it is possible to bind memory to a type,
this example may be rewritten so that strict aliasing rules are
statically enforced. Now the caller no longer needs to assume the
pointer type that was used to initialize memory in `initAB`. They only
need to agree on the layout of the memory:

```swift
// --- new and improved version ---
// Return a pointer to an untyped memory region initialized with (A, B).
func initRawAB() -> UnsafeMutableRawPointer {
  let intPtr = UnsafeMutablePointer<Int>.allocate(capacity: 2)
  intPtr[0] = 42 // knowing A is layout compatible with Int
  intPtr[1] = 13 // knowing B is layout compatible with Int
  return UnsafeMutableRawPointer(intPtr)
}

func testInitAB() {
  // Get a raw pointer to (A, B).
  let p = initRawAB()

  let pA = p.bindMemory(to: A.self, capacity: 1)
  printA(pA)

  // Knowing the `B` has the same alignment as `A`.
  let pB = UnsafeRawPointer(pA + 1).bindMemory(to: B.self, capacity: 1)
  printB(pB)
}
```

----

Initializing or assigning values of different types to the same
location using a typed pointer is undefined. Here, the compiler can
choose to ignore the order of assignment, and `initAthenB` may print
13 twice or 42 twice.

```swift
// --- old version ---
func initAthenB(_ p: UnsafeMutablePointer<Void>) {
  let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)

  initA(UnsafeMutablePointer(p))  // *p = 42
  printA(UnsafeMutablePointer(p))

  initB(UnsafeMutablePointer(p))  // *p = 13
  printB(UnsafeMutablePointer(p))
}
```

With the proposed API, assigning values of different types to the same
location can now be safely done by properly initializing and
deinitializing the memory through `UnsafeMutableRawPointer`. Ultimately, the
values may still be accessed via the same convenient
`UnsafeMutablePointer` type. Type punning has not happened, because the
`UnsafeMutablePointer` has the same type as the memory's bound
type whenever it is dereferenced.

```swift
// --- new version ---
func initAthenB {
  let rawPtr = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<Int>.stride,
                                                alignedTo: MemoryLayout<Int>.alignment)

  let pA = initRawA(rawPtr) // raw pointer initialization binds memory to `A`
  printA(pA)

  // After deinitializing pA, uninitPtr receives a pointer to
  // untyped raw memory, which may be reused for `B`.
  let uninitPtr = pA.deinitialize(count: 1)

  // rawPtr and uninitPtr have the same value, thus are substitutable.
  assert(rawPtr == uninitPtr)

  // initB rebinds the memory to `B` before writing to memory, so
  // reinitialization cannot be reordered with previous accesses to pA.
  initRawB(uninitPtr)
  printB(pB)
}
```

----

No API currently exists that allows initialized memory to hold either `A` or `B`.

```swift
// --- old version ---
// This conditional initialization looks valid, but is dangerous.
func initAorB(_ p: UnsafeMutablePointer<Void>, isA: Bool) {
  if isA {
    initA(UnsafeMutablePointer(p))
  }
  else {
    initB(UnsafeMutablePointer(p))
  }
}
```

 Code in the caller could produce undefined behavior:

```swift
// --- old version ---
func testInitAorB() {
  let p = UnsafeMutablePointer<Int>.allocate(capacity: 1)

  // If the compiler inlines, then the initialization and use of the
  // values of type `A` and `B`, which share memory, could be incorrectly
  // interleaved.
  initAorB(p, isA: true)
  printA(UnsafeMutablePointer(p))

  initAorB(p, isA: false)
  printB(UnsafeMutablePointer(p))
}
```

`UnsafeMutableRawPointer` allows initialized memory to hold either `A`
or `B`. The same `UnsafeMutableRawPointer` value can be reused across
multiple initializations and deinitializations. Unlike the old API,
this is safe because the memory initialization on a raw pointer writes
to untyped memory and binds the memory type. Binding memory to a type
separates access to the distinct types from the compiler's viewpoint.

```swift
// --- new version ---
func initRawAorB(_ p: UnsafeMutableRawPointer, isA: Bool) {
  // Unsafe pointer conversion is no longer required to initialize memory.
  if isA {
    initRawA(p)
  }
  else {
    initRawB(p)
  }
}
```

Code in the caller is well defined because `initAorB` is now a
compiler barrier for unsafe pointer access. Furthermore, each unsafe
pointer cast is explicit:

```swift
// --- new version ---
func testInitAorB() {
  let p = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<Int>.stride,
                                           alignedTo: MemoryLayout<Int>.alignment)

  initRawAorB(p, isA: true)
  printA(p.assumingMemoryBound(to: A.self))

  initRawAorB(p, isA: false)
  printB(p.assumingMemoryBound(to: B.self))
}
```

----

`UnsafeMutableRawPointer` provides a legal way to reinterpret memory
in-place, which was previously unsupported. The following example is
safe because the load of `B` reads from untyped memory via a raw
pointer.

```swift
// --- new version ---
func testReinterpret() {
  let p = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<Int>.stride,
                                           alignedTo: MemoryLayout<Int>.alignment)

  // Initialize raw memory to `A`.
  initRawAorB(p, isA: true)

  // Load from raw memory as `B` (reinterpreting the value in memory).
  print(p.load(as: B.self))
}
```

This is not "type-punning" because a typed pointer is never
accessed. Note that `printB(p.assumingMemoryBound(to: B.self))` would
be illegal, because the a typed pointer to `B` cannot be used to
access an unrelated type `A`.

----

Developers may be forced to work with "loosely typed" APIs,
particularly for interoperability:

```swift
func readBytes(_ bytes: UnsafePointer<UInt8>) {
  // 3rd party implementation...
}
func readCStr(_ string: UnsafePointer<CChar>) {
  // 3rd party implementation...
}
```

Working with these third party API's exclusively using
`UnsafeMutablePointer` would lead to undefined behavior, as shown here
using the current API:

```swift
// --- old version ---
func stringFromBytes(size: Int, value: UInt8) {
  let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: size + 1)
  bytes.initialize(to: value, count: size)
  bytes[size] = 0

  // Unsafe pointer conversion is required to invoke readCString.
  // If readCString is inlineable and compiled with strict aliasing,
  // then it could read uninitialized memory.
  readCStr(UnsafePointer(bytes))

  // The signature of readBytes is consistent with the `bytes` argument type.
  readBytes(bytes)
}
```

Reading from uninitialized memory is now prevented by explicitly
rebinding the type.

```swift
// --- new version ---
func stringFromBytes(size: Int, value: UInt8) {
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size + 1)
  buffer.initialize(to: value, count: size)
  buffer[size] = 0

  buffer.withMemoryRebound(to: CChar.self, capacity: size + 1) {
    readCStr($0)
  }
  readBytes(buffer)
}
```

Rather than temporarily rebinding memory, the user may want to rebind
memory to `CChar` once and keep the same typed pointer around for
future use without keeping track of the memory capacity. In that case,
the program could continue to write `UInt8` values to memory without
casting to `CChar` and without rebinding memory as long as those writes
use the `UnsafeMutableRawPointer.storeBytes` API for raw memory access:

```swift
// --- new version ---
func mutateBuffer(size: Int, value: UInt8) {
  let rawBuffer = UnsafeMutableRawPointer.allocate(bytes: size + 1,
                                                   alignedTo: 1)
  rawBuffer.initializeMemory(as: UInt8.self, count: size, to: value)
  rawBuffer.initializeMemory(as: UInt8.self, atIndex: size, to: 0)

  let cstr = rawBuffer.bindMemory(to: CChar.self, capacity: size + 1)
  // Access memory as CChar.
  readCStr(cstr)

  // Write UInt8 values to memory without needing explicitly cast each
  // value to CChar first.
  for i in 0..<size {
    rawBuffer.storeBytes(of: getByte(), toByteOffset: i, as: UInt8.self)
  }

  // Access memory again as CChar.
  readCStr(cstr)
}
func getByte() -> UInt8 {
  // 3rd party implementation...
}
```

----

The side effects of illegal type punning may result in storing values
in the wrong sequence, reading uninitialized memory, or memory
corruption. It could even result in execution following code paths
that aren't expected as shown here:

```swift
// --- old version ---
func testUndefinedExecution() {
  let pA = UnsafeMutablePointer<A>.allocate(capacity: 1)
  pA[0] = A(value:42)
  if pA[0].value != 42 {
    // Code path should never execute...
    releaseDemons()
  }
  // This compiler may inline this, and hoist the store above the
  // previous check.
  unforeseenCode(pA)
}

func releaseDemons() {
  // Something that should never be executed...
}

func assignB(_ pB: UnsafeMutablePointer<B>) {
  pB[0] = B(value:13)
}

func unforeseenCode(_ pA: UnsafeMutablePointer<A>) {
  // At some arbitrary point in the future, the same memory is
  // innocuously assigned to B.
  assignB(UnsafeMutablePointer(pA))
}
```

Prohibiting conversion between incompatible `UnsafePointer` types,
providing an API for binding memory to a type, and supporting raw
memory access are necessary to avoid the dangers of type punning and
encourage safe idioms for working with pointers.

## Memory model explanation

### Raw vs. Typed Pointers

The fundamental difference between `Unsafe[Mutable]RawPointer` and
`Unsafe[Mutable]Pointer<Pointee>` is simply that the former is used
for "untyped" memory access, and the later is used for "typed" memory
access. Let's refer to these as "raw pointers" and "typed
pointers". Because operations on raw pointers access untyped memory, the
compiler cannot make assumptions about the underlying type of memory
and must be conservative. With operations on typed pointers, the
compiler may make strict assumptions about the type of the underlying
memory, which allows more aggressive optimization.

### Memory initialization

All allocated memory is either "uninitialized" or "initialized". Upon
initialization, memory contains a typed value. Initialized memory may
be assigned to a new value of the same type. Upon deinitialization,
the memory no longer holds a value.

Consider the sequence of abstract memory operations:

Abstract Operation                  | Memory State 
----------------------------------- | ------------ 
`rawptr = allocate()`               | uninitialized
`tptr = rawptr.initializeMemory(T)` | initialized
`tptr.pointee = T`                  | initialized
`tptr.deinitialize()`               | uninitialized

Initializing memory via a raw pointer binds the memory
type. Initialized memory must always be bound to a type. Deinitialization
does not unbind the type. Memory remains bound to a type until it is
rebound to a different type.

Abstract Operation                  | Memory State  | Type
----------------------------------- | ------------  | ----------
`rawptr = allocate()`               | uninitialized | None
`tptr = rawptr.initializeMemory(T)` | initialized   | bound to T
`tptr.deinitialize()`               | uninitialized | bound to T
`uptr = rawptr.initializeMemory(U)` | initialized   | bound to U
`uptr.deinitialize()`               | uninitialized | bound to U
`rawptr.deallocate()`               | invalid       | None

Rebinding memory effectively changes the type of any initialized
values within the rebound memory region. Accessing the memory via a
typed pointer of unrelated type is undefined:

Abstract Operation                  | Memory State  | Type
----------------------------------- | ------------  | ----------
`tptr = rawptr.initializeMemory(T)` | initialized   | bound to T
`tptr.deinitialize()`               | uninitialized | bound to T
`uptr = rawptr.initializeMemory(U)` | initialized   | bound to U
`uptr.deinitialize()`               | uninitialized | bound to U
`tptr.initialize()`                 | undefined     | undefined

By this convention, raw pointers primarily refer to uninitialized
memory and typed pointers primarily refer to initialized memory. This
is not a requirement, and important use cases follow different
conventions. After a raw pointer is initialized, the raw pointer value
remains valid and can continue to be used to access the underlying
memory in an untyped way. Conversely, a raw pointer can bound to a
typed pointer without initializing the underlying memory.

### Binding memory type

A raw pointer's memory may be explicitly bound to a type, bypassing
raw initialization:

```swift
let ptrA = rawPtr.bindMemory(to: A.self, capacity: 1)
```

The resulting typed pointer may then be used to initialize memory:

```swift
ptrA.initialize(to: A())
```

Abstract Operation                | Memory State  | Type
--------------------------------- | ------------  | ----------
`rawptr = allocate()`             | uninitialized | None
`tptr = rawptr.bindMemory(T)`     | uninitialized | bound to T
`tptr.initialize()`               | initialized   | bound to T

The memory remains bound to this type until it is rebound through raw
pointer initialization or another call to `bindMemory(to:)`.

Abstract Operation                | Memory State  | Type
--------------------------------- | ------------  | ----------
`rawptr = allocate()`             | uninitialized | None
`tptr = rawptr.bindMemory(T)`     | uninitialized | bound to T
`tptr.initialize()`               | initialized   | bound to T
`tptr.deinitialize()`             | uninitialized | bound to T
`uptr = rawptr.bindMemory(U)`     | uninitialized | bound to U
`uptr.initialize()`               | initialized   | bound to U

Allocation and binding can be combined as typed allocation:

Abstract Operation                | Memory State  | Type
--------------------------------- | ------------  | ----------
`tptr = allocate(T)`              | uninitialized | bound to T
`tptr.initialize()`               | initialized   | bound to T

### Typed pointer initialization

Initializing memory via a typed pointer requires the memory to be
already be bound to that type. This is often more convenient than
working with raw pointers, and can improve performance in some
cases. In particular, it is an effective technique for implementing
data structures that manage storage for contiguous elements. The data
structure may allocate a buffer with extra capacity and track the
initialized state of each element position as such:

```swift
func getAt(index: Int) -> A {
  if !isInitializedAt(index) {
    (ptrA + index).initialize(to: Type())
  }
  return ptrA[index]
}
```

For example, see the [C buffer](#c-buffer) use case below.

When using a typed pointer to initialize memory, the programmer must ensure that memory has been bound to that type and takes responsibility for tracking the initialized state of memory.

### Strict aliasing

Accessing memory via a pointer type that is unrelated to the memory's
bound type violates strict aliasing, and is thus undefined. For the
purpose of this proposal, we simply specify when strict aliasing
applies and that aliasing types must be related. For an explanation of
related types and layout compatibility, see
[proposed Type Safe Memory Access documentation][1].

Regardless of whether strict aliasing applies, accessing initialized
in-memory values always requires the access type to be layout
compatible with the value's type. This applies to access via the raw
pointer API in addition to typed pointer access. Similarly, rebinding
initialized in-memory values to another type requires both the
previous and new type to be mutually layout compatible.

Accessing memory via a typed pointer (or normal, safe language
construct) has an *additional* requirement that the pointer type must
be related to the memory's bound type. For this reason, typed pointers
are only obtained by initializing raw memory or explicitly binding the
memory type. In practice, with the proposed API, the only way to
violate strict aliasing is to reuse a typed pointer value after the
underlying memory has been rebound to an unrelated type:

Abstract Operation                | Memory State  | Type
--------------------------------- | ------------  | ----------
`tptr = rawptr.bindMemory(T)`     | uninitialized | bound to T
`uptr = rawptr.bindMemory(U)`     | uninitialized | bound to U
`tptr.initialize()`               | undefined     | `T` is unrelated to `U`

### Accessing initialized memory with a raw pointer.

A program may read from and write to memory via a raw pointer even
after the memory has been initialized:

```swift
let rawPtr = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<SomeType>.stride,
                                              alignedTo: MemoryLayout<SomeType>.alignment)

let ptrToSomeType = rawPtr.initializeMemory(as: SomeType.self, to: SomeType())

// read raw initialized memory
let reinterpretedValue = rawPtr.load(as: AnotherType.self)

// overwrite raw initialized memory
rawPtr.storeBytes(of: AnotherType(), as: AnotherType.self)
```

`SomeType` and `AnotherType` need not to be related types. They must
only be layout compatible. In other words, the programmer must ensure
compatibility of the size, alignment, and position of references. This
requires some knowledge of the ABI.

Loading from raw memory reinterprets the in-memory bytes, and
constructs a new local value. If that value contains class references,
the class type of those reference must be related to the instance's
dynamic type. This is a incontrovertible property of all reference
values in the system.

Storing a value into raw memory does not support reference
types. Additionally, it requires consideration of the type of value
being overwritten because a raw store overwrites memory contents
without destroying the previous value. Storing to raw memory is safe
if either the memory is uninitialized or initialized to a trivial
type. The value being stored must also be trivial so that it can be
assigned via a bit-for-bit copy.

### Trivial types

A "trivial type" promises that assignment just requires a fixed-size
bit-for-bit copy without any indirection or reference-counting
operations. Generally, native Swift types that do not contain strong
or weak references or other forms of indirection are trivial, as are
imported C structs and enums.

Examples of trivial types:

- Integer and floating-point types
- `Bool`
- `Optional<T>` where `T` is trivial
- `Unmanaged<T: AnyObject>`
- struct types where all members are trivial
- enum types where all payloads are trivial

## Expected use cases

This section lists several typical use cases involving
`UnsafeRawPointer` and `UnsafePointer`.

For explanatory purposes consider the following global definitions:

```swift
struct A {
  var value: Int32
}
struct B {
  var value: Int32
}

var ptrToA: UnsafeMutablePointer<A>
var eltCount: Int = 0
```

### Single value

Using a pointer to a single value:

```swift
func createValue() {
  ptrToA = UnsafeMutablePointer<A>.allocate(capacity: 1)
  ptrToA.initialize(to: A(value: 42))
}

func deleteValue() {
  ptrToA.deinitialize(count: 1)
  ptrToA.deallocate(capacity: 1)
}
```

### C array

Using a fully initialized set of contiguous homogeneous values:

```swift
func createCArray(from source: UnsafePointer<A>, count: Int) {
  ptrToA = UnsafeMutablePointer<A>.allocate(capacity: count)
  ptrToA.initialize(from: source, count: count)
  eltCount = count
}

func deleteCArray() {
  ptrToA.deinitialize(count: eltCount)
  ptrToA.deallocate(capacity: eltCount)
}
```

### C buffer

Managing a buffer with a mix of initialized and uninitialized
contiguous elements. Typically, information about which elements are
initialized will be separately maintained to ensure that each method's
preconditions are met:

```swift
func createCBuffer(size: Int) {
  ptrToA = UnsafeMutablePointer<A>.allocate(capacity: size)
  eltCount = size
}

// - precondition: memory at `index` is uninitialized.
func initElement(index: Int, with value: A) {
  (ptrToA + index).initialize(to: value)
}

// - precondition: memory at `index` is initialized.
func getElement(index: Int) -> A {
  return ptrToA[index]
}

// - precondition: memory at `index` is initialized.
func assignElement(index: Int, with value: A) {
  ptrToA[index] = value
}

// - precondition: memory at `index` is initialized.
func deinitElement(index: Int) {
  (ptrToA + index).deinitialize()
}

// - precondition: memory for all elements is uninitialized.
func freeCBuffer() {
  ptrToA.deallocate(capacity: eltCount)
}
```

### Manual layout of typed, aligned memory

```swift
// Layout an object with header type `A` followed by `n` elements of type `B`.
func createValueWithTail(count: Int) {
  // Assuming the alignment of `A` satisfies the alignment of `B`.
  let numBytes = MemoryLayout<A>.stride + (count * MemoryLayout<B>.stride)

  let rawPtr = UnsafeMutableRawPointer.allocate(
    bytes: numBytes, alignedTo: MemoryLayout<A>.alignment)

  // Initialize the object header.
  ptrToA = rawPtr.initializeMemory(as: A.self, to: A(value: 42))

  // Append `count` elements of type `B` to the object tail.
  eltCount = count
  UnsafeMutableRawPointer(ptrToA + 1).initializeMemory(
    as: B.self, count: count, to: B(value: 13))
}

func getTailElement(index: Int) -> B {
  return UnsafeRawPointer(ptrToA + 1)
    .assumingMemoryBound(to: B.self)[index]
}

func deleteValueWithTail() {
  UnsafeMutableRawPointer(ptrToA + 1)
    .assumingMemoryBound(to: B.self).deinitialize(count: eltCount)

  let numBytes = MemoryLayout<A>.stride + (eltCount * MemoryLayout<B>.stride)

  ptrToA.deinitialize(count: 1).deallocate(
    bytes: numBytes, alignedTo: MemoryLayout<A>.alignment)
}
```

### Raw buffer of unknown type

Direct bytewise memory access to a buffer of unknown type:

```swift
// Format1:
//   flags: UInt16
//   state: UInt16
//   value: Int32

// Format2:
//   value: Int32

func receiveMsg(flags: UInt16, state: UInt16, value: Int32) {
  // ...
}

func readMsg(msgBuf: UnsafeRawPointer, isFormat1: Bool) {
  if isFormat1 {
    receiveMsg(flags: msgBuf.load(as: UInt16.self),
      state: msgBuf.load(fromByteOffset: 2, as: UInt16.self),
      value: msgBuf.load(fromByteOffset: 4, as: Int32.self))
  }
  else {
    receiveMsg(flags: 0, state: 0, value: msgBuf.load(as: Int32.self))
  }
}
```

### Loads and stores on untyped memory

Accessing raw underlying memory bytes, independent of the memory's
bound type:

```swift
// Direct bytewise element copy.
func copyArrayElement(fromIndex: Int, toIndex: Int) {
  let srcPtr = UnsafeRawPointer(ptrToA + fromIndex)
  let destPtr = UnsafeMutableRawPointer(ptrToA + toIndex)

  destPtr.copyBytes(from: srcPtr, count: MemoryLayout<A>.size))
}

// Bytewise element swap.
// Initializes and deinitializes temporaries of type Int.
// Int is layout compatible with `A`.
func swapArrayElements(index i: Int, index j: Int) {
  let rawPtrI = UnsafeMutableRawPointer(ptrToA + i)
  let rawPtrJ = UnsafeMutableRawPointer(ptrToA + j)
  let tmpi = rawPtrI.load(as: Int.self)
  let tmpj = rawPtrJ.load(as: Int.self)
  rawPtrI.storeBytes(of: tmpj, as: Int.self)
  rawPtrJ.storeBytes(of: tmpi, as: Int.self)
}
```

### Custom memory allocation

```swift
var freePtr: UnsafeMutableRawPointer? = nil

func allocate32() -> UnsafeMutableRawPointer {
  if let newPtr = freePtr {
    freePtr = nil
    return newPtr
  }
  return UnsafeMutableRawPointer.allocate(bytes: 4, alignedTo: 4)
}

func deallocate32(_ rawPtr: UnsafeMutableRawPointer) {
  if freePtr != nil {
    rawPtr.deallocate(bytes: 4, alignedTo: 4)
  }
  else {
    freePtr = rawPtr
  }
}

func createA(value: Int32) -> UnsafeMutablePointer<A> {
  return allocate32().initializeMemory(as: A.self, to: A(value: value))
}

func createB(value: Int32) -> UnsafeMutablePointer<B> {
  return allocate32().initialize(as: B.self, to: B(value: value))
}

func deleteA(ptrToA: UnsafeMutablePointer<A>) {
  deallocate32(ptrToA.deinitialize(count: 1))
}

func deleteB(ptrToB: UnsafeMutablePointer<B>) {
  deallocate32(ptrToB.deinitialize(count: 1))
}
```

## Detailed design

### Pointer conversion details

`UnsafePointer<T>` to `UnsafeRawPointer` conversion will be provided
via an unlabeled initializer.

```swift
extension UnsafeRawPointer: _Pointer {
  init<T>(_: UnsafePointer<T>)
  init<T>(_: UnsafeMutablePointer<T>)
}
extension UnsafeMutableRawPointer: _Pointer {
  init<T>(_: UnsafeMutablePointer<T>)
}
```

Conversion from `UnsafeRawPointer` to a typed `UnsafePointer<T>`
requires invoking `UnsafeRawPointer.bindMemory(to:capacity:)` or
`UnsafeRawPointer.assumingMemoryBound(to:)`, explicitly spelling the
destination type:

```swift
let p = UnsafeRawPointer(...)
let pT = p.bindMemory(to: T.self, capacity: n)
...
let pT2 = p.assumingMemoryBound(to: T.self)
```

Just as with `unsafeBitCast`, although the destination of the cast can
usually be inferred, we want the developer to explicitly state the
intended destination type, both because type inference can be
surprising, and because it's important for code comprehension.

Some existing conversions between `UnsafePointer` types do not
convert `Pointee` types but instead coerce an
`UnsafePointer` to an `UnsafeMutablePointer`. This is no longer an
inferred conversion, but must be explicitly requested:

```swift
extension UnsafeMutablePointer {
  init(mutating from: UnsafePointer<Pointee>)
}
```

### Implicit argument conversion

Consider two C functions that take `const` pointers:

```C
void takesConstTPtr(const T*);
void takesConstVoidPtr(const void*);
```

Which will be imported with immutable pointer argument types:

```swift
func takesConstTPtr(_: UnsafePointer<T>)
func takesConstVoidPtr(_: UnsafeRawPointer)
```

Mutable pointers can be passed implicitly as immutable pointers.

```swift
let unsafeMutablePtr: UnsafeMutablePointer<T>
let mutableRawPtr: UnsafeMutableRawPointer
takesConstTPtr(unsafeMutablePtr)
takesConstVoidPtr(mutableRawPtr)
```

Any mutable or immutable typed pointer can be passed implicitly as an
immutable void pointer:

```swift
let unsafePtr: UnsafePointer<T>
let unsafeMutablePtr: UnsafeMutablePointer<T>
takesConstVoidPtr(unsafePtr)
takesConstVoidPtr(unsafeMutablePtr)
```

Implicit inout conversion will continue to work:

```swift
var anyT: T
takesConstTPtr(&anyT)
takesConstVoidPtr(&anyT)
```

`Array`/`String` conversion will continue to work:

```swift
let a = [T()]
takesConstTPtr(a)
takesConstVoidPtr(a)

let s = "string"
takesConstVoidPtr(s)
```

Consider two C functions that take non-`const` pointers:

```C
void takesTPtr(T*);
void takesVoidPtr(void*);
```

Which will be imported with mutable pointer argument types:

```swift
func takesTPtr(_: UnsafeMutablePointer<T>)
func takesVoidPtr(_: UnsafeMutableRawPointer)
```

Any mutable pointer type can be passed implicitly as a mutable void pointer:

```swift
let unsafeMutablePtr: UnsafeMutablePointer<T>
takesVoidPtr(unsafeMutablePtr)
```

Implicit inout conversion will continue to work:

```swift
var anyT = T(...)
takesTPtr(&anyT)
takesVoidPtr(&anyT)
```

`Array`/`String` conversion to mutable pointer is still not allowed.

### Bulk copies

The following API entry points support copying or moving values
between unsafe pointers.

Given values of these types:

```swift
let unsafePtr: UnsafePointer<T>
let unsafeMutablePtr: UnsafeMutablePointer<T>
let rawPtr: UnsafeRawPointer
let mutableRawPtr: UnsafeMutableRawPointer
let c: Int
```

#### `UnsafeRawPointer` to `UnsafeMutableRawPointer` raw copy (`memcpy`):

```swift
mutableRawPtr.copyBytes(from: rawPtr, count: c)
```

#### `UnsafePointer<T>` to `UnsafeMutableRawPointer`:

A raw copy from typed to raw memory can also be done by calling
`copyBytes`, exactly as shown above. Implicit argument conversion from
`UnsafePointer<T>` to `UnsafeRawPointer` makes this seamless.

Additionally, raw memory can be bulk initialized from typed memory:

```swift
mraw.initializeMemory(as: T.self, from: unsafePtr, count: c)
```

#### `UnsafeMutablePointer<T>` to `UnsafeMutableRawPointer`:

Because `UnsafeMutablePointer<T>` arguments are implicitly converted to `UnsafePointer<T>`, the `initializeMemory` call above works seamlessly.

Additionally, a mutable typed pointer can be moved-from:

```swift
mraw.moveInitializeMemory(as: T.self, from: unsafeMutablePtr, count: c)
```

#### `UnsafeRawPointer` to `UnsafeMutablePointer<T>`:

No bulk conversion is currently supported from raw to typed memory.

#### `UnsafePointer<T>` to `UnsafeMutablePointer<T>`:

Copying between typed memory is still supported via bulk assignment
(the naming style is updated for consistency):

```swift
ump.assign(from: up, count: c)
ump.moveAssign(from: up, count: c)
```

### CString conversion

One of the more common unsafe pointer conversions arises from viewing a C
string as either an array of bytes (`UInt8`) or C characters
(`CChar`). In Swift, this manifests as arguments of type
`UnsafePointer<UInt8>` and `UnsafePointer<CChar>`. The String API
even encourages interoperability between C APIs and a String's UTF8
encoding. For example:

```swift
var utf8 = template.nulTerminatedUTF8
let (fd, fileName) = utf8.withUnsafeMutableBufferPointer {
  (utf8) -> (CInt, String) in
  let cStrBuf = UnsafeRawPointer(utf8.baseAddress!)
    .assumingMemoryBound(to: UnsafePointer<CChar>)
  let fd = mkstemps(cStrBuf, suffixlen)
  let fileName = String(cString: cStrBuf)
  ...
}
```

This particular case is theoretically invalid because
`nulTerminatedUTF8` writes a buffer of `UInt8` and `mkstemps`
overwrites the same memory as a buffer of `CChar`. More commonly, the
pointer conversion is valid because the buffer is only initialized
once. Nonetheless, the explicit casting is extremely awkward for
such a common use case. To avoid excessive `UnsafePointer` conversion
and ease migration to the `UnsafeRawPointer` model, helpers will be
added to the `String` API.

In `CString.swift`:

```swift
extension String {
  init(cString: UnsafePointer<UInt8>)
}
```

And in `StringUTF8.swift`:

```swift
extension String {
  var nulTerminatedUTF8CString: ContiguousArray<CChar>
}
```

With these two helpers, conversion between `UnsafePointer<CChar>` and
`UnsafePointer<UInt8>` is safe without sacrificing efficiency. The
`String` initializer already copies the byte array into the String's
internal representation, so can trivially convert the element
type. The `nulTerminatedUTF8CString` function also copies the
string's internal representation into an array of `UInt8`. With this
helper, no unsafe casting is necessary in the previous example:

```swift
var utf8Cstr = template.nulTerminatedUTF8CString
let (fd, fileName) = utf8.withUnsafeMutableBufferPointer {
  (utf8CStrBuf) -> (CInt, String) in
  let fd = mkstemps(utf8CStrBuf, suffixlen)
  let fileName = String(cString: utf8CStrBuf)
  ...
}
```

### Full `UnsafeRawPointer` API

Most of the API was already presented above. For the sake of having it
in one place, a list of the expected `UnsafeMutableRawPointer` members
is shown below.

For full doc comments, see the [github revision](https://github.com/atrick/swift/blob/rawptr/stdlib/public/core/UnsafeRawPointer.swift.gyb).

```swift
struct UnsafeMutableRawPointer : Strideable, Hashable, _Pointer {
  var _rawValue: Builtin.RawPointer
  var hashValue: Int

  init(_ _rawValue : Builtin.RawPointer)
  init(_ other : OpaquePointer)
  init(_ other : OpaquePointer?)
  init?(bitPattern: Int)
  init?(bitPattern: UInt)
  init<T>(_: UnsafeMutablePointer<T>)
  init?<T>(_: UnsafeMutablePointer<T>?)

  static func allocate(bytes: Int, alignedTo: Int)
  -> UnsafeMutableRawPointer

  func deallocate(bytes: Int, alignedTo: Int)

  func bindMemory<T>(to: T.Type, capacity: Int) -> UnsafeMutablePointer<T>

  func assumingMemoryBound<T>(to: T.Type) -> UnsafeMutablePointer<T>

  func initializeMemory<T>(as: T.Type, at: Int = 0, count: Int = 1, to: T)
  -> UnsafeMutablePointer<T>

  func initializeMemory<T>(as: T.Type, from: UnsafePointer<T>, count: Int)
  -> UnsafeMutablePointer<T>

  func initializeMemory<C : Collection>(as: C.Iterator.Element.Type, from: C)
  -> UnsafeMutablePointer<C.Iterator.Element>

  func moveInitializeMemory<T>(
    as: T.Type, from: UnsafeMutablePointer<T>, count: Int
  ) -> UnsafeMutablePointer<T> {

  func load<T>(fromByteOffset: Int = 0, as: T.Type) -> T

  func storeBytes<T>(of: T, toByteOffset: Int = 0, as: T.Type)

  func copyBytes(from: UnsafeRawPointer, count: Int)

  func distance(to: UnsafeRawPointer) -> Int
  func advanced(by: Int) -> UnsafeRawPointer
}
```

The immutable `UnsafeRawPointer` members are:

```swift
struct UnsafeRawPointer : Strideable, Hashable, _Pointer {
  var _rawValue: Builtin.RawPointer
  var hashValue: Int

  init(_ _rawValue : Builtin.RawPointer)
  init(_ other : OpaquePointer)
  init(_ other : OpaquePointer?)
  init?(bitPattern: Int)
  init?(bitPattern: UInt)
  init<T>(_: UnsafeMutablePointer<T>)
  init?<T>(_: UnsafeMutablePointer<T>?)

  func deallocate(bytes: Int, alignedTo: Int)

  func bindMemory<T>(to: T.Type, capacity: Int) -> UnsafePointer<T>
  func assumingMemoryBound<T>(to: T.Type) -> UnsafePointer<T>

  func load<T>(fromByteOffset: Int = 0, as: T.Type) -> T

  func distance(to: UnsafeRawPointer) -> Int
  func advanced(by: Int) -> UnsafeRawPointer
}

```

The added `UnsafeMutablePointer` members are:

```swift
UnsafeMutablePointer<Pointee> {
  init(mutating from: UnsafePointer<Pointee>)

  func withMemoryRebound<T>(to: T.Type, capacity count: Int,
    _ body: @noescape (UnsafeMutablePointer<T>) throws -> ()) rethrows

}
```

The added `UnsafePointer` members are:

```swift
UnsafePointer<Pointee> {
  // Inferred initialization from mutable to immutable.
  init(_ from: UnsafeMutablePointer<Pointee>)
}
```

The following unsafe pointer conversions on `Unsafe[Mutable]Pointer`
members are removed:

```swift
UnsafeMutablePointer<Pointee> {
  init<U>(_ from : UnsafeMutablePointer<U>)
  init?<U>(_ from : UnsafeMutablePointer<U>?)
  init<U>(_ from : UnsafePointer<U>)
  init?<U>(_ from : UnsafePointer<U>?)
}
UnsafePointer<Pointee> {
  init<U>(_ from : UnsafePointer<U>)
  init?<U>(_ from : UnsafePointer<U>?)
}
```

`UnsafeMutablePointer.deinitialize` now returns a raw pointer:

```swift
UnsafeMutablePointer<Pointee> {
  func deinitialize(count: Int = 1) -> UnsafeMutableRawPointer
}
```

The following `UnsafeMutablePointer` members are renamed:

```swift
extension UnsafeMutablePointer<Pointee> {
  static func allocate(capacity: Int)
  func deallocate(capacity: Int)

  func initialize(to: Pointee, count: Int = 1)

  func assign(from source: UnsafePointer<Pointee>, count: Int)
  func moveInitialize(from source: ${Self}, count: Int)
  func initialize(from source: UnsafePointer<Pointee>, count: Int)
  func initialize<C : Collection>(from source: C)
  func moveAssign(from source: ${Self}, count: Int)
}
```

The following `UnsafeMutablePointer` members are removed:

```swift
extension UnsafeMutablePointer<Pointee> {
  func assignBackwardFrom(_ source: UnsafePointer<Pointee>, count: Int)
  func moveInitializeBackwardFrom(_ source: ${Self}, count: Int)
}
```

## Impact on existing code

The largest impact of this change is that `void*` and `const void*`
are imported as `UnsafeMutableRawPointer` and
`UnsafeRawPointer`. This impacts many public APIs, but with implicit
argument conversion should not affect typical uses of those APIs.

Any Swift projects that rely on type inference to convert between
`UnsafePointer` types will need to take action. The developer needs to
determine whether type punning is necessary. If so, they must migrate
to the `UnsafeRawPointer` API. Otherwise, they can work around the new
restriction by using `bindMemory(to:capacity:)`,
`assumingMemoryBound<T>(to)`, or adding a `mutating` label to their
initializer.

The [unsafeptr_convert branch][2] contains an implementation of a
previous design, which will soon be ported to the [rawptr branch][3].

[2]:https://github.com/atrick/swift/commits/unsafeptr_convert
[3]:https://github.com/atrick/swift/commits/rawptr

### Swift code migration

All occurrences of the type `Unsafe[Mutable]Pointer<Void>` will be
automatically replaced with `Unsafe[Mutable]RawPointer`.

Initialization of the form `Unsafe[Mutable]Pointer`(p) will
automatically be replaced by `Unsafe[Mutable]RawPointer(p)` whenever
the type checker determines that is the expression's expected type.

Conversion between incompatible `Unsafe[Mutable]Pointer` values will
produce a diagnostic explaining asking the user to migrate to one of these forms:
- `Unsafe[Mutable]RawPointer($0).withMemoryRebound(to:capacity:)`
- `Unsafe[Mutable]RawPointer($0).bindMemory(to:capacity:)`
- `Unsafe[Mutable]RawPointer($0).assumingMemoryBound(to: T.self)`

The following UnsafeMutablePointer methods:

- `initializeFrom(_: UnsafePointer<Pointee>, count: Int)`
- `initializeBackwardFrom(_: UnsafePointer<Pointee>, count: Int)`
- `assignFrom(_ source: Unsafe[Mutable]Pointer<Pointee>, count: Int)`
- `moveAssignFrom(_ source: Unsafe[Mutable]Pointer<Pointee>, count: Int)`

will be automatically converted to:

- `initialize(from: UnsafePointer<Pointee>, count: Int)`
- `assign(from source: Unsafe[Mutable]Pointer<Pointee>, count: Int)`

### Standard library changes

Disallowing inferred `UnsafePointer` conversion requires some standard
library code to use an explicit `.bindMemory(to:capacity:)`
whenever the conversion may previously violate strict aliasing.

All occurrences of `Unsafe[Mutable]Pointer<Void>` in the standard
library are converted to `Unsafe[Mutable]RawPointer`. e.g. `unsafeAddress()` now
returns `UnsafeRawPointer`, not `UnsafePointer<Void>`.

Some occurrences of `Unsafe[Mutable]Pointer<Pointee>` in the standard
library are replaced with `UnsafeRawPointer`, either because the code was
playing too loosely with strict aliasing rules, or because the code
actually wanted to perform pointer arithmetic on byte-addresses.

`StringCore.baseAddress` changes from `OpaquePointer` to
`UnsafeMutableRawPointer` because it is computing byte offsets and
accessing the memory.  `OpaquePointer` is meant for bridging, but
should be truly opaque; that is, non-dereferenceable and not involved
in address computation.

The `StringCore` implementation does a considerable amount of casting
between different views of the `String` storage. For interoperability
and optimization, String buffers frequently need to be cast to and
from `CChar`. This will be made safe by using `bindMemory(to:capacity:)`.

`CoreAudio` utilities now use `Unsafe[Mutable]RawPointer`.


## Implementation status

An [unsafeptr_convert branch][2] has the first prototype, named
`UnsafeBytePointer`, and includes standard library and type system changes
listed below. A [rawptr branch][3] has the latest proposed
implementation of `UnsafeRawPointer`. I am currently updating the
`rawptr` branch to include the following changes.

There are a several things going on here in order to make it possible
to build the standard library with the changes:

- A new `UnsafeRawPointer` type is defined.

- The type system imports `void*` as UnsafeRawPointer.

- The type system handles implicit conversions to UnsafeRawPointer.

- `UnsafeRawPointer` replaces both `UnsafePointer<Void>` and
  `UnsafeMutablePointer<Void>` (Recent feedback suggestes that
  `UnsafeMutablePointer` should also be introduced).

- The standard library was relying on inferred `UnsafePointer`
  conversion in over 100 places. Most of these conversions now either
  take an explicit label, such as `mutating` or have been rewritten.

- Several places in the standard library that were playing loosely
  with strict aliasing or doing bytewise pointer arithmetic now use
  `UnsafeRawPointer` instead.

- Explicit labeled `Unsafe[Mutable]Pointer` initializers are added.

- The inferred `Unsafe[Mutable]Pointer` conversion is removed.

Remaining work:

- A SIL-level builtin needs to be implemented for binding a region of memory.

- A name mangled abbreviation needs to be created for `UnsafeRawPointer`.

- We may want a convenience utility for binding null-terminated string
  without providing a capacity.

- The StringAPI tests should probably be rewritten with
  `UnsafeRawPointer`.

- The NSStringAPI utilities and tests may need to be ported to
  `UnsafeRawPointer`

- The CoreAudio utilities and tests may need to be ported to
  `UnsafeRawPointer`.

## Future improvements and planned additive API

`UnsafeRawPointer` should eventually support unaligned memory access. I
believe that we will eventually have a modifier that allows "packed"
struct members. At that time we may also want to add an "unaligned" flag to
`UnsafeRawPointer`'s `load` and `initialize` methods.

## Alternatives previously considered

### unsafeBitCast workaround

In some cases, developers can safely reinterpret values to achieve the
same effect as type punning:

```swift
let ptrI32 = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
ptrI32[0] = Int32()
let u = unsafeBitCast(ptrI32[0], to: UInt32.self)
```

Note that all access to the underlying memory is performed with the
same element type. This is perfectly legitimate, but simply isn't a
complete solution. It also does not eliminate the inherent danger in
declaring a typed pointer and expecting it to point to values of a
different type.

### typePunnedMemory property

We considered adding a `typePunnedMemory` property to the existing
`Unsafe[Mutabale]Pointer` API. This would provide a legal way to
access a potentially type punned `Unsafe[Mutabale]Pointer`. However,
it would certainly cause confusion without doing much to reduce
likelihood of programmer error. Furthermore, there are no good use
cases for such a property evident in the standard library.

### Special UnsafeMutablePointer<RawByte> type

The opaque `_RawByte` struct is a technique that allows for
byte-addressable buffers while hiding the dangerous side effects of
type punning (a `_RawByte` could be loaded but it's value cannot be
directly inspected). `UnsafePointer<_RawByte>` is a clever alternative
to `UnsafeRawPointer`. However, it doesn't do enough to prevent
undefined behavior. The loaded `_RawByte` would naturally be accessed
via `unsafeBitCast`, which would mislead the author into thinking that
they have legally bypassed the type system. In actuality, this API
blatantly violates strict aliasing. It theoretically results in
undefined behavior as it stands, and may actually exhibit undefined
behavior if the user recovers the loaded value.

To solve the safety problem with `UnsafePointer<_RawByte>`, the
compiler could associate special semantics with a `UnsafePointer`
bound to this concrete generic parameter type. Statically enforcing
casting rules would be difficult if not impossible without new
language features. It would also be impossible to distinguish between
typed and untyped pointer APIs. For example,
`UnsafePointer<T>.load<U>` would be a nonsensical vestige.

### UnsafeBytePointer

This first version of this proposal introduced an
`UnsafeBytePointer`. `UnsafeRawPointer` better conveys the type's role
with respect to uninitialized memory. The best way to introduce
`UnsafeRawPointer` to users is by showing how it represents
uninitialized memory. It is the result of allocation, input to
initialization, and result of deinitialization.  This helps users
understand the relationship between initializing memory and imbuing it
with a type.

Furthermore, we do not intend to allow direct access to the "bytes"
via subscript which would be implied by `UnsafeBytePointer`.

### Alternate proposal for `void*` type

Changing the imported type for `void*` will be somewhat disruptive. We
could continue to import `void*` as `UnsafeMutablePointer<Void>` and
`const void*` as `UnsafePointer<Void>`, which will continue to serve
as an "opaque" untyped pointer. Converting to `UnsafeRawPointer` would
be necessary to perform pointer arithmetic or to conservatively handle
possible type punning.

This alternative is *much* less disruptive, but we are left with two
forms of untyped pointer, one of which (`UnsafePointer`) the type
system somewhat conflates with typed pointers.

There seems to be general agreement that `UnsafeMutablePointer<Void>`
is fundamentally the wrong way to represent untyped memory.

From a practical perspective, given the current restrictions of the
language, it's not clear how to statically enforce the necessary rules
for casting `UnsafePointer<Void>` once general `UnsafePointer<T>`
conversions are disallowed. The following conversions should be
inferred, and implied for function arguments (ignoring mutability):

- `UnsafePointer<T>` to `UnsafePointer<Void>`

- `UnsafePointer<Void>` to `UnsafeRawPointer`

I did not implement this simpler design because my primary goal was to
enforce legal pointer conversion and rid Swift code of undefined
behavior. I can't do that while allowing `UnsafePointer<Void>`
conversions.

The general consensus now is that as long as we are making source
breaking changes to `UnsafePointer`, we should try to shoot for an
overall better design that helps programmers understand the concepts.
