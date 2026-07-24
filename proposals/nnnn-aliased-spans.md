# Aliased Span types

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

Introduces a family of `Aliased*Span` types that provide the memory safety guarantees of the `Span` family of types, but with looser requirements around exclusivity, making them suitable for shared memory and interoperability with other languages.

## Motivation

The `Span` family of types, including `Span` ([SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md)), `MutableSpan` ([SE-0467](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md)), `OutputSpan` ([SE-0485](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md)), as well as their `Raw.*Span` counterparts, provide memory-safe access to contiguous memory. Span types provide lifetime safety, ensuring that the memory they reference isn't freed while the span instance is still accessible, as well as bounds safety because all indexed accesses ensure that the indices are within bounds.

### Spans and the Law of Exclusivity

The `Span` family of types depends on Swift's so-called [Law of Exclusivity](https://github.com/swiftlang/swift/blob/main/docs/OwnershipManifesto.md#the-law-of-exclusivity), which states that if there are two accesses to the same value in memory, both of them must be reads. Therefore, any access that can change the value in memory is known to be the only place that will modify that memory, which unlocks important optimization opportunities while still maintaining memory safety for the values in the memory the reference. Fundamentally, maintaining the Law of Exclusivity requires reasoning about all potential *aliases* of a particular location in memory, i.e., places where there is a reference (or pointer) to that memory that could be used to access the value stored there. Swift maintains the Law of Exclusivity through a mix of language and runtime features. Non-copyable types (like `UniqueArray`, [SE-527](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md)) establish unique ownership, whereas non-escapable types (like the `Span` family of types) limit the scope in which data can be accessed, all at compile time. Copy-on-write collections (such as `Array`) and dynamic exclusivity checking (e.g., for global variables) establish exclusivity at run-time for places where it isn't possible to reason about every potential alias. Most of this is invisible to the Swift developer, unless they encounter code that violates the Law of Exclusivity. For example, attempting to create two `MutableSpan` instances that reference into the same `Array`, or modify the `Array` while there is an actual `Span` referencing its storage, will produce a compile-time error about the "overlapping access" that violates exclusivity:

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

The `Span` dependency on the Law of Exclusivity manifests in its API surface. The `subscript` for `Span` uses a `borrow` accessor ([SE-0507](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0507-borrow-accessors.md)), which provides direct access to the value without requiring the caller to make a copy, which is only safe when the underlying value cannot change. Similarly, `MutableSpan` exclusively references its underlying memory, and it's `subscript` provides a `mutate` accessor to directly reference that memory (including modifing it). The choices here are important semantically, because they make it possible to support spans over non-copyable types, and also for performance, because they avoid the need for extraneous copies of the underlying data.

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

## Proposed solution

This proposal introduces the `Aliased*Span` family of types, which are similar in shape to the `Span` family of types, providing lifetime and bounds safety. These types are:

