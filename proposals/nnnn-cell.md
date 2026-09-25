# Cell, ConstCell, and Volatile

* Proposal: [SE-NNNN](NNNN-cell.md)
* Authors: [Alejandro Alonso](https://github.com/azoy), [Doug Gregor](https://github.com/douggregor)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN)
* Previous Revision: [AliasedSpan and AliasedRef](https://github.com/DougGregor/swift-evolution/blob/aliased-spans/proposals/nnnn-aliased-spans.md)
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

Introduces a family of `Cell` types that provide looser requirements around
exclusivity, making them suitable for shared memory, synchronization primitives,
concurrent data structures, and interoperability with other languages.

## Motivation

The `Span` / `Ref` family of types, including `Span`
([SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md)),
`MutableSpan` ([SE-0467](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md)),
`OutputSpan` ([SE-0485](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md)),
and `Ref` ([SE-0519](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md)),
as well as their `Raw.*Span` counterparts, provide memory-safe access to
contiguous memory. Span and ref types provide lifetime safety, ensuring that the
memory they reference isn't freed while the instance is still accessible, as
well as bounds safety for spans because all indexed accesses ensure that the
indices are within bounds.

However, they can only reference memory that is non-aliased by other parts of
the process or operating system. This is due to types in Swift not having the
capability of interior mutability (besides classes).

### Spans and the Law of Exclusivity

The `Span` and `Ref` family of types depends on Swift's so-called [Law of Exclusivity](https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md#the-law-of-exclusivity), which states that if there are two accesses to the same value in memory, both of them must be reads. Therefore, any access that can change the value in memory is known to be the only place that will modify that memory, which unlocks important optimization opportunities while still maintaining memory safety for the values in the memory the reference. Fundamentally, maintaining the Law of Exclusivity requires reasoning about all potential *aliases* of a particular location in memory, i.e., places where there is a reference (or pointer) to that memory that could be used to access the value stored there. Swift maintains the Law of Exclusivity through a mix of language and runtime features. Non-copyable types (like `UniqueArray`, [SE-527](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md)) establish unique ownership, whereas non-escapable types (like the `Span` family of types) limit the scope in which data can be accessed, all at compile time. Copy-on-write collections (such as `Array`) and dynamic exclusivity checking (e.g., for global variables) establish exclusivity at run-time for places where it isn't possible to reason about every potential alias. Most of this is invisible to the Swift developer, unless they encounter code that violates the Law of Exclusivity. For example, attempting to create two `MutableSpan` instances that reference into the same `Array`, or modify the `Array` while there is an actual `Span` referencing its storage, will produce a compile-time error about the "overlapping access" that violates exclusivity:

```swift
func f() {
  var array = [1, 2, 3, 4, 5]

  let data = array.span // note: conflicting access is here
  array.append(6) // error: overlapping accesses to 'array', but modification requires 
                  // exclusive access; consider copying to a local variable 
  print(data[0])
}
```

Scenarios involving runtime exclusivity checking are described in more detail in [SE-0176](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0176-enforce-exclusive-access-to-memory.md).

The `Span` and `Ref` dependency on the Law of Exclusivity manifests in its API surface. The `subscript` for `Span` uses a `borrow` accessor ([SE-0507](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0507-borrow-accessors.md)), which provides direct access to the value without requiring the caller to make a copy, which is only safe when the underlying value cannot change. Similarly, `MutableSpan` exclusively references its underlying memory, and it's `subscript` provides a `mutate` accessor to directly reference that memory (including modifing it). The choices here are important semantically, because they make it possible to support spans over non-copyable types, and also for performance, because they avoid the need for extraneous copies of the underlying data.

### Span without the Law of Exclusivity breaks memory safety

Using the `Span` types in places where we have lifetime safety but have not established the Law of Exclusivity can cause memory-safety problems. For example, consider the following code that introduces aliasing issues through `Span` by using unsafe pointers:

```swift
class MyClass {
  var counter = 0
  
  func doSomething(_ body: () -> Void) {
    body()
    counter += 1
  }
}

func aliasingSafetyProblem(buffer: UnsafeMutableBufferPointer<MyClass>) {
  let otherBuffer = buffer
  let span = unsafe buffer.span
  unsafe span[0].doSomething {        // call doesn't adjust reference count
    unsafe otherBuffer[0] = MyClass() // MyClass instance in the doSomething call could be freed here
  }
}
```

Much of the code is marked `unsafe` here, including deriving a span from an unsafe buffer, because the developer needs to reason about both the lifetime and exclusivity of the unsafe pointer. In the next selection, we explore places where it is possible to reason about lifetime but it is not possible or practical to reason about exclusivity.

### Lifetime safety of buffers is useful without the Law of Exclusivity

There are scenarios where the lifetime- and bounds-safety properties of spans are desirable, but it is impossible or impractical to ensure that the memory they reference obeys the Law of Exclusivity. One concrete example is shared memory, where the same region of memory is also accessible by another process or by some other hardware in the system (e.g., a GPU or network controller with direct memory access). One can build an abstraction to ensure that the shared memory's lifetime is correctly managed (e.g., with noncopyable types or classes), but the Law of Exclusivity can never be applied to such memory, because there are, fundamentally, aliases outside of the view of the program that cannot be reasoned about.

Interoperability with the C family of languages is another area where lifetime can be established through conventions, sometimes backed by static analysis. The vision for [optional strict memory safety in Swift](https://github.com/swiftlang/swift-evolution/blob/main/visions/memory-safety.md#expressing-memory-safe-interfaces-for-the-c-family-of-languages) outlines the use of C attributes to describe memory-safety properties for lifetimes and bounds to enable importing C(++) APIs using pointers as `Span`-based APIs, allowing them to be used safely from Swift. For example, a C++ API like the following

```c
class MyBuffer {
public:
  std::span<const double> getContents() const __attribute__((lifetimebound));
};
```

could have its method imported into Swift as:

```swift
func getContents() -> Span<Double>
```

The `lifetimebound` attribute indicates that the pointer inside the `std::span` will live as long as the `MyBuffer` instance is still alive and hasn't been changed (e.g., via a non-`const` method), which describes the fundamental lifetime safety property. However, it does *not* imply that there are no aliases for that storage that might modify the memory it references: ensuring the lack of aliases would require reasoning about all C and C++ code that might ever have access to that pointer, which is impractical.

For these cases, where we have lifetime information but cannot provide exclusivity, the only suitable types in the Swift standard library are the `Unsafe(Mutable)(Raw)BufferPointer` types. However, these types throw away all aspects of memory safety, so their use is generally discouraged.

### Synchronization Primitives and Concurrent Data Structures

A good example of safe shared memory are synchronization primitives like `Atomic`
and `Mutex`. The concept of static mutability breaks down concurrently because
multiple threads may need to mutate the same memory at the same time, while types
like these help synchronize their accesses to ensure data race safety. Having
methods like `Mutex.withLock` be `mutating` is impossible because there must
only be a single exclusive access to the `Mutex` but two or more threads may
be attempting to call this method at the same time. That's why methods like these
are `borrowing` to allow for shared access while internally ensuring that multiple
writes are not happening at the same time. In order to build such primitives,
these types need to be able to "mutate" their memory while only having shared
access to it. This is achievable through interior mutability.

Interior mutability is the notion of being to mutate memory while multiple
shared references to the same memory are being aliased. Under the Law of
Exclusivity, this is explicitly not supported due to the data racey nature that
this introduces in multithread contexts.

```swift
struct Mutex<Value: ~Copyable>: ~Copyable {
  var value: Value

  var lockImplementation: ...

  borrowing func withLock(...) {
    lockImplementation.lock()

    defer {
      lockImplementation.unlock()
    }

    // error: cannot pass immutable value as inout argument: 'self' is immutable
    try body(&value)
  }
}
```

Unlike a lot of interop scenarios where you simply have references or spans of
shared memory that you need to access, these primitives, and similarly concurrent
data structures, need to create storage that allows for interior mutability and
shared memory access.

## Proposed solution

We propose introducing three new types to the standard library to make working
on these types of issues easier, or in some cases, possible now.

### `Cell`

`Cell` is a thin generic wrapper over a type that grants access to a mutable
pointer to itself under a `borrowing` method. This makes it possible to implement
the `Mutex` example above like the following:

```swift
struct Mutex<Value: ~Copyable>: ~Copyable {
  var value: Cell<Value>

  var lockImplementation: ...

  borrowing func withLock(...) {
    lockImplementation.lock()

    defer {
      lockImplementation.unlock()
    }

    try value.withUnsafeMutablePointer {
      try body(&$0.pointee)
    }
  }
}
```

The layout of `Cell` is exactly the same as type it's wrapping and it introduces
no overhead in terms of layout or performance. 

Having this new `Cell` type, we can create compositions that solve the C-interop
use cases of needing a reference or buffer type that has the lifetime guarantees,
but doesn't have the exclusivity guarantees. `Ref<Cell<T>>` and `Span<Cell<T>>`
allow you to use the de facto lifetime bound reference and buffer type in Swift
while also disabling exclusivity guarantees on a per element basis.

```swift
struct Person {
  var age: Int
}

func foo(people: Span<Cell<Person>>) {
  people[0].value.age += 1
}
```

Notice how we're now able to mutate the underlying `Person` struct within a
read-only `Span` instance with `Cell`.

`Cell` implements a `value` property for `Copyable` types using a `get`/`set` to
prevent exclusivity issues by performing a copy out/copy in.

### `ConstCell`

In addition to `Cell`, there's a `ConstCell` type that provides the same guarantees
as `Cell`, but disallow writes from Swift. The memory may still be altered from
outside of Swift.

```swift
func foo(people: Span<ConstCell<Person>>) {
  people[0].value.age += 1 // error: 'value' is get-only
}
```

### `Volatile`

Finally, we propose `Volatile` which accesses an underlying value through
[volatile pointer loads and stores](https://llvm.org/docs/LangRef.html#volatile),
similar to `volatile` in C and C++.

While related to the aliasing issues mentioned above, `Volatile` serves to solve
other problems with accessing shared memory in Swift. In some areas, like
memory mapped IO (MMIO), it is critical that the compiler not eliminate certain
pointer reads and writes as well as reordering them. This memory may be shared
with processes outside of the one currently executing or may be directly altered
by the hardware itself. 

```swift
let controlRegister = UnsafePointer<Volatile<Bool>>(bitPattern: 0x40000100)!
print(controlRegister.pointee.value) // true
print(controlRegister.pointee.value) // maybe true, maybe false
```

Notably, writing to a `Volatile` value requires exclusive access (because
`.value` requires a `mutating set`) contrary to the `Cell` types proposed above.
If you need to be able to write to one of these values, you can compose the types
like `Cell<Volatile<T>>` to be able to write into the `Volatile`:

```swift
func write(to x: borrowing Cell<Volatile<Bool>>) -> Volatile<Bool> {
  // `Cell.value` requires `T` to be `Copyable`,
  // `Volatile` is `~Copyable`.
  x.replace(with: Volatile(false))
}
```

## Detailed design

### `Cell`

```swift
public struct Cell<Value: ~Copyable>: ~Copyable {
  public init(_ initialValue: consuming Value)

  public func withUnsafeMutablePointer<Result: ~Copyable, E>(
    _ body: (UnsafeMutablePointer<Value>) throws(E) -> Result
  ) throws(E) -> Result

  @discardableResult
  public func replace(with newValue: consuming Value) -> Value
}

extension Cell: Sendable where Value: Sendable & FullyInhabited {}

extension Cell where Value: ~Copyable {
  @unsafe
  public var borrow: Value {
    borrow
    nonmutating mutate
  }
}

extension Cell where Value: Copyable {
  public var value: Value {
    get
    nonmutating set
  }
}
```

`Cell` is `Sendable` when `Value` is both `Sendable` and `FullyInhabited`. The
nature of non-synchronized shared memory is inherently prone to data race safety
issues, but if a type is considered `FullyInhabited`, then any such race will
allow the type to still be considered fully initialized. Races for suhc types
are not considered undefined behavior.

### `ConstCell`

```swift
public struct ConstCell<Value: ~Copyable>: ~Copyable {
  public init(_ initialValue: consuming Value)

  public func withUnsafePointer<Result: ~Copyable, E>(
    _ body: (UnsafePointer<Value>) throws(E) -> Result
  ) throws(E) -> Result
}

extension ConstCell: Sendable where Value: Sendable & FullyInhabited {}

extension ConstCell where Value: ~Copyable {
  @unsafe
  public var borrow: Value {
    borrow
  }
}

extension ConstCell where Value: Copyable {
  public var value: Value {
    get
  }
}
```

### `Volatile`

```swift
public struct Volatile<Value: ~Copyable>: ~Copyable {
  public init(_ initialValue: consuming Value)

  public func withUnsafeMutablePointer<Result: ~Copyable, E>(
    _ body: (UnsafeMutablePointer<Value>) throws(E) -> Result
  ) throws(E) -> Result

  @discardableResult
  public func replace(with newValue: consuming Value) -> Value
}

extension Volatile where Value: BitwiseCopyable {
  public var value: Value {
    get
    set
  }
}
```

It's important to note that `.value` requires a `BitwiseCopyable` conformance
rather than the usual `Copyable` one seen in the cell types. The volatile pointer
reads and stores operate directly on the bitwise representation of the type in
memory. A non-trivial type like `String` that requires a `swift_retain` for its
copy operation doesn't translate to volatile semantics for example.

### Conversions

```swift
extension MutableRef where Value: ~Copyable {
  public consuming func cell() -> Ref<Cell<Value>>
}

extension Span where Element: ~Copyable {
  public var constCell: Span<ConstCell<Element>> {
    get
  }

  @unsafe
  public func cells() -> Span<Cell<Element>>
}

extension MutableSpan where Element: ~Copyable {
  public consuming func cells() -> Span<Cell<Element>>
}
```

Going from `MutableRef<T>` -> `Ref<Cell<T>>` is safe, because from the Swift side
you've enforced that you had exclusive access to the `T` before downgrading it
to a shared access pointing to shared memory. The same argument can be applied
to the `MutableSpan<T>` -> `Span<Cell<T>>` conversion.

The `Span<T>` -> `Span<ConstCell<T>>` is safe, because from Swift's perspective
the underlying memory being pointed to is still read-only even though the memory
may be shared to other parts of the process not written in Swift or other parts
of the operating system that will mutate the memory.

`Span<T>` -> `Span<Cell<T>>` is a fundamentally unsafe operation. This
conversion is taking a buffer of non-shared memory and then treating it like
shared memory that is directly mutatable from Swift.

## Source compatibility

This proposal introduces new types into the Swift standard library, but
otherwise has no effect on source compatibility.

## ABI compatibility

This proposal introduces new types into the Swift standard library, which adds
to the ABI, but otherwise has no effect on ABI compatibility.

## Implications on adoption

The new `Cell` family of types is intended to be adopted in places where
it is impossible or impractical to ensure non-aliasing, such as the
shared-memory, concurrent data structures, and C-interoperability use cases. It
is possible that these types will propagate further in the Swift ecosystem than
intended, for example because something that is implemented on top of a C library
provides `Span<Cell<T>>`-based APIs rather than `Span<T>`-based APIs for convenience
(or safety). If this happens, it could lead to confusion about which types
should be used, and potentially undermine Swift performance if `Cell<T>` is
used in places where it shouldn't be.

## Future directions

### C(++) interoperability

As noted in the [strict memory safety vision](https://github.com/swiftlang/swift-evolution/blob/main/visions/memory-safety.md#expressing-memory-safe-interfaces-for-the-c-family-of-languages), a span of cells could be used to represent C pointers if we know about the bounds and lifetime of those pointers. For example, in this C++ API:

```c++
class MyBuffer {
public:
  std::span<double> getContents() __attribute__((lifetimebound));
};
```

the `std::span` provides a pointer and its bounds, and the `lifetimebound` attribute specifies that the lifetime of the resulting pointer is bound to the `*this` instance. This is sufficient information to import that C++ method with the following signature in Swift:

```swift
func getContents() -> Span<Cell<Double>>
```

The actual C and C++ annotations, as well as their mapping into Swift, are out of the scope of this proposal.

## Alternatives considered

### Don't solve the aliasing problem

Shared memory is somewhat of a niche concern, and it's generally our policy that C interoperability not dictate the direction of the Swift language. We could choose for Swift not to solve the aliasing problem at all, and require any code interacting with shared memory or C pointers to be unsafe. Doing so would limit the places where Swift is applicable in systems programming, as well as undermining the ability to safely interoperate with the C family of languages as expressed in the [strict memory safety vision](https://github.com/swiftlang/swift-evolution/blob/main/visions/memory-safety.md#expressing-memory-safe-interfaces-for-the-c-family-of-languages).

### Name this type `Aliased<T>`

To more closely align these types and this proposal with solving the exclusivity
aliasing issue, we could name `Cell<T>` to `Aliased<T>` (or `Alias<T>`) to make
it more understandable about what specific problem it is solving. However, we
don't feel that this name represents the use case of creating shared memory
storage like in the `Mutex` example:

```swift
struct Mutex<Value: ~Copyable>: ~Copyable {
  var value: Aliased<Value>
}
```

While it could work, it seems a bit odd and out of place.

[The `Cell` name comes from the Rust terminology for this type.](https://doc.rust-lang.org/std/cell/struct.Cell.html)

### `Aliased*Span` and `Aliased*Ref`

A previous iteration of this proposal introduced a family of `Aliased*Span` and
`Aliased*Ref` types mimiking the behavior that `Span<Cell<T>>` accomplishes. We
decided against that direction due to large API surface that it adds and introduces
both implmentation complexity (keeping `Span` and `AliasedSpan` API surface the
same) and developer complexity (when should I use `Span` vs. `AliasedSpan`?).
These aliased span and ref types also wouldn't be sufficient enough to be able
to implement `Atomic` or `Mutex` because those types need to own their storage,
but the aliased span/ref approach wouldn't allow you to own such memory.

### Put these types in a different module

Arguably, these types are for niche low-level and interop purposes, so stuffing
them in the default `Swift` namespace isn't really ideal for autocomplete purposes.
`Cell` is also a very general name that could be applied to many domains in software.
We could put this in a different module, but we feel there isn't a proper module
already in the toolchain best suited for these types and introducing a new
module for just these is a bit overkill. While it would be ideal if Swift had
proper namespaces or submodules, we don't currently have such features to land
these types under.

### `read()` and `write(_:)` functions on `Volatile`

An alternative to `Volatile.value` with its getter and setter are explicit `read()`
and `write()` functions. There is some prior art here with [swift-mmio](https://github.com/apple/swift-mmio)
providing a `Register<T>` type which is equivalent to `UnsafePointer<Volatile<T>>`
which has a `read()` and `write(_:)`. Given the precedent with `UniqueBox` and the
proposed `Cell` types as well, we thought continuing with this `.value` trend
would be more consistent.

## Acknowledgments

Geoff Garen identified the core aliasing problem addressed by the cell
types presented here, and noted the memory safety issues it introduces for Swift.
Gábor Horváth comprehensively explored what imposing the Law of Exclusivity
would mean for the C family of languages, which directly informed this design
and the safe interoperability with C that it enables. Steve Canon helped design
the cell types and provided valuable feedback on this proposal.
