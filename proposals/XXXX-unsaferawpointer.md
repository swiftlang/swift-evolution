# UnsafeRawPointer API

* Proposal: [SE-NNNN](https://github.com/atrick/swift-evolution/blob/voidpointer/proposals/XXXX-unsaferawpointer.md)
* Author(s): [Andrew Trick](https://github.com/atrick)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

For quick reference, jump to:
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
example of *type punning* using the ``UnsafePointer`` type::

```swift
  let ptrT: UnsafeMutablePointer<T> = ...
  // Store T at this address.
  ptrT[0] = T()
  // Load U at this address
  let u = UnsafePointer<U>(ptrT)[0]
```

This code violates assumptions made by the compiler and falls into the
category of "undefined behavior". Undefined behavior is a way of
saying that we cannot easily specify constraints on the behavior of
programs that violate a rule. The program may crash, corrupt memory,
or be miscompiled in other ways. Miscompilation may include optimizing
away code that was expected to execute or executing code that was not
expected to execute.

Swift already protects against undefined behavior as long as the code
does not use "unsafe" constructs. However, UnsafePointer is an
important API for interoperability and building high performance data
structures. As such, the rules for safe, well-defined usage of the API
should be clear. Currently, it is too easy to use UnsafePointer
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
not bound by the same strict aliasing rules.

This proposal aims to achieve several goals in one coherent design:

1. Provide an untyped pointer type.

2. Specify which pointer types follow strict aliasing rules.

3. Inhibit UnsafePointer conversion that violates strict aliasing.

4. Provide an API for safe type punning (memcpy semantics).

5. Provide an API for manual memory layout (bytewise pointer arithmetic).

Early swift-evolution threads:

- [\[RFC\] UnsafeBytePointer API for In-Memory Layout](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/thread.html#16909)

- [\[RFC\] UnsafeBytePointer API for In-Memory Layout (Round 2)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/thread.html#18156)

[1]:https://github.com/atrick/swift/blob/type-safe-mem-docs/docs/TypeSafeMemory.rst

Mentions of `UnsafePointer` that appear in this document's prose also
apply to `UnsafeMutablePointer`.

## Proposed Solution

We first introduce each aspect of the proposed API so that the
Motivation section can show examples. The Detailed design section
lists the complete API.

### UnsafeRawPointer

New `UnsafeRawPointer` and `UnsafeMutableRawPointer` types will
represent a "raw" untyped memory region. Raw memory is what is
returned from memory allocation prior to initialization. Normally,
once the memory has been initialized, it will be accessed via a typed
`UnsafeMutablePointer`. After initialization, the raw memory can still
be accessed as a sequence of bytes, but the raw API provides no
information about the initialized type. Because the raw pointer may
alias with any type, the semantics of reading and writing through a
raw pointer are similar to C `memcpy`.

### Memory allocation and initialization

`UnsafeMutableRawPointer` will provide an `allocatingCapacity`
initializer and `deallocate` method:

```swift
extension UnsafeMutableRawPointer {
    // Allocate memory with the size and alignment of `allocatingCapacity`
    // contiguous elements of `T`. The resulting `self` pointer is not
    // associated with the type `T`. The type is only provided as a convenient
    // way to derive stride and alignment.
    init<T>(allocatingCapacity: Int, of: T.Type)

    func deallocate<T>(capacity: Int, of: T.Type)
```

Initializing memory at an `UnsafeMutableRawPointer` produces an
`UnsafeMutablePointer<Pointee>` and deinitializing the
`UnsafeMutablePointer<Pointee>` produces an `UnsafeMutableRawPointer`.

```swift
extension UnsafeMutableRawPointer {
  // Copy a value of type `T` into this uninitialized memory.
  // Returns an UnsafeMutablePointer into the newly initialized memory.
  //
  // Precondition: memory is uninitialized.
  func initialize<T>(_: T.Type, with: T, count: Int = 1)
    -> UnsafeMutablePointer<T>
}

extension UnsafeMutablePointer {
  /// De-initialize the `count` `Pointee`s starting at `self`, returning
  /// their memory to an uninitialized state.
  /// Returns a raw pointer to the uninitialized memory.
  public func deinitialize(count: Int = 1) -> UnsafeMutableRawPointer
}
```

Note that the `T.Type` argument on `initialize` is redundant because
it may be inferred from the `with` argument. However, relying on type
inferrence at this point is dangerous. The user needs to ensure that
the raw pointer has the necessary size and alignment for the
initialized type. Explicitly spelling the type at initialization
prevents bugs in which the user has incorrectly guessed the inferred
type.

### Raw memory access

Loading from and storing to memory via an `Unsafe[Mutable]RawPointer`
is safe independent of the type of value being loaded or stored and
independent of the memory's initialized type as long as layout
guarantees are met (per the ABI), and care is taken to properly
initialize and deinitialize nontrivial values (see
[Trivial types](#trivial-types)). This allows legal type punning
within Swift and allows Swift code to access a common region of memory
that may be shared across an external interface that does not provide
type safety guarantees.

Accessing type punned memory directly through a designated
`Unsafe[Mutable]RawPointer` type provides sound basis for compiler
implementation of strict aliasing. It may be tempting to simply
provide a special unsafe pointer cast operation that designates
aliasing between pointers of different types. However, this strategy
cannot be reliably implemented because the pointer access may be
visible to the compiler, while the cast itself is obscured. The
purpose of type-based aliasing is to allow the compiler to optimize
even when it cannot determine the origin of the pointer. With
`Unsafe[Mutable]RawPointer`, the compiler can detect *at the point of
access* that the pointer is "raw" and therefore may alias with other
pointers of unrelated types.

```swift
extension UnsafeMutableRawPointer {
  // Read raw bytes and produce a value of type `T`.
  func load<T>(_: T.Type) -> T

  // Write a value of type `T` into this memory, overwriting any
  // previous values.
  //
  // Note that this is not an assignment, because any previously
  // initialized value in this memory is not deinitialized.
  //
  // Precondition: memory is either uninitialized or initialized with a
  // trivial type.
  //
  // Precondition: `T` is a trivial type.
  //
  // A "trivial" type promises that assignment just requires a fixed-size
  // bit-for-bit copy without any indirection or reference-counting operations.
  func storeRaw<T>(_: T.Type, with: T)
}
```

### Bytewise pointer arithmetic

Providing an API for accessing raw memory would not serve much purpose
without the ability to compute byte offsets. Naturally,
`UnsafeRaw[Mutable]Pointer` is Strideable as a sequence of bytes.

```swift
extension UnsafeRawPointer : Strideable {
  public func distance(to : UnsafeRawPointer) -> Int

  public func advanced(by : Int) -> UnsafeRawPointer
}

public func == (lhs: UnsafeRawPointer, rhs: UnsafeRawPointer) -> Bool

public func < (lhs: UnsafeRawPointer, rhs: UnsafeRawPointer) -> Bool

public func + (lhs: UnsafeRawPointer, rhs: Int) -> UnsafeRawPointer

public func - (lhs: UnsafeRawPointer, rhs: UnsafeRawPointer) -> Int
```

### Unsafe pointer conversion

Currently, an `UnsafePointer` initializer supports conversion between
potentially incompatible pointer types:

```swift
struct UnsafePointer<Pointee> {
  public init<U>(_ from : UnsafePointer<U>)
}
```

This initializer will be removed. To perform an unsafe cast to a typed
pointer, the user will be required to construct an `UnsafeRawPointer`
and invoke a conversion method that explicitly takes the destination type:

```swift
extension UnsafeRawPointer {
  func cast<T>(to: UnsafePointer<T>.Type) -> UnsafePointer<T>
}
```

## Motivation

The following examples show the differences between memory access as
it currently would be done using `UnsafeMutablePointer` vs. the
proposed `UnsafeMutableRawPointer`.

Consider two layout compatible, but unrelated structs, `A` and `B`, and helpers
that write to and read from these structs via unsafe pointers:

```swift
// --- common definitions used by old and new code ---
struct A {
  var value: Int
}

struct B {
  var value: Int
}

func assignA(_ pA: UnsafeMutablePointer<A>) {
  pA[0] = A(value:42)
}

func assignB(_ pB: UnsafeMutablePointer<B>) {
  pB[0] = B(value:13)
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
  pA.initialize(with: A(value:42))
}

func initB(pB: UnsafeMutablePointer<B>) {
  pB.initialize(with: B(value:13))
}

func normalLifetime() {
  // Memory is uninitialized, but `pA` is already typed, which is misleading.
  let pA = UnsafeMutablePointer<A>(allocatingCapacity: 1)

  initA(pA)

  printA(pA)

  pA.deinitialize(count: 1)

  pA.deallocateCapacity(1)
}
```

The current API does nothing to discourage using assigment for
initialization. It happens to work in this case because `A` is a
trivial type:

```swift
// --- old version with assignment ---
func normalLifetime() {
  let pA = UnsafeMutablePointer<A>(allocatingCapacity: 1)

  // Assignment without initialization.
  assignA(pA)

  printA(pA)

  pA.deinitialize(count: 1)

  pA.deallocateCapacity(1)
}
```

With `UnsafeMutableRawPointer`, the distinction between initialized
and uninitialized memory is now clear. This may seem dogmatic, but
becomes important when writing generic code. First we provide new
helpers for initialization that operate on the raw pointer to
allocated memory:

```swift
// --- new version ---
func initA(p: UnsafeMutableRawPointer) -> UnsafeMutablePointer<A> {
  return p.initialize(A.self, with: A(value:42))
}

func initB(p: UnsafeMutableRawPointer) -> UnsafeMutablePointer<B> {
  return p.initialize(B.self, with: B(value:13))
}
```

Now we can safely initialize raw memory and obtain a typed pointer:

```swift
// --- new version ---
func normalLifetime() {
  let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: 1, of: A.self)

  // assignA cannot be called on rawPtr, which forces initialization:
  let pA = initA(rawPtr)

  printA(pA)

  let uninitPtr = pA.deinitialize(count: 1)
  uninitPtr.deallocate(capacity: 1, of: A.self)
}
```

<hr>
Technically, it is correct to initialize values of type `A` and `B` in
different memory locations, but confusing and dangerous with the
current `UnsafeMutablePointer` API:

```swift
// --- old version ---
// Return a pointer to (A, B).
func initAB() -> UnsafeMutablePointer<A> {

  // Memory is uninitialized, but `pA` is already typed.
  let pA = UnsafeMutablePointer<A>(allocatingCapacity: 2)

  initA(UnsafeMutablePointer(pA))

  // pA is recast as pB with no indication that the pointee type has changed!
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

  // pA is again recast as pB with no indication that the pointee type changes!
  printB(UnsafeMutablePointer(pA + 1))

  // Or recast to pB first, which is also misleading!
  printB(UnsafeMutablePointer<B>(pA) + 1)
}
```

With `UnsafeMutableRawPointer`, raw memory may have the correct size and
alignment for a type, but does not have a type until it is
initialized.

```swift
// --- new version ---
// Return a pointer to an untyped memory region initialized with (A, B).
func initAB() -> UnsafeMutableRawPointer {

  // Allocate raw memory of size 2 x strideof(Int).
  let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: 2, of: Int.self)

  // Initialize the first Int with A, producing UnsafeMutablePointer<A>.
  let pA = initA(rawPtr)

  // Initialize the second Int with B.
  // This implicitly casts UnsafeMutablePointer<A> to UnsafeMutableRawPointer,
  // which is equivalent to initB(p + strideof(Int)).
  // Unlike the old API, no unsafe pointer conversion is needed.
  initB(pA + 1)

  return p
}
```

Unsafe conversion from raw memory to typed memory is always explicit:

```swift
// --- new version ---
// Code in the caller is explicit:
func testInitAB() {
  // Get a raw pointer to (A, B).
  let p = initAB()

  // The untyped memory is explicitly converted to a pointer-to-A.
  // Safe because we know the underlying memory is initialized to A.
  let pA = p.cast(to: UnsafePointer<A>.self)
  printA(pA)

  // Converting from a pointer-to-A into a pointer-to-B requires
  // creation of an UnsafeRawPointer.
  printB(UnsafeRawPointer(pA + 1).cast(to: UnsafePointer<B>.self))

  // Or convert the original UnsafeRawPointer into pointer-to-B.
  printB((p + strideof(Int.self)).cast(to: UnsafePointer<B>.self))
}
```

<hr>

Initializing or assigning values of different type to the same
location using a typed pointer is undefined. Here, the compiler can
choose to ignore the order of assignment, and `initAthenB` may print
13 twice or 42 twice.

```swift
// --- old version ---
func initAthenB(_ p: UnsafeMutablePointer<Void>) {
  let p = UnsafeMutablePointer<Int>(allocatingCapacity: 1)

  initA(UnsafeMutablePointer(p))
  printA(UnsafeMutablePointer(p))

  initB(UnsafeMutablePointer(p))
  printB(UnsafeMutablePointer(p))
}
```

With the proposed API, assigning values of different types to the same
location can now be safely done by properly initializing and
deinitializing the memory through `UnsafeMutableRawPointer`. Ultimately, the
values may still be accessed via the same convenient
UnsafeMutablePointer type. Type punning has not happened, because the
UnsafeMutablePointer has the same type as the memory's initialized
type whenever it is dereferenced.

```swift
// --- new version ---
func initAthenB {
  let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: 1, of: Int.self)

  let pA = initA(rawPtr)

  // Raw memory now holds an `A` which may be accessed via `pA`.
  printA(pA)

  // After deinitializing `pA`, `uninitPtr` receives a pointer to
  // untyped raw memory, which may be reused for `B`.
  let uninitPtr = pA.deinitialize(count: 1)

  // rawPtr and uninitPtr have the same value, thus are substitutable.
  assert(rawPtr == uninitPtr)

  // initB now operates on raw memory, so cannot be reordered with previous
  // accesses to pA.
  initB(uninitPtr)

  printB(pB)
}
```

<hr>
No API currently exists that allows initialized memory to hold either A or B.

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

```swift
// --- old version ---
// Code in the caller could produce undefined behavior:
func testInitAorB() {
  let p = UnsafeMutablePointer<Int>(allocatingCapacity: 1)

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
this is safe because the memory initialization on a raw pointer is an
untyped operation. This initialization separates access to the
distinct types from the compiler's viewpoint.

```swift
// --- new version ---
func initAorB(_ p: UnsafeMutableRawPointer, isA: Bool) {
  // Unsafe pointer conversion is no longer required to initialize memory.
  if isA {
    initA(p)
  }
  else {
    initB(p)
  }
}
```

Code in the caller is now well defined because initAorB is now a
compiler barrier for unsafe pointer access. Furthermore, each unsafe
pointer cast is explicit:

```swift
// --- new version ---
func testInitAorB() {
  let p = UnsafeMutableRawPointer(allocatingCapacity: 1, of: Int.self)

  initAorB(p, isA: true)
  printA(p.cast(to: UnsafePointer<A>.self))

  initAorB(p, isA: false)
  printB(p.cast(to: UnsafePointer<B>.self))
}
```

<hr>
`UnsafeMutableRawPointer` also provides a legal way to access the
memory using a different pointer type than the memory's initialized
type (type punning). The following example is safe because the memory
is never accessed via a typed `UnsafePointer`. A raw pointer is
allocated, the raw pointer is initialized, and the raw pointer
dereferenced. Every read and write through `UnsafeRawPointer` has
untyped (memcpy) semantics.

```swift
// --- new version ---
func testTypePun() {
  let p = UnsafeMutableRawPointer(allocatingCapacity: 1, of: Int.self)

  // Initialize raw memory to `A`.
  initAorB(p, isA: true)

  // Load from raw memory as `B` (type punning).
  // `printB(p.cast(to: UnsafePointer<B>.self))` would be illegal, because the
  // a typed pointer to `B` cannot be used to access an unrelated type `A`.
  // However, `p.load(B.self)` is safe because `B` is layout compatible with `A`
  // and `p` is a raw, untyped pointer.
  print(p.load(B.self))
}
```

<hr>
Developer's may be forced to work with "loosely typed" APIs,
particularly for interoperability:

```swift
func readBytes(_ bytes: UnsafePointer<UInt8>) {
  // 3rd party implementation...
}
func readCStr(_ string: UnsafePointer<CChar>) {
  // 3rd party implementation...
}
```

Working with these API's exclusively using UnsafeMutablePointer leads
to undefined behavior, as shown here using the current API:

```swift
// --- old version ---
func stringFromBytes(size: Int, value: UInt8) {
  let bytes = UnsafeMutablePointer<UInt8>(allocatingCapacity: size + 1)
  bytes.initialize(with: value, count: size)
  bytes[size] = 0

  // The signature of readBytes is consistent with the `bytes` argument type.
  readBytes(bytes)

  // Unsafe pointer conversion is requred to invoke readCString.
  // If readCString is inlineable and compiled with strict aliasing,
  // then it could read uninitialized memory.
  readCStr(UnsafePointer(bytes))
}
```

Initializing memory with `UnsafeRawPointer` makes it legal to read
that memory regardless of the pointer type. Reading from uninitialized
memory is now prevented:

```swift
// --- new version ---
func stringFromBytes(size: Int, value: UInt8) {
  let buffer = UnsafeMutableRawPointer(
    allocatingCapacity: size + 1, of: UInt8.self)

  // Writing the bytes using UnsafeRawPointer allows the bytes to be
  // read later as any type without violating strict aliasing.
  buffer.initialize(UInt8.self, with: value, count: size)
  buffer.initialize(toContiguous: UInt8.self, atIndex: size, with: 0)

  // All subsequent reads are guaranteed to see initialized memory.
  readBytes(buffer)

  readCStr(buffer)
}
```

It is even possible for the shared buffer to be mutable by using
`UnsafeRawPointer.initialize` or `UnsafeRawPointer.storeRaw` to
perform the writes:

```swift
// --- new version ---
func mutateBuffer(size: Int, value: UInt8) {
  let buffer = UnsafeMutableRawPointer(
    allocatingCapacity: size + 1, of: UInt8.self)

  buffer.initialize(UInt8.self, with: value, count: size)
  buffer.initialize(toContiguous: UInt8.self, atIndex: size, with: 0)

  readBytes(bytes)

  // Mutating the raw, untyped buffer bypasses strict aliasing rules.
  buffer.storeRaw(UInt8.self, with: getChar())

  readCStr(bytes)
}
func getChar() -> CChar) {
  // 3rd party implementation...
}
```

<hr>
The side effects of illegal type punning may result in storing values
in the wrong sequence, reading uninitialized memory, or memory
corruption. It could even result in execution following code paths
that aren't expected as shown here:

```swift
// --- old version ---
func testUndefinedExecution() {
  let pA = UnsafeMutablePointer<A>(allocatingCapacity: 1)
  assignA(pA)
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

func unforeseenCode(_ pA: UnsafeMutablePointer<A>) {
  // At some arbitrary point in the future, the same memory is
  // innocuously assigned to B.
  assignB(UnsafeMutablePointer(pA))
}
```

Prohibiting conversion between incompatible `UnsafePointer` types and
providing an API for raw memory access is necessary to expose the
danger of type punning at the API level and encourage safe idioms for
working with pointers.

## Memory model explanation

### Raw vs. Typed Pointers

The fundamental difference between `Unsafe[Mutable]RawPointer` and
`Unsafe[Mutable]Pointer<Pointee>` is simply that the former is used
for "untyped" memory access, and the later is used for "typed" memory
access. Let's refer to these as "raw pointers" and "typed
pointers". Because operations on raw pointers are "untyped", the
compiler cannot make assumptions about the underlying type of memory
and must be conservative. With operations on typed pointers, the
compiler may make strict assumptions about the type of the underlying
memory, which allows more aggressive optimization.

### Memory initialization

All allocated memory exists in one of two states: "uninitialized" or
"initialized". Upon initialization, memory is associated with the type
of value that it holds and remains associated with that type until it
is deinitialized. Initialized memory may be assigned to a new value of
the same type.

Consider this sequence of abstract memory operations:

Abstract Operation              | Memory State  | Type
------------------------------- | ------------  | ----
rawptr = allocate()             | uninitialized | None
tptr = rawptr.initialize(t1: T) | initialized   | contains T
tptr.assign(t2: T)              | initialized   | contains T
tptr.deinitialize               | uninitialized | None
uptr = rawptr.initialize(u1: U) | initialized   | contains U
uptr.assign(u2: U)              | initialized   | contains U
uptr.deinitialize               | uninitialized | None
rawptr.deallocate               | invalid       | None

The proposed API establishes a convention whereby raw pointers
primarily refer to uninitialized memory and typed pointers primarily
refer to initialized memory. This provides the most safety and clarity
by default, but is not a stricly enforced rule. After a raw pointer is
intialized, the raw pointer value remains valid and can continue to be
used to access the underlying memory in an untyped way. Conversely, a
raw pointer can be force-cast to a typed pointer without initializing
the underlying memory. When a program defies convention this way, the
programmer must be aware of the rules for working with raw memory as
explaned below.

### Trivial types

Certain kinds of memory access, as decribed in the following two sections,
are only valid for "trivial types". A ``trivial type`` promises
that assignment just requires a fixed-size bit-for-bit copy without
any indirection or reference-counting operations. Generally, native
Swift types that do not contain strong or weak references or other
forms of indirection are trivial, as are imported C structs and enums.

Examples of trivial types:
- Integer and floating-point types
- `Bool`
- `Optional<T>` where `T` is trivial
- `Unmanaged<T: AnyObject>`
- struct types where all members are trivial
- enum types where all payloads are trivial

### Accessing uninitialized memory with a typed pointer (binding the type)

A raw pointer may be cast to a typed pointer, bypassing raw initialization:

```swift
let ptrToSomeType = rawPtr.cast(to: UnsafePointer<SomeType>.self)
```

This cast explicitly signals the intention to bind the raw
memory to the destination type. Using the cast's typed pointer result to
initialize the memory actually binds the type. If memory is bound to a
type, it is illegal for the program to access the same allocated
memory as an unrelated type. Consequently, this should only be done
when the programmer has control over the allocation and deallocation
of the memory and thus can guarantee that the memory is never
initialized to an unrelated type.

The sequence shown below binds allocated memory to type `T` in two
places. The sequence is valid because the bound memory is never
accessed as a different type:

Abstract Operation                            | Memory State  | Type
--------------------------------------------- | ------------  | ----
rawptr = allocate()                           | uninitialized | None
tptr = rawptr.cast(to: UnsafePointer<T>.Type) | uninitialized | None
tptr.initialize(t1: T)                        | initialized   | binds to T
tptr.deinitialize                             | uninitialized | None
tptr.initialize(t2: T)                        | initialized   | binds to T
tptr.deinitialize                             | uninitialized | None
rawptr.deallocate                             | invalid       | None

When binding allocated memory to a type, the programmer assumes
responsibility for two aspects of the managing the memory:

1. ensuring that the underlying raw memory will only *ever* be
   initialized to the pointer's type

2. tracking the memory's initialized state (usually of several
   individual contiguous elements)

For example:

```swift
func getAt(index: Int) -> A {
  if !isInitializedAt(index) {
    (ptrToSomeType + index).initialize(with: Type())
  }
  return ptrToSomeType[index]
}
```

This is a useful technique for optimizing data structures that manage
storage for contiguous elements. The data structure may allocate a
buffer with extra capacity and track the initialized state of each
element position. Accessing the buffer via a typed pointer is both
more convenient and may improve performance under some conditions.

(See the [C buffer](#c-buffer) use case below.)

Casting a raw pointer to a typed pointer also allows initialization
via an assignment operation. However, this is only valid on trivial types:

```swift
  let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: 1, of: Int.self)

  // Cast uninitialized memory to a typed pointer.
  let pInt = rawPtr.cast(to: UnsafeMutablePointer<Int>.self)

  // Initialize the trivial Int type using assignment.
  pInt[0] = 42

  // Skip deinitialization for the trivial Int type.
  rawPtr.deallocate(capacity: 1, of: Int.self)
```

### Accessing initialized memory with a raw pointer.

A program may read from and write to memory via a raw pointer even
after the memory has been initialized:

```swift
let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: 1, of: SomeType.self)

let ptrToSomeType = rawPtr.initialize(SomeType.self, SomeType())

// read raw initialized memory
let reinterpretedValue = rawPtr.load(AnotherType.self)

// overwrite raw initialized memory
rawPtr.storeRaw(AnotherType.self, with: AnotherType())
```

For both loading from and storing to raw memory, the programmer takes
responsibility for ensuring size and alignment compatibility between
the type of value held in memory and the type used to access the
memory via a raw pointer. This requires some knowledge of the ABI.

When loading from raw memory, and potentially reinterpreting a value,
the programmer takes responsibility for ensuring that class references
are never formed to an unrelated object type. This is a
incontravertible property of all reference values in the
system. Otherwise, as long as the above conditions are met, loading is
safe.

Storing a value into raw memory requires consideration of the type of
value being overwritten because a raw store overwrites memory contents
without destroying the previous value. Storing to raw memory is safe
if both the previous value in memory, and the value being stored are
trivial types, which can be assigned via a bit-for-bit copy.

## Expected use cases

This section lists several typical use cases involving `UsafeRawPointer`.

For explanatory purposes consider the following global definitions:

```swift
struct A {
  var value: Int
}
struct B {
  var value: Int
}

var ptrToA: UnsafeMutablePointer<A>
var eltCount: Int = 0
```

### Single value

Using a pointer to a single value:

```swift
func createValue() {
  let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: 1, of: A.self)
  ptrToA = rawPtr.initialize(A.self, with: A(value: 42))
}

func deleteValue() {
  ptrToA.deinitialize(count: 1).deallocate(capacity: 1, of: A.self)
}
```

### C array

Using a fully initialized set of contiguous homogeneous values:

```swift
func createCArray(from source: UnsafePointer<A>, count: Int) {
  let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: count, of: A.self)
  ptrToA = rawPtr.initialize(from: source, count: count)
  eltCount = count
}

func deleteCArray() {
  ptrToA.deinitialize(count: eltCount).deallocate(
    capacity: eltCount, of: A.self)
}
```

### Untyped loads and stores

Accessing raw underlying memory bytes:

```swift
// Direct bytewise element copy.
func copyArrayElement(fromIndex: Int, toIndex: Int) {
  let srcPtr = UnsafeRawPointer(ptrToA) + (fromIndex * strideof(A))
  let destPtr = UnsafeMutableRawPointer(ptrToA) + (toIndex * strideof(A))

  destPtr.storeRaw(contiguous: A.self, from: srcPtr, count: 1)
}

// Bytewise element swap.
// Initializes and deinitializes temporaries of type Int.
// Int is layout compatible with `A`.
func swapArrayElements(index i: Int, index j: Int) {
  let rawPtr = UnsafeMutableRawPointer(ptrToA)
  let tmpi = rawPtr.load(fromContiguous: Int.self, atIndex: i)
  let tmpj = rawPtr.load(fromContiguous: Int.self, atIndex: j)
  rawPtr.storeRaw(toContiguous: Int.self, atIndex: i, with: tmpj)
  rawPtr.storeRaw(toContiguous: Int.self, atIndex: j, with: tmpi)
}
```

### C buffer

Managing a buffer with a mix of initialized and uninitialized
contiguous elements. Typically, information about which elements are
initialized will be separately maintained to ensure that the following
preconditions are always met:

```swift
func createCBuffer(size: Int) {
  let rawPtr = UnsafeMutableRawPointer(allocatingCapacity: size, of: A.self)
  ptrToA = rawPtr.cast(to: UnsafeMutablePointer<A>.self)
  eltCount = size
}

// - precondition: memory at `index` is uninitialized.
func initElement(index: Int, with value: A) {
  (ptrToA + index).initialize(with: value)
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
  UnsafeRawPointer(ptrToA).deallocate(capacity: eltCount, of: A.self)
}
```

### Manual layout of typed, aligned memory

```swift
// Layout an object with header type `A` following by `n` elements of type `B`.
func createValueWithTail(count: Int) {
  // Assuming the alignment of `A` satisfies the alignment of `B`.
  let numBytes = strideof(A) + (count * strideof(B))

  let rawPtr = UnsafeMutableRawPointer(allocatingBytes: numBytes,
    alignedTo: alignof(A))

  // Initialize the object header.
  ptrToA = rawPtr.initialize(A.self, with: A(value: 42))
  eltCount = count

  // Append `count` elements of type `B` to the object tail.
  UnsafeMutableRawPointer(ptrToA + 1).initialize(
    B.self, with: B(value: 13), count: count)
}

func getTailElement(index: Int) -> B {
  return UnsafeRawPointer(ptrToA + 1)
    .cast(to: UnsafePointer<B>.self)[index]
}

func deleteValueWithTail() {
  UnsafeMutableRawPointer(ptrToA + 1)
    .cast(to: UnsafePointer<B>.self).deinitialize(count: eltCount)

  let numBytes = strideof(A) + (eltCount * strideof(B))

  ptrToA.deinitialize(count: 1).deallocate(
    bytes: numBytes, alignedTo: alignof(A))
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

func receiveMsg(flags: UInt16, state: UInt16, value: Int32) {}

func readMsg(msgBuf: UnsafeRawPointer, isFormat1: Bool) {
  if isFormat1 {
    receiveMsg(flags: msgBuf.load(UInt16.self),
      state: msgBuf.load(UInt16.self, atByteOffset: 2),
      value: msgBuf.load(Int32.self, atByteOffset: 4))
  }
  else {
    receiveMsg(flags: 0, state: 0, value: msgBuf.load(Int32.self))
  }
}
```

### Custom memory allocation

Note: The same allocated raw memory cannot be used both for this custom
memory allocation case and for the C buffer case above because the C
buffer requries that the allocated raw memory is always initialized to
the same type.

```swift
var freePtr: UnsafeMutableRawPointer? = nil

func allocate32() -> UnsafeMutableRawPointer {
  if let newPtr = freePtr {
    freePtr = nil
    return newPtr
  }
  return UnsafeMutableRawPointer(allocatingBytes: 4, alignedTo: 4)
}

func deallocate32(_ rawPtr: UnsafeMutableRawPointer) {
  if freePtr != nil {
    rawPtr.deallocate(bytes: 4, alignedTo: 4)
  }
  else {
    freePtr = rawPtr
  }
}

func createA(value: Int) -> UnsafeMutablePointer<A> {
  return allocate32().initialize(A.self, with: A(value: value))
}

func createB(value: Int) -> UnsafeMutablePointer<B> {
  return allocate32().initialize(B.self, with: B(value: value))
}

func deleteA(ptrToA: UnsafeMutablePointer<A>) {
  return deallocate32(ptrToA.deinitialize(count: 1))
}

func deleteB(ptrToB: UnsafeMutablePointer<B>) {
  return deallocate32(ptrToB.deinitialize(count: 1))
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
requires invoking `UnsafeRawPointer.cast(to: UnsafePointer<T>.Type)`, explicitly
spelling the destination type:

```swift
let p = UnsafeRawPointer(...)
let pT = p.cast(to: UnsafePointer<T>.self)
```

Just as with `unsafeBitCast`, although the destination of the cast can
usually be inferred, we want the developer to explicitly state the
intended destination type, both because type inferrence can be
surprising, and because it's important for code comprehension.

Inferred `UnsafePointer<T>` conversion will now be statically
prohibited. Instead, unsafe conversion will need to explictly cast
through a raw pointer:

```swift
let pT = UnsafePointer<T>(...)
let pU = UnsafeRawPointer(pT).cast(to: UnsafePointer<U>.self)
```

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

Consider two C functions that take const pointers:

```C
void takesConstTPtr(const T*);
void takesConstVoidPtr(const void*);
```

Which will be imported with immutable pointer argument types:

```swift
func takesConstTPtr(_: UnsafePointer<T>)
func takesConstVoidPtr(_: UnsafeRawPointer)
```

Mutable pointers can be passed implicitly to immutable pointers.

```swift
let umptr: UnsafeMutablePointer<T>
let mrawptr: UnsafeMutableRawPointer
takesConstTPtr(umptr)
takesConstVoidPtr(mrawptr)
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

Consider two C functions that take nonconst pointers:

```C
void takesTPtr(T*);
void takesVoidPtr(void*);
```

Which will be imported with mutable pointer argument types:

```swift
func takesTPtr(_: UnsafeMutablePointer<T>)
func takesVoidPtr(_: UnsafeMutableRawPointer)
```

Implicit inout conversion will continue to work:

```swift
var anyT = T(...)
takesTPtr(&anyT)
takesVoidPtr(&anyT)
```

`Array`/`String` conversion to mutable pointer is still not allowed.

### Bulk copies

The following API entry points support copying or moving values between unsafe pointers.

Given values of these types:

```swift
  let uPtr: UnsafePointer<T>
  let umPtr: UnsafeMutablePointer<T>
  let rawPtr: UnsafeRawPointer
  let mrawPtr: UnsafeMutableRawPointer
  let c: Int
```

#### `UnsafeRawPointer` to `UnsafeMutableRawPointer` raw copy (memcpy):

```swift
  mrawPtr.storeRaw(contiguous: T.self, from: rawPtr, count: c)
  mrawPtr.storeRawBackward(contiguous: T.self, from: rawPtr, count: c)
```

#### `UnsafePointer<T>` to `UnsafeMutableRawPointer`:

A raw copy from typed to raw memory can also be done by calling `storeRaw`
and `storeRawBackward`, exactly as shown above. Implicit argument conversion
from `UnsafePointer<T>` to `UnsafeRawPointer` makes this seamless.

Additionally, raw memory can be bulk initialized from typed memory:

```swift
  mraw.initialize(from: uPtr, count: c)
  mraw.initializeBackward(from: uPtr, count: c)
```

#### `UnsafeMutablePointer<T>` to `UnsafeMutableRawPointer`:

Because `UnsafeMutablePointer<T>` arguments are implicitly converted
to `UnsafePointer<T>`, the `initialize` and `initializeBackward` calls
above work seamlessly.

Additionally, a mutable typed pointer can be moved-from:

```swift
  mraw.moveInitialize(from: umPtr, count: c)
  mraw.moveInitializeBackward(from: umPtr, count: c)
```

#### `UnsafeRawPointer` to `UnsafeMutablePointer<T>`:

No bulk conversion is currently supported from raw to typed memory.

#### `UnsafePointer<T>` to `UnsafeMutablePointer<T>`:

Copying between typed memory is still supported via bulk assignment
(the naming style is updated for consistency):

```swift
  ump.assign(from: up, count: c)
  ump.assignBackward(from: up, count: c)
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
      .cast(to: UnsafePointer<CChar>)
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
such a common use case. To avoid excessive UnsafePointer conversion
and ease migration to the UnsafeRawPointer model, helpers will be
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
`UnsafePointer<UInt8>` is safe without sacrificing efficieny. The
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

### Full UnsafeRawPointer API

Most of the API was already presented above. For the sake of having it
in one place, a list of the expected UnsafeMutableRawPointer members
is shown below:

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

  init(allocatingBytes: Int, alignedTo: Int)
  init<T>(allocatingCapacity: Int, of: T.Type)
  deallocate(bytes: Int, alignedTo: Int)
  deallocate<T>(capacity: Int, of: T.Type)

  func cast<T>(to: UnsafeMutablePointer<T>.Type) -> UnsafeMutablePointer<T>
  func cast<T>(to: UnsafePointer<T>.Type) -> UnsafePointer<T>

  func initialize<T>(_: T.Type, with: T, count: Int = 1)
    -> UnsafeMutablePointer<T>
  func initialize<T>(toContiguous: T.Type, atIndex: Int, with: T)
    -> UnsafeMutablePointer<T>

  func initialize<T>(from: UnsafePointer<T>, count: Int)
    -> UnsafeMutablePointer<T>
  func initializeBackward<T>(from: UnsafePointer<T>, count: Int)
    -> UnsafeMutablePointer<T>

  // The `move` APIs deinitialize the memory at `from`.
  func moveInitialize<T>(from: UnsafePointer<T>, count: Int)
    -> UnsafeMutablePointer<T>
  func moveInitializeBackward<T>(from: UnsafePointer<T>, count: Int)
    -> UnsafeMutablePointer<T>

  func load<T>(_: T.Type) -> T
  func load<T>(_: T.Type, atByteOffset: Int) -> T
  func load<T>(fromContiguous: T.Type, atIndex: Int) -> T

  // storeRaw performs bytewise writes, but proper alignment for `T` is still
  // required.
  // T must be a trivial type.
  func storeRaw<T>(_: T.Type, with: T)
  func storeRaw<T>(toContiguous: T.Type, atIndex: Int, with: T)
  func storeRaw<T>(contiguous: T.Type, from: UnsafeRawPointer, count: Int)
  func storeRawBackward<T>(
    contiguous: T.Type, from: UnsafeRawPointer, count: Int)

  func distance(to: UnsafeRawPointer) -> Int
  func advanced(by: Int) -> UnsafeRawPointer
}
```

The remaining relevant `UnsafeMutablePointer` members are:

```swift
extension UnsafeMutablePointer<Pointee> {
  init(mutating from: UnsafePointer<Pointee>)

  func deinitialize(count: Int = 1) -> UnsafeMutableRawPointer

  // --- bulk assignment is safe, but conventions change ---
  func assign(from source: UnsafePointer<Pointee>, count: Int)
  func assignBackward(from source: UnsafePointer<Pointee>, count: Int)

  // Warning: This leaves `self` memory in a deinitialized state.
  func move() -> Pointee

  // Warning: This leaves `source` memory in a deinitialized state.
  func moveAssign(from source: UnsafeMutablePointer<Pointee>, count: Int)

  // Typed initialization.
  // - Warning: undefined if the underlying raw memory is ever cast to an
  //   unrelated Pointee type and dereferenced.
  //
  // Only single-element initialization is available, which supports a
  // typed buffer of elements that are individually initialized.
  func initialize(with newValue: Pointee, count: Int = 1)
}
```

```swift
extension UnsafePointer<Pointee> {
  // Inferred initialization from mutable to immutable.
  init(_ from: UnsafeMutablePointer<Pointee>)
}
```

The removed `UnsafeMutablePointer` members are:

```swift
extension UnsafeMutablePointer<Pointee> {
  // Unsafe pointer conversions are removed.
  init<U>(_ from : UnsafeMutablePointer<U>)
  init?<U>(_ from : UnsafeMutablePointer<U>?)
  init<U>(_ from : UnsafePointer<U>)
  init?<U>(_ from : UnsafePointer<U>?)

  // Unsafe bulk initialization is removed.
  func moveInitializeFrom(_ source: ${Self}, count: Int)
  func moveInitializeBackwardFrom(_ source: ${Self}, count: Int)
  func initializeFrom(_ source: ${Self}, count: Int)
  func initializeFrom<C : Collection>(_ source: C)
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
restriction by using `UnsafeRawPointer($0).cast(to:
UnsafePointer<Pointee>.self)`, and/or adding a `mutating` label to
their initializer.

The API for allocating and initializing unsafe pointer changes:

```swift
let p = UnsafeMutablePointer<T>(allocatingCapacity: num)
p.initialize(with: T())
```

becomes

```swift
let p = UnsafeMutableRawPointer(allocatingCapacity: num, of: T.self).initialize(with: T())
```

Deallocation similarly changes from:

```swift
p.deinitialize(num)
p.deallocateCapacity(num)
```

to

```swift
p.deinitialize(num).deallocate(capacity: num, of: T.self)
```

The [unsafeptr_convert branch][2] contains an implementation of a
simlar, previous design.

[2]:https://github.com/atrick/swift/commits/unsafeptr_convert

### Swift code migration

All occurrences of the type `Unsafe[Mutable]Pointer<Void>` will be
automatically replaced with `Unsafe[Mutable]RawPointer`.

Initialization of the form `Unsafe[Mutable]Pointer`(p) will
automatically be replaced by `Unsafe[Mutable]RawPointer(p)` whenever
the type checker determines that is the expression's expected type.

Conversion between incompatible `Unsafe[Mutable]Pointer` values will
produce a diagnostic explaining that
`Unsafe[Mutable]RawPointer($0).cast(to: Unsafe[Mutable]Pointer<T>.self)`
syntax is required for unsafe conversion.

`initializeFrom(_: UnsafePointer<Pointee>, count: Int)`,
`initializeBackwardFrom(_: UnsafePointer<Pointee>, count: Int)`,
`assignFrom(_ source: Unsafe[Mutable]Pointer<Pointee>, count: Int)`,
`moveAssignFrom(_ source: Unsafe[Mutable]Pointer<Pointee>, count: Int)`

will be automatically converted to:

`initialize(from: UnsafePointer<Pointee>, count: Int)`,
`initializeBackward(from: UnsafePointer<Pointee>, count: Int)`,
`assign(from source: Unsafe[Mutable]Pointer<Pointee>, count: Int)`,
`moveAssign(from source: Unsafe[Mutable]Pointer<Pointee>, count: Int)`

### Standard library changes

Disallowing inferred `UnsafePointer` conversion requires some standard
library code to use an explicit .cast(to:
UnsafePointer<Pointee>.self)` whenever the conversion may violate
strict aliasing.

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
should be truly opaque; that is, nondereferenceable and not involved
in address computation.

The `StringCore` implementation does a considerable amount of casting
between different views of the `String` storage. For interoperability
and optimization, String buffers frequently need to be cast to and
from `CChar`. This will be made safe by ensuring that the string
buffer is always written as a raw pointer.

`CoreAudio` utilities now use `Unsafe[Mutable]RawPointer`.


## Implementation status

An [unsafeptr_convert branch][2] has the first prototype, named
`UnsafeBytePointer`, and includes stdlib and type system changes
listed below. A [rawptr branch][3] has the latest proposed
implementation of `UnsafeRawPointer`. I am currently updating the
rawptr branch to include the following changes.

There are a several things going on here in order to make it possible
to build the standard library with the changes:

- A new `UnsafeRawPointer` type is defined.

- The type system imports `void*` as UnsafeRawPointer.

- The type system handles implicit conversions to UnsafeRawPointer.

- `UnsafeRawPointer` replaces both `UnsafePointer<Void>` and
  `UnsafeMutablePointer<Void>` (Recent feedback suggestes that
  `UnsafeMutablePointer` should also be introduced).

- The standard library was relying on inferred UnsafePointer
  conversion in over 100 places. Most of these conversions now either
  take an explicit label, such as `mutating` or have been rewritten.

- Several places in the standard library that were playing loosely
  with strict aliasing or doing bytewise pointer arithmetic now use
  UnsafeRawPointer instead.

- Explicit labeled `Unsafe[Mutable]Pointer` initializers are added.

- The inferred `Unsafe[Mutable]Pointer` conversion is removed.

Remaining work:

- A name mangled abbreviation needs to be created for UnsafeRawPointer.

- The StringAPI tests should probably be rewritten with
  `UnsafeRawPointer`.

- The NSStringAPI utilities and tests may need to be ported to
  `UnsafeRawPointer`

- The CoreAudio utilities and tests may need to be ported to
  `UnsafeRawPointer`.

[3]:https://github.com/atrick/swift/commits/rawptr

## Future improvements and planned additive API

`UnsafeRawPointer` should eventually support unaligned memory access. I
believe that we will eventually have a modifier that allows "packed"
struct members. At that time we may also want to add a "packed" flag to
`UnsafeRawPointer`'s `load` and `initialize` methods.

## Variations under consideration

### Freestanding `allocate`/`deallocate`

I considered defining allocation and deallocation global functions
that operation on UnsafeMutableRawPointer. `allocate` is not logically
an initializer because it is not a conversion and its main function is
not simply the construction of an `UnsafeRawPointer`:


```swift
func allocate<T>(capacity: Int, of: T.Type) -> UnsafeMutableRawPointer

func deallocate<T>(_: UnsafeMutableRawPointer, capacity: Int, of: T.Type) {}

let rawPtr = allocate(capacity: 1, of: A.self)

deallocate(rawPtr, capacity: 1, of: A.self)
```

The allocate/initialize idiom would be:

```swift
let ptrToA = allocate(capacity: 1, of: A.self).initialize(A.self, with: A())

deallocate(ptrToA.deinitialize(count: 1))
```

The main reason this was not done was to avoid introducing these names
into the global namespace.

A reasonable compromise would be a static method on allocation, and an
instance method on deallocation:

```swift
let ptrA = UnsafeMutableRawPointer.allocate(capacity: 1, of: A.self)
  .initialize(A.self, with: A())

ptrA.deinitialize(count: 1).deallocate(capacity: 1, of: A.self)
```

### Conversion via initializer instead of `cast<T>(to: UnsafePointer<T>)`

This proposal calls for unsafe pointer type conversion to be performed
via an `UnsafeRawPointer.cast(to:)` method as in:

```swift
rawptr.cast(to: UnsafePointer<A>.self)
```

However, conversions are customarily done via an initializer, such as:

```swift
UnsafePointer(rawptr, to: A.self)
```

Conversion via initialization is generally a good convention, but
there are reasons not to use an initializer in this case. Conversion
via initializer indicates a normal, expected operation on the type
that is safe or at least checked. (e.g. integer initialization may
narrow, but traps on truncation). UnsafePointer is already "unsafe" in
the sense that it's lifetime is not automatically managed, but its
initializers should not introduce a new dimension of unsafety. Pointer
type conversion can easily lead to undefined behavior, and is beyond
the normal concerns of `UnsafePointer` users.

In order to convert between incompatible pointer types, the user
should be forced to cast through `UnsafeRawPointer`. This signifies
that the operation is recasting raw memory into a different type.

The only way to force users to explicitly cast through
`UnsafeRawPointer` is to introduce a conversion function:

```swift
func takesUnsafePtr(_: UnsafePointer<U>)

let p = UnsafePointer<T>(...)
takesUnsafePtr(UnsafeRawPointer(p).cast(to: UnsafePointer<U>.self))
```

A common case involves converting return values back from `void*` C
functions. With an initializer, many existing conversions in this form:

```swift
let voidptr = c_function()
let typedptr = UnsafePointer<T>(voidp)
```

Would need to be migrated to this form:

```swift
let voidptr = c_function()
let typedptr = UnsafePointer(voidp, to: T.self)
```

This source transformation appears to be inane. It doesn't obviously
convey more information.

In this case, the initializer does not provide any benefit in terms of
brevity, and the `cast(to:)` API makes the reason for the source change
more clear:

```swift
let voidptr = c_function()
let typedptr = voidptr.cast(to: UnsafePointer<T>.self)
```

### `moveInitialize` should be more elegant

This proposal keeps the existing `moveInitialize` API but moves it
into the `UnsafeMutableRawPointer` type. To be complete, the API
should now return a tuple:

```swift
  func moveInitialize<T>(from: UnsafePointer<T>, count: Int)
    -> (UnsafeMutableRawPointer, UnsafeMutablePointer<T>)
  func moveInitializeBackward<T>(from: UnsafePointer<T>, count: Int)
    -> (UnsafeMutableRawPointer, UnsafeMutablePointer<T>)
```

However, this would make for an extremely awkward interface. Instead,
I've chosen to document that the source pointer should typically be
cast down to a raw pointer before reinitializing the memory.

The `move()` and `moveAssignFrom` methods have a simlar problem.

## Alternatives previously considered

### unsafeBitCast workaround

In some cases, developers can safely reinterpret values to achieve the
same effect as type punning:

```swift
let ptrI32 = UnsafeMutablePointer<Int32>(allocatingCapacity: 1)
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
type punning (a _RawByte could be loaded but it's value cannot be
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
as an "opaque" untyped pointer. Converting to UnsafeRawPointer would
be necesarry to perform pointer arithmetic or to conservatively handle
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