* `AliasedSpan<Element>`: non-mutating access to a contiguous region of memory storing `Element` values
* `AliasedMutableSpan<Element>`: mutating access to a contiguous region of memory storing `Element` `
* `AliasedRawSpan`: non-mutating access to a contiguous region of untyped memory
* `AliasedMutableRawSpan`: mutating access to a contiguous region of untyped memory

The aliased span types are non-escapable, like their span counterparts. However, because the memory they reference is potentially aliased, they do not depend on the Law of Exclusivity. This causes API differences that are small but meaningful. For example:

* The `subscript` operations use `get` and `set` accessors, which require the client to copy out the value on access. This allows a separate alias to replace the value while the original access is ongoing, without making it a memory safety violation. In the previous `aliasingSafetyProblem` example, this means that the object produced by `self[0]` will be copied (i.e., its retain count is increased) for the duration of the call to `doSomething`, so it cannot be deallocated while the closure is executed.
* The aliased span types do not support non-copyable `Element` types, because we cannot do so on top of `get` and `set` accessors.
* The `AliasedMutable*Span` types are copyable: the non-aliased `Mutable*Span` types are non-copyable because that is needed to maintain exclusive access over the storage by preventing aliases. The `AliasedMutable*Span` types can be copied, because they already account for the possibility of aliases.

There is a full set of conversion operations between the various aliased span types and their non-aliased counterparts. It is safe to create an aliased span from its non-aliased counterparts, because the aliased spans make fewer assumptions, so long as the original span cannot be used in a manner that can be undermined by the derived aliased spans. For example, the following API is safe because the underlying storage is already guaranteed not to be mutated by anyone:

```swift
extension Span where Element: Copyable {
  // Retrieve an aliased span referencing the same storage.
  var aliased: AliasedSpan<Element> { get }
}
```

With mutable spans, we consume the `MutableSpan` to produce the `AliasedMutableSpan`:

```swift
extension MutableSpan where Element: Copyable {
  // Retrieve an aliased mutable span from this mutable span.
  consuming func asAliased() -> AliasedMutableSpan<Element> { }
}
```

this ensures that one cannot try to access the original `MutableSpan` (which assumes exclusivity) while there might be any aliased mutable spans referencing the same storage.

The conversion in the other direction, which produces a span from an aliased span, is fundamentally unsafe, because it requires one to establish that no other aliases exist for the storage. This proposal provides those conversion APIs, but explicitly marks them as `@unsafe`.

## Detailed design

### `AliasedSpan`

`AliasedSpan` provides access to a contiguous buffer of type `Element`. While the `AliasedSpan` type itself cannot change the contents of the buffer, it is possible that other code also has a reference to that memory and can make changes there. The majority of the API mirrors `Span` itself:

```swift
struct AliasedSpan<Element>: ~Escapable, Copyable, BitwiseCopyable {
  @lifetime(immortal)
  init()
    
  var count: Int { get }
  var isEmpty: Bool { get }

  typealias Index = Int
  var indices: Range<Index> { get }
  
  @lifetime(copy self)
  func extracting(_ bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_ bounds: some RangeExpression<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: ClosedRange<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_: UnboundedRange) -> Self
    
  @lifetime(copy self)
  func extracting(first maxLength: Int) -> Self
  
  @lifetime(copy self)
  func extracting(droppingLast k: Int) -> Self

  @lifetime(copy self)
  func extracting(last maxLength: Int) -> Self

  @lifetime(copy self)
  func extracting(droppingFirst k: Int) -> Self

  @safe
  func withUnsafeBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
    
  @safe
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result where Element: BitwiseCopyable
    
  func isIdentical(to other: Self) -> Bool
  func isTriviallyIdentical(to other: Self) -> Bool
  func indices(of other: borrowing Self) -> Range<Index>?
}

extension AliasedSpan: Sendable where Element: Sendable {}
```

As noted in the Proposed Solution section, the subscripts for `AliasedSpan` use `get` accessors rather than `borrow` accessors to force the caller to copy the result.

```swift
extension AliasedSpan {
  subscript(_ position: Index) -> Element { get }
  subscript(unchecked position: Index) -> Element { get }
}
```

`AliasedSpan` conforms to the `Iterable` protocol. Note that iteration over an `AliasedSpan` is necessarily less efficient than the corresponding `Span`, because the underlying buffer could be aliased and, therefore, mutated during iteration. Therefore, the iterator will get copies of the elements during iteration, and vend a `Span` into those copied elements, much like an `Iterable` conformance for an arbitrary `Sequence`.

```swift 
extension AliasedSpan: Iterable {
  typealias Failure = Never
  var underestimatedCount: Int { get }

  @lifetime(borrow self)
  func makeBorrowingIterator() -> BorrowingIterator
}
```

APIs that involve byte-level access using `AliasedRawSpan` (in place of `RawSpan` for `Span`), but are otherwise unchanged:

```swift
extension AliasedSpan where Element: ConvertibleFromBytes {
  @lifetime(copy bytes)
  init(viewing bytes: AliasedRawSpan)
}

extension AliasedSpan where Element: ConvertibleToBytes {
  var bytes: AliasedRawSpan { get }
}
```

### `AliasedMutableSpan`

The `AliasedMutableSpan` type is the counterpart to `MutableSpan`, allowing mutating of the contents of the buffer it references. The primary difference from `MutableSpan` is that `AliasedMutableSpan` is `Copyable`. This means that a lot of the API surface, while it has roughly the same shape as `MutableSpan`, no longer needs to be consuming.

```swift
struct AliasedMutableSpan<Element>: ~Escapable, Copyable, BitwiseCopyable {
  @lifetime(immortal)
  init()
    
  var count: Int { get }
  var isEmpty: Bool { get }

  typealias Index = Int
  var indices: Range<Index> { get }

  /// Retrieving an aliased span from a mutable span is a safe operation,
  /// because both assume they can alias the underlying storage.
  @lifetime(self copy)
  var aliased: AliasedSpan<Element> { 
    @lifetime(copy self)
    get
  }
}
```

As noted in the Proposed Solution section, the `AliasedMutableSpan` subscript operation uses `get` and `set` accessors, forcing clients to copy the data in and out. Note that the setter is non-mutating, because it does not change the shape of the span, only the contents of the underlying buffer.

```swift
extension AliasedMutableSpan {
  subscript(_ position: Index) -> Element { 
    get 
    nonmutating set 
  }
  subscript(unchecked position: Index) -> Element {
    get
    nonmutating set
  }
}
```

Other element mutation APIs are similarly non-mutating:

```swift
extension AliasedMutableSpan {
  func swapAt(_ i: Index, _ j: Index)
  func swapAt(unchecked i: Index, unchecked j: Index)
  func update(repeating repeatedValue: consuming Element)
}
```

Unsafe accesses to the buffer mirror that of `MutableSpan`, except that none of them are mutating for the same reason:

```swift
extension AliasedMutableSpan {
  @safe
  func withUnsafeBufferPointer<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
  
  @safe
  func withUnsafeMutableBufferPointer<
    E: Error, Result: ~Copyable
  >(
    _ body: (UnsafeMutableBufferPointer<Element>) throws(E) -> Result
  ) throws(E) -> Result
}

extension AliasedMutableSpan where Element: BitwiseCopyable {}
  @safe
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result

  @safe
  mutating func withUnsafeMutableBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeMutableRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
}
```

Similarly for the `extracting` family of operations, which no longer need to be `mutating`:

```swift
extension AliasedMutableSpan {
  @lifetime(copy self)
  func extracting(_ bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_ bounds: some RangeExpression<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: ClosedRange<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_: UnboundedRange) -> Self
    
  @lifetime(copy self)
  func extracting(first maxLength: Int) -> Self
  
  @lifetime(copy self)
  func extracting(droppingLast k: Int) -> Self

  @lifetime(copy self)
  func extracting(last maxLength: Int) -> Self

  @lifetime(copy self)
  func extracting(droppingFirst k: Int) -> Self  
}
```

APIs involving byte-level access relate to `AliasedMutableRawSpan`. There is only a single `mutableBytes` version, because we don't need distinguish between `inout` and `consuming` the way we did with the non-copyable `MutableSpan`. All of the properties copy the `self` dependency, because it's fine to have multiple aliases of the same storage.

```swift
extension AliasedMutableSpan where Element: ConvertibleFromBytes & ConvertibleToBytes {
  /// Convert a raw span to a typed span.
  @lifetime(copy mutableBytes)
  init(mutableBytes: AliasedMutableRawSpan)
}

extension AliasedMutableSpan where Element: ConvertibleToBytes {
  var bytes: RawSpan {
    @lifetime(copy self)
    get
  }
}

extension AliasedMutableSpan where Element: ConvertibleToBytes & ConvertibleFromBytes {
  var mutableBytes: MutableRawSpan {
    @lifetime(copy self)
    get
  }
}
```

As with `AliasedSpan`, `AliasedMutableSpan` conforms to the `Iterable` protocol, but requires a buffer in the iterator to isolate the iteration from changes to the underlying buffer.

```swift
extension AliasedMutableSpan: Iterable {
  typealias Failure = Never
  var underestimatedCount: Int { get }

  @lifetime(borrow self)
  func makeBorrowingIterator() -> BorrowingIterator
}
```

### `AliasedRawSpan`

The `AliasedRawSpan` type has an API that is equivalent to `RawSpan`, but where the `Span` types in parameters and result types have been replaced with their corresponding `Aliased` versions.

```swift
struct AliasedRawSpan: ~Escapable, Copyable, BitwiseCopyable, Sendable {
  @lifetime(immortal)
  init()
  
  @lifetime(copy span)
  @unsafe init<Element>(unsafeElements span: AliasedSpan<Element>)
  
  @lifetime(copy span)
  init<Element: ConvertibleToBytes>(elements span: AliasedSpan<Element>)
  
  var byteCount: Int { get }
  var isEmpty: Bool { get }
  var byteOffsets: Range<Int> { get }

  subscript(_ byteOffset: Int) -> UInt8 { get }
  @unsafe subscript(unchecked byteOffset: Int) -> UInt8
  
  @lifetime(copy self)
  func extracting(_ bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_ bounds: some RangeExpression<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: ClosedRange<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_: UnboundedRange) -> Self
    
  @lifetime(copy self)
  func extracting(first maxLength: Int) -> Self
  
  @lifetime(copy self)
  func extracting(droppingLast k: Int) -> Self

  @lifetime(copy self)
  func extracting(last maxLength: Int) -> Self

  @lifetime(copy self)
  func extracting(droppingFirst k: Int) -> Self
  
  @safe
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result

  @unsafe
  func unsafeLoad<T>(
    fromByteOffset offset: Int = 0, as type: T.Type
  ) -> T

  @unsafe
  func unsafeLoad<T>(
    fromUncheckedByteOffset offset: Int, as type: T.Type
  ) -> T

  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromByteOffset offset: Int = 0, as type: T.Type
  ) -> T
  
  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromUncheckedByteOffset offset: Int, as type: T.Type
  ) -> T

  func load<T: ConvertibleFromBytes>(
    fromByteOffset offset: Int,
    as type: T.Type
  ) -> T
  
  func load<T: ConvertibleFromBytes & FixedWidthInteger>(
    fromByteOffset offset: Int,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) -> T

  func byteOffsets(of other: borrowing Self) -> Range<Int>?

  func isIdentical(to other: Self) -> Bool
  func isTriviallyIdentical(to other: Self) -> Bool
  func indices(of other: borrowing Self) -> Range<Index>?
}
```

The `Iterable` conformance requires bytes to be buffered, as with all of the aliased span conformances to `Iterable`:

```swift 
extension AliasedRawSpan: Iterable {
  typealias Failure = Never
  var underestimatedCount: Int { get }

  @lifetime(borrow self)
  func makeBorrowingIterator() -> BorrowingIterator
}
```

### `AliasedMutableRawSpan`

The `AliasedMutableRawSpan` type has an API that is similar to `MutableRawSpan`, but where the `Span` types in parameters and result types have been replaced with their corresponding `Aliased` versions. As with `AliasedMutableSpan`, `AliasedMutableRawSpan` is a copyable type (whereas `MutableRawSpan` is not), so there is not need for `mutating` or `consuming` on the operations in it.

```swift
struct AliasedMutableRawSpan: Copyable, ~Escapable, BitwiseCopyable {
  @lifetime(immortal)
  init()
  
  init<Element: ConvertibleFromBytes & ConvertibleToBytes>(
    elements: AliasedMutableSpan<Element>
  )
  
  @unsafe
  @lifetime(copy elements)
  init<Element>(
    unsafeElements elements: AliasedMutableSpan<Element>
  )
  
  var byteCount: Int { get }
  var isEmpty: Bool { get }
  var byteOffsets: Range<Int> { get }
  
  subscript(_ byteOffset: Int) -> UInt8 { 
    get 
    nonmutating set
  }
  @unsafe subscript(unchecked byteOffset: Int) -> UInt8 { 
    get 
    nonmutating set
  }
  
  @safe
  func withUnsafeBytes<E: Error, Result: ~Copyable>(
    _ body: (_ buffer: UnsafeRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
  
  @safe
  func withUnsafeMutableBytes<E: Error, Result: ~Copyable>(
    _ body: (UnsafeMutableRawBufferPointer) throws(E) -> Result
  ) throws(E) -> Result
  
  var bytes: AliasedRawSpan { get }

  @unsafe
  func unsafeLoad<T>(
    fromByteOffset offset: Int = 0, as type: T.Type
  ) -> T

  @unsafe
  func unsafeLoad<T>(
    fromUncheckedByteOffset offset: Int, as type: T.Type
  ) -> T

  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromByteOffset offset: Int = 0, as type: T.Type
  ) -> T
  
  @unsafe
  func unsafeLoadUnaligned<T: BitwiseCopyable>(
    fromUncheckedByteOffset offset: Int, as type: T.Type
  ) -> T

  func load<T: ConvertibleFromBytes>(
    fromByteOffset offset: Int,
    as type: T.Type
  ) -> T
  
  func load<T: ConvertibleFromBytes & FixedWidthInteger>(
    fromByteOffset offset: Int,
    as type: T.Type,
    _ byteOrder: ByteOrder
  ) -> T
  
  func storeBytes<T: BitwiseCopyable>(
    of value: T, toByteOffset offset: Int = 0, as type: T.Type
  )
  
  func storeBytes<T: BitwiseCopyable>(
    of value: T, toUncheckedByteOffset offset: Int, as type: T.Type
  )
  
  func storeBytes<T: ConvertibleToBytes & BitwiseCopyable>(
    of value: T, toByteOffset offset: Int, as type: T.Type
  )
  
  func storeBytes<
    T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  >(
    of value: T,
    toByteOffset offset: Int,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )
  
  func storeBytes<T: BitwiseCopyable>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )
  
  func storeBytes<T: ConvertibleToBytes & BitwiseCopyable>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )
  
  func storeBytes<
    T: ConvertibleToBytes & BitwiseCopyable & FixedWidthInteger
  >(
    repeating repeatedValue: T,
    count: Int,
    as type: T.Type,
    _ byteOrder: ByteOrder
  )
  
  @lifetime(copy self)
  func extracting(_ bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: Range<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_ bounds: some RangeExpression<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(unchecked bounds: ClosedRange<Index>) -> Self
  
  @lifetime(copy self)
  func extracting(_: UnboundedRange) -> Self
    
  @lifetime(copy self)
  func extracting(first maxLength: Int) -> Self
  
  @lifetime(copy self)
  func extracting(droppingLast k: Int) -> Self

  @lifetime(copy self)
  func extracting(last maxLength: Int) -> Self

  @lifetime(copy self)
  func extracting(droppingFirst k: Int) -> Self
}
```

The `Iterable` conformance is similar to the other aliased span types, requiring a copy of the bytes:

```swift
extension AliasedMutableRawSpan: Iterable {
  typealias Failure = Never
  var underestimatedCount: Int { get }

  @lifetime(borrow self)
  func makeBorrowingIterator() -> BorrowingIterator
}
```

### Conversions to the aliased span types

An aliased span can be created from its corresponding span type. These operations expressed as either properties or methods on the span type to enable chaining, e.g., `span.aliased.bytes`. `Span` introduces the `aliased` property:

```swift
extension Span where Element: Copyable {
  /// Retrieve an aliased span referencing the same storage.
  @lifetime(copy self)
  var aliased: AliasedSpan<Element> { get }
}
```

For the mutable spans, we need to consume the `MutableSpan` to create the first `AliasedMutableSpan`, otherwise accesses to the original `MutableSpan` (which assumes exclusivity) could overlap the `AliasedMutableSpan` instance that is returned (or a copy thereof).

```swift
extension MutableSpan where Element: Copyable {
  // Retrieve an aliased mutable span from this mutable span.
  consuming func asAliased() -> AliasedMutableSpan<Element>
}
```

The aliased raw spans follow similarly:

```swift
extension RawSpan {
  /// Retrieve an aliased raw span referencing the same bytes.
  @lifetime(copy self)
  var aliased: AliasedRawSpan { get }  
}

extension MutableRawSpan {
  // Retrieve an aliased mutable span from this mutable span.
  consuming func asAliased() -> AliasedMutableRawSpan
}
```

### Conversions from the aliased span types

A span type can be created from its corresponding aliased span type, but doing so is *always unsafe*. While the aliased span types do provide lifetime and bounds safety, they do not ensure the absence of aliases that could modify the storage, undermining the safety of the span.

```swift
extension AliasedSpan {
  // Retrieving a span from an aliased span is an unsafe operation,
  // because one must ensure that the underlying storage is not
  // modified by any code while the span (or any copy derived from it) is
  // in use.
  @unsafe var span: Span<Element> { get } 
}

extension AliasedRawSpan {
  // Retrieving a span from an aliased span is an unsafe operation,
  // because one must ensure that the underlying storage is not
  // modified by any code while the span (or any copy derived from it) is
  // in use.
	@unsafe var rawSpan: RawSpan { get }  
}

extension AliasedMutableSpan {
  // Retrieving a mutable span from an aliased mutable span is an
  // unsafe operation, because one must ensure that the underlying storage
  // and not accessed at all (read or write) while the mutable span is in
  // use.
  @unsafe var mutableSpan: MutableSpan<Element> { get }
}

extension AliasedMutableRawSpan {
  // Retrieving a mutable raw span from an aliased raw mutable span is an
  // unsafe operation, because one must ensure that the underlying storage
  // and not accessed at all (read or write) while the raw mutable span is
  // in use.
  @unsafe var mutableRawSpan: MutableRawSpan { get }
}
```

## Source compatibility

This proposal introduces new types into the Swift standard library, but otherwise has no effect on source compatibility.

## ABI compatibility

This proposal introduces new types into the Swift standard library, which adds to the ABI, but otherwise has no effect on ABI compatibility.

## Implications on adoption

The new `Aliased*Span` family of types is intended to be adopted in places where it is impossible or impractical to ensure non-aliasing, such as the shared-memory and C-interoperability use cases. It is possible that these types will propagate further in the Swift ecosystem than intended, for example because something that is implemented on top of a C library provides `AliasedSpan`-based APIs rather than `Span`-based APIs for convenience (or safety). If this happens, it could lead to confusion about which types should be used, and potentially undermine Swift performance if `AliasedSpan` is used in places where it shouldn't be.

## Alternatives considered

### Don't solve the aliasing problem

Shared memory is somewhat of a niche concern, and it's generally our policy that C interoperability not dictate the direction of the Swift language. We could choose for Swift not to solve the aliasing problem at all, and require any code interacting with shared memory or C pointers to be unsafe. Doing so would limit the places where Swift is applicable in systems programming, as well as undermining the ability to safely interoperate with the C family of languages as expressed in the [strict memory safety vision](https://github.com/swiftlang/swift-evolution/blob/main/visions/memory-safety.md#expressing-memory-safe-interfaces-for-the-c-family-of-languages).

### Teach the existing span family of types to deal with aliasing

Rather than introducing new aliased span types, we could consider loosening the requirements on `Span`, `MutableSpan`, and so on to allow aliasing. However, doing so means that the compromises present in the aliased span family as described in this proposal would become limitations of span: spans wouldn't be able to support non-copyable element types, and would require copy-in/copy-out semantics on access that would degrade their performance.

### Aliased `OutputSpan`

`OutputSpan` concerns the initialization of a memory buffer. It only makes sense if there are no aliases of the underlying storage, or if there is external coordination through a single output span to perform the initialization. Therefore, there is no reason to have an aliasing version.

## Acknowledgments

Geoff Garen identified the core aliasing problem addressed by the aliased span types presented here, and noted the memory safety issues it introduces for Swift. Gábor Horváth comprehensively explored what imposing the Law of Exclusivity would mean for the C family of languages, which directly informed this design and the safe interoperability with C that it enables.
